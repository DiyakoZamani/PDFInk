import Foundation
import PDFInkCore

extension StrokeColor {
    /// Parses "#RRGGBB", "RRGGBB", "#RGB" or "RGB" (case-insensitive). Alpha = 1.
    static func from(hex: String) -> StrokeColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return StrokeColor(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                           green: CGFloat((value >> 8) & 0xFF) / 255.0,
                           blue: CGFloat(value & 0xFF) / 255.0,
                           alpha: 1.0)
    }

    /// "#RRGGBB", uppercase.
    var hexString: String {
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
