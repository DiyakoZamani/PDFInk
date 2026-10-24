# PDFInk

Native macOS PDF annotation app (AppKit + PDFKit) with full Wacom tablet
support: pressure-sensitive pen, highlighter, stroke-level eraser, and
eraser-flip via stylus proximity events. No PencilKit — the drawing canvas is a
custom NSView overlay.

## Build & run

```sh
make app                        # builds dist/PDFInk.app
open dist/PDFInk.app            # or: dist/PDFInk.app/Contents/MacOS/PDFInk file.pdf
make test                       # unit tests (coordinate transforms, serialization)
```

Only the Xcode Command Line Tools are required. **Note for this machine:** the
CLT install is half-updated and two workarounds are active — see
`scripts/fix-clt.sh` (stale duplicate `SwiftBridging` modulemap masked via
`-vfsoverlay`; the reason every swiftc invocation carries that flag) and
`scripts/fix-swiftpm.sh` (stale SwiftPM manifest interfaces). The Makefile
drives `swiftc` directly; `Package.swift` is kept so the project opens in
Xcode/SPM once a healthy toolchain is installed (`swift build` will then work
with `SWIFTPM_CUSTOM_LIBS_DIR` per fix-swiftpm.sh, or unmodified after a CLT
reinstall).

## Features

- Open PDFs via File ▸ Open, drag-and-drop, or CLI argument; continuous
  vertical scroll with a page-thumbnail sidebar (PDFThumbnailView).
- Tools: pen (pressure 0.5–4 pt at medium width), highlighter (constant width,
  40% alpha, multiply blend), stroke-level eraser, lasso (stubbed).
  Keyboard: ⌘1/⌘2/⌘3. 6 preset colors + custom (NSColorPanel), 3 width presets.
- Wacom: `NSEvent.subtype == .tabletPoint` pressure drives stroke width; tilt
  is logged; flipping the stylus to its eraser end auto-switches tools via
  `.tabletProximity` monitoring. Mouse/trackpad falls back to constant pressure.
- Strokes are stored in **PDF page space** and stay registered at any zoom
  (pinch or ⌘+/⌘−). Committed strokes render from per-page bitmap caches;
  the live stroke draws incrementally with Catmull-Rom smoothing.
- Undo/redo per stroke (NSUndoManager, preserves z-order on reinsert).
- ⌘S writes strokes as PDF **ink annotations** in place — visible in Preview,
  Acrobat, etc. Full-fidelity stroke JSON (per-sample pressure) is stashed in
  each annotation, so PDFInk re-opens its own annotations as editable strokes.
- File ▸ Export Flattened PDF burns the ink (with pressure-varying widths)
  into page content.
- Autosave drafts every 30 s (and at quit) to
  `~/Library/Application Support/PDFInk/Drafts/`; unsaved ink is restored on
  next open.
- **Whiteboards** (notebook mode): File ▸ New Whiteboard — Blank (⌘N), Grid,
  or Lined paper. Created as real PDFs in `~/Documents/PDFInk Whiteboards/`
  and auto-saved notebook-style. Add Pages (⌘⇧N) adds matching pages
  (works on opened PDFs too, adding blank pages).
- **Blank documents**: File ▸ Create a Blank Document… (⌘⌥N, also a button on
  the start screen) asks for the page count and paper size (A4/A3/A5/Letter/
  Legal or custom) and opens it as an untitled document. Press ⌘S to pick
  the folder and file name in the standard Save panel (you're also asked when
  closing, quitting or opening something else while it is unsaved).
- Page management: Add Pages prompts for count and dimensions, with an
  "Add after current page" checkbox (otherwise pages go after the last page).
  In the page sidebar, ⌘-click or ⇧-click to select several pages, then drag
  any selected thumbnail to rearrange them together (ink follows its pages;
  undoable). Right-click a thumbnail for **Delete Page** / **Delete N Pages**
  (or select pages and press Delete). Deletions remap ink to follow the pages
  and are undoable via ⌘Z.
- Text Select tool: the **T** button in the toolbar (or press T) lets you
  select PDF text, then copy it with ⌘C (Edit ▸ Copy).
- Colors: keys **1–5** pick the palette colors from left to right. Pressing a
  number again (or the number of the active color) steps forward through the
  palette and wraps around, e.g. 3, 3, 3, 3 → colors 3, 4, 5, 1. Palette
  circles have a white outline so dark colors show on the dark toolbar.
- Lasso selection: a dark bar with the five palette colors floats above the
  selection (and follows it while you move/scale/rotate). Click a color to
  recolor every selected stroke (undoable); the ring marks the shared color
  when all selected strokes have the same palette color.

## Architecture

| Component | File | Role |
|---|---|---|
| `DrawingCanvasView` | `Sources/PDFInk/` | Input (mouse/tablet), live rendering, per-page bitmap caches |
| `StrokeStore` | `Sources/PDFInkCore/` | Model: strokes per page in page space, hit-testing, JSON |
| `StrokeGeometry` | `Sources/PDFInkCore/` | Pressure→width, Catmull-Rom, page↔view affine transforms |
| `StrokeRenderer` | `Sources/PDFInkCore/` | Stroke → CGContext (canvas cache + flattened export) |
| `AnnotationSerializer` | `Sources/PDFInkCore/` | Stroke ↔ PDFAnnotation (PDFKit bridge) |
| `ToolState` | `Sources/PDFInk/` | Current tool/color/width, eraser-flip state |
| `AutosaveManager` | `Sources/PDFInk/` | 30 s draft autosave to Application Support |
| `FlattenedExporter` | `Sources/PDFInk/` | Flattened PDF export via CGContext |

A stroke is an array of `(point, pressure)` samples plus tool metadata. All
page↔view mapping goes through PDFView's `convert` APIs; the canvas derives
exact affine transforms from three reference points (covers scale, translation,
and flips), unit-tested in `Tests/PDFInkCoreTests`.
