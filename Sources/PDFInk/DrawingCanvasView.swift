import AppKit
import PDFKit
import PDFInkCore
import UniformTypeIdentifiers
import ImageIO

/// Reads PDF file URLs from Finder drags without relying on pasteboard
/// content-type filtering, which can reject otherwise valid file URL drags.
enum PDFDropSupport {
    static func pdfURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]

        return urls?.first(where: isPDF)
    }

    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .pdf)
    }
}

/// Transparent overlay covering the PDFView. Captures pen/mouse/tablet input,
/// maps it to PDF page space, renders live strokes incrementally, and blits
/// per-page bitmap caches of committed strokes.
///
/// Coordinate model: stroke samples are stored in PDF page space (origin
/// bottom-left, unscaled points). All page↔view mapping goes through
/// PDFView's convert APIs, so strokes stay registered at any zoom level.
final class DrawingCanvasView: NSView {

    weak var pdfView: PDFView?
    let store: StrokeStore
    let toolState: ToolState

    /// Called when a PDF is dropped onto the drawing canvas.
    var onPDFDropped: ((URL) -> Void)?

    /// Called when a color shortcut key (1–5) is pressed; the argument is the
    /// 0-based palette slot (left → right).
    var onColorShortcut: ((Int) -> Void)?

    /// Called when the Image tool becomes active (toolbar, menu or the I key);
    /// the window controller responds by showing the image picker.
    var onImageToolSelected: (() -> Void)?

    /// The palette's current colors (left → right), shown in the color bar that
    /// floats above a lasso selection.
    var paletteColors: () -> [StrokeColor] = { [] }

    // MARK: Live stroke state (page space)
    private var activeSamples: [StrokeSample] = []
    private var activePage: PDFPage?
    private var activePageIndex: Int = -1
    private var lastSampleViewPoints: [CGPoint] = [] // for incremental invalidation
    private var tiltLogCounter = 0

    /// True while the stylus in proximity is the eraser end (set via proximity events).
    private var stylusIsEraserEnd = false
    private var proximityMonitor: Any?

    // Hand tool (hold Space)
    private var spaceHeld = false
    private var isPanning = false
    private var lastPanWindowPoint: CGPoint = .zero
    private var keyMonitor: Any?

    // Lasso
    private enum LassoDrag: Equatable {
        case drawing                        // freehand selection loop
        case move
        case scale(anchor: CGPoint)         // page space: the opposite corner stays fixed
        case rotate(center: CGPoint)        // page space
    }
    private var lassoDrag: LassoDrag?
    private var lassoPath: [CGPoint] = []            // view space, while drawing the loop
    private var lassoPage: PDFPage?
    private var lassoPageIndex = -1
    private var selectedIDs: Set<UUID> = []
    private var selectionPageIndex = -1
    private var dragStartPagePoint: CGPoint = .zero
    private var dragOriginals: [Stroke] = []
    private var dragHasMoved = false

    // MARK: Committed-stroke bitmap caches, one per page
    private final class PageCache {
        let context: CGContext
        var image: CGImage?
        let pageRectInView: CGRect
        let scaleFactor: CGFloat
        init(context: CGContext, pageRectInView: CGRect, scaleFactor: CGFloat) {
            self.context = context
            self.pageRectInView = pageRectInView
            self.scaleFactor = scaleFactor
        }
    }
    private var pageCaches: [Int: PageCache] = [:]

    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Init

