import AppKit
import QuartzCore
import SwiftUI

/// Typo drawn once per expression into small images, then moved by Core
/// Animation. Redrawing Typo's vector art every frame cost about 15% of a CPU
/// core while it only stood and breathed; moving cached layers costs about 1%,
/// because almost every frame changes only the pose (hop, squash, sink, tilt),
/// not the face.
@MainActor
final class TypoSpriteSet {
    /// The part of the design space the images cover: Typo, its bubble when
    /// enlarged about its tail, shout lines, and room for the white edge.
    static let region = CGRect(x: 300, y: 300, width: 1640, height: 1060)
    /// Cached images beyond this many are dropped; a dictation uses a few dozen.
    static let capacity = 64
    /// The talking mouth follows the microphone in this many steps.
    static let mouthSteps: CGFloat = 8

    private(set) var scale: CGFloat = 0
    private var backing: CGFloat = 0
    private var bodies: [TypoExpression: CGImage] = [:]
    private var bubbles: [TypoExpression.Glyph: CGImage] = [:]
    private(set) var shadow: CGImage?

    /// The expression's drawing without its bubble, with continuous values
    /// snapped so near-identical frames share one image.
    static func bodyKey(_ e: TypoExpression) -> TypoExpression {
        var key = e
        key.bubble = nil
        key.bubbleOpacity = 0
        key.bubbleScale = 1
        key.mouthOpen = e.mouth == .talk ? (e.mouthOpen * mouthSteps).rounded() / mouthSteps : 1
        return key
    }

    /// Sets the size the images are drawn at; a change drops what was cached
    /// and answers true.
    @discardableResult
    func prepare(scale: CGFloat, backing: CGFloat) -> Bool {
        guard scale != self.scale || backing != self.backing else { return false }
        self.scale = scale
        self.backing = backing
        bodies.removeAll()
        bubbles.removeAll()
        shadow = nil
        return true
    }

    var cachedCount: Int { bodies.count + bubbles.count }

    func body(_ key: TypoExpression) -> CGImage? {
        if let image = bodies[key] { return image }
        if cachedCount >= Self.capacity {
            bodies.removeAll()
            bubbles.removeAll()
        }
        let image = render(key, parts: .body)
        bodies[key] = image
        return image
    }

    func bubble(_ glyph: TypoExpression.Glyph) -> CGImage? {
        if let image = bubbles[glyph] { return image }
        var e = TypoExpression()
        e.bubble = glyph
        e.bubbleOpacity = 1
        let image = render(e, parts: .bubble)
        bubbles[glyph] = image
        return image
    }

    /// The shadow's falloff on a unit disc; the layer stretches it to the ellipse.
    func shadowImage() -> CGImage? {
        if let shadow { return shadow }
        let disc = Canvas { ctx, size in
            ctx.fill(
                Path(ellipseIn: CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(stops: TypoRenderer.shadowStops),
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: 0, endRadius: size.width / 2
                )
            )
        }
        .frame(width: 48, height: 48)
        let renderer = ImageRenderer(content: disc)
        renderer.scale = 1
        shadow = renderer.cgImage
        return shadow
    }

    private func render(_ e: TypoExpression, parts: TypoRenderer.Parts) -> CGImage? {
        let region = Self.region
        let scale = self.scale
        let picture = Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -region.minX, y: -region.minY)
            TypoRenderer.draw(
                e, outline: 3 / scale, minimumLine: TypoRenderer.minimumLinePoints / scale,
                parts: parts, in: &ctx
            )
        }
        .frame(width: region.width * scale, height: region.height * scale)
        let renderer = ImageRenderer(content: picture)
        renderer.scale = backing
        return renderer.cgImage
    }
}

extension TypoRenderer {
    /// `motion(of:)` for a layer whose bounds are in view points with y up:
    /// scaled from design units to points and flipped from y-down.
    static func layerTransform(of pose: TypoPerformance.Pose, scale: CGFloat) -> CGAffineTransform {
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let toPoints = CGAffineTransform(scaleX: scale, y: scale)
        return flip
            .concatenating(toPoints.inverted())
            .concatenating(motion(of: pose))
            .concatenating(toPoints)
            .concatenating(flip)
    }

