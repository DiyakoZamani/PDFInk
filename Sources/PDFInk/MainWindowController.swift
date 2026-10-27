import AppKit
import PDFKit
import PDFInkCore
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, NSTextFieldDelegate {

    let pdfView = PDFView()
    let thumbnailView = PageSidebarView()
    private let dropContainer = DropContainerView()
    private var undoRedoControl: UndoRedoControlView?
    private var undoRedoObservers: [NSObjectProtocol] = []
    private let placeholderLabel = NSTextField(labelWithString: "Drop a PDF here or use File ▸ Open (⌘O)")
    private lazy var createBlankButton: NSButton = {
        let button = NSButton(title: "Create a blank document",
                              target: self,
                              action: #selector(newBlankDocumentAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }()

    let store = StrokeStore()
    let toolState = ToolState()
    private(set) var canvas: DrawingCanvasView?
    private lazy var autosave = AutosaveManager(store: store)
    /// Store generation at the last successful explicit save.
    private var savedGeneration: UInt64 = 0

    private var toolSegment: NSSegmentedControl?
    private var sizeSlider: NSSlider?
    private var sizeLabel: NSTextField?
    private var opacitySlider: NSSlider?
    private var opacityLabel: NSTextField?
    private var swatchBar: ColorSwatchBar?
    private var colorPanelObserver: NSObjectProtocol?
    private var editingSlot: Int?
    private let palette = ColorPalette()

    private(set) var fileURL: URL?
    /// True for a freshly created blank document that has no name/location yet.
    /// It lives in a temporary file (so autosave and page edits keep working)
    /// until the user picks a place for it with the Save panel.
    private(set) var isUntitled = false
    var hasUnsavedUntitledDocument: Bool { isUntitled && pdfView.document != nil }
    /// Template used when this document was created as a whiteboard; Add Page
    /// appends a matching page (blank for opened PDFs).
    private(set) var whiteboardTemplate: WhiteboardTemplate?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "PDFInk"
        window.center()
        window.setFrameAutosaveName("PDFInkMainWindow")
        super.init(window: window)
        window.delegate = self
        setUpContentView()
        setUpToolbar()
        observeUndoManager()
        toolState.color = palette.colors[palette.activeSlot]

        store.onChange = { [weak self] pageIndex in
            guard let self else { return }
            self.canvas?.storeDidChange(pageIndex: pageIndex)
            self.window?.isDocumentEdited = true
            self.updateUndoRedoControl()
        }
        toolState.onChange = { [weak self] in
            self?.canvas?.toolStateDidChange()
            self?.syncToolbarSelection()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func setUpContentView() {
        guard let contentView = window?.contentView else { return }

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnailView.backgroundColor = .underPageBackgroundColor
        thumbnailView.pageMenuProvider = { [weak self] index in
            self?.pageContextMenu(for: index)
        }
        thumbnailView.allowsMultipleSelection = true
        thumbnailView.onMovePages = { [weak self] indexes, insertion in
            self?.movePages(indexes, toInsertionIndex: insertion)
        }
        thumbnailView.onDeleteKey = { [weak self] in
            guard let self else { return }
            let indexes = self.thumbnailView.selectedPageIndexes
            if !indexes.isEmpty { self.deletePages(at: indexes) }
        }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(thumbnailView)
        splitView.addArrangedSubview(pdfView)
        thumbnailView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        dropContainer.onPDFDropped = { [weak self] url in
            self?.confirmReplacingUntitledDocument { self?.openPDF(at: url) }
        }
        dropContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = .systemFont(ofSize: 16, weight: .medium)

        contentView.addSubview(dropContainer)
        dropContainer.addSubview(splitView)
        dropContainer.addSubview(placeholderLabel)
        createBlankButton.translatesAutoresizingMaskIntoConstraints = false
        dropContainer.addSubview(createBlankButton)

        let undoRedo = UndoRedoControlView(
            onUndo: { [weak self] in self?.undo(nil) },
            onRedo: { [weak self] in self?.redo(nil) },
            onDragEnded: { [weak self] in self?.snapUndoRedoControl() })
        undoRedoControl = undoRedo
        dropContainer.addSubview(undoRedo)
        positionUndoRedoControl()

        // Drawing overlay sits on top of the PDFView, same frame, and maps all
        // input through PDFView's page geometry.
        let canvasView = DrawingCanvasView(pdfView: pdfView, store: store, toolState: toolState)
        pdfView.addSubview(canvasView)
        canvasView.paletteColors = { [weak self] in self?.palette.colors ?? [] }
        canvasView.onColorShortcut = { [weak self] slot in self?.handleColorShortcut(slot) }
        canvasView.onImageToolSelected = { [weak self] in self?.presentImageImport() }
        canvas = canvasView

        NSLayoutConstraint.activate([
            dropContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            dropContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dropContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dropContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: dropContainer.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: dropContainer.centerYAnchor),
            createBlankButton.centerXAnchor.constraint(equalTo: dropContainer.centerXAnchor),
            createBlankButton.topAnchor.constraint(equalTo: placeholderLabel.bottomAnchor, constant: 16),
        ])
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let tools = NSToolbarItem.Identifier("pdfink.tools")
        static let color = NSToolbarItem.Identifier("pdfink.color")
        static let width = NSToolbarItem.Identifier("pdfink.width")
        static let opacity = NSToolbarItem.Identifier("pdfink.opacity")
    }

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "PDFInkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private enum UndoRedoDockPosition: String {
        case top, bottomLeft, bottomRight
    }

    private var undoRedoDockPosition: UndoRedoDockPosition {
        get {
            UndoRedoDockPosition(rawValue: UserDefaults.standard.string(forKey: "PDFInk.undoRedoDockPosition") ?? "") ?? .top
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "PDFInk.undoRedoDockPosition")
        }
    }

    private func positionUndoRedoControl() {
        guard let control = undoRedoControl else { return }
        let bounds = dropContainer.bounds
        let margin: CGFloat = 16
        let size = NSSize(width: 94, height: 34)
        let x: CGFloat
        let y: CGFloat
        switch undoRedoDockPosition {
        case .top:
            x = (bounds.width - size.width) / 2
            y = bounds.height - size.height - margin
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = bounds.width - size.width - margin
            y = margin
        }
        control.setFrameSize(size)
        control.setFrameOrigin(NSPoint(x: max(margin, x), y: max(margin, y)))
    }

    private func snapUndoRedoControl() {
        guard let control = undoRedoControl else { return }
        let bounds = dropContainer.bounds
        let center = NSPoint(x: control.frame.midX, y: control.frame.midY)
        let nearTop = center.y > bounds.height * 0.62
        if nearTop {
            undoRedoDockPosition = .top
        } else {
            undoRedoDockPosition = center.x < bounds.midX ? .bottomLeft : .bottomRight
        }
        positionUndoRedoControl()
    }

    private func updateUndoRedoControl() {
        undoRedoControl?.updateEnabledState(
            canUndo: window?.undoManager?.canUndo ?? false,
            canRedo: window?.undoManager?.canRedo ?? false)
    }

    private func observeUndoManager() {
        guard let manager = window?.undoManager else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidUndoChange,
                     Notification.Name.NSUndoManagerDidRedoChange,
                     Notification.Name.NSUndoManagerDidCloseUndoGroup] {
            undoRedoObservers.append(center.addObserver(
                forName: name, object: manager, queue: .main) { [weak self] _ in
                    self?.updateUndoRedoControl()
                })
        }
        updateUndoRedoControl()
    }

    func windowDidResize(_ notification: Notification) {
        positionUndoRedoControl()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        positionUndoRedoControl()
    }

    fileprivate func makeToolsItem() -> NSToolbarItem {
        let segment = NSSegmentedControl(
            labels: ["✏️ Pen", "🖍 Highlight", "◻️ Erase", "◌ Lasso", "", ""],
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolSegmentChanged(_:)))
        segment.setImage(Self.textToolIcon(), forSegment: 4)
        segment.setImageScaling(.scaleProportionallyDown, forSegment: 4)
        segment.setToolTip("Text Select (T)", forSegment: 4)
        segment.setWidth(36, forSegment: 4)
        // Image import: Apple's native SF Symbol image icon (template, follows tint/selection).
        let photo = NSImage(systemSymbolName: "photo", accessibilityDescription: "Import Image")
        segment.setImage(photo, forSegment: 5)
        segment.setImageScaling(.scaleProportionallyDown, forSegment: 5)
        segment.setToolTip("Import Image (I)", forSegment: 5)
        segment.setWidth(36, forSegment: 5)
        segment.selectedSegment = 0
        toolSegment = segment
        let item = NSToolbarItem(itemIdentifier: ToolbarID.tools)
        item.label = "Tools"
        item.view = segment
        return item
    }

    /// A bold "T" glyph used as the Text Select tool's toolbar icon (template
    /// image, so it follows the system tint and selection state).
    private static func textToolIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "T", attributes: attributes)
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2,
                                   y: rect.midY - glyphSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    fileprivate func makeColorItem() -> NSToolbarItem {
        let bar = ColorSwatchBar()
        bar.reload(from: palette)
        bar.onSelect = { [weak self] slot in
            guard let self else { return }
            self.selectColorSlot(slot)
            // If the editor is open, make it follow the newly selected swatch.
            if self.editingSlot != nil { self.openEditor(forSlot: slot) }
        }
        bar.onEdit = { [weak self] slot in
            guard let self else { return }
            self.selectColorSlot(slot)
            self.openEditor(forSlot: slot)
        }
        swatchBar = bar
        let item = NSToolbarItem(itemIdentifier: ToolbarID.color)
        item.label = "Color"
        item.view = bar
        return item
    }

    private func selectColorSlot(_ slot: Int) {
        palette.select(slot: slot)
        toolState.color = palette.colors[palette.activeSlot]
        swatchBar?.reload(from: palette)
    }

    /// The key (0-based slot) pressed last and the slot it ended up selecting,
    /// used to tell "press the same number again" from "jump to this number".
    private var lastColorShortcut: (key: Int, result: Int)?

    /// Keys 1–5 (left → right). Pressing a number jumps to that color; pressing
    /// it again steps forward through the palette, wrapping after the last color:
    /// from 1, `3` → 3, `3` → 4, `3` → 5, `3` → 1, `3` → 2 …
    /// Pressing the number of the color that is already active also steps forward.
    private func handleColorShortcut(_ key: Int) {
        guard palette.colors.indices.contains(key) else { return }
        let active = palette.activeSlot
        let repeatedKey = lastColorShortcut?.key == key && lastColorShortcut?.result == active
        let target = (key == active || repeatedKey) ? (active + 1) % ColorPalette.slotCount : key
        lastColorShortcut = (key, target)
        selectColorSlot(target)
        // If the editor is open, make it follow the newly selected swatch.
        if editingSlot != nil { openEditor(forSlot: target) }
    }

    fileprivate func makeWidthItem() -> NSToolbarItem {
        let slider = NSSlider(value: Double(toolState.baseWidth),
                              minValue: Double(ToolState.penWidthRange.lowerBound),
                              maxValue: Double(ToolState.penWidthRange.upperBound),
                              target: self, action: #selector(sizeSliderChanged(_:)))
        slider.isContinuous = true
        let label = NSTextField(labelWithString: "")
        sizeSlider = slider
        sizeLabel = label
        let item = NSToolbarItem(itemIdentifier: ToolbarID.width)
        item.label = "Size"
        item.view = Self.makeSliderRow(title: "Size", slider: slider, valueLabel: label)
        syncSliders()
        return item
    }

    fileprivate func makeOpacityItem() -> NSToolbarItem {
        let slider = NSSlider(value: Double(toolState.highlighterOpacity),
                              minValue: Double(ToolState.opacityRange.lowerBound),
                              maxValue: Double(ToolState.opacityRange.upperBound),
                              target: self, action: #selector(opacitySliderChanged(_:)))
        slider.isContinuous = true
        let label = NSTextField(labelWithString: "")
        opacitySlider = slider
        opacityLabel = label
        let item = NSToolbarItem(itemIdentifier: ToolbarID.opacity)
        item.label = "Opacity"
        item.view = Self.makeSliderRow(title: "Opacity", slider: slider, valueLabel: label)
        syncSliders()
        return item
    }

    private static func makeSliderRow(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .right
        titleLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .left
        valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let stack = NSStackView(views: [titleLabel, slider, valueLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 46 + 100 + 38 + 12).isActive = true
        stack.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return stack
    }

    private func syncToolbarSelection() {
        var toolIndex: Int
        switch toolState.tool {
        case .pen: toolIndex = 0
        case .highlighter: toolIndex = 1
        case .eraser: toolIndex = 2
        case .lasso: toolIndex = 3
        case .image: toolIndex = 5
        }
        if toolState.isTextSelectionEnabled { toolIndex = 4 }   // Text Select ("T")
        toolSegment?.selectedSegment = toolIndex
        swatchBar?.reload(from: palette)
        syncSliders()
    }

    private func syncSliders() {
        let isHighlighter = toolState.tool == .highlighter
        let range = isHighlighter ? ToolState.highlighterWidthRange : ToolState.penWidthRange
        sizeSlider?.minValue = Double(range.lowerBound)
        sizeSlider?.maxValue = Double(range.upperBound)
        sizeSlider?.doubleValue = Double(toolState.baseWidth)
        sizeSlider?.isEnabled = (toolState.tool == .pen || isHighlighter)
        sizeLabel?.stringValue = String(format: "%.1f", Double(toolState.baseWidth))

        opacitySlider?.doubleValue = Double(toolState.highlighterOpacity)
        opacitySlider?.isEnabled = isHighlighter
        opacityLabel?.stringValue = "\(Int((toolState.highlighterOpacity * 100).rounded()))%"
    }

    @objc private func toolSegmentChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 4 {            // Text Select
            toolState.isTextSelectionEnabled = true
            return
        }
        if sender.selectedSegment == 5 {            // Image import
            if toolState.tool == .image { presentImageImport() } else { toolState.tool = .image }
            return
        }
        let tools: [Tool] = [.pen, .highlighter, .eraser, .lasso]
        guard (0..<tools.count).contains(sender.selectedSegment) else { return }
        toolState.tool = tools[sender.selectedSegment]
    }



    @objc private func sizeSliderChanged(_ sender: NSSlider) {
        toolState.baseWidth = CGFloat((sender.doubleValue * 2).rounded() / 2)       // 0.5 steps
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        toolState.highlighterOpacity = CGFloat((sender.doubleValue * 20).rounded() / 20)   // 5% steps
    }


    // MARK: - Color palette editor

    private func openEditor(forSlot slot: Int) {
        guard palette.colors.indices.contains(slot) else { return }
        editingSlot = slot
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.mode = .wheel
        let c = palette.colors[slot]
        panel.color = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        installHexAccessory(on: panel, for: c)

        if let obs = colorPanelObserver { NotificationCenter.default.removeObserver(obs) }
        colorPanelObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.clearColorPanelTarget()
        }
        panel.orderFront(nil)
    }

    private func installHexAccessory(on panel: NSColorPanel, for color: StrokeColor) {
        let label = NSTextField(labelWithString: "Hex")
        let field = NSTextField(string: color.hexString)
        field.tag = 9999
        field.delegate = self
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "#RRGGBB"
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        panel.accessoryView = stack
    }

    private func updateHexField(to color: StrokeColor) {
        guard let stack = NSColorPanel.shared.accessoryView as? NSStackView else { return }
        for case let field as NSTextField in stack.arrangedSubviews where field.tag == 9999 {
            field.stringValue = color.hexString
        }
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        guard let slot = editingSlot,
              let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        let c = StrokeColor(red: rgb.redComponent, green: rgb.greenComponent,
                            blue: rgb.blueComponent, alpha: 1)
        palette.setColor(c, at: slot)
        if slot == palette.activeSlot { toolState.color = c }
        updateHexField(to: c)
        swatchBar?.reload(from: palette)
        canvas?.paletteDidChange()
    }

    private func clearColorPanelTarget() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.accessoryView = nil
        if let obs = colorPanelObserver {
            NotificationCenter.default.removeObserver(obs)
            colorPanelObserver = nil
        }
        editingSlot = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.tag == 9999,
              let slot = editingSlot else { return }
        guard let c = StrokeColor.from(hex: field.stringValue) else {
            NSSound.beep()
            field.stringValue = palette.colors[slot].hexString
            return
        }
        let panel = NSColorPanel.shared
        panel.color = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        panelColorChanged(panel)
    }
    // MARK: - Document handling

    func openPDF(at url: URL, untitled: Bool = false) {
        guard let document = PDFDocument(url: url) else {
            presentError(message: "Couldn't open PDF", info: url.path)
            return
        }
        autosave.saveNow() // preserve unsaved ink of the previous document
        fileURL = url
        isUntitled = untitled
        whiteboardTemplate = nil // newWhiteboard(template:) restores it after

        // Reload editable strokes: an autosaved draft wins (it's newest);
        // otherwise recover strokes from PDFInk annotations saved in the file.
        store.removeAll()
        window?.undoManager?.removeAllActions()
        updateUndoRedoControl()
        // Drop strokes that reference pages no longer present in the document
        // (ink orphaned by a session that added pages without persisting them);
        // otherwise they would silently reappear on a page added later.
        func restore(_ strokes: [Stroke]) -> Int {
            var skipped = 0
            for stroke in strokes {
                if stroke.pageIndex >= 0 && stroke.pageIndex < document.pageCount {
                    store.add(stroke)
                } else {
                    skipped += 1
                }
            }
            return skipped
        }
        if let draft = AutosaveManager.loadDraft(forDocument: url), !draft.isEmpty {
            let restored = draft.allStrokes
            let skipped = restore(restored)
            NSLog("PDFInk: restored %d strokes from autosave draft (%d orphaned skipped)",
                  restored.count - skipped, skipped)
        } else {
            let recovered = AnnotationSerializer.extractStrokes(from: document)
            let skipped = restore(recovered)
            if !recovered.isEmpty {
                NSLog("PDFInk: recovered %d strokes from PDF annotations (%d orphaned skipped)",
                      recovered.count - skipped, skipped)
            }
        }
        // PDFInk-tagged annotations are re-editable via the store, so hide them
        // from the display copy — the canvas is the source of truth on screen.
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == AnnotationSerializer.annotationTitle {
                page.removeAnnotation(annotation)
            }
        }

        pdfView.document = document
        pdfView.layoutDocumentView()
        if let firstPage = document.page(at: 0) {
            let top = CGPoint(x: 0, y: firstPage.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: firstPage, at: top))
        }
        placeholderLabel.isHidden = true
        createBlankButton.isHidden = true
        savedGeneration = store.generation
        window?.isDocumentEdited = false
        autosave.begin(documentURL: url)
        if untitled {
            window?.title = "PDFInk — Untitled"
            window?.representedURL = nil
        } else {
            window?.title = "PDFInk — \(url.lastPathComponent)"
            window?.representedURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        NSLog("PDFInk: opened \(url.lastPathComponent) with \(document.pageCount) pages")
    }

    func windowWillClose(_ notification: Notification) {
        for observer in undoRedoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        undoRedoObservers.removeAll()
        persistDraftIfNeeded()
    }

    /// A named document is always on disk, but an untitled one only exists in a
    /// temporary file: ask whether to save it (and where) before closing.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedUntitledDocument else { return true }
        askToSaveUntitled { [weak self] shouldClose in
            if shouldClose { self?.window?.close() }
        }
        return false
    }

    // MARK: - Whiteboards (notebook-style)

    static func whiteboardsDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("PDFInk Whiteboards", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a new whiteboard as a real PDF file (so save/autosave work
    /// immediately, notebook-style) and opens it.
    func newWhiteboard(template: WhiteboardTemplate) {
        if isUntitled {
            confirmReplacingUntitledDocument { [weak self] in self?.newWhiteboard(template: template) }
            return
        }
        do {
            let dir = try Self.whiteboardsDirectory()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            let stamp = formatter.string(from: Date())
            var url = dir.appendingPathComponent("Whiteboard \(stamp).pdf")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("Whiteboard \(stamp) (\(counter)).pdf")
                counter += 1
            }
            try template.pdfData(pageCount: 1, size: WhiteboardTemplate.pageSize).write(to: url)
            openPDF(at: url) // clears whiteboardTemplate, so set it after
            whiteboardTemplate = template
            NSLog("PDFInk: created %@ whiteboard at %@", template.rawValue, url.path)
        } catch {
            presentError(message: "Couldn't create whiteboard", info: error.localizedDescription)
        }
    }

    // MARK: - Blank documents

    /// Where new blank documents live until the user saves them somewhere.
    static func untitledDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFInk Untitled", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File ▸ Create a Blank Document… (and the button on the start screen):
    /// asks for page count and size, then creates and opens the document.
    @objc func newBlankDocumentAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Create a Blank Document"
        alert.informativeText = "Choose how many pages the document has and their size."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let form = BlankDocumentForm()
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.initialResponder

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let options = form.result() else {
            presentError(message: "Invalid input",
                         info: "Pages must be 1–1000 and width/height must be positive numbers (in points).")
            return
        }
        confirmReplacingUntitledDocument { [weak self] in
            self?.createBlankDocument(pageCount: options.count, size: options.size)
        }
    }

    /// Creates a blank PDF in a temporary file and opens it as an untitled
    /// document. Nothing is written to the user's folders until they choose a
    /// name and location with the Save panel (⌘S).
    func createBlankDocument(pageCount: Int, size: CGSize) {
        do {
            let url = try Self.untitledDirectory()
                .appendingPathComponent("Untitled-\(UUID().uuidString).pdf")
            try WhiteboardTemplate.blank.pdfData(pageCount: pageCount, size: size).write(to: url)
            openPDF(at: url, untitled: true)
            NSLog("PDFInk: created untitled blank document with %d pages (%.0fx%.0f pt)",
                  pageCount, size.width, size.height)
        } catch {
            presentError(message: "Couldn't create document", info: error.localizedDescription)
        }
    }

    // MARK: - Saving untitled documents

    /// Runs `proceed` right away, unless an untitled document is open: then it
    /// asks to save it first and runs `proceed` only if the user didn't cancel.
    func confirmReplacingUntitledDocument(then proceed: @escaping () -> Void) {
        guard hasUnsavedUntitledDocument else { proceed(); return }
        askToSaveUntitled { shouldProceed in
            if shouldProceed { proceed() }
        }
    }

    /// "Save / Don't Save / Cancel" sheet for the untitled document. Calls
    /// `completion(true)` once it is saved or deliberately discarded and
    /// `completion(false)` if the user cancels (or the save fails/is cancelled).
    func askToSaveUntitled(completion: @escaping (Bool) -> Void) {
        guard let window, hasUnsavedUntitledDocument else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save this document?"
        alert.informativeText = "If you don't save, this document and its changes will be lost."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            switch response {
            case .alertFirstButtonReturn:
                // Let the alert sheet finish closing before showing the Save panel.
                DispatchQueue.main.async {
                    self.presentSaveLocationPanel(completion: completion)
                }
            case .alertSecondButtonReturn:
                self.discardUntitled()
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// The standard Save sheet: pick a folder in Finder-style browsing and type
    /// the file name at the top.
    private func presentSaveLocationPanel(completion: ((Bool) -> Void)?) {
        guard let window, pdfView.document != nil else { completion?(false); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled.pdf"
        panel.directoryURL = try? FileManager.default.url(for: .documentDirectory,
                                                          in: .userDomainMask,
                                                          appropriateFor: nil, create: false)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else {
                completion?(false)
                return
            }
            completion?(self.saveUntitled(to: destination))
        }
    }

    /// Writes the untitled document (with its ink) to `destination` and turns
    /// it into a regular named document.
    private func saveUntitled(to destination: URL) -> Bool {
        guard let document = pdfView.document, let temporaryURL = fileURL,
              let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data) else {
            presentError(message: "Couldn't prepare document for saving", info: destination.lastPathComponent)
            return false
        }
        AnnotationSerializer.apply(store: store, to: copy)
        guard copy.write(to: destination) else {
            presentError(message: "Couldn't save PDF", info: destination.path)
            return false
        }
        autosave.clearDraft() // draft is keyed by the temporary path
        try? FileManager.default.removeItem(at: temporaryURL)
        fileURL = destination
        isUntitled = false
        savedGeneration = store.generation
        window?.isDocumentEdited = false
        autosave.begin(documentURL: destination)
        window?.title = "PDFInk — \(destination.lastPathComponent)"
        window?.representedURL = destination
        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
        NSLog("PDFInk: saved untitled document to %@", destination.path)
        return true
    }

    /// "Don't Save": throws the temporary file and its draft away.
    private func discardUntitled() {
        autosave.clearDraft()
        autosave.detach()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        savedGeneration = store.generation
        isUntitled = false
        window?.isDocumentEdited = false
    }

    // MARK: - Adding pages

    /// Adds pages matching the whiteboard's template (blank for PDFs).
    /// Interactive invocations (menu/keyboard) prompt for count, size and
    /// placement (after the current page or at the end); programmatic calls
    /// (dev harness, tests) append one page at the current page's size.
    @objc func addPageAction(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        let template = whiteboardTemplate ?? .blank

        let defaultSize = (pdfView.currentPage ?? document.page(at: document.pageCount - 1))?
            .bounds(for: pdfView.displayBox).size ?? WhiteboardTemplate.pageSize

        let request: (count: Int, size: CGSize, afterCurrent: Bool)
        if sender != nil {
            guard let chosen = promptForAddPages(defaultSize: defaultSize) else { return }
            request = chosen
        } else {
            request = (1, defaultSize, false)
        }

        guard request.count > 0 else { return }
        addPages(count: request.count, size: request.size, template: template,
                 afterCurrent: request.afterCurrent)
    }

    private func addPages(count: Int, size: CGSize, template: WhiteboardTemplate, afterCurrent: Bool) {
        guard let document = pdfView.document else { return }

        // Where the first new page goes: right after the current page, or at the end.
        var insertionIndex = document.pageCount
        if afterCurrent, let current = pdfView.currentPage {
            let currentIndex = document.index(for: current)
            if currentIndex != NSNotFound { insertionIndex = currentIndex + 1 }
        }

        var insertedCount = 0
        for i in 0..<count {
            guard let page = template.makePage(size: size) else { break }
            let index = insertionIndex + i
            document.insert(page, at: index)
            // Pages that were after the insertion point moved down one; their ink
            // is keyed by page index, so it has to move with them.
            if index < document.pageCount - 1 {
                store.insertPage(at: index, strokes: [])
            }
            insertedCount += 1
        }
        guard insertedCount > 0 else { return }

        // Pages built in a scratch PDFDocument keep that document's numbering, so
        // every new page would read "1" in the sidebar until the file is reopened.
        // Round-tripping the document through its data makes PDFKit renumber all
        // pages (exactly what reopening does).
        reloadDocumentFromMemory()
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()
        window?.isDocumentEdited = true

        // Scroll to the new pages: the first one when inserting after the
        // current page, otherwise the last one at the end of the document.
        let targetIndex = afterCurrent ? insertionIndex : insertionIndex + insertedCount - 1
        if let document = pdfView.document, let target = document.page(at: targetIndex) {
            let top = CGPoint(x: 0, y: target.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: target, at: top))
        }
        NSLog("PDFInk: added %d %@ pages (%.0fx%.0f pt) at index %d, document now has %d pages",
              insertedCount, template.rawValue, size.width, size.height, insertionIndex,
              pdfView.document?.pageCount ?? 0)
        // Persist the new page structure immediately: the draft/autosave mechanism
        // only serializes strokes (keyed by page index), not pages, so unsaved
        // pages would vanish on restart and leave their ink orphaned.
        saveDocumentAction(nil)
    }

    /// Replaces the displayed document with a fresh copy built from its own data
    /// (same pages and content, annotation-free display copy as before). Used to
    /// make PDFKit recompute page labels/thumbnails after pages were inserted.
    private func reloadDocumentFromMemory() {
        guard let document = pdfView.document,
              let data = document.dataRepresentation(),
              let fresh = PDFDocument(data: data) else { return }
        pdfView.document = fresh
    }

    /// Prompts for how many pages to add, their size in PDF points, and whether
    /// they go after the current page. Returns nil on cancel/invalid input.
    private func promptForAddPages(defaultSize: CGSize) -> (count: Int, size: CGSize, afterCurrent: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Add Pages"
        alert.informativeText = "Enter how many pages to add and their size (in points; 72 pt = 1 inch)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let countField = NSTextField(string: "1")
        let widthField = NSTextField(string: String(format: "%g", defaultSize.width))
        let heightField = NSTextField(string: String(format: "%g", defaultSize.height))
        for field in [countField, widthField, heightField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        func row(_ title: String, _ field: NSTextField, _ unit: String) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let unitField = NSTextField(labelWithString: unit)
            let stack = NSStackView(views: [label, field, unitField])
            stack.orientation = .horizontal
            stack.spacing = 6
            return stack
        }

        let afterCurrentCheckbox = NSButton(checkboxWithTitle: "Add after current page",
                                            target: nil, action: nil)
        afterCurrentCheckbox.state = .off

        let stack = NSStackView(views: [
            row("Count", countField, "pages"),
            row("Width", widthField, "pt"),
            row("Height", heightField, "pt"),
            afterCurrentCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = countField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let count = Int(countField.stringValue.trimmingCharacters(in: .whitespaces))
        let width = Double(widthField.stringValue.trimmingCharacters(in: .whitespaces))
        let height = Double(heightField.stringValue.trimmingCharacters(in: .whitespaces))
        guard let count, count > 0, count <= 1000,
              let width, let height, width > 0, height > 0 else {
            presentError(message: "Invalid input",
                         info: "Count must be 1–1000 and width/height must be positive numbers (in points).")
            return nil
        }
        return (count,
                CGSize(width: min(width, 20000), height: min(height, 20000)),
                afterCurrentCheckbox.state == .on)
    }

    // MARK: - Page reordering

    /// Moves a single page so it ends up at index `to`. Ink follows its page,
    /// and the move is undoable.
    func movePage(from: Int, to: Int) {
        guard let document = pdfView.document, from != to,
              (0..<document.pageCount).contains(from),
              (0..<document.pageCount).contains(to) else { return }
        let insertion = to > from ? to + 1 : to
        movePages([from], toInsertionIndex: insertion)
    }

    /// Moves several pages at once (drag-and-drop of a multi-selection in the
    /// sidebar). `insertion` is the gap (0...pageCount) in the current page list
    /// the pages are dropped on; the moved pages keep their relative order.
    func movePages(_ indexes: [Int], toInsertionIndex insertion: Int) {
        guard let document = pdfView.document else { return }
        let count = document.pageCount
        let moving = Array(Set(indexes.filter { (0..<count).contains($0) })).sorted()
        guard !moving.isEmpty, (0...count).contains(insertion) else { return }

        let movingSet = Set(moving)
        let rest = (0..<count).filter { !movingSet.contains($0) }
        let restBefore = insertion - moving.filter { $0 < insertion }.count
        let newOrder = Array(rest.prefix(restBefore)) + moving + Array(rest.dropFirst(restBefore))
        guard newOrder != Array(0..<count) else { return }

        applyPageOrder(newOrder, actionName: moving.count > 1 ? "Move Pages" : "Move Page")
        if let first = pdfView.document?.page(at: restBefore) { pdfView.go(to: first) }
        NSLog("PDFInk: moved %d page(s) to position %d", moving.count, restBefore)
    }

    /// Reorders the document so that new position `i` holds the page that is
    /// currently at `newOrder[i]`. Ink follows its pages and the whole change is
    /// one undo step (undo applies the inverse permutation).
    private func applyPageOrder(_ newOrder: [Int], actionName: String) {
        guard let document = pdfView.document, newOrder.count == document.pageCount else { return }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard pages.count == newOrder.count else { return }
        let desired = newOrder.map { pages[$0] }

        // Selection-sort with single moves; positions before `target` are final.
        for target in 0..<desired.count {
            let from = document.index(for: desired[target])
            if from == NSNotFound || from == target { continue }
            document.removePage(at: from)
            document.insert(desired[target], at: target)
            store.movePage(from: from, to: target)
        }
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()

        var inverse = [Int](repeating: 0, count: newOrder.count)
        for (newPosition, oldIndex) in newOrder.enumerated() { inverse[oldIndex] = newPosition }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.applyPageOrder(inverse, actionName: actionName)
        }
        window?.undoManager?.setActionName(actionName)
        saveDocumentAction(nil)
    }

    // MARK: - Page deletion

    /// Context menu shown when right-clicking a page thumbnail. Acts on the
    /// whole selection when the clicked page is part of a multi-selection.
    private func pageContextMenu(for index: Int) -> NSMenu {
        let selected = thumbnailView.selectedPageIndexes
        let targets = (selected.count > 1 && selected.contains(index)) ? selected : [index]
        let menu = NSMenu()
        let deleteItem = NSMenuItem(title: targets.count > 1 ? "Delete \(targets.count) Pages" : "Delete Page",
                                    action: #selector(deletePageAction(_:)),
                                    keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = targets
        menu.addItem(deleteItem)
        return menu
    }

    /// Menu/keyboard entry point: deletes the pages the user picked (context
    /// menu) or the selected pages / current page.
    @objc func deletePageAction(_ sender: Any?) {
        if let indexes = (sender as? NSMenuItem)?.representedObject as? [Int] {
            deletePages(at: indexes)
            return
        }
        let selected = thumbnailView.selectedPageIndexes
        if !selected.isEmpty {
            deletePages(at: selected)
            return
        }
        if let current = pdfView.currentPage, let document = pdfView.document {
            let index = document.index(for: current)
            if index != NSNotFound { deletePage(at: index) }
        }
    }

    func deletePage(at index: Int) {
        deletePages(at: [index])
    }

    private struct RemovedPage {
        let index: Int
        let page: PDFPage
        let strokes: [Stroke]
    }

    /// Deletes the given pages, remaps stroke page indices, and persists the
    /// change. Registers one undo that restores all pages and their ink.
    func deletePages(at indexes: [Int]) {
        guard let document = pdfView.document else { return }
        let targets = Array(Set(indexes.filter { $0 >= 0 && $0 < document.pageCount })).sorted()
        guard let firstTarget = targets.first else { return }
        guard targets.count < document.pageCount else {
            presentError(message: targets.count == 1 ? "Can't delete the only page" : "Can't delete every page",
                         info: "A PDF must keep at least one page.")
            return
        }
        let removed: [RemovedPage] = targets.compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return RemovedPage(index: index, page: page, strokes: store.strokes(onPage: index))
        }

        // Highest index first, so the lower indices stay valid while deleting.
        for item in removed.reversed() {
            document.removePage(at: item.index)
            store.removePage(at: item.index)
        }
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()
        // Keep a valid page current so the sidebar selection stays meaningful.
        if let neighbour = document.page(at: min(firstTarget, document.pageCount - 1)) {
            pdfView.go(to: neighbour)
        }

        let name = removed.count > 1 ? "Delete Pages" : "Delete Page"
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.restorePages(removed)
        }
        window?.undoManager?.setActionName(name)
        saveDocumentAction(nil)
        NSLog("PDFInk: deleted %d page(s), document now has %d pages", removed.count, document.pageCount)
    }

    /// Inverse of `deletePages(at:)` (used by undo): re-inserts the pages and
    /// their strokes at their original indices and persists.
    private func restorePages(_ items: [RemovedPage]) {
        guard let document = pdfView.document else { return }
        // Ascending order puts every page back at its original index.
        for item in items.sorted(by: { $0.index < $1.index }) {
            let clamped = min(max(item.index, 0), document.pageCount)
            document.insert(item.page, at: clamped)
            store.insertPage(at: clamped, strokes: item.strokes)
        }
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()

        let indexes = items.map(\.index)
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.deletePages(at: indexes)
        }
        window?.undoManager?.setActionName(items.count > 1 ? "Delete Pages" : "Delete Page")
        saveDocumentAction(nil)
    }

    @objc func newBlankWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .blank) }
    @objc func newGridWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .grid) }
    @objc func newLinedWhiteboardAction(_ sender: Any?) { newWhiteboard(template: .lined) }

    /// Unsaved ink survives via the draft; explicit save clears it.
    func persistDraftIfNeeded() {
        if store.generation != savedGeneration {
            autosave.saveNow()
        }
    }

    /// Dev/demo: wipe in-memory ink, undo history, and any autosaved draft so
    /// a scripted run starts from a clean slate and leaves none behind.
    func discardDraftAndInk() {
        store.removeAll()
        window?.undoManager?.removeAllActions()
        updateUndoRedoControl()
        autosave.clearDraft()
        savedGeneration = store.generation
        window?.isDocumentEdited = false
    }

    /// Dev/testing: renders the window's content view into a PNG.
    func writeWindowSnapshot(to url: URL) {
        NSLog("PDFInk: snapshot state: scale=%.2f currentPage=%@ visible=%d docView=%@",
              pdfView.scaleFactor,
              pdfView.currentPage.map { String(describing: pdfView.document?.index(for: $0)) } ?? "nil",
              pdfView.visiblePages.count,
              NSStringFromRect(pdfView.documentView?.frame ?? .zero))
        guard let image = composeWindowImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        NSLog("PDFInk: snapshot written to %@", url.path)
    }

    /// Composes what the user sees into a CGImage (backing-scale pixels).
    /// Used by snapshots and the demo recorder.
    func composeWindowImage() -> CGImage? {
        guard let contentView = window?.contentView else { return nil }
        // PDFView draws through Metal-backed layers that cacheDisplay can't
        // capture, so compose the snapshot manually: the view hierarchy first
        // (chrome, sidebar, drawing overlay), then the visible PDF pages drawn
        // through the same page→view transforms the app uses. Any coordinate
        // bug shows up as misregistration between pages and ink.
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        contentView.cacheDisplay(in: bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        guard let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        // Layer 1: PDF pages at their on-screen positions.
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(bounds)
        if pdfView.document != nil {
            for page in pdfView.visiblePages {
                let pageRectInContent = contentView.convert(
                    pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
                ctx.saveGState()
                // Convert to the CG context's bottom-left origin if needed.
                let flippedY = contentView.isFlipped
                    ? bounds.height - pageRectInContent.maxY
                    : pageRectInContent.minY
                ctx.translateBy(x: pageRectInContent.minX, y: flippedY)
                ctx.scaleBy(x: pageRectInContent.width / page.bounds(for: pdfView.displayBox).width,
                            y: pageRectInContent.height / page.bounds(for: pdfView.displayBox).height)
                ctx.setFillColor(.white)
                ctx.fill(page.bounds(for: pdfView.displayBox))
                page.draw(with: pdfView.displayBox, to: ctx)
                ctx.restoreGState()
            }
        }

        // Layer 2: the captured view hierarchy (sidebar, overlay ink, chrome)
        // composited on top, letting the PDF show through where views are clear.
        if let viewImage = rep.cgImage {
            ctx.saveGState()
            ctx.scaleBy(x: 1 / scale, y: 1 / scale)
            ctx.setBlendMode(.multiply) // white view backgrounds pass the pages through
            ctx.draw(viewImage, in: CGRect(x: 0, y: 0,
                                           width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
            ctx.restoreGState()
        }

        return ctx.makeImage()
    }

    private func presentError(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu actions

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.confirmReplacingUntitledDocument { self?.openPDF(at: url) }
        }
    }

    /// Cmd+S: writes strokes as ink annotations into the PDF in place.
    /// The annotations are applied to a copy so the display document (and the
    /// canvas as source of truth) stay annotation-free.
    ///
    /// For an untitled blank document, Cmd+S (a user action, `sender != nil`)
    /// opens the standard Save panel to pick a folder and name. Internal calls
    /// with a nil sender just persist to the temporary file.
    @objc func saveDocumentAction(_ sender: Any?) {
        if isUntitled, sender != nil {
            presentSaveLocationPanel(completion: nil)
            return
        }
        guard let document = pdfView.document, let url = fileURL else { return }
        guard let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data) else {
            presentError(message: "Couldn't prepare document for saving", info: url.lastPathComponent)
            return
        }
        AnnotationSerializer.apply(store: store, to: copy)
        if copy.write(to: url) {
            savedGeneration = store.generation
            window?.isDocumentEdited = false
            autosave.clearDraft()
            NSLog("PDFInk: saved %d strokes as ink annotations to %@",
                  store.allStrokes.count, url.lastPathComponent)
        } else {
            presentError(message: "Couldn't save PDF", info: url.path)
        }
    }

    @objc func exportFlattenedAction(_ sender: Any?) {
        guard let document = pdfView.document, let url = fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (flattened).pdf"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let outURL = panel.url else { return }
            do {
                try FlattenedExporter.export(document: document, store: self.store, to: outURL)
                NSLog("PDFInk: exported flattened PDF to %@", outURL.path)
            } catch {
                self.presentError(message: "Export failed", info: error.localizedDescription)
            }
        }
    }

    /// Dev/testing: non-interactive flattened export.
    func exportFlattened(to outURL: URL) throws {
        guard let document = pdfView.document else { return }
        try FlattenedExporter.export(document: document, store: store, to: outURL)
    }

    @objc func zoomInAction(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOutAction(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func actualSizeAction(_ sender: Any?) { pdfView.scaleFactor = 1.0 }

    @objc func selectPenAction(_ sender: Any?) { toolState.tool = .pen }
    @objc func selectHighlighterAction(_ sender: Any?) { toolState.tool = .highlighter }
    @objc func selectEraserAction(_ sender: Any?) { toolState.tool = .eraser }
    @objc func selectLassoAction(_ sender: Any?) { toolState.tool = .lasso }
    @objc func selectImageAction(_ sender: Any?) {
        if toolState.tool == .image { presentImageImport() } else { toolState.tool = .image }
    }

    private var imagePanelOpen = false

    /// Shows the image picker. A picked image is placed and selected (the tool
    /// switches to the lasso so it can be moved/scaled); cancelling returns to
    /// the previous drawing tool.
    func presentImageImport() {
        guard !imagePanelOpen, let window else { return }
        guard pdfView.document != nil else {
            NSSound.beep()
            toolState.tool = toolState.lastDrawingTool
            return
        }
        imagePanelOpen = true
        let panel = NSOpenPanel()
        panel.title = "Import Image"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Deferred a tick so the toolbar/shortcut event that triggered this finishes first.
        DispatchQueue.main.async { [weak self] in
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.imagePanelOpen = false
                if response == .OK, let url = panel.url, self.canvas?.importImage(from: url) == true { return }
                if response == .OK { NSSound.beep() }
                if self.toolState.tool == .image { self.toolState.tool = self.toolState.lastDrawingTool }
            }
        }
    }

    @objc func undo(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { window?.undoManager?.redo() }

    /// ⌘C / Edit ▸ Copy: copies the text selected with the Text Select tool.
    /// Text fields (hex field, dialogs) handle their own `copy:` before this is
    /// reached, because the menu item has no fixed target.
    @objc(copy:) func copySelectedText(_ sender: Any?) {
        guard let selection = pdfView.currentSelection,
              let text = selection.string, !text.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let attributed = selection.attributedString, attributed.length > 0 {
            pasteboard.writeObjects([attributed])   // rich text + plain string
        } else {
            pasteboard.setString(text, forType: .string)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copySelectedText(_:)):
            return !(pdfView.currentSelection?.string ?? "").isEmpty
        case #selector(undo(_:)): return window?.undoManager?.canUndo ?? false
        case #selector(redo(_:)): return window?.undoManager?.canRedo ?? false
        default: return true
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        // Disable document-dependent menu items until a PDF is open.
        let docSelectors: Set<Selector> = [
            #selector(saveDocumentAction(_:)), #selector(exportFlattenedAction(_:)),
            #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(actualSizeAction(_:)),
            #selector(addPageAction(_:)), #selector(deletePageAction(_:)),
        ]
        if let sel = aSelector, docSelectors.contains(sel), pdfView.document == nil {
            return false
        }
        return super.responds(to: aSelector)
    }
}

/// Compact, draggable undo/redo control. Drag the narrow grip on the left to
/// dock it at the top or either bottom corner of the document area.
final class UndoRedoControlView: NSView {
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let grip = NSTextField(labelWithString: "⠿")
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onDragEnded: () -> Void
    private var dragOffset = NSPoint.zero
    private var isDragging = false

    init(onUndo: @escaping () -> Void,
         onRedo: @escaping () -> Void,
         onDragEnded: @escaping () -> Void) {
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onDragEnded = onDragEnded
        super.init(frame: NSRect(x: 0, y: 0, width: 94, height: 34))

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.textColor = .secondaryLabelColor
        grip.alignment = .center
        grip.font = .systemFont(ofSize: 12, weight: .medium)
        grip.toolTip = "Drag to move this control"
        addSubview(grip)

        configure(undoButton, symbol: "arrow.uturn.backward", title: "Undo", action: #selector(undoPressed))
        configure(redoButton, symbol: "arrow.uturn.forward", title: "Redo", action: #selector(redoPressed))
        addSubview(undoButton)
        addSubview(redoButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 13),
            undoButton.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 1),
            undoButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            undoButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            undoButton.widthAnchor.constraint(equalToConstant: 34),
            separator.leadingAnchor.constraint(equalTo: undoButton.trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            separator.widthAnchor.constraint(equalToConstant: 1),
            redoButton.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            redoButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            redoButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            redoButton.widthAnchor.constraint(equalToConstant: 34),
            redoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        updateEnabledState(canUndo: false, canRedo: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    func updateEnabledState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    @objc private func undoPressed() { onUndo() }
    @objc private func redoPressed() { onRedo() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the grip's hit area on this view so its mouse tracking can drag
        // the whole control instead of being intercepted by the label subview.
        if bounds.contains(point), point.x <= 17 { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= 17 else {
            super.mouseDown(with: event)
            return
        }
        isDragging = true
        guard let parent = superview else { return }
        let parentPoint = parent.convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: parentPoint.x - frame.minX,
                             y: parentPoint.y - frame.minY)
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp {
                isDragging = false
                onDragEnded()
                break
            }
            guard isDragging else { continue }
            let currentPoint = parent.convert(next.locationInWindow, from: nil)
            frame.origin = NSPoint(x: currentPoint.x - dragOffset.x,
                                   y: currentPoint.y - dragOffset.y)
        }
    }
}

/// Container view accepting PDF file drags anywhere in the window.
final class DropContainerView: NSView {

    var onPDFDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func pdfURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pdfURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = pdfURL(from: sender) else { return false }
        onPDFDropped?(url)
        return true
    }
}

extension MainWindowController {
    /// Dev: dump page placement geometry for snapshot debugging.
    func logPageGeometry() {
        guard let contentView = window?.contentView, let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let r = contentView.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
            NSLog("PDFInk: page %d rectInContent=%@", i, NSStringFromRect(r))
        }
        NSLog("PDFInk: contentView bounds=%@ flipped=%d", NSStringFromRect(contentView.bounds), contentView.isFlipped ? 1 : 0)
    }
}

extension MainWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.tools, .flexibleSpace, ToolbarID.color, ToolbarID.width, ToolbarID.opacity]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.tools: return makeToolsItem()
        case ToolbarID.color: return makeColorItem()
        case ToolbarID.width: return makeWidthItem()
        case ToolbarID.opacity: return makeOpacityItem()
        default: return nil
        }
    }
}
