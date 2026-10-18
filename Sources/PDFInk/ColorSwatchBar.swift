import AppKit
import PDFInkCore

final class ColorSwatchButton: NSView {
    var color = StrokeColor(red: 0, green: 0, blue: 0) { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onEdit: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) || isActive || event.clickCount == 2 {
            onEdit?()
        } else {
            onSelect?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onEdit?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 0.75
        circle.stroke()

        if isActive {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

/// Horizontal row of 5 color circles for the toolbar.
final class ColorSwatchBar: NSView {
    private static let diameter: CGFloat = 22
    private static let spacing: CGFloat = 6
    private static let size = NSSize(
        width: CGFloat(ColorPalette.slotCount) * diameter
             + CGFloat(ColorPalette.slotCount - 1) * spacing + 4,
        height: 26)

    var onSelect: ((Int) -> Void)?
    var onEdit: ((Int) -> Void)?
    private var buttons: [ColorSwatchButton] = []

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true

        for i in 0..<ColorPalette.slotCount {
            let x = 2 + CGFloat(i) * (Self.diameter + Self.spacing)
            let button = ColorSwatchButton(frame: NSRect(x: x, y: 2,
                                                         width: Self.diameter, height: Self.diameter))
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel("Color slot \(i + 1)")
            button.onSelect = { [weak self] in self?.onSelect?(i) }
            button.onEdit = { [weak self] in self?.onEdit?(i) }
            addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.size }

    func reload(from palette: ColorPalette) {
        for (i, button) in buttons.enumerated() where palette.colors.indices.contains(i) {
            button.color = palette.colors[i]
            button.isActive = (i == palette.activeSlot)
            button.toolTip = palette.colors[i].hexString
        }
    }
}
