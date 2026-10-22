import AppKit
import PDFInkCore

/// Current tool/color/width selection, shared by toolbar, menus, and canvas.
/// Pen size, highlighter size and highlighter opacity persist across launches.
final class ToolState {

    static let presetColors: [(name: String, color: StrokeColor)] = [
        ("Black", StrokeColor(red: 0.10, green: 0.10, blue: 0.10)),
        ("Blue", StrokeColor(red: 0.00, green: 0.35, blue: 0.95)),
        ("Red", StrokeColor(red: 0.90, green: 0.15, blue: 0.15)),
        ("Green", StrokeColor(red: 0.05, green: 0.60, blue: 0.25)),
        ("Yellow", StrokeColor(red: 1.00, green: 0.85, blue: 0.10)),
        ("Purple", StrokeColor(red: 0.55, green: 0.20, blue: 0.85)),
    ]

    /// Kept for compatibility (no longer used by the toolbar).
    static let widthPresets: [(name: String, width: CGFloat)] = [
        ("Thin", 1.0), ("Medium", 2.0), ("Thick", 4.0),
    ]

    static let penWidthRange: ClosedRange<CGFloat> = 0.5...10
    static let highlighterWidthRange: ClosedRange<CGFloat> = 1...6
    static let opacityRange: ClosedRange<CGFloat> = 0.1...1.0

    private enum Key {
        static let penWidth = "pdfink.penWidth"
        static let highlighterWidth = "pdfink.highlighterWidth"
        static let highlighterOpacity = "pdfink.highlighterOpacity"
    }

    private let defaults: UserDefaults

    var onChange: (() -> Void)?

    /// When enabled, pointer events pass through the drawing overlay to PDFView,
    /// allowing PDFKit's native text selection and copy behaviour.
    var isTextSelectionEnabled = false {
        didSet {
            guard oldValue != isTextSelectionEnabled else { return }
            onChange?()
        }
    }

    private var eraserSetByStylus = false
    private var applyingStylusSwitch = false

    var tool: Tool = .pen {
        didSet {
            isTextSelectionEnabled = false
            if oldValue != tool, oldValue != .eraser { lastDrawingTool = oldValue }
            if !applyingStylusSwitch { eraserSetByStylus = false }   // user picked a tool manually
            onChange?()
        }
    }

    /// The drawing tool to restore when the stylus eraser end leaves proximity.
    private(set) var lastDrawingTool: Tool = .pen

    var color: StrokeColor = ToolState.presetColors[0].color { didSet { onChange?() } }

    private(set) var penWidth: CGFloat = 2.0 {
        didSet { defaults.set(Double(penWidth), forKey: Key.penWidth); onChange?() }
    }
    private(set) var highlighterWidth: CGFloat = 2.0 {
        didSet { defaults.set(Double(highlighterWidth), forKey: Key.highlighterWidth); onChange?() }
    }
    var highlighterOpacity: CGFloat = 0.4 {
        didSet {
            highlighterOpacity = Self.clamp(highlighterOpacity, Self.opacityRange)
            defaults.set(Double(highlighterOpacity), forKey: Key.highlighterOpacity)
            onChange?()
        }
    }

    /// Size of the current tool (pen and highlighter are remembered separately).
    var baseWidth: CGFloat {
        get { tool == .highlighter ? highlighterWidth : penWidth }
        set {
            if tool == .highlighter {
                highlighterWidth = Self.clamp(newValue, Self.highlighterWidthRange)
            } else {
                penWidth = Self.clamp(newValue, Self.penWidthRange)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load(_ key: String, _ fallback: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return Self.clamp(CGFloat(defaults.double(forKey: key)), range)
        }
        // Property observers don't fire inside init, so loading doesn't rewrite defaults.
        penWidth = load(Key.penWidth, 2.0, Self.penWidthRange)
        highlighterWidth = load(Key.highlighterWidth, 2.0, Self.highlighterWidthRange)
        highlighterOpacity = load(Key.highlighterOpacity, 0.4, Self.opacityRange)
    }

    private static func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
        min(max(v, r.lowerBound), r.upperBound)
    }

    /// Called from tablet proximity handling when the stylus is flipped.
    /// Only reverts the tool if the eraser was activated by the stylus itself.
    func stylusEnteredProximity(isEraserEnd: Bool) {
        applyingStylusSwitch = true
        defer { applyingStylusSwitch = false }
        if isEraserEnd {
            if tool != .eraser {
                eraserSetByStylus = true
                tool = .eraser
            }
        } else if eraserSetByStylus {
            eraserSetByStylus = false
            if tool == .eraser { tool = lastDrawingTool == .eraser ? .pen : lastDrawingTool }
        }
    }

    var nsColor: NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    func setColor(from nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return }
        color = StrokeColor(red: rgb.redComponent, green: rgb.greenComponent,
                            blue: rgb.blueComponent, alpha: 1.0)
    }
}
