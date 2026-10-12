import AppKit
import PDFKit

/// Sidebar page thumbnails with per-page context menus and Delete-key handling,
/// layered on `PDFThumbnailView`.
///
/// `PDFThumbnailView` hosts a private `NSCollectionView` (`PDFIconCollectionView`)
/// internally. That collection view is still an `NSCollectionView`, so its public
/// `indexPathForItem(at:)` resolves which page a click landed on without any
/// private API.
final class PageSidebarView: PDFThumbnailView {

    /// Returns the context menu to show for the page at `index`.
    var pageMenuProvider: ((Int) -> NSMenu?)?
    /// Invoked when Delete/Backspace is pressed while a page is selected.
    var onDeleteKey: (() -> Void)?

    /// Index of the currently selected page, if any. `PDFThumbnailView` keeps
    /// its selection in sync with the PDFView's current page.
    var selectedPageIndex: Int? {
        guard let document = pdfView?.document, let page = selectedPages?.first else { return nil }
        let index = document.index(for: page)
        return (index >= 0 && index < document.pageCount) ? index : nil
    }

    override var acceptsFirstResponder: Bool { true }

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
        selectPage(at: index)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = Delete (Backspace), 117 = Forward Delete.
        if (event.keyCode == 51 || event.keyCode == 117), selectedPageIndex != nil {
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