    /// The bubble's own growth about its tail, which stays on Typo's body, as
    /// a layer transform (y up, points, relative to Typo's feet).
    static func bubbleTransform(scale: CGFloat, growth: CGFloat) -> CGAffineTransform {
        let tail = CGPoint(
            x: (TypoGeometry.bubbleTail.x - feetAnchor.x) * scale,
            y: -(TypoGeometry.bubbleTail.y - feetAnchor.y) * scale
        )
        return CGAffineTransform(translationX: tail.x, y: tail.y)
            .scaledBy(x: growth, y: growth)
            .translatedBy(x: -tail.x, y: -tail.y)
    }
}

/// Typo and its shadow as Core Animation layers. Callers hand over the pose
/// each frame in view points with y down (the way SwiftUI places it); a clip
/// hides the part of Typo below the line it stands on, or behind a capsule.
@MainActor
final class TypoSpriteView: NSView {
    enum Clip: Equatable {
        /// Typo is hidden below the line it stands on (and where a leap lands).
        case belowLine
        /// Typo is hidden inside this rounded rectangle (y down), like a bar's capsule.
        case behind(CGRect, cornerRadius: CGFloat)
    }

    var clip: Clip = .belowLine {
        didSet { if clip != oldValue { applyClipShape() } }
    }

