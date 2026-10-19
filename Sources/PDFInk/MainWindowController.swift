import AppKit
import PDFKit
import PDFInkCore
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, NSTextFieldDelegate {

    let pdfView = PDFView()
    let thumbnailView = PageSidebarView()
    private let dropContainer = DropContainerView()
    private let placeholderLabel = NSTextField(labelWithString: "Drop a PDF here or use File ▸ Open (⌘O)")

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
        toolState.color = palette.colors[palette.activeSlot]

        store.onChange = { [weak self] pageIndex in
            guard let self else { return }
            self.canvas?.storeDidChange(pageIndex: pageIndex)
            self.window?.isDocumentEdited = true
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
        thumbnailView.onDeleteKey = { [weak self] in
            guard let self, let index = self.thumbnailView.selectedPageIndex else { return }
            self.deletePage(at: index)
        }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(thumbnailView)
        splitView.addArrangedSubview(pdfView)
        thumbnailView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        dropContainer.onPDFDropped = { [weak self] url in
            self?.openPDF(at: url)
        }
        dropContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = .systemFont(ofSize: 16, weight: .medium)

        contentView.addSubview(dropContainer)
        dropContainer.addSubview(splitView)
        dropContainer.addSubview(placeholderLabel)

        // Drawing overlay sits on top of the PDFView, same frame, and maps all
        // input through PDFView's page geometry.
        let canvasView = DrawingCanvasView(pdfView: pdfView, store: store, toolState: toolState)
        pdfView.addSubview(canvasView)
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

    fileprivate func makeToolsItem() -> NSToolbarItem {
        let segment = NSSegmentedControl(
            labels: ["✏️ Pen", "🖍 Highlight", "◻️ Erase", "◌ Lasso"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolSegmentChanged(_:)))
        segment.selectedSegment = 0
        toolSegment = segment
        let item = NSToolbarItem(itemIdentifier: ToolbarID.tools)
        item.label = "Tools"
        item.view = segment
        return item
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
        let toolIndex: Int
        switch toolState.tool {
        case .pen: toolIndex = 0
        case .highlighter: toolIndex = 1
        case .eraser: toolIndex = 2
        case .lasso: toolIndex = 3
        }
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

    func openPDF(at url: URL) {
        guard let document = PDFDocument(url: url) else {
            presentError(message: "Couldn't open PDF", info: url.path)
            return
        }
        autosave.saveNow() // preserve unsaved ink of the previous document
        fileURL = url
        whiteboardTemplate = nil // newWhiteboard(template:) restores it after

        // Reload editable strokes: an autosaved draft wins (it's newest);
        // otherwise recover strokes from PDFInk annotations saved in the file.
        store.removeAll()
        window?.undoManager?.removeAllActions()
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
        savedGeneration = store.generation
        window?.isDocumentEdited = false
        autosave.begin(documentURL: url)
        window?.title = "PDFInk — \(url.lastPathComponent)"
        window?.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NSLog("PDFInk: opened \(url.lastPathComponent) with \(document.pageCount) pages")
    }

    func windowWillClose(_ notification: Notification) {
        persistDraftIfNeeded()
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

    /// Appends a page matching the whiteboard's template (blank for PDFs).
    /// Interactive invocations (menu/keyboard) prompt for the page dimensions;
    /// programmatic calls (dev harness, tests) use the current page's size.
    @objc func addPageAction(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        let template = whiteboardTemplate ?? .blank

        let defaultSize = (pdfView.currentPage ?? document.page(at: document.pageCount - 1))?
            .bounds(for: pdfView.displayBox).size ?? WhiteboardTemplate.pageSize

        let pageSize: CGSize
        if sender != nil {
            guard let chosen = promptForPageSize(defaultSize: defaultSize) else { return }
            pageSize = chosen
        } else {
            pageSize = defaultSize
        }

        guard let page = template.makePage(size: pageSize) else { return }
        document.insert(page, at: document.pageCount)
        pdfView.layoutDocumentView()
        window?.isDocumentEdited = true
        // Scroll to the new page so it's ready to draw on.
        if let newPage = document.page(at: document.pageCount - 1) {
            let top = CGPoint(x: 0, y: newPage.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: newPage, at: top))
        }
        NSLog("PDFInk: added %@ page (%.0fx%.0f pt), document now has %d pages",
              template.rawValue, pageSize.width, pageSize.height, document.pageCount)
        // Persist the new page structure immediately for every document.
        // The draft/autosave mechanism only serializes strokes (keyed by page
        // index), not pages, so an unsaved added page would vanish on restart
        // and leave its ink orphaned. Writing now (which also records current
        // strokes as ink annotations) keeps Add Page durable like whiteboards.
        saveDocumentAction(nil)
    }

    @objc func addMultiplePagesAction(_ sender: Any?) {
        guard let document = pdfView.document else { return }
        let template = whiteboardTemplate ?? .blank

        let defaultSize = (pdfView.currentPage ?? document.page(at: document.pageCount - 1))?
            .bounds(for: pdfView.displayBox).size ?? WhiteboardTemplate.pageSize

        let (count, pageSize): (Int, CGSize)
        if sender != nil {
            guard let chosen = promptForPageCountAndSize(defaultSize: defaultSize) else { return }
            count = chosen.count
            pageSize = chosen.size
        } else {
            count = 1
            pageSize = defaultSize
        }

        guard count > 0 else { return }
        addPages(count: count, size: pageSize, template: template)
    }

    private func addPages(count: Int, size: CGSize, template: WhiteboardTemplate) {
        guard let document = pdfView.document else { return }

        var lastPage: PDFPage?
        for _ in 0..<count {
            guard let page = template.makePage(size: size) else { break }
            document.insert(page, at: document.pageCount)
            lastPage = page
        }
        pdfView.layoutDocumentView()
        window?.isDocumentEdited = true
        if let lastPage {
            let top = CGPoint(x: 0, y: lastPage.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: lastPage, at: top))
        }
        let finalPageCount = document.pageCount
        NSLog("PDFInk: added %d %@ pages (%.0fx%.0f pt), document now has %d pages",
              count, template.rawValue, size.width, size.height, finalPageCount)
        saveDocumentAction(nil)
    }

    private func promptForPageCountAndSize(defaultSize: CGSize) -> (count: Int, size: CGSize)? {
        let alert = NSAlert()
        alert.messageText = "Add Multiple Pages"
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

        let stack = NSStackView(views: [
            row("Count", countField, "pages"),
            row("Width", widthField, "pt"),
            row("Height", heightField, "pt"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 210, height: 90)
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
        return (count, CGSize(width: min(width, 20000), height: min(height, 20000)))
    }

    /// Prompts for a new page's width/height in PDF points. Returns nil on cancel.
    private func promptForPageSize(defaultSize: CGSize) -> CGSize? {
        let alert = NSAlert()
        alert.messageText = "Add Page"
        alert.informativeText = "Choose the size of the new page (in points; 72 pt = 1 inch)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let widthField = NSTextField(string: String(format: "%g", defaultSize.width))
        let heightField = NSTextField(string: String(format: "%g", defaultSize.height))
        for field in [widthField, heightField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        func row(_ title: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let unit = NSTextField(labelWithString: "pt")
            let stack = NSStackView(views: [label, field, unit])
            stack.orientation = .horizontal
            stack.spacing = 6
            return stack
        }

        let stack = NSStackView(views: [row("Width", widthField), row("Height", heightField)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 190, height: 54)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = widthField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let width = Double(widthField.stringValue.trimmingCharacters(in: .whitespaces))
        let height = Double(heightField.stringValue.trimmingCharacters(in: .whitespaces))
        guard let width, let height, width > 0, height > 0 else {
            presentError(message: "Invalid page size",
                         info: "Width and height must be positive numbers (in points).")
            return nil
        }
        return CGSize(width: min(width, 20000), height: min(height, 20000))
    }

    // MARK: - Page deletion

    /// Context menu shown when right-clicking a page thumbnail. Additional
    /// per-page actions can be appended here later.
    private func pageContextMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let deleteItem = NSMenuItem(title: "Delete Page",
                                    action: #selector(deletePageAction(_:)),
                                    keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = index
        menu.addItem(deleteItem)
        return menu
    }

    /// Menu/keyboard entry point: deletes the page the user picked (context
    /// menu) or the selected/current page.
    @objc func deletePageAction(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.representedObject as? Int
            ?? thumbnailView.selectedPageIndex
            ?? pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        guard let index else { return }
        deletePage(at: index)
    }

    /// Deletes the page at `index`, remaps stroke page indices, and persists the
    /// change. Registers an undo that restores the page and its ink.
    func deletePage(at index: Int) {
        guard let document = pdfView.document, index >= 0, index < document.pageCount else { return }
        guard document.pageCount > 1 else {
            presentError(message: "Can't delete the only page",
                         info: "A PDF must keep at least one page.")
            return
        }
        guard let page = document.page(at: index) else { return }
        let removedStrokes = store.strokes(onPage: index)

        document.removePage(at: index)
        store.removePage(at: index)
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()
        // Keep a valid page current so the sidebar selection stays meaningful.
        let neighbour = document.page(at: min(index, document.pageCount - 1))
        if let neighbour { pdfView.go(to: neighbour) }

        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.restorePage(page, at: index, strokes: removedStrokes)
        }
        window?.undoManager?.setActionName("Delete Page")
        saveDocumentAction(nil)
        NSLog("PDFInk: deleted page %d, document now has %d pages", index, document.pageCount)
    }

    /// Inverse of `deletePage(at:)` (used by undo): re-inserts the page and its
    /// strokes at `index` and persists.
    func restorePage(_ page: PDFPage, at index: Int, strokes: [Stroke]) {
        guard let document = pdfView.document else { return }
        let clamped = min(max(index, 0), document.pageCount)
        document.insert(page, at: clamped)
        store.insertPage(at: clamped, strokes: strokes)
        pdfView.layoutDocumentView()
        canvas?.storeStructureDidChange()

        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.deletePage(at: clamped)
        }
        window?.undoManager?.setActionName("Delete Page")
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
            self?.openPDF(at: url)
        }
    }

    /// Cmd+S: writes strokes as ink annotations into the PDF in place.
    /// The annotations are applied to a copy so the display document (and the
    /// canvas as source of truth) stay annotation-free.
    @objc func saveDocumentAction(_ sender: Any?) {
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

    @objc func undo(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { window?.undoManager?.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
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
            #selector(addPageAction(_:)), #selector(addMultiplePagesAction(_:)), #selector(deletePageAction(_:)),
        ]
        if let sel = aSelector, docSelectors.contains(sel), pdfView.document == nil {
            return false
        }
        return super.responds(to: aSelector)
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
