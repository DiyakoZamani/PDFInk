import Foundation
import CoreGraphics
import ImageIO

/// Renders strokes into a CGContext whose coordinate system is PDF page space
/// (or view space with a page→view transform already concatenated).
/// Shared by the live canvas, the bitmap cache, and flattened PDF export.
public enum StrokeRenderer {

    public static let highlighterAlpha: CGFloat = 0.4

    // Decoded images, keyed by item id, so dragging/scaling doesn't re-decode every frame.
    private static let imageCache = NSCache<NSString, CGImage>()

    /// Decodes (and caches) the pixels of an `.image` item.
    public static func cgImage(for stroke: Stroke) -> CGImage? {
        let key = stroke.id.uuidString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = stroke.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Draws the image into the quad described by the item's four corner samples.
    private static func drawImage(_ stroke: Stroke, in ctx: CGContext) {
        guard stroke.samples.count == 4, let image = cgImage(for: stroke) else { return }
        let c = stroke.samples.map(\.point)          // BL, BR, TR, TL
        // Unit square → quad (handles move, uniform scale and rotation).
        let t = StrokeGeometry.affineTransform(mappingOrigin: c[0], unitX: c[1], unitY: c[3])
        ctx.saveGState()
        ctx.concatenate(t)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.restoreGState()
    }

    public static func draw(_ stroke: Stroke, in ctx: CGContext) {
        guard !stroke.samples.isEmpty else { return }
        if stroke.tool == .image { drawImage(stroke, in: ctx); return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = CGColor(red: stroke.color.red, green: stroke.color.green,
                            blue: stroke.color.blue, alpha: 1.0)
        ctx.setStrokeColor(color)

        switch stroke.tool {
        case .highlighter:
            // Single stroked path at constant alpha: overlapping segments would
            // double-blend, so the whole stroke is one stroke operation.
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(min(max(stroke.opacity ?? highlighterAlpha, 0.05), 1))
            ctx.setLineWidth(StrokeGeometry.width(forPressure: 1, baseWidth: stroke.baseWidth, tool: .highlighter))
            ctx.addPath(StrokeGeometry.smoothedPath(stroke.samples))
            ctx.strokePath()
        default:
            ctx.setAlpha(stroke.color.alpha)
            if stroke.samples.count == 1 {
                // A tap: draw a dot sized by pressure.
                let s = stroke.samples[0]
                let w = StrokeGeometry.width(forPressure: s.pressure, baseWidth: stroke.baseWidth, tool: stroke.tool)
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: s.point.x - w / 2, y: s.point.y - w / 2, width: w, height: w))
                return
            }
            // Pressure-varying width: each smoothed segment stroked at its own
            // interpolated width. Opaque ink, so overlaps at joints are invisible.
            for seg in StrokeGeometry.catmullRomSegments(stroke.samples) {
                let w0 = StrokeGeometry.width(forPressure: seg.startPressure, baseWidth: stroke.baseWidth, tool: stroke.tool)
                let w1 = StrokeGeometry.width(forPressure: seg.endPressure, baseWidth: stroke.baseWidth, tool: stroke.tool)
                ctx.setLineWidth((w0 + w1) / 2)
                ctx.move(to: seg.start)
                ctx.addCurve(to: seg.end, control1: seg.c1, control2: seg.c2)
                ctx.strokePath()
            }
        }
    }

    /// Draws only the tail of an in-progress stroke (last few samples), used for
    /// incremental live rendering without re-stroking the whole polyline.
    public static func drawTail(samples: [StrokeSample], tool: Tool, color: StrokeColor,
                                baseWidth: CGFloat, tailCount: Int, in ctx: CGContext) {
        guard samples.count >= 2 else {
            draw(Stroke(tool: tool, color: color, baseWidth: baseWidth, pageIndex: 0, samples: samples), in: ctx)
            return
        }
        let start = max(0, samples.count - tailCount)
        let tail = Array(samples[start...])
        draw(Stroke(tool: tool, color: color, baseWidth: baseWidth, pageIndex: 0, samples: tail), in: ctx)
    }
}
