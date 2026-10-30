import AppKit
import QuartzCore

/// A pointer that is drawn by the canvas itself instead of being requested
/// from AppKit.
///
/// Why: `NSCursor.set()` is a shared, last-writer-wins resource. PDFView (the
/// canvas's parent), AppKit's cursor rects and tracking areas all write to it
/// too, and which write lands last depends on event order and on how busy the
/// main thread is. That race is what makes a system cursor flicker.
///
/// So while the pointer is over the canvas we hide the system cursor and show
/// a small layer at the pointer position. Nobody else can change what the
/// layer shows, and a hidden system cursor stays hidden no matter what
/// anyone `set()`s.
///
/// Safety: hiding is level-triggered. The owner calls `show` / `hide` from
/// every relevant event, and while hidden a 10 Hz watchdog asks the owner to
/// re-evaluate, so the system cursor can never stay hidden for more than
/// ~100 ms after the pointer has left.
final class CanvasCursor {

    /// One cursor image. Hot spot is measured from the TOP-LEFT, in points,
    /// like `NSCursor.hotSpot`.
    final class Sprite {
        let image: CGImage
        let size: CGSize
        let hotSpot: CGPoint
        let scale: CGFloat

        init(image: CGImage, size: CGSize, hotSpot: CGPoint, scale: CGFloat) {
            self.image = image
            self.size = size
            self.hotSpot = hotSpot
            self.scale = scale
        }

        /// Draws a sprite with Core Graphics. `draw` runs in a y-up context
        /// measured in points (origin bottom-left).
        static func drawn(size: CGSize, hotSpot: CGPoint, scale: CGFloat = 4,
                          draw: (CGContext) -> Void) -> Sprite? {
            let w = Int((size.width * scale).rounded(.up))
            let h = Int((size.height * scale).rounded(.up))
            guard w > 0, h > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            draw(ctx)
            guard let image = ctx.makeImage() else { return nil }
            return Sprite(image: image, size: size, hotSpot: hotSpot, scale: scale)
        }

        /// Reuses the artwork of a system cursor (hand, I-beam, eraser poof).
        static func from(systemCursor cursor: NSCursor) -> Sprite? {
            let img = cursor.image
            guard img.size.width > 0, img.size.height > 0 else { return nil }
            var rect = CGRect(x: 0, y: 0, width: img.size.width * 2, height: img.size.height * 2)
            guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return Sprite(image: cg, size: img.size, hotSpot: cursor.hotSpot,
                          scale: CGFloat(cg.width) / img.size.width)
        }
    }

    // MARK: Built-in sprites

    /// Pen / highlighter / default: white outer ring + dark inner ring, so it
    /// is visible on any background.
    static let circle: Sprite? = Sprite.drawn(size: CGSize(width: 16, height: 16),
                                              hotSpot: CGPoint(x: 8, y: 8)) { ctx in
        let r = CGRect(x: 0, y: 0, width: 16, height: 16).insetBy(dx: 2.5, dy: 2.5)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.strokeEllipse(in: r)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokeEllipse(in: r)
    }

    /// Resize: a "+" whose four arms each end in an arrowhead (white halo
    /// under a black body).
    static let resize: Sprite? = Sprite.drawn(size: CGSize(width: 24, height: 24),
                                              hotSpot: CGPoint(x: 12, y: 12)) { ctx in
        let c = CGPoint(x: 12, y: 12)
        let reach: CGFloat = 10.5      // center → arrow tip
        let head: CGFloat = 5          // arrowhead length
        let half: CGFloat = 3.2        // arrowhead half-width
        let directions: [(CGFloat, CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        let path = CGMutablePath()
        for (dx, dy) in directions {
            let tip = CGPoint(x: c.x + dx * reach, y: c.y + dy * reach)
            let base = CGPoint(x: c.x + dx * (reach - head), y: c.y + dy * (reach - head))
            path.move(to: c)                                   // arm
            path.addLine(to: base)
            path.move(to: tip)                                 // arrowhead
            path.addLine(to: CGPoint(x: base.x - dy * half, y: base.y + dx * half))
            path.addLine(to: CGPoint(x: base.x + dy * half, y: base.y - dx * half))
            path.closeSubpath()
        }
        ctx.setLineJoin(.miter)

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(3.2)
        ctx.drawPath(using: .fillStroke)

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1.2)
        ctx.drawPath(using: .fillStroke)
    }

    static let eraser: Sprite? = Sprite.from(systemCursor: .disappearingItem)
    static let openHand: Sprite? = Sprite.from(systemCursor: .openHand)
    static let closedHand: Sprite? = Sprite.from(systemCursor: .closedHand)
    static let iBeam: Sprite? = Sprite.from(systemCursor: .iBeam)

    // MARK: Presentation

    /// Called ~10×/s while the system cursor is hidden; the owner re-evaluates
    /// whether the pointer is still inside its region.
    var onWatchdogTick: (() -> Void)?

    private let layer = CALayer()
    private var currentSprite: Sprite?
    private var systemCursorHidden = false
    private var watchdog: Timer?

    init() {
        layer.anchorPoint = .zero
        layer.zPosition = 10_000
        layer.isHidden = true
    }

    deinit {
        watchdog?.invalidate()
        if systemCursorHidden { NSCursor.unhide() }
    }

    /// Idempotent. Call whenever the host layer may have changed.
    func attach(to host: CALayer) {
        guard layer.superlayer !== host else { return }
        layer.removeFromSuperlayer()
        host.addSublayer(layer)
    }

    /// Shows `sprite` with its hot spot at `point` (host-layer coordinates,
    /// y-up) and hides the system cursor.
    func show(_ sprite: Sprite, at point: CGPoint, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentSprite !== sprite {
            currentSprite = sprite
            layer.bounds = CGRect(origin: .zero, size: sprite.size)
            layer.contentsScale = sprite.scale
            layer.contents = sprite.image
        }
        let scale = max(backingScale, 1)
        let x = point.x - sprite.hotSpot.x
        let y = point.y - (sprite.size.height - sprite.hotSpot.y)
        layer.position = CGPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale)
        layer.isHidden = false
        CATransaction.commit()
        setSystemCursorHidden(true)
    }

    /// Hides our pointer and gives the system cursor back.
    func hide() {
        if !layer.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.isHidden = true
            CATransaction.commit()
        }
        setSystemCursorHidden(false)
    }

    /// The only place that calls hide/unhide, and only on a real change, so
    /// the calls are always balanced.
    private func setSystemCursorHidden(_ hidden: Bool) {
        guard hidden != systemCursorHidden else { return }
        systemCursorHidden = hidden
        if hidden {
            NSCursor.hide()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.onWatchdogTick?()
            }
            RunLoop.main.add(timer, forMode: .common)   // .common: also fires during menu tracking
            watchdog = timer
        } else {
            NSCursor.unhide()
            watchdog?.invalidate()
            watchdog = nil
        }
    }
}