    private let sprites = TypoSpriteSet()
    private let shadowLayer = CALayer()
    private let clipLayer = CALayer()
    private let bubbleLayer = CALayer()
    private let bodyLayer = CALayer()
    private let capsuleMask = CAShapeLayer()
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    private var shownBody: TypoExpression?
    private var shownGlyph: TypoExpression.Glyph?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [shadowLayer, bubbleLayer, bodyLayer] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
        }
        clipLayer.addSublayer(bubbleLayer)
        clipLayer.addSublayer(bodyLayer)
        layer?.addSublayer(shadowLayer)
        layer?.addSublayer(clipLayer)
        badgeLayer.backgroundColor = NSColor.white.cgColor
        badgeLayer.borderColor = NSColor.black.cgColor
        badgeText.foregroundColor = NSColor.black.cgColor
        badgeText.alignmentMode = .center
        badgeLayer.addSublayer(badgeText)
        layer?.addSublayer(badgeLayer)
        capsuleMask.fillRule = .evenOdd
        applyClipShape()
        hide()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shownBody = nil
        shownGlyph = nil
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func hide() {
        shadowLayer.isHidden = true
        clipLayer.isHidden = true
        badgeLayer.isHidden = true
    }

    /// Where the count of held cards sits: on Typo's upper-left shoulder, in
    /// design units from its feet, moved with every hop, tilt and somersault.
    static let badgeAnchor = CGPoint(x: -400, y: -660)

    private func updateBadge(_ pose: TypoPerformance.Pose, motion: CGAffineTransform, line: CGPoint, scale: CGFloat) {
        let opacity = pose.opacity * pose.badgeOpacity
        let p = Self.badgeAnchor.applying(motion)
        // Below the line it stands on the badge is hidden with Typo's body.
        guard pose.badge > 0, opacity > 0.01, p.y < -60 else {
            badgeLayer.isHidden = true
            return
        }
        let diameter = max(14, 200 * scale)
        let height = bounds.height
        badgeLayer.isHidden = false
        badgeLayer.opacity = Float(opacity)
        badgeLayer.frame = CGRect(
            x: line.x + p.x * scale - diameter / 2,
            y: height - (line.y + p.y * scale) - diameter / 2,
            width: diameter, height: diameter
        )
        badgeLayer.cornerRadius = diameter / 2
        badgeLayer.borderWidth = max(1.2, diameter * 0.09)
        let fontSize = diameter * 0.6
        badgeText.contentsScale = backingScale
        badgeText.font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        badgeText.fontSize = fontSize
        badgeText.string = pose.badge > 9 ? "9+" : "\(pose.badge)"
        badgeText.frame = CGRect(x: 0, y: (diameter - fontSize * 1.2) / 2, width: diameter, height: fontSize * 1.2)
    }

    private func applyClipShape() {
        switch clip {
        case .belowLine:
            clipLayer.mask = nil
            clipLayer.masksToBounds = true
        case .behind(let capsule, let radius):
            clipLayer.masksToBounds = false
            var path = Path(CGRect(origin: .zero, size: bounds.size))
            path.addPath(Path(roundedRect: capsule, cornerRadius: radius, style: .continuous))
            // The mask lives in view coordinates with y up; flip the y-down path.
            var flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -bounds.height)
            capsuleMask.path = path.cgPath.copy(using: &flip)
            capsuleMask.frame = bounds
            clipLayer.mask = capsuleMask
        }
    }

    override func layout() {
        super.layout()
        if case .behind = clip { applyClipShape() }
    }

    /// Draws `pose` with Typo's feet at `line` (view points, y down), `scale`
    /// view points per design unit.
    func update(pose: TypoPerformance.Pose, line: CGPoint, scale: CGFloat) {
        guard pose.opacity > 0.001, scale > 0, bounds.width > 0 else {
            hide()
            return
        }
        let backing = backingScale
        if sprites.prepare(scale: scale, backing: backing) {
            shownBody = nil
            shownGlyph = nil
            shadowLayer.contents = nil
        }
        let height = bounds.height
        let lineUp = height - line.y

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Shadow, in the view's own coordinates: never clipped.
        let ellipse = TypoRenderer.shadowEllipse(pose, line: line, scale: scale)
        let shadow = TypoShadow(pose)
        // Typo behind a capsule has no ground of its own to cast a shadow on.
        var castsShadow = shadow.darkness > 0.005
        if case .behind = clip { castsShadow = false }
        shadowLayer.isHidden = !castsShadow
        if !shadowLayer.isHidden {
            if shadowLayer.contents == nil {
                shadowLayer.contents = sprites.shadowImage()
                shadowLayer.contentsScale = 1
            }
            shadowLayer.frame = CGRect(x: ellipse.minX, y: height - ellipse.maxY, width: ellipse.width, height: ellipse.height)
            shadowLayer.opacity = Float(shadow.darkness / TypoShadow.maxDarkness)
        }

        // The clip: everything above the line Typo stands on, or the whole view.
        clipLayer.isHidden = false
        let clipOriginY: CGFloat
        switch clip {
        case .belowLine:
            let edge = line.y + pose.travel.height * scale + 1
            clipOriginY = height - max(0, edge)
            clipLayer.frame = CGRect(x: 0, y: clipOriginY, width: bounds.width, height: max(0, edge))
        case .behind:
            clipOriginY = 0
            clipLayer.frame = bounds
        }
        clipLayer.opacity = Float(pose.opacity)

        // Body and bubble share the sprite's frame, anchored at Typo's feet.
        let region = TypoSpriteSet.region
        let size = CGSize(width: region.width * scale, height: region.height * scale)
        let anchor = CGPoint(
            x: (TypoRenderer.feetAnchor.x - region.minX) / region.width,
            y: 1 - (TypoRenderer.feetAnchor.y - region.minY) / region.height
        )
        let position = CGPoint(x: line.x, y: lineUp - clipOriginY)
        let motion = TypoRenderer.layerTransform(of: pose, scale: scale)
        for layer in [bodyLayer, bubbleLayer] {
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.anchorPoint = anchor
            layer.position = position
            layer.contentsScale = backing
        }
        bodyLayer.setAffineTransform(motion)
        updateBadge(pose, motion: TypoRenderer.motion(of: pose), line: line, scale: scale)

        let key = TypoSpriteSet.bodyKey(pose.expression)
        if key != shownBody {
            bodyLayer.contents = sprites.body(key)
            shownBody = key
        }

        let e = pose.expression
        if let glyph = e.bubble, e.bubbleOpacity > 0.01 {
            if glyph != shownGlyph {
                bubbleLayer.contents = sprites.bubble(glyph)
                shownGlyph = glyph
            }
            bubbleLayer.isHidden = false
            bubbleLayer.opacity = Float(e.bubbleOpacity)
            bubbleLayer.setAffineTransform(
                TypoRenderer.bubbleTransform(scale: scale, growth: e.bubbleScale).concatenating(motion)
            )
        } else {
            bubbleLayer.isHidden = true
        }
    }
}
