# Plan: Keep circle cursor on drawing tools after drawing

## Goal
When the active tool is pen / highlighter / eraser, the cursor should stay a circle at all times — including immediately after a drawing stroke ends (`mouseUp`). Currently it starts as a circle but reverts (to pointing hand / default) after drawing completes.

## Context
- Cursor logic lives in `Sources/PDFInk/DrawingCanvasView.swift`:
  - `circleCursor` (static, 16 pt oval) defined at line 484.
  - `resetCursorRects()` (line 500): sets circleCursor for `.pen`, `.highlighter`, `.eraser`; pointing hand for `.lasso`; adds cursor rect over `bounds`.
  - `cursorUpdate(with:)` (line 511): sets `Self.circleCursor` for drawing tools, `NSCursor.pointingHand` for lasso.
  - `toolStateDidChange()` (line 142): calls `window?.invalidateCursorRects(for: self)` when tool/color/width changes.
- `toolState.tool` is the source of truth for the cursor (eraser flip sets `toolState.tool = .eraser` via `ToolState.stylusEnteredProximity`, ToolState.swift:40).
- `NSCursor.pointingHand` only appears for `.lasso` (cursorUpdate line 514, resetCursorRects line 504), so a pointing hand after drawing implies the cursor is falling back outside the drawing-tool branch — most likely right after `mouseUp` when the cursor is no longer refreshed by move events and cursor-rect evaluation lands on something else.

## Decisions
1. **Root fix**: In `mouseUp(with:)`, after the stroke is committed (or on the early-return guard paths), explicitly re-assert the correct cursor for the current `toolState.tool` via `NSCursor.set()` (circleCursor for pen/highlighter/eraser, pointingHand for lasso). This closes the window right after a stroke where the cursor can revert before the next move event.
2. **Supplementary**: call `window?.invalidateCursorRects(for: self)` in `mouseUp` so `resetCursorRects()` re-establishes the circle-cursor rect over `bounds` immediately after drawing.
3. Keep `cursorUpdate(with:)` and `resetCursorRects()` unchanged — they already map pen/highlighter/eraser → circleCursor correctly.
4. Cursor is based on `toolState.tool` (not on `activeSamples`/drawing state), so the circle shows even while idle on a drawing tool.

## Risks
- `mouseUp` has an early return (`guard effectiveTool == .pen || ... else { return }` at line 365). The cursor re-assert must apply for ALL tools (including lasso and the early-return cases), so place it unconditionally based on `toolState.tool`, outside the draw-stroke guard.
- `NSCursor.set()` in `mouseUp` only sets the current cursor; subsequent mouse moves re-trigger `cursorUpdate`, so no conflict.
- `invalidateCursorRects` triggers `resetCursorRects` on the main thread; cheap operation.

## Tasks
1. Edit `mouseUp(with:)` in DrawingCanvasView.swift: after the `defer` block / stroke-commit logic (or just before `return` in every path), set the cursor based on `toolState.tool` and invalidate cursor rects.
2. Build with `make app`; confirm no warnings/errors.
3. Run `make test` to ensure no regressions.
4. Validate manually:
   - Launch, cursor is circle on pen/highlighter/eraser.
   - Draw a stroke; immediately after mouseUp, cursor is still circle (not pointing hand / arrow).
   - Switch to lasso → pointing hand; switch back to pen → circle.
   - Eraser flip (stylus eraser end) → circle while erasing.

## Out of scope
- Changing the circle cursor image/size.
- Different cursors per tool (pen vs highlighter vs eraser all share circleCursor, per existing design).
