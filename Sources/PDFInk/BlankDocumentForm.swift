import AppKit

/// Accessory form for "Create a Blank Document": page count + paper size.
/// Standard sizes are in PDF points (72 pt = 1 inch).
final class BlankDocumentForm: NSObject {

    struct Preset {
        let name: String
        /// Portrait size; nil means the width/height fields are user-defined.
        let size: CGSize?
    }

    static let presets: [Preset] = [
        Preset(name: "A4", size: CGSize(width: 595, height: 842)),
        Preset(name: "A3", size: CGSize(width: 842, height: 1191)),
        Preset(name: "A5", size: CGSize(width: 420, height: 595)),
        Preset(name: "US Letter", size: CGSize(width: 612, height: 792)),
        Preset(name: "US Legal", size: CGSize(width: 612, height: 1008)),
        Preset(name: "Custom", size: nil),
    ]

    let view = NSStackView()
    var initialResponder: NSView { countField }

    private let countField = NSTextField(string: "1")
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orientationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")

    override init() {
        super.init()

        presetPopup.addItems(withTitles: Self.presets.map(\.name))
        orientationPopup.addItems(withTitles: ["Portrait", "Landscape"])
        for popup in [presetPopup, orientationPopup] {
            popup.target = self
            popup.action = #selector(selectionChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 130).isActive = true
        }
        for field in [countField, widthField, heightField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        func row(_ title: String, _ control: NSView, _ unit: String? = nil) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 78).isActive = true
            var views: [NSView] = [label, control]
            if let unit { views.append(NSTextField(labelWithString: unit)) }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 6
            return stack
        }

        view.setViews([
            row("Pages", countField),
            row("Size", presetPopup),
            row("Orientation", orientationPopup),
            row("Width", widthField, "pt"),
            row("Height", heightField, "pt"),
        ], in: .top)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 160)

        selectionChanged(nil)
    }

    @objc private func selectionChanged(_ sender: Any?) {
        let preset = Self.presets[max(presetPopup.indexOfSelectedItem, 0)]
        let isCustom = preset.size == nil
        widthField.isEnabled = isCustom
        heightField.isEnabled = isCustom
        orientationPopup.isEnabled = !isCustom
        guard let base = preset.size else { return }
        let landscape = orientationPopup.indexOfSelectedItem == 1
        let size = landscape ? CGSize(width: base.height, height: base.width) : base
        widthField.stringValue = String(format: "%g", size.width)
        heightField.stringValue = String(format: "%g", size.height)
    }

    /// Parsed page count and size, or nil when the input is invalid.
    func result() -> (count: Int, size: CGSize)? {
        func trimmed(_ field: NSTextField) -> String {
            field.stringValue.trimmingCharacters(in: .whitespaces)
        }
        guard let count = Int(trimmed(countField)), (1...1000).contains(count),
              let width = Double(trimmed(widthField)), width > 0,
              let height = Double(trimmed(heightField)), height > 0 else { return nil }
        return (count, CGSize(width: min(width, 20000), height: min(height, 20000)))
    }
}
