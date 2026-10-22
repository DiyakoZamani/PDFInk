import AppKit

/// Keeps text selection as a separate interaction mode rather than adding a
/// pseudo-drawing tool to the stroke model.
extension MainWindowController {
    @objc func selectTextSelectionAction(_ sender: Any?) {
        toolState.isTextSelectionEnabled.toggle()
        canvas?.toolStateDidChange()
    }
}
