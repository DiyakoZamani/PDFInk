# Plan: Add Multiple Pages at Once

## Goal
Add a File ▸ "Add Multiple Pages…" menu item that prompts for a page count (and optional page size), then creates that many pages at once in the current document, matching existing Add Page behavior (template, size default, persistence via save).

## Context
- Single-page flow: `MainWindowController.addPageAction(_:)` at Sources/PDFInk/MainWindowController.swift:342 prompts for width/height via `promptForPageSize(defaultSize:)` (line 377), creates one page via `WhiteboardTemplate.makePage(size:)` (WhiteboardTemplate.swift:40), inserts at end, scrolls to it, then calls `saveDocumentAction(nil)`.
- Menu registered in AppDelegate.swift:129 ("Add Page", ⌘⇧N).
- `responds(to:)` (MainWindowController.swift:665) disables page actions when no document is open; add the new selector to `docSelectors`.
- Programmatic calls pass `sender = nil` to skip the prompt and use the current page's size (DevHarness.swift:172).

## Decisions
1. **Entry point**: New menu item "Add Multiple Pages…" in the File menu right after "Add Page" (AppDelegate.swift). No keyboard equivalent; menu-only, with "…" to signal a dialog. Selector: `addMultiplePagesAction(_:)`.
2. **Dialog**: Single modal dialog prompting for:
   - Number of pages (integer field; required). Validation: positive integer, capped at 1000 to avoid UI freeze; error alert on invalid input, no pages added.
   - Width/height (optional; default to current page size, same 20000 pt cap as Add Page). All pages share one size/template.
   - Returns `(count, size)` or nil on cancel.
3. **Insertion**: New helper `addPages(count:size:template:)` inserts all pages in memory in one loop, then `layoutDocumentView`, sets `isDocumentEdited`, scrolls to the last new page, and saves once via `saveDocumentAction(nil)`. Saving once avoids repeated file writes.
4. **Template**: `whiteboardTemplate ?? .blank` (same as Add Page).
5. **Undo**: No explicit undo grouping — parity with Add Page (⌤Z behavior unchanged).
6. **Programmatic variant**: Core helper accepts `count` so it can be called without prompting; DevHarness changes out of scope.

## Risks
- Large page counts may briefly block the main thread (PDFKit insertion is main-thread only); mitigated by the 1000 cap.
- Save failure: pages exist in memory but aren't persisted; error alert shown, document stays edited; user can retry Save.
- No selective undo of individual added pages (matches Add Page).

## Tasks
1. Add `addMultiplePagesAction(_:)`, `promptForPageCountAndSize(defaultSize:)` dialog, and `addPages(count:size:template:)` helper in MainWindowController.swift.
2. Register "Add Multiple Pages…" menu item in AppDelegate.swift after "Add Page".
3. Add `#selector(addMultiplePagesAction(_:))` to `docSelectors` in `responds(to:)`.
4. Build with `make app`; ensure no new warnings.
5. Validate manually:
   - Add Page still works unchanged.
   - Add Multiple Pages with count 3 on a 1-page doc → 4 pages; thumbnails show all; scroll lands on last new page.
   - Save, reopen → 4 pages persist.
   - Invalid count (0, negative, non-numeric, >1000) → error alert, no pages added.
   - Cancel → no change.
   - No document open → menu item disabled.

## Open questions (recommendations)
- Max page count cap: recommend 1000.
- Keyboard shortcut: recommend none.
- Undo grouping for all pages at once: recommend no (keep parity with Add Page).
