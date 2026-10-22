import AppKit
import PDFKit
import PDFInkCore
import UniformTypeIdentifiers

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
        cursorMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(p) {
                DispatchQueue.main.async { [weak self] in self?.activeCursor.set() }
            }
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

    func toolStateDidChange() {
        if toolState.tool != .lasso, !selectedIDs.isEmpty { clearSelection() }
        window?.invalidateCursorRects(for: self)
        activeCursor.set()
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
            activeCursor.set()                           // NEW
            return                                       // NEW
        }                                                // NEW
        reassertCursor()
        guard pdfView?.document != nil else { return }
        let viewPoint = viewPoint(for: event)
        guard let (page, pageIndex) = page(at: viewPoint) else { return }

        let effectiveTool = stylusIsEraserEnd ? .eraser : toolState.tool
        switch effectiveTool {
        case .eraser:
            erase(at: viewPoint, page: page, pageIndex: pageIndex)
        case .lasso:
            beginLasso(at: viewPoint, page: page, pageIndex: pageIndex)
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
        reassertCursor()
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
            reassertCursor()                             // NEW
            return                                       // NEW
        }

        if lassoDrag != nil { lassoEnded(); return }        // NEW
        reassertCursor()

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
        while let hit = store.hitTest(point: pagePoint, pageIndex: pageIndex, tolerance: tolerance) {
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

    /// Z pen, X eraser, C highlighter, V lasso. With a lasso selection: Delete/Backspace/X delete it, Esc deselects.
    private func handleToolShortcut(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let tool: Tool?
        switch event.keyCode {
        case 6: tool = .pen            // Z
        case 7: tool = .eraser         // X
        case 8: tool = .highlighter    // C
        case 9: tool = .lasso          // V
        case 51, 117, 53: tool = nil   // Delete, Forward Delete, Esc
        default: return event
        }
        guard let window, window.isKeyWindow, event.window === window,
              !(window.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              activePage == nil, lassoDrag == nil, !spaceHeld
        else { return event }

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
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            activeCursor.set()
        }
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
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func lassoHit(_ p: CGPoint, page: PDFPage) -> LassoDrag? {
        guard let g = selectionGeometry(page: page) else { return nil }
        let r: CGFloat = 11
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
            return Double(inside) / Double(stroke.samples.count) >= 0.5      // selection threshold
        }
        selectedIDs = Set(chosen.map(\.id))
        selectionPageIndex = chosen.isEmpty ? -1 : pageIndex
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
    }

    // MARK: - Cursor

    private var trackingArea: NSTrackingArea?
    private var cursorMonitor: Any?

    /// Set now, and again after AppKit/PDFKit finish handling this event.
    private func reassertCursor() {
        activeCursor.set()
        DispatchQueue.main.async { [weak self] in self?.activeCursor.set() }
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

    private var activeCursor: NSCursor {
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: activeCursor)
    }

    override func cursorUpdate(with event: NSEvent) { activeCursor.set() }
    override func mouseMoved(with event: NSEvent)   { activeCursor.set() }
    override func mouseEntered(with event: NSEvent) { activeCursor.set() }
}
