import Foundation
import PDFInkCore

/// Five user-editable color slots + the active slot, persisted in UserDefaults.
final class ColorPalette {
    static let slotCount = 5
    private static let colorsKey = "pdfink.paletteColors"
    private static let activeSlotKey = "pdfink.activeColorSlot"

    private let defaults: UserDefaults
    private(set) var colors: [StrokeColor]
    private(set) var activeSlot: Int
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Default palette: first five presets (Black, Blue, Red, Green, Yellow).
        var loaded = (0..<ColorPalette.slotCount).map { ToolState.presetColors[$0].color }
        if let hexes = defaults.stringArray(forKey: ColorPalette.colorsKey) {
            for (i, hex) in hexes.prefix(ColorPalette.slotCount).enumerated() {
                if let c = StrokeColor.from(hex: hex) { loaded[i] = c }   // bad entry -> keep default
            }
        }
        self.colors = loaded

        let saved = defaults.object(forKey: ColorPalette.activeSlotKey) as? Int ?? 0
        self.activeSlot = (0..<ColorPalette.slotCount).contains(saved) ? saved : 0
    }

    func setColor(_ color: StrokeColor, at slot: Int) {
        guard colors.indices.contains(slot) else { return }
        colors[slot] = color
        persist()
        onChange?()
    }

    func select(slot: Int) {
        activeSlot = min(max(slot, 0), ColorPalette.slotCount - 1)
        persist()
        onChange?()
    }

    private func persist() {
        defaults.set(colors.map { $0.hexString }, forKey: ColorPalette.colorsKey)
        defaults.set(activeSlot, forKey: ColorPalette.activeSlotKey)
    }
}
