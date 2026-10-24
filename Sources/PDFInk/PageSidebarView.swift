import AppKit
import PDFKit

/// Sidebar page thumbnails with per-page context menus, Delete-key handling,
/// multi-selection (⌘-click / ⇧-click) and drag-to-reorder, layered on
/// `PDFThumbnailView`.
///
/// `PDFThumbnailView` hosts a private `NSCollectionView` (`PDFIconCollectionView`)
/// internally. That collection view is still an `NSCollectionView`, so its public
/// `indexPathForItem(at:)` resolves which page a click landed on without any
/// private API.
final class PageSidebarView: PDFThumbnailView {

    /// Returns the context menu to show for the page at `index`.
    var pageMenuProvider: ((Int) -> NSMenu?)?
    /// Invoked when Delete/Backspace is pressed while pages are selected.
    var onDeleteKey: (() -> Void)?
    /// Invoked when one or more thumbnails are dragged to a new spot.
    /// `indexes` are the (sorted) indices of the dragged pages and `insertion`
    /// is the gap (0...pageCount, in the pre-move list) they were dropped on.
    var onMovePages: ((_ indexes: [Int], _ insertion: Int) -> Void)?

    // MARK: Drag-to-reorder state
    private var dragMonitor: Any?
    private var dragSourceIndex: Int?
    /// Selection as it was when the mouse went down, i.e. before the click
    /// itself changed it. Dragging a page that is part of a multi-selection
    /// moves the whole selection.
    private var selectionAtMouseDown: [Int] = []
    private var draggedIndexes: [Int] = []
    private var dragStartPoint: CGPoint = .zero
    private var isReordering = false
    private var dropInsertionIndex: Int?
    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        v.layer?.cornerRadius = 1.5
        v.isHidden = true
        return v
    }()

    /// Index of the currently selected page, if any. `PDFThumbnailView` keeps
    /// its selection in sync with the PDFView's current page.
    var selectedPageIndex: Int? {
        guard let document = pdfView?.document, let page = selectedPages?.first else { return nil }
        let index = document.index(for: page)
        return (index >= 0 && index < document.pageCount) ? index : nil
    }

    /// Indices of all selected pages, ascending.
    var selectedPageIndexes: [Int] {
        guard let document = pdfView?.document, let pages = selectedPages else { return [] }
        let indexes = pages.map { document.index(for: $0) }
            .filter { $0 != NSNotFound && $0 >= 0 && $0 < document.pageCount }
        return Array(Set(indexes)).sorted()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        guard window != nil else { return }
        addSubview(dropIndicator)
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Returning nil swallows the event; `?? event` would defeat that.
            guard let self else { return event }
            return self.handleReorderEvent(event)
        }
    }

    deinit {
        if let monitor = dragMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Drag-to-reorder

    /// Watches mouse events over the thumbnails. Clicks pass through untouched
    /// (so selection keeps working); once a press on a thumbnail moves far
    /// enough it turns into a reorder drag and the events are consumed.
    private func handleReorderEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            dragSourceIndex = nil
            isReordering = false
            guard bounds.contains(point), !isHiddenOrHasHiddenAncestor,
                  (pdfView?.document?.pageCount ?? 0) > 1,
                  let index = pageIndex(at: point) else { return event }
            // ⌘/⇧-click extends the selection; it never starts a reorder.
            if !event.modifierFlags.intersection([.command, .shift]).isEmpty { return event }
            dragSourceIndex = index
            dragStartPoint = point
            selectionAtMouseDown = selectedPageIndexes
            return event

        case .leftMouseDragged:
            guard let source = dragSourceIndex else { return event }
            if !isReordering {
                guard hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y) > 6 else { return event }
                isReordering = true
                // Dragging a selected page drags the whole selection.
                draggedIndexes = (selectionAtMouseDown.count > 1 && selectionAtMouseDown.contains(source))
                    ? selectionAtMouseDown : [source]
                NSCursor.closedHand.push()
            }
            if let collection = Self.findCollectionView(in: self) {
                _ = collection.autoscroll(with: event)
            }
            let insertion = insertionIndex(at: point)
            dropInsertionIndex = insertion
            updateDropIndicator(forInsertionAt: insertion)
            return nil

        case .leftMouseUp:
            defer {
                dragSourceIndex = nil
                dropInsertionIndex = nil
                draggedIndexes = []
                dropIndicator.isHidden = true
            }
            guard isReordering, dragSourceIndex != nil else {
                isReordering = false
                return event
            }
            isReordering = false
            NSCursor.pop()
            if let insertion = dropInsertionIndex,
               !Self.isNoOpMove(of: draggedIndexes, toInsertionAt: insertion) {
                onMovePages?(draggedIndexes, insertion)
            }
            return nil

        default:
            return event
        }
    }

    /// Which gap (0...pageCount) between thumbnails a point (in this view's
    /// coordinates) is closest to.
    private func insertionIndex(at point: CGPoint) -> Int {
        guard let collection = Self.findCollectionView(in: self) else { return 0 }
        let p = collection.convert(point, from: self)
        let count = collection.numberOfItems(inSection: 0)
        for i in 0..<count {
            let frame = collection.frameForItem(at: i)
            let isBefore = collection.isFlipped ? p.y < frame.midY : p.y > frame.midY
            if isBefore { return i }
        }
        return count
    }

    /// True when dropping `indexes` (ascending) on `insertion` would leave the
    /// page order unchanged.
    private static func isNoOpMove(of indexes: [Int], toInsertionAt insertion: Int) -> Bool {
        guard let first = indexes.first else { return true }
        let base = insertion - indexes.filter { $0 < insertion }.count
        return indexes == Array(base..<(base + indexes.count)) && base >= 0 && first >= 0
    }

    private func updateDropIndicator(forInsertionAt insertion: Int) {
        guard let collection = Self.findCollectionView(in: self) else { return }
        let count = collection.numberOfItems(inSection: 0)
        guard count > 0 else { return }
        // Dropping right where it already is would be a no-op; hide the line.
        if Self.isNoOpMove(of: draggedIndexes, toInsertionAt: insertion) {
            dropIndicator.isHidden = true
            return
        }
        let edgeY: CGFloat
        if insertion < count {
            let f = collection.frameForItem(at: insertion)
            edgeY = collection.isFlipped ? f.minY : f.maxY
        } else {
            let f = collection.frameForItem(at: count - 1)
            edgeY = collection.isFlipped ? f.maxY : f.minY
        }
        let inSelf = convert(NSRect(x: 0, y: edgeY, width: collection.bounds.width, height: 0), from: collection)
        dropIndicator.frame = NSRect(x: 8, y: inSelf.midY - 1.5, width: bounds.width - 16, height: 3)
        dropIndicator.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click selects the page under the cursor and opens its menu.
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = pageIndex(at: point), let menu = pageMenuProvider?(index) else {
            super.rightMouseDown(with: event)
            return
        }
        // Right-clicking inside a multi-selection keeps it (so the menu acts on
        // all of it); right-clicking anywhere else selects just that page.
        let selected = selectedPageIndexes
        if !(selected.count > 1 && selected.contains(index)) {
            selectPage(at: index)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = Delete (Backspace), 117 = Forward Delete.
        if (event.keyCode == 51 || event.keyCode == 117), !selectedPageIndexes.isEmpty {
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Selects a page by making it the PDFView's current page; the thumbnail
    /// view mirrors that selection automatically.
    private func selectPage(at index: Int) {
        guard let document = pdfView?.document, let page = document.page(at: index) else { return }
        pdfView?.go(to: page)
    }

    /// Resolves a point (in this view's coordinates) to the page index under it.
    func pageIndex(at point: CGPoint) -> Int? {
        guard let collection = Self.findCollectionView(in: self) else { return nil }
        let pointInCollection = collection.convert(point, from: self)
        return collection.indexPathForItem(at: pointInCollection)?.item
    }

    private static func findCollectionView(in view: NSView) -> NSCollectionView? {
        if let collection = view as? NSCollectionView { return collection }
        for sub in view.subviews {
            if let found = findCollectionView(in: sub) { return found }
        }
        return nil
    }
}
