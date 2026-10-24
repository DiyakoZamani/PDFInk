import Foundation
import CoreGraphics

/// Drawing tools available in the app.
public enum Tool: String, Codable, CaseIterable, Sendable {
    case pen
    case highlighter
    case eraser
    case lasso // stubbed for v1
    /// An imported raster image. Stored as a `Stroke` so selection, transforms,
    /// z-order, undo, autosave and page remapping all work unchanged: `samples`
    /// holds the image's four corners in page space (bottom-left, bottom-right,
    /// top-right, top-left) and `imageData` holds the encoded pixels.
    case image
}

/// A single input sample: a point in PDF page space plus stylus pressure.
public struct StrokeSample: Codable, Equatable, Sendable {
    /// Point in PDF page coordinates (origin bottom-left, unscaled).
    public var point: CGPoint
    /// Normalized pressure 0...1. Mouse/trackpad input uses a constant fallback.
    public var pressure: CGFloat

    public init(point: CGPoint, pressure: CGFloat) {
        self.point = point
        self.pressure = pressure
    }
}

/// RGBA color stored as components so the model stays Codable and AppKit-free.
public struct StrokeColor: Codable, Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// One committed stroke: samples in PDF page space plus tool metadata.
public struct Stroke: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tool: Tool
    public var color: StrokeColor
    /// Base width in PDF points at pressure ~0.5; actual segment widths scale with pressure.
    public var baseWidth: CGFloat
    /// Index of the page this stroke belongs to.
    public var pageIndex: Int
    public var samples: [StrokeSample]
    /// Highlighter opacity 0...1. nil = legacy default (StrokeRenderer.highlighterAlpha). Unused by the pen.
    public var opacity: CGFloat?
    /// Encoded image bytes (PNG) for `.image` strokes; nil for every other tool.
    public var imageData: Data?

    public init(id: UUID = UUID(),
                tool: Tool,
                color: StrokeColor,
                baseWidth: CGFloat,
                pageIndex: Int,
                samples: [StrokeSample] = [],
                opacity: CGFloat? = nil,
                imageData: Data? = nil) {
        self.id = id
        self.tool = tool
        self.color = color
        self.baseWidth = baseWidth
        self.pageIndex = pageIndex
        self.samples = samples
        self.opacity = opacity
        self.imageData = imageData
    }

    /// Builds an image item from its page-space center, size (points) and rotation (radians).
    public static func image(data: Data, pageIndex: Int, center: CGPoint,
                             size: CGSize, rotation: CGFloat = 0) -> Stroke {
        let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation)
        let hw = size.width / 2, hh = size.height / 2
        let corners = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                       CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
            .map { $0.applying(t) }
        return Stroke(tool: .image, color: StrokeColor(red: 0, green: 0, blue: 0),
                      baseWidth: 0, pageIndex: pageIndex,
                      samples: corners.map { StrokeSample(point: $0, pressure: 1) },
                      imageData: data)
    }

    /// Returns a copy with all sample points transformed. `widthScale` scales the pen width too.
    public func applying(_ t: CGAffineTransform, widthScale: CGFloat = 1) -> Stroke {
        var s = self
        s.samples = samples.map { StrokeSample(point: $0.point.applying(t), pressure: $0.pressure) }
        s.baseWidth = baseWidth * widthScale
        return s
    }

    /// Axis-aligned bounding box in page space, outset by the maximum possible width.
    public var pageBounds: CGRect {
        guard let first = samples.first else { return .null }
        var minX = first.point.x, maxX = first.point.x
        var minY = first.point.y, maxY = first.point.y
        for s in samples {
            minX = min(minX, s.point.x); maxX = max(maxX, s.point.x)
            minY = min(minY, s.point.y); maxY = max(maxY, s.point.y)
        }
        let pad = tool == .image ? 0 : StrokeGeometry.width(forPressure: 1.0, baseWidth: baseWidth, tool: tool)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -pad, dy: -pad)
    }
}