    init(pdfView: PDFView, store: StrokeStore, toolState: ToolState) {
        self.pdfView = pdfView
        self.store = store
        self.toolState = toolState
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        // The canvas overlays PDFView, so it must be a drag destination too.
        registerForDraggedTypes([.fileURL])

        proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { [weak self] event in
            self?.handleProximity(event)
            return event
        }
        observePDFViewChanges()
        // The ONE place that enforces the cursor. PDFView (our parent) also sets
        // cursors from its own tracking areas, so we re-apply ours once, after
        // the event has been fully dispatched. Requests are coalesced.
        cursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved,
                       .mouseEntered, .mouseExited, .cursorUpdate, .scrollWheel]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.scheduleCursorRefresh()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 49 { return self.handleSpaceKey(event) }   // Space = hand tool
            // T selects PDF text. Ignore modified shortcuts and typing into
            // text fields so this does not steal normal keyboard input.
            if event.type == .keyDown,
               event.charactersIgnoringModifiers?.lowercased() == "t",
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !(self.window?.firstResponder is NSTextView) {
                self.toolState.isTextSelectionEnabled.toggle()
                return nil
            }
            return self.handleToolShortcut(event)                          // Z / X / C
        }
        // If the window loses focus while Space is held, the key-up never arrives.
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSWindow) === self.window, self.spaceHeld else { return }
            self.isPanning = false
            self.setSpaceHeld(false)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let proximityMonitor { NSEvent.removeMonitor(proximityMonitor) }
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// Returning nil lets PDFView receive mouse events instead of the overlay.
    /// This is intentionally all-or-nothing: pen/eraser/lasso input remains
    /// untouched whenever Text Select is not the active tool.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !toolState.isTextSelectionEnabled else { return nil }
        return super.hitTest(point)
    }

    // MARK: - PDF drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PDFDropSupport.pdfURL(from: sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PDFDropSupport.pdfURL(from: sender) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PDFDropSupport.pdfURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = PDFDropSupport.pdfURL(from: sender) else {
            return false
        }

        onPDFDropped?(url)
        return true
    }

    func storeDidChange(pageIndex: Int) {
        invalidateCache(forPage: pageIndex)
        if pageIndex == selectionPageIndex {                       // drop selected ids that no longer exist
            let existing = Set(store.strokes(onPage: pageIndex).map(\.id))
            selectedIDs = selectedIDs.intersection(existing)
            if selectedIDs.isEmpty { selectionPageIndex = -1 }
        }
        needsDisplay = true
    }

    func storeStructureDidChange() {
        clearSelection()
        invalidateAllCaches()
    }

    /// The palette changed (a slot was edited): refresh the selection's color bar.
    func paletteDidChange() {
        if !selectedIDs.isEmpty { needsDisplay = true }
    }

    func toolStateDidChange() {
        if toolState.tool != .lasso, !selectedIDs.isEmpty { clearSelection() }
        if toolState.tool == .image { onImageToolSelected?() }
        window?.invalidateCursorRects(for: self)
        scheduleCursorRefresh()
    }

    // MARK: - PDFView observation

    private func observePDFViewChanges() {
        guard let pdfView else { return }
        let nc = NotificationCenter.default

        notificationTokens.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.invalidateAllCaches()
        })
        notificationTokens.append(nc.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.invalidateAllCaches()
        })
        notificationTokens.append(nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.evictOffscreenCaches()
            self?.needsDisplay = true
        })
        // PDFView hosts an internal NSScrollView; observe scrolling so the
        // overlay re-blits its caches at the new offsets.
        if let scrollView = Self.findScrollView(in: pdfView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            notificationTokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification,
                                                     object: scrollView.contentView, queue: .main) { [weak self] _ in
                // Scrolling moves pages under the static overlay; page rects in
                // view space change, so cached placements must be recomputed.
                self?.invalidateAllCaches()
            })
        } else {
            NSLog("PDFInk: WARNING - couldn't find PDFView's scroll view; scroll redraw may lag")
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Cache management

    private func invalidateAllCaches() {
        pageCaches.removeAll()
        needsDisplay = true
    }

    private func invalidateCache(forPage pageIndex: Int) {
        pageCaches.removeValue(forKey: pageIndex)
    }

    private func evictOffscreenCaches() {
        guard let pdfView, let document = pdfView.document else { return }
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) })
        pageCaches = pageCaches.filter { visible.contains($0.key) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    /// Builds (or returns) the bitmap cache of committed strokes for a page.
    private func cache(forPage pageIndex: Int, page: PDFPage) -> PageCache? {
        guard let pdfView else { return nil }
        let pageRect = pageRectInView(for: page)
        if let existing = pageCaches[pageIndex],
           existing.pageRectInView == pageRect,
           existing.scaleFactor == pdfView.scaleFactor {
            return existing
        }
        let bscale = backingScale
        let pixelW = Int((pageRect.width * bscale).rounded(.up))
        let pixelH = Int((pageRect.height * bscale).rounded(.up))
        guard pixelW > 0, pixelH > 0, pixelW < 12000, pixelH < 12000,
              let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Page space → bitmap pixels: apply page→view transform, shift the page
        // rect to the origin, then scale up to backing pixels.
        ctx.scaleBy(x: bscale, y: bscale)
        ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        ctx.concatenate(pageToViewTransform(for: page))

        for stroke in store.strokes(onPage: pageIndex) {
            StrokeRenderer.draw(stroke, in: ctx)
        }

        let cache = PageCache(context: ctx, pageRectInView: pageRect, scaleFactor: pdfView.scaleFactor)
        cache.image = ctx.makeImage()
        pageCaches[pageIndex] = cache
        return cache
    }

    // MARK: - Coordinate mapping

    private func pageRectInView(for page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        let bounds = page.bounds(for: pdfView.displayBox)
        let rectInPDFView = pdfView.convert(bounds, from: page)
        return convert(rectInPDFView, from: pdfView)
    }

    /// Exact affine transform mapping page space → overlay view space, derived
    /// from three reference points so scale/translation/rotation/flip are all
    /// captured. (Unit-testable core in StrokeGeometry.affineTransform.)
    private func pageToViewTransform(for page: PDFPage) -> CGAffineTransform {
        func toView(_ p: CGPoint) -> CGPoint {
            guard let pdfView else { return p }
            return convert(pdfView.convert(p, from: page), from: pdfView)
        }
        return StrokeGeometry.affineTransform(mappingOrigin: toView(.zero),
                                              unitX: toView(CGPoint(x: 1, y: 0)),
                                              unitY: toView(CGPoint(x: 0, y: 1)))
    }

    private func viewToPage(_ viewPoint: CGPoint, page: PDFPage) -> CGPoint {
        guard let pdfView else { return viewPoint }
        return pdfView.convert(convert(viewPoint, to: pdfView), to: page)
    }

    private func pageToView(_ pagePoint: CGPoint, page: PDFPage) -> CGPoint {
        guard let pdfView else { return pagePoint }
        return convert(pdfView.convert(pagePoint, from: page), from: pdfView)
    }

    private func page(at viewPoint: CGPoint) -> (PDFPage, Int)? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let pointInPDFView = convert(viewPoint, to: pdfView)
        guard let page = pdfView.page(for: pointInPDFView, nearest: false) else { return nil }
        return (page, document.index(for: page))
    }

    // MARK: - Input

    /// Event location in this view's coordinates. Handles windowless events
    /// (e.g. NSEvent(cgEvent:) wrappers), whose locationInWindow is in screen
    /// coordinates.
    private func viewPoint(for event: NSEvent) -> CGPoint {
        if event.window === window {
            return convert(event.locationInWindow, from: nil)
        }
        guard let window else { return .zero }
        let inWindow = window.convertPoint(fromScreen: event.locationInWindow)
        return convert(inWindow, from: nil)
    }

    private func pressure(for event: NSEvent) -> CGFloat {
        if event.subtype == .tabletPoint {
            return CGFloat(max(0, min(1, event.pressure)))
        }
        return 0.5 // constant fallback for mouse/trackpad
    }

    private func logTiltIfTablet(_ event: NSEvent) {
        guard event.subtype == .tabletPoint else { return }
        tiltLogCounter += 1
        if tiltLogCounter % 60 == 1 {
            let tilt = event.tilt
            NSLog("PDFInk: tablet tilt x=%.3f y=%.3f pressure=%.3f", tilt.x, tilt.y, event.pressure)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {                                   // NEW
            isPanning = true                             // NEW
            lastPanWindowPoint = convert(viewPoint(for: event), to: nil)   // NEW
            return                                       // NEW
        }                                                // NEW
        guard pdfView?.document != nil else { return }
        let viewPoint = viewPoint(for: event)
        // Clicks on the selection's color bar recolor the selected strokes.
        if toolState.tool == .lasso, !stylusIsEraserEnd, lassoDrag == nil,
           handleColorBarClick(at: viewPoint) { return }
        guard let (page, pageIndex) = page(at: viewPoint) else { return }

        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool
        switch effectiveTool {
        case .eraser:
            erase(at: viewPoint, page: page, pageIndex: pageIndex)
        case .lasso:
            beginLasso(at: viewPoint, page: page, pageIndex: pageIndex)
        case .image:
            return          // the picker is already showing; nothing to draw
        case .pen, .highlighter:
            activePage = page
            activePageIndex = pageIndex
            activeSamples = [StrokeSample(point: viewToPage(viewPoint, page: page),
                                          pressure: pressure(for: event))]
            lastSampleViewPoints = [viewPoint]
        }
        logTiltIfTablet(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning { pan(with: event); return }        // NEW
        let viewPoint = viewPoint(for: event)
        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool

        if lassoDrag != nil { lassoDragged(to: viewPoint); return }

        if effectiveTool == .eraser {
            if let (page, pageIndex) = page(at: viewPoint) {
                erase(at: viewPoint, page: page, pageIndex: pageIndex)
            }
            return
        }
        guard let activePage else { return }

        let pagePoint = viewToPage(viewPoint, page: activePage)
        // Drop near-duplicate points from high-frequency tablet input.
        if let last = activeSamples.last,
           StrokeGeometry.squaredDistance(last.point, pagePoint) < 0.12 {
            return
        }
        activeSamples.append(StrokeSample(point: pagePoint, pressure: pressure(for: event)))
        logTiltIfTablet(event)

        lastSampleViewPoints.append(viewPoint)
        if lastSampleViewPoints.count > 5 { lastSampleViewPoints.removeFirst() }
        setNeedsDisplay(invalidationRect(around: lastSampleViewPoints))
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {                                   // NEW
            isPanning = false                            // NEW
            return                                       // NEW
        }

        if lassoDrag != nil { lassoEnded(); return }        // NEW

        defer {
            activeSamples = []
            activePage = nil
            activePageIndex = -1
            lastSampleViewPoints = []
        }
        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool
        guard effectiveTool == .pen || effectiveTool == .highlighter,
              activePage != nil, !activeSamples.isEmpty else { return }

        let stroke = Stroke(tool: effectiveTool,
                            color: toolState.color,
                            baseWidth: toolState.baseWidth,
                            pageIndex: activePageIndex,
                            samples: activeSamples,
                            opacity: effectiveTool == .highlighter ? toolState.highlighterOpacity : nil)
        performAdd(stroke)
    }

    private func invalidationRect(around viewPoints: [CGPoint]) -> CGRect {
        guard let first = viewPoints.first else { return bounds }
        var rect = CGRect(origin: first, size: .zero)
        for p in viewPoints.dropFirst() {
            rect = rect.union(CGRect(origin: p, size: .zero))
        }
        let scale = pdfView?.scaleFactor ?? 1
        let pad = StrokeGeometry.width(forPressure: 1, baseWidth: toolState.baseWidth, tool: toolState.tool) * scale + 4
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Zoom (pinch)

    override func magnify(with event: NSEvent) {
        guard let pdfView else { return }
        let newScale = pdfView.scaleFactor * (1.0 + event.magnification)
        pdfView.scaleFactor = min(max(newScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    // MARK: - Eraser (stroke-level)

    private func erase(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) {
        let pagePoint = viewToPage(viewPoint, page: page)
        // ~8 screen points of tolerance, expressed in page space.
        let tolerance = 8.0 / max(pdfView?.scaleFactor ?? 1, 0.01)
        // Images are removed via lasso ▸ Delete, so ink scrubbed over a picture leaves it intact.
        while let hit = store.hitTest(point: pagePoint, pageIndex: pageIndex,
                                      tolerance: tolerance, includeImages: false) {
            performRemove(strokeID: hit.id, pageIndex: pageIndex, actionName: "Erase Stroke")
        }
    }

    // MARK: - Mutations with undo

    func performAdd(_ stroke: Stroke, actionName: String = "Draw Stroke") {
        store.add(stroke)
        undoManager?.registerUndo(withTarget: self) { target in
            target.performRemove(strokeID: stroke.id, pageIndex: stroke.pageIndex, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    func performRemove(strokeID: UUID, pageIndex: Int, actionName: String) {
        guard let index = store.index(of: strokeID, pageIndex: pageIndex),
              let stroke = store.remove(id: strokeID, pageIndex: pageIndex) else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.performInsert(stroke, at: index, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    func performInsert(_ stroke: Stroke, at index: Int, actionName: String) {
        store.insert(stroke, at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            target.performRemove(strokeID: stroke.id, pageIndex: stroke.pageIndex, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Proximity (eraser flip)

    private func handleProximity(_ event: NSEvent) {
        if event.isEnteringProximity {
            stylusIsEraserEnd = (event.pointingDeviceType == .eraser)
            NSLog("PDFInk: stylus entered proximity, device=%@",
                  stylusIsEraserEnd ? "eraser-end" : "pen-tip")
            toolState.stylusEnteredProximity(isEraserEnd: stylusIsEraserEnd)
        } else {
            NSLog("PDFInk: stylus left proximity")
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let document = pdfView.document,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        for page in pdfView.visiblePages {
            let pageIndex = document.index(for: page)
            let pageRect = pageRectInView(for: page)
            guard pageRect.intersects(dirtyRect) else { continue }

            // Committed strokes: blit the per-page bitmap cache.
            if !store.strokes(onPage: pageIndex).isEmpty,
               let cache = cache(forPage: pageIndex, page: page),
               let image = cache.image {
                ctx.saveGState()
                ctx.clip(to: pageRect)
                ctx.draw(image, in: pageRect)
                ctx.restoreGState()
            }

            // Live stroke on top (vector, clipped to the dirty region).
            if pageIndex == activePageIndex, !activeSamples.isEmpty {
                ctx.saveGState()
                ctx.clip(to: pageRect.intersection(dirtyRect))
                ctx.concatenate(pageToViewTransform(for: page))
                let liveTool: Tool = stylusIsEraserEnd ? .pen : toolState.tool
                let live = Stroke(tool: liveTool,
                                  color: toolState.color,
                                  baseWidth: toolState.baseWidth,
                                  pageIndex: pageIndex,
                                  samples: activeSamples,
                                  opacity: liveTool == .highlighter ? toolState.highlighterOpacity : nil)
                StrokeRenderer.draw(live, in: ctx)
                ctx.restoreGState()
            }
        }
        drawLassoOverlay()
    }

    // MARK: - Hand tool (hold Space to pan)

    /// Returns nil to swallow the event so PDFView never does its "page down" on Space.
    private func handleSpaceKey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49 else { return event }          // 49 = Space

        if event.type == .keyUp {
            guard spaceHeld else { return event }
            setSpaceHeld(false)
            return nil
        }

        if spaceHeld { return nil }                              // swallow key auto-repeat
        guard let window, window.isKeyWindow, event.window === window,
              !(window.firstResponder is NSTextView),            // typing in the hex/page-size fields
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              pdfView?.document != nil,
              activePage == nil                                  // don't interrupt a stroke
        else { return event }

        setSpaceHeld(true)
        return nil
    }

    /// Z pen, X eraser, C highlighter, V lasso, I image, 1–5 palette colors (left → right).
    /// With a lasso selection: Delete/Backspace/X delete it, Esc deselects.
    private func handleToolShortcut(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let tool: Tool?
        var colorSlot: Int?
        switch event.keyCode {
        case 6: tool = .pen            // Z
        case 7: tool = .eraser         // X
        case 8: tool = .highlighter    // C
        case 9: tool = .lasso          // V
        case 34: tool = .image         // I
        case 18: tool = nil; colorSlot = 0   // 1
        case 19: tool = nil; colorSlot = 1   // 2
        case 20: tool = nil; colorSlot = 2   // 3
        case 21: tool = nil; colorSlot = 3   // 4
        case 23: tool = nil; colorSlot = 4   // 5
        case 51, 117, 53: tool = nil   // Delete, Forward Delete, Esc
        default: return event
        }
        guard let window, window.isKeyWindow, event.window === window,
              !(window.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              activePage == nil, lassoDrag == nil, !spaceHeld
        else { return event }

        if let colorSlot {
            if !event.isARepeat { onColorShortcut?(colorSlot) }
            return nil
        }

        let hasSelection = !selectedStrokes.isEmpty
        switch event.keyCode {
        case 7 where hasSelection, 51 where hasSelection, 117 where hasSelection:
            if !event.isARepeat { deleteSelection() }
            return nil
        case 53 where hasSelection:
            clearSelection()
            return nil
        default: break
        }
        guard let tool else { return event }      // Delete/Esc with no selection: pass through
        if !event.isARepeat { toolState.tool = tool }
        return nil
    }

    private func setSpaceHeld(_ held: Bool) {
        spaceHeld = held
        window?.invalidateCursorRects(for: self)
        scheduleCursorRefresh()
    }

    private func pan(with event: NSEvent) {
        guard let pdfView, let scrollView = Self.findScrollView(in: pdfView) else { return }
        let clip = scrollView.contentView
        let current = convert(viewPoint(for: event), to: nil)     // window coordinates (don't scroll)
        let before = clip.convert(lastPanWindowPoint, from: nil)
        let after = clip.convert(current, from: nil)
        lastPanWindowPoint = current

        var origin = clip.bounds.origin
        origin.x -= (after.x - before.x)                          // content follows the pen
        origin.y -= (after.y - before.y)
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Lasso select / transform

    private var selectedStrokes: [Stroke] {
        guard selectionPageIndex >= 0 else { return [] }
        return store.strokes(onPage: selectionPageIndex).filter { selectedIDs.contains($0.id) }
    }

    private func clearSelection() {
        selectedIDs = []
        selectionPageIndex = -1
        lassoDrag = nil
        lassoPath = []
        needsDisplay = true
    }

    private func deleteSelection() {
        let victims = selectedStrokes
        let pageIndex = selectionPageIndex
        selectedIDs = []
        selectionPageIndex = -1
        for s in victims {
            performRemove(strokeID: s.id, pageIndex: pageIndex, actionName: "Delete Selection")
        }
        needsDisplay = true
    }

    private struct SelectionGeometry {
        var corners: [CGPoint]        // view space: bottom-left, bottom-right, top-right, top-left
        var center: CGPoint
        var topMid: CGPoint
        var rotateHandle: CGPoint
    }

    private func selectionGeometry(page: PDFPage) -> SelectionGeometry? {
        let strokes = selectedStrokes
        guard var rect = strokes.first?.pageBounds, !rect.isNull else { return nil }
        for s in strokes.dropFirst() { rect = rect.union(s.pageBounds) }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { pageToView($0, page: page) }
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let topMid = CGPoint(x: (corners[2].x + corners[3].x) / 2, y: (corners[2].y + corners[3].y) / 2)
        let dx = topMid.x - center.x, dy = topMid.y - center.y
        let len = max(hypot(dx, dy), 1)
        let handle = CGPoint(x: topMid.x + dx / len * 24, y: topMid.y + dy / len * 24)
        return SelectionGeometry(corners: corners, center: center, topMid: topMid, rotateHandle: handle)
    }

    private static func polygonContains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        StrokeGeometry.polygon(poly, contains: p)
    }

    private func lassoHit(_ p: CGPoint, page: PDFPage) -> LassoDrag? {
        guard let g = selectionGeometry(page: page) else { return nil }
        let r = Self.handleHitRadius
        func near(_ a: CGPoint) -> Bool { hypot(a.x - p.x, a.y - p.y) <= r }
        if near(g.rotateHandle) { return .rotate(center: viewToPage(g.center, page: page)) }
        for i in 0..<4 where near(g.corners[i]) {
            return .scale(anchor: viewToPage(g.corners[(i + 2) % 4], page: page))
        }
        if Self.polygonContains(g.corners, p) { return .move }
        return nil
    }

    private func beginLasso(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) {
        if selectionPageIndex == pageIndex, let hit = lassoHit(viewPoint, page: page) {
            lassoDrag = hit
            dragStartPagePoint = viewToPage(viewPoint, page: page)
            dragOriginals = selectedStrokes
            dragHasMoved = false
            return
        }
        clearSelection()
        lassoDrag = .drawing
        lassoPage = page
        lassoPageIndex = pageIndex
        lassoPath = [viewPoint]
    }

    private func lassoDragged(to viewPoint: CGPoint) {
        guard let drag = lassoDrag else { return }
        if drag == .drawing {
            if let last = lassoPath.last, hypot(viewPoint.x - last.x, viewPoint.y - last.y) < 2 { return }
            lassoPath.append(viewPoint)
            needsDisplay = true
            return
        }
        guard let page = pdfView?.document?.page(at: selectionPageIndex) else { return }
        let p = viewToPage(viewPoint, page: page)
        var widthScale: CGFloat = 1
        let t: CGAffineTransform
        switch drag {
        case .move:
            t = CGAffineTransform(translationX: p.x - dragStartPagePoint.x, y: p.y - dragStartPagePoint.y)
        case .scale(let a):
            let d0 = hypot(dragStartPagePoint.x - a.x, dragStartPagePoint.y - a.y)
            let d1 = hypot(p.x - a.x, p.y - a.y)
            let f = min(max(d1 / max(d0, 1), 0.05), 20)
            widthScale = f
            t = CGAffineTransform(translationX: a.x, y: a.y).scaledBy(x: f, y: f).translatedBy(x: -a.x, y: -a.y)
        case .rotate(let c):
            let a0 = atan2(dragStartPagePoint.y - c.y, dragStartPagePoint.x - c.x)
            let a1 = atan2(p.y - c.y, p.x - c.x)
            t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a1 - a0).translatedBy(x: -c.x, y: -c.y)
        case .drawing:
            return
        }
        // Always transform from the originals, so there is no drift while dragging.
        for s in dragOriginals { store.replace(s.applying(t, widthScale: widthScale)) }
        dragHasMoved = true
    }

    private func lassoEnded() {
        guard let drag = lassoDrag else { return }
        lassoDrag = nil
        if drag == .drawing {
            finishLassoSelection()
        } else if dragHasMoved {
            registerReplace(old: dragOriginals, new: selectedStrokes, actionName: "Transform Selection")
        }
        dragOriginals = []
        dragHasMoved = false
        needsDisplay = true
    }

    private func finishLassoSelection() {
        defer { lassoPath = []; lassoPage = nil; needsDisplay = true }
        guard let page = lassoPage, let first = lassoPath.first else { return }
        let pageIndex = lassoPageIndex

        let xs = lassoPath.map(\.x), ys = lassoPath.map(\.y)
        let diagonal = hypot((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))

        if diagonal < 5 {   // a tap: select the stroke under the pointer
            let tolerance = 6.0 / max(pdfView?.scaleFactor ?? 1, 0.01)
            if let hit = store.hitTest(point: viewToPage(first, page: page), pageIndex: pageIndex, tolerance: tolerance) {
                selectedIDs = [hit.id]
                selectionPageIndex = pageIndex
            }
            return
        }
        guard lassoPath.count >= 3 else { return }

        let polygon = lassoPath.map { viewToPage($0, page: page) }
        let chosen = store.strokes(onPage: pageIndex).filter { stroke in
            guard !stroke.samples.isEmpty else { return false }
            let inside = stroke.samples.filter { Self.polygonContains(polygon, $0.point) }.count
            if stroke.tool == .image {
                // An image counts when its center or at least half its corners are in the loop.
                let n = CGFloat(stroke.samples.count)
                let center = CGPoint(x: stroke.samples.map(\.point.x).reduce(0, +) / n,
                                     y: stroke.samples.map(\.point.y).reduce(0, +) / n)
                return Self.polygonContains(polygon, center) || Double(inside) / Double(stroke.samples.count) >= 0.5
            }
            return Double(inside) / Double(stroke.samples.count) >= 0.5      // selection threshold
        }
        selectedIDs = Set(chosen.map(\.id))
        selectionPageIndex = chosen.isEmpty ? -1 : pageIndex
    }

    // MARK: - Image import

    /// Longest edge, in pixels, an imported image is downscaled to (keeps the
    /// autosave draft and the saved PDF annotation a sane size).
    private static let maxImportPixels: CGFloat = 2048

    /// Places the image at `url` on the page in view, centered in the visible
    /// area, then switches to the lasso with the image selected so it can be
    /// moved, scaled (corner handles) or rotated straight away. One undo step.
    @discardableResult
    func importImage(from url: URL) -> Bool {
        guard let pdfView, let document = pdfView.document,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }

        // Page under the middle of the visible area, else the current page.
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let located = page(at: viewCenter)
        guard let page = located?.0 ?? pdfView.currentPage ?? document.page(at: 0) else { return false }
        let pageIndex = document.index(for: page)

        // Downscale huge images and re-encode as PNG (keeps transparency).
        let longest = CGFloat(max(decoded.width, decoded.height))
        var cgImage = decoded
        if longest > Self.maxImportPixels {
            let f = Self.maxImportPixels / longest
            let w = max(Int((CGFloat(decoded.width) * f).rounded()), 1)
            let h = max(Int((CGFloat(decoded.height) * f).rounded()), 1)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { cgImage = scaled }
            }
        }
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            return false
        }

        // Natural size (1 px = 1 pt), shrunk to fit within 60% of the page.
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let natural = CGSize(width: cgImage.width, height: cgImage.height)
        let fit = min(1, 0.6 * pageBounds.width / natural.width, 0.6 * pageBounds.height / natural.height)
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)

        var center = located != nil ? viewToPage(viewCenter, page: page)
                                    : CGPoint(x: pageBounds.midX, y: pageBounds.midY)
        center.x = min(max(center.x, pageBounds.minX + size.width / 2), pageBounds.maxX - size.width / 2)
        center.y = min(max(center.y, pageBounds.minY + size.height / 2), pageBounds.maxY - size.height / 2)

        let item = Stroke.image(data: png, pageIndex: pageIndex, center: center, size: size)
        toolState.tool = .lasso                      // clears any old selection via toolStateDidChange
        clearSelection()
        performAdd(item, actionName: "Import Image")
        selectedIDs = [item.id]
        selectionPageIndex = pageIndex
        needsDisplay = true
        return true
    }

    // MARK: - Selection color bar

    private static let barSwatchDiameter: CGFloat = 22
    private static let barSwatchSpacing: CGFloat = 8
    private static let barPadding: CGFloat = 10

    private static func sameColor(_ a: StrokeColor, _ b: StrokeColor) -> Bool {
        abs(a.red - b.red) < 0.005 && abs(a.green - b.green) < 0.005 && abs(a.blue - b.blue) < 0.005
    }

    /// Palette slot matching the selection's color: only when every selected
    /// stroke has the same color and that color is one of the palette colors.
    private var selectionPaletteSlot: Int? {
        let strokes = selectedStrokes.filter { $0.tool != .image }
        guard let first = strokes.first,
              strokes.allSatisfy({ Self.sameColor($0.color, first.color) }) else { return nil }
        return paletteColors().firstIndex { Self.sameColor($0, first.color) }
    }

    /// Frame of the color bar: centered horizontally above the selection box
    /// (above the rotate handle). If there's no room above it goes below, and it
    /// is always kept inside the canvas.
    private func colorBarRect(for g: SelectionGeometry) -> CGRect? {
        // Images have no ink color: a selection of only images gets no color bar.
        guard selectedStrokes.contains(where: { $0.tool != .image }) else { return nil }
        let count = paletteColors().count
        guard count > 0 else { return nil }
        let n = CGFloat(count)
        let width = n * Self.barSwatchDiameter + (n - 1) * Self.barSwatchSpacing + 2 * Self.barPadding
        let height = Self.barSwatchDiameter + 2 * Self.barPadding
        let points = g.corners + [g.rotateHandle]
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }

        var rect = CGRect(x: (minX + maxX) / 2 - width / 2, y: maxY + 14, width: width, height: height)
        if rect.maxY > bounds.maxY - 4 { rect.origin.y = minY - 14 - height }   // no room above
        rect.origin.x = min(max(rect.origin.x, bounds.minX + 4), max(bounds.maxX - width - 4, bounds.minX + 4))
        rect.origin.y = min(max(rect.origin.y, bounds.minY + 4), max(bounds.maxY - height - 4, bounds.minY + 4))
        return rect
    }

    private func currentColorBarRect() -> CGRect? {
        guard selectionPageIndex >= 0,
              let page = pdfView?.document?.page(at: selectionPageIndex),
              let g = selectionGeometry(page: page) else { return nil }
        return colorBarRect(for: g)
    }

    private func swatchRect(_ index: Int, in bar: CGRect) -> CGRect {
        CGRect(x: bar.minX + Self.barPadding + CGFloat(index) * (Self.barSwatchDiameter + Self.barSwatchSpacing),
               y: bar.minY + Self.barPadding,
               width: Self.barSwatchDiameter, height: Self.barSwatchDiameter)
    }

    /// Returns true if the click landed on the bar (and was handled).
    private func handleColorBarClick(at point: CGPoint) -> Bool {
        guard let bar = currentColorBarRect(), bar.contains(point) else { return false }
        for (index, color) in paletteColors().enumerated()
        where swatchRect(index, in: bar).insetBy(dx: -4, dy: -4).contains(point) {
            recolorSelection(to: color)
            break
        }
        return true   // clicks on the bar's padding are swallowed too
    }

    /// Gives every selected stroke `color` as one undoable step. Selected images are left untouched.
    private func recolorSelection(to color: StrokeColor) {
        let old = selectedStrokes.filter { $0.tool != .image }
        guard !old.isEmpty else { return }
        let new = old.map { stroke -> Stroke in
            var recolored = stroke
            recolored.color = color
            return recolored
        }
        guard new != old else { return }
        new.forEach { store.replace($0) }
        registerReplace(old: old, new: new, actionName: "Change Color")
        needsDisplay = true
    }

    private func drawColorBar(for g: SelectionGeometry) {
        guard let bar = colorBarRect(for: g) else { return }
        let box = NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.10, alpha: 0.96).setFill()
        box.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        box.lineWidth = 1
        box.stroke()

        let selected = selectionPaletteSlot
        for (index, color) in paletteColors().enumerated() {
            let rect = swatchRect(index, in: bar)
            let circle = NSBezierPath(ovalIn: rect)
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            circle.fill()
            // Thin outline keeps dark colors visible on the dark box.
            NSColor.white.withAlphaComponent(0.45).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if index == selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3.5, dy: -3.5))
                NSColor.white.setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    // Undo for transforms: swap between two sets of stroke versions.
    private func registerReplace(old: [Stroke], new: [Stroke], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyReplace(strokes: old, undoTo: new, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func applyReplace(strokes: [Stroke], undoTo other: [Stroke], actionName: String) {
        strokes.forEach { store.replace($0) }
        registerReplace(old: other, new: strokes, actionName: actionName)
    }

    private func drawLassoOverlay() {
        let accent = NSColor.controlAccentColor

        if lassoDrag == .drawing, lassoPath.count > 1 {
            let path = NSBezierPath()
            path.move(to: lassoPath[0])
            for p in lassoPath.dropFirst() { path.line(to: p) }
            path.close()
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            accent.setStroke()
            path.stroke()
        }

        guard selectionPageIndex >= 0,
              let page = pdfView?.document?.page(at: selectionPageIndex),
              let g = selectionGeometry(page: page) else { return }

        let box = NSBezierPath()
        box.move(to: g.corners[0])
        for c in g.corners.dropFirst() { box.line(to: c) }
        box.close()
        box.lineWidth = 1
        box.setLineDash([4, 3], count: 2, phase: 0)
        accent.setStroke()
        box.stroke()

        let stem = NSBezierPath()
        stem.move(to: g.topMid)
        stem.line(to: g.rotateHandle)
        stem.lineWidth = 1
        stem.stroke()

        func handle(at p: CGPoint, round: Bool) {
            let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            let shape = round ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            NSColor.white.setFill()
            shape.fill()
            shape.lineWidth = 1.5
            accent.setStroke()
            shape.stroke()
        }
        g.corners.forEach { handle(at: $0, round: false) }
        handle(at: g.rotateHandle, round: true)
        drawColorBar(for: g)
    }

    // MARK: - Cursor

    private var trackingArea: NSTrackingArea?
    private var cursorMonitor: Any?
    private var cursorRefreshPending = false

    /// Hit radius (view points) of the lasso's corner / rotate handles.
    private static let handleHitRadius: CGFloat = 11

    /// Asks for the cursor to be re-applied once, after the current event has
    /// finished dispatching. Any number of calls within one run-loop turn
    /// collapse into a single `set()`, so PDFView's own cursor changes can't
    /// interleave with ours and cause flicker.
    private func scheduleCursorRefresh() {
        guard !cursorRefreshPending else { return }
        cursorRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cursorRefreshPending = false
            self.applyCursor()
        }
    }

    private func applyCursor() {
        guard let window, window.isKeyWindow else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let p = convert(mouseInWindow, from: nil)
        let dragging = lassoDrag != nil || activePage != nil || isPanning
        if !dragging {
            guard bounds.contains(p) else { return }
            // Don't claim the cursor over controls floating above the canvas
            // (undo/redo pill, etc.).
            if let content = window.contentView, let pdfView {
                let inSuperview = content.superview?.convert(mouseInWindow, from: nil) ?? mouseInWindow
                if let hit = content.hitTest(inSuperview), hit !== self, !hit.isDescendant(of: pdfView) {
                    return
                }
            }
        }
        cursor(at: p).set()
    }

    /// Circle cursor: white outer ring + dark inner ring so it's visible on any background.
    private static let circleCursor: NSCursor = {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            let outer = NSBezierPath(ovalIn: r)
            outer.lineWidth = 3
            NSColor.white.withAlphaComponent(0.9).setStroke()
            outer.stroke()
            let inner = NSBezierPath(ovalIn: r)
            inner.lineWidth = 1.2
            NSColor.black.setStroke()
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    /// Resize cursor: a "+" whose four arms each end in an arrowhead.
    /// White halo under a black body so it reads on any background.
    private static let resizeCursor: NSCursor = {
        let size: CGFloat = 24
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let reach: CGFloat = 10.5   // center → arrow tip
            let head: CGFloat = 5       // arrowhead length
            let half: CGFloat = 3.2     // arrowhead half-width
            let directions: [(CGFloat, CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

            let shape = NSBezierPath()
            for (dx, dy) in directions {
                let tip = CGPoint(x: c.x + dx * reach, y: c.y + dy * reach)
                let base = CGPoint(x: c.x + dx * (reach - head), y: c.y + dy * (reach - head))
                shape.move(to: c)                       // arm
                shape.line(to: base)
                shape.move(to: tip)                     // arrowhead
                shape.line(to: CGPoint(x: base.x - dy * half, y: base.y + dx * half))
                shape.line(to: CGPoint(x: base.x + dy * half, y: base.y - dx * half))
                shape.close()
            }
            shape.lineJoinStyle = .miter

            NSColor.white.withAlphaComponent(0.95).setStroke()
            NSColor.white.withAlphaComponent(0.95).setFill()
            shape.lineWidth = 3.2
            shape.stroke()
            shape.fill()

            NSColor.black.setStroke()
            NSColor.black.setFill()
            shape.lineWidth = 1.2
            shape.stroke()
            shape.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    /// True when `p` (view space) is over one of the selection's corner scale handles.
    private func isOverScaleHandle(_ p: CGPoint) -> Bool {
        guard selectionPageIndex >= 0,
              let page = pdfView?.document?.page(at: selectionPageIndex),
              let g = selectionGeometry(page: page) else { return false }
        return g.corners.contains { hypot($0.x - p.x, $0.y - p.y) <= Self.handleHitRadius }
    }

    /// Cursor for the current tool/state, and for `p` when hovering a handle.
    private func cursor(at p: CGPoint) -> NSCursor {
        if spaceHeld { return isPanning ? .closedHand : .openHand }
        if toolState.isTextSelectionEnabled { return .iBeam }
        if let drag = lassoDrag, case .scale = drag { return Self.resizeCursor }   // stays while resizing
        if lassoDrag == nil, !stylusIsEraserEnd, toolState.tool == .lasso, isOverScaleHandle(p) {
            return Self.resizeCursor
        }
        return baseCursor
    }

    /// Position-independent cursor for the current tool (used for the cursor rect).
    private var baseCursor: NSCursor {
        if spaceHeld { return isPanning ? .closedHand : .openHand }
        if toolState.isTextSelectionEnabled { return .iBeam }
        return toolState.tool == .eraser ? .disappearingItem : Self.circleCursor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // The cursor rect keeps PDFView's own cursor rects (I-beam over text, etc.)
    // from winning underneath us; the precise cursor is applied by applyCursor().
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: baseCursor)
    }

    override func cursorUpdate(with event: NSEvent) { scheduleCursorRefresh() }
    override func mouseMoved(with event: NSEvent)   { scheduleCursorRefresh() }
    override func mouseEntered(with event: NSEvent) { scheduleCursorRefresh() }
}
