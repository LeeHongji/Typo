import SwiftUI

/// One frame of Typo, composed from parts that keep the reference style: a solid
/// black keycap, a white oval face, solid black features, detached stroke arms,
/// and a solid black speech bubble carrying a white glyph.
struct TypoExpression: Equatable {
    enum Eye: Equatable { case open, happy, relaxed, line, dot, ring, heart, chevron, angry, sad }
    enum Mouth: Equatable { case smile, grin, talk, shout, flat, frown, zigzag, tinyO, cat }
    enum Glyph: Equatable { case dots, exclaim, question, interrobang, heart, zz, check, vein, note }

    /// An arm is the traced reference stroke, optionally flipped upward about its
    /// shoulder end, then rotated clockwise by `degrees`.
    struct Arm: Equatable {
        var up = false
        var degrees: Double = 0
    }

    var eyeL: Eye = .open
    var eyeR: Eye = .open
    /// Offset of both eyes in design units, used to glance around.
    var look: CGSize = .zero
    var mouth: Mouth = .smile
    /// Scales the talking mouth, so it can follow the microphone level.
    var mouthOpen: CGFloat = 1
    var armL = Arm()
    var armR = Arm()
    var bubble: Glyph?
    var bubbleOpacity: Double = 0
    /// 0 keeps the traced silhouette; 1 is fully bristled.
    var spikiness: CGFloat = 0
    var blush = false
    var tears = false
    var sweat = false
    var impact = false
    var shout = false
}

enum TypoGeometry {
    static let ink = Color.black
    static let paper = Color.white
    static let line: CGFloat = 19.6
    static let eyeLCenter = CGPoint(x: 859, y: 830)
    static let eyeRCenter = CGPoint(x: 1088, y: 833)
    static let mouthCenter = CGPoint(x: 956, y: 912)
    static let armLPivot = CGPoint(x: 462, y: 930)
    static let armRPivot = CGPoint(x: 1444, y: 925)
    static let bodyCentroid = CGPoint(x: 936, y: 1003)
    static let bubbleCenter = CGPoint(x: 1618, y: 650)
    /// The line Typo stands on: the bottom edge of the traced body.
    static let baselineY: CGFloat = 1282
    static let bodyHeight: CGFloat = 728
    /// Region of the design space a companion view shows, with room above the
    /// head for hops, shout lines and the sweat drop.
    static let viewport = CGRect(x: 320, y: 300, width: 1540, height: 1000)
}

enum TypoPath {
    /// Smooth closed or open curve through traced points. Corners sharper than
    /// `cornerAngle` keep their point so notches and the bubble tail stay crisp,
    /// and each tangent is capped by its own segment so curves never overshoot.
    static func smooth(_ p: [CGPoint], closed: Bool, cornerAngle: CGFloat = 1.1) -> Path {
        var path = Path()
        let n = p.count
        guard n > 2 else { return path }
        func at(_ i: Int) -> CGPoint {
            closed ? p[(i % n + n) % n] : p[min(max(i, 0), n - 1)]
        }
        func isCorner(_ i: Int) -> Bool {
            if !closed && (i <= 0 || i >= n - 1) { return true }
            let a = at(i - 1), b = at(i), c = at(i + 1)
            let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            let l = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
            guard l > 0 else { return false }
            let cosv = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / l))
            return acos(cosv) > cornerAngle
        }
        func dir(_ a: CGPoint, _ b: CGPoint) -> CGVector {
            let l = hypot(b.x - a.x, b.y - a.y)
            return l > 0 ? CGVector(dx: (b.x - a.x) / l, dy: (b.y - a.y) / l) : .zero
        }
        path.move(to: at(0))
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            let seg = hypot(p2.x - p1.x, p2.y - p1.y) / 3
            let t1 = dir(p0, p2), t2 = dir(p1, p3)
            var c1 = CGPoint(x: p1.x + t1.dx * seg, y: p1.y + t1.dy * seg)
            var c2 = CGPoint(x: p2.x - t2.dx * seg, y: p2.y - t2.dy * seg)
            if isCorner(i) { c1 = p1 }
            if isCorner(i + 1) { c2 = p2 }
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }
}

enum TypoRenderer {
    typealias G = TypoGeometry

    private static let body = TypoPath.smooth(TypoReference.body, closed: true)
    private static let face = TypoPath.smooth(TypoReference.faceContour, closed: true)
    private static let bubble = TypoPath.smooth(TypoReference.bubble, closed: true)
    private static let armL = TypoPath.smooth(TypoReference.armLShape, closed: true)
    private static let armR = TypoPath.smooth(TypoReference.armRShape, closed: true)
    private static let eyeL = TypoPath.smooth(TypoReference.eyeL, closed: true)
    private static let eyeR = TypoPath.smooth(TypoReference.eyeR, closed: true)
    private static let mouth = TypoPath.smooth(TypoReference.mouthShape, closed: true)
    private static let bodySamples = evenSamples(of: body, count: 64)

    /// Draws one expression in design units. `outline` is the width, in design
    /// units, of the white sticker edge that keeps Typo legible on dark windows.
    static func draw(_ e: TypoExpression, outline: CGFloat, in ctx: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(G.ink)
        let paper = GraphicsContext.Shading.color(G.paper)
        let edge = StrokeStyle(lineWidth: outline, lineCap: .round, lineJoin: .round)

        let bodyPath = e.spikiness > 0.01 ? spikyBody(e.spikiness) : body
        let armPathL = arm(armL, pivot: G.armLPivot, pose: e.armL)
        let armPathR = arm(armR, pivot: G.armRPivot, pose: e.armR)

        if outline > 0 {
            for p in [bodyPath, armPathL, armPathR] { ctx.stroke(p, with: paper, style: edge) }
            if e.bubbleOpacity > 0.01 {
                var b = ctx
                b.opacity = e.bubbleOpacity
                b.stroke(bubble, with: paper, style: edge)
            }
        }

        if e.bubbleOpacity > 0.01 {
            var b = ctx
            b.opacity = e.bubbleOpacity
            b.fill(bubble, with: ink)
            if let glyph = e.bubble { drawGlyph(glyph, in: &b) }
        }
        if e.shout { drawShoutLines(outline: outline, in: &ctx) }
        if e.sweat { drawSweat(in: &ctx) }

        ctx.fill(armPathL, with: ink)
        ctx.fill(armPathR, with: ink)
        ctx.fill(bodyPath, with: ink)
        ctx.fill(face, with: paper)

        var f = ctx
        f.clip(to: face)
        drawEye(e.eyeL, center: G.eyeLCenter, traced: eyeL, isLeft: true, look: e.look, in: &f)
        drawEye(e.eyeR, center: G.eyeRCenter, traced: eyeR, isLeft: false, look: e.look, in: &f)
        drawMouth(e.mouth, open: e.mouthOpen, in: &f)
        if e.blush { drawBlush(in: &f) }
        if e.tears { drawTears(in: &f) }
        if e.impact { drawImpact(outline: outline, in: &ctx) }
    }

    // MARK: - Parts

    private static func arm(_ shape: Path, pivot: CGPoint, pose: TypoExpression.Arm) -> Path {
        var t = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        t = t.rotated(by: pose.degrees * .pi / 180)
        if pose.up { t = t.scaledBy(x: 1, y: -1) }
        t = t.translatedBy(x: -pivot.x, y: -pivot.y)
        return shape.applying(t)
    }

    private static func stroke(_ path: Path, _ ctx: inout GraphicsContext, width: CGFloat = G.line) {
        ctx.stroke(path, with: .color(G.ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func drawEye(
        _ eye: TypoExpression.Eye, center c0: CGPoint, traced: Path,
        isLeft: Bool, look: CGSize, in ctx: inout GraphicsContext
    ) {
        let c = CGPoint(x: c0.x + look.width, y: c0.y + look.height)
        let ink = GraphicsContext.Shading.color(G.ink)
        let moved = traced.applying(CGAffineTransform(translationX: look.width, y: look.height))
        let towardCentre: CGFloat = isLeft ? 1 : -1
        switch eye {
        case .open:
            ctx.fill(moved, with: ink)
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 44, y: c.y + 30))
            p.addQuadCurve(to: CGPoint(x: c.x + 44, y: c.y + 30), control: CGPoint(x: c.x, y: c.y - 78))
            stroke(p, &ctx, width: 24)
        case .relaxed:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 44, y: c.y + 6))
            p.addQuadCurve(to: CGPoint(x: c.x + 44, y: c.y + 6), control: CGPoint(x: c.x, y: c.y + 78))
            stroke(p, &ctx, width: 24)
        case .line:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 42, y: c.y + 22))
            p.addLine(to: CGPoint(x: c.x + 42, y: c.y + 18))
            stroke(p, &ctx, width: 24)
        case .dot:
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 26, y: c.y - 14, width: 52, height: 62)), with: ink)
        case .ring:
            stroke(Path(ellipseIn: CGRect(x: c.x - 50, y: c.y - 52, width: 100, height: 110)), &ctx, width: 20)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 16, y: c.y - 14, width: 32, height: 36)), with: ink)
        case .heart:
            ctx.fill(heart(center: CGPoint(x: c.x, y: c.y + 4), size: 128), with: ink)
        case .chevron:
            var p = Path()
            let d: CGFloat = isLeft ? 1 : -1
            p.move(to: CGPoint(x: c.x - 34 * d, y: c.y - 44))
            p.addLine(to: CGPoint(x: c.x + 36 * d, y: c.y + 4))
            p.addLine(to: CGPoint(x: c.x - 34 * d, y: c.y + 52))
            stroke(p, &ctx, width: 26)
        case .angry, .sad:
            // The traced eye with its upper corner sliced off: toward the face
            // centre for anger, away from it for sadness.
            let inner = eye == .angry ? towardCentre : -towardCentre
            let slope: CGFloat = eye == .angry ? 145 : 120
            var cut = Path()
            cut.move(to: CGPoint(x: c.x - 120, y: c.y + 260))
            cut.addLine(to: CGPoint(x: c.x + 120, y: c.y + 260))
            cut.addLine(to: CGPoint(x: c.x + 120, y: c.y - 60 + slope * inner))
            cut.addLine(to: CGPoint(x: c.x - 120, y: c.y - 60 - slope * inner))
            cut.closeSubpath()
            var e = ctx
            e.clip(to: cut)
            e.fill(moved, with: ink)
        }
    }

    private static func drawMouth(_ kind: TypoExpression.Mouth, open: CGFloat, in ctx: inout GraphicsContext) {
        let c = G.mouthCenter
        let ink = GraphicsContext.Shading.color(G.ink)
        switch kind {
        case .smile:
            ctx.fill(mouth, with: ink)
        case .grin:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 58, y: c.y - 14))
            p.addQuadCurve(to: CGPoint(x: c.x + 58, y: c.y - 18), control: CGPoint(x: c.x, y: c.y - 24))
            p.addQuadCurve(to: CGPoint(x: c.x - 58, y: c.y - 14), control: CGPoint(x: c.x + 6, y: c.y + 104))
            p.closeSubpath()
            ctx.fill(p, with: ink)
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 10, lineJoin: .round))
        case .talk:
            let w = 64 * (0.55 + 0.45 * open), h = 76 * open
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y + 12 - h / 2, width: w, height: max(14, h))), with: ink)
        case .shout:
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 50, y: c.y - 34, width: 100, height: 112)), with: ink)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 34, y: c.y + 10))
            p.addLine(to: CGPoint(x: c.x + 34, y: c.y + 6))
            stroke(p, &ctx)
        case .frown:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 38, y: c.y + 26))
            p.addQuadCurve(to: CGPoint(x: c.x + 38, y: c.y + 24), control: CGPoint(x: c.x, y: c.y - 30))
            stroke(p, &ctx)
        case .zigzag:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 52, y: c.y + 12))
            p.addLine(to: CGPoint(x: c.x - 26, y: c.y - 8))
            p.addLine(to: CGPoint(x: c.x, y: c.y + 12))
            p.addLine(to: CGPoint(x: c.x + 26, y: c.y - 8))
            p.addLine(to: CGPoint(x: c.x + 52, y: c.y + 12))
            stroke(p, &ctx)
        case .tinyO:
            stroke(Path(ellipseIn: CGRect(x: c.x - 17, y: c.y - 12, width: 34, height: 40)), &ctx, width: 16)
        case .cat:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 40, y: c.y - 6))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - 2), control: CGPoint(x: c.x - 22, y: c.y + 40))
            p.addQuadCurve(to: CGPoint(x: c.x + 40, y: c.y - 6), control: CGPoint(x: c.x + 22, y: c.y + 40))
            stroke(p, &ctx)
        }
    }

    private static func drawGlyph(_ glyph: TypoExpression.Glyph, in ctx: inout GraphicsContext) {
        var g = ctx
        let c = G.bubbleCenter
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .degrees(-12))
        let white = GraphicsContext.Shading.color(G.paper)
        func text(_ s: String, _ size: CGFloat) {
            let t = g.resolve(Text(s).font(.system(size: size, weight: .black, design: .rounded)).foregroundColor(G.paper))
            g.draw(t, at: .zero, anchor: .center)
        }
        switch glyph {
        case .dots:
            for i in -1...1 {
                g.fill(Path(ellipseIn: CGRect(x: CGFloat(i) * 68 - 22, y: -22, width: 44, height: 44)), with: white)
            }
        case .exclaim: text("!", 190)
        case .question: text("?", 180)
        case .interrobang: text("?!", 150)
        case .zz: text("Zz", 130)
        case .note: text("♪", 160)
        case .heart:
            g.fill(heart(center: CGPoint(x: 0, y: 4), size: 140), with: white)
        case .check:
            var p = Path()
            p.move(to: CGPoint(x: -58, y: 4))
            p.addLine(to: CGPoint(x: -14, y: 46))
            p.addLine(to: CGPoint(x: 62, y: -44))
            g.stroke(p, with: white, style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
        case .vein:
            for q in 0..<4 {
                let a = Double(q) * .pi / 2 + .pi / 4
                let mid = CGPoint(x: cos(a) * 52, y: sin(a) * 52)
                let t = CGPoint(x: -sin(a) * 30, y: cos(a) * 30)
                var p = Path()
                p.move(to: CGPoint(x: mid.x - t.x + cos(a) * 18, y: mid.y - t.y + sin(a) * 18))
                p.addQuadCurve(
                    to: CGPoint(x: mid.x + t.x + cos(a) * 18, y: mid.y + t.y + sin(a) * 18),
                    control: CGPoint(x: mid.x - cos(a) * 26, y: mid.y - sin(a) * 26)
                )
                g.stroke(p, with: white, style: StrokeStyle(lineWidth: 22, lineCap: .round))
            }
        }
    }

    private static func heart(center c: CGPoint, size s: CGFloat) -> Path {
        var p = Path()
        let w = s / 2
        p.move(to: CGPoint(x: c.x, y: c.y + w * 0.9))
        p.addCurve(to: CGPoint(x: c.x - w, y: c.y - w * 0.15),
                   control1: CGPoint(x: c.x - w * 0.45, y: c.y + w * 0.55),
                   control2: CGPoint(x: c.x - w, y: c.y + w * 0.3))
        p.addArc(center: CGPoint(x: c.x - w / 2, y: c.y - w * 0.2), radius: w / 2,
                 startAngle: .degrees(174), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: c.x + w / 2, y: c.y - w * 0.2), radius: w / 2,
                 startAngle: .degrees(180), endAngle: .degrees(6), clockwise: false)
        p.addCurve(to: CGPoint(x: c.x, y: c.y + w * 0.9),
                   control1: CGPoint(x: c.x + w, y: c.y + w * 0.3),
                   control2: CGPoint(x: c.x + w * 0.45, y: c.y + w * 0.55))
        p.closeSubpath()
        return p
    }

    private static func drawBlush(in ctx: inout GraphicsContext) {
        for base in [CGPoint(x: 770, y: 935), CGPoint(x: 1150, y: 940)] {
            for i in 0..<3 {
                var p = Path()
                let x = base.x + CGFloat(i) * 26
                p.move(to: CGPoint(x: x, y: base.y + 18))
                p.addLine(to: CGPoint(x: x + 16, y: base.y - 16))
                stroke(p, &ctx, width: 10)
            }
        }
    }

    private static func drawTears(in ctx: inout GraphicsContext) {
        for (x, y) in [(CGFloat(808), CGFloat(958)), (CGFloat(1140), CGFloat(960))] {
            ctx.fill(drop(x: x, y: y, scale: 1), with: .color(G.ink))
        }
    }

    private static func drop(x: CGFloat, y: CGFloat, scale k: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y - 34 * k))
        p.addCurve(to: CGPoint(x: x, y: y + 22 * k),
                   control1: CGPoint(x: x - 26 * k, y: y - 2 * k), control2: CGPoint(x: x - 24 * k, y: y + 22 * k))
        p.addCurve(to: CGPoint(x: x, y: y - 34 * k),
                   control1: CGPoint(x: x + 24 * k, y: y + 22 * k), control2: CGPoint(x: x + 26 * k, y: y - 2 * k))
        return p
    }

    private static func drawSweat(in ctx: inout GraphicsContext) {
        let p = drop(x: 1372, y: 548, scale: 1.45)
        ctx.fill(p, with: .color(G.paper))
        ctx.stroke(p, with: .color(G.ink), style: StrokeStyle(lineWidth: 14, lineJoin: .round))
    }

    private static func drawLines(_ lines: [(CGPoint, CGPoint)], width: CGFloat, outline: CGFloat, in ctx: inout GraphicsContext) {
        for (a, b) in lines {
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            if outline > 0 {
                ctx.stroke(p, with: .color(G.paper), style: StrokeStyle(lineWidth: width + outline, lineCap: .round))
            }
            stroke(p, &ctx, width: width)
        }
    }

    private static func drawShoutLines(outline: CGFloat, in ctx: inout GraphicsContext) {
        drawLines([
            (CGPoint(x: 905, y: 520), CGPoint(x: 900, y: 450)),
            (CGPoint(x: 790, y: 535), CGPoint(x: 750, y: 478)),
            (CGPoint(x: 1020, y: 528), CGPoint(x: 1052, y: 465)),
        ], width: 20, outline: outline, in: &ctx)
    }

    private static func drawImpact(outline: CGFloat, in ctx: inout GraphicsContext) {
        drawLines([
            (CGPoint(x: 455, y: 1270), CGPoint(x: 390, y: 1282)),
            (CGPoint(x: 470, y: 1220), CGPoint(x: 400, y: 1205)),
            (CGPoint(x: 1425, y: 1235), CGPoint(x: 1492, y: 1245)),
            (CGPoint(x: 1420, y: 1190), CGPoint(x: 1488, y: 1172)),
        ], width: 18, outline: outline, in: &ctx)
    }

    /// The traced silhouette with alternate even samples pushed outward: the
    /// keycap's version of bristling fur, scaled continuously by `amount`.
    private static func spikyBody(_ amount: CGFloat) -> Path {
        var out = Path()
        let c = G.bodyCentroid
        for (k, p) in bodySamples.enumerated() {
            let l = max(1, hypot(p.x - c.x, p.y - c.y))
            let push = (k % 2 == 0 ? 34 : -4) * amount
            let q = CGPoint(x: p.x + (p.x - c.x) / l * push, y: p.y + (p.y - c.y) / l * push)
            if k == 0 { out.move(to: q) } else { out.addLine(to: q) }
        }
        out.closeSubpath()
        return out
    }

    private static func evenSamples(of path: Path, count: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        path.cgPath.copy(dashingWithPhase: 0, lengths: [1, 0]).applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: pts.append(e.points[0])
            case .addQuadCurveToPoint: pts.append(e.points[1])
            case .addCurveToPoint: pts.append(e.points[2])
            default: break
            }
        }
        guard pts.count > 1 else { return pts }
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count {
            lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        let total = lengths.last ?? 1
        var out: [CGPoint] = []
        var j = 0
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count)
            while j < lengths.count - 2 && lengths[j + 1] < target { j += 1 }
            let t = (target - lengths[j]) / max(1, lengths[j + 1] - lengths[j])
            out.append(CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * t, y: pts[j].y + (pts[j + 1].y - pts[j].y) * t))
        }
        return out
    }
}

extension TypoRenderer {
    /// Draws a performance pose into a view of `size`. Everything below the
    /// baseline is clipped, so Typo rises out of and sinks back into its line.
    static func draw(_ pose: TypoPerformance.Pose, in ctx: inout GraphicsContext, size: CGSize) {
        guard pose.opacity > 0.001 else { return }
        let v = TypoGeometry.viewport
        let scale = size.width / v.width
        let baseline = TypoGeometry.baselineY
        let feet = CGPoint(x: 978, y: baseline)

        ctx.opacity = pose.opacity
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -v.minX, y: -v.minY)
        ctx.clip(to: Path(CGRect(x: v.minX, y: v.minY, width: v.width, height: baseline - v.minY + 1)))

        if pose.sink < 0.98 {
            let lift = min(1, pose.hop / 220)
            let width = 760 * (1 - 0.35 * lift) * (2 - pose.squash) * (1 - pose.sink)
            var shadow = ctx
            shadow.opacity = pose.opacity * 0.16 * Double(1 - lift * 0.6)
            shadow.fill(
                Path(ellipseIn: CGRect(x: feet.x - width / 2, y: baseline - 16, width: width, height: 32)),
                with: .color(.black)
            )
        }

        let travel = baseline - v.minY
        ctx.translateBy(x: pose.shake, y: pose.sink * travel - pose.hop)
        ctx.translateBy(x: feet.x, y: feet.y)
        ctx.rotate(by: .degrees(pose.tiltDegrees))
        let squash = max(0.05, pose.squash)
        ctx.scaleBy(x: 1 / sqrt(squash), y: squash)
        ctx.translateBy(x: -feet.x, y: -feet.y)

        // About 1.5 pt of white edge outside the black shapes at any size.
        let outline = 3 / scale
        TypoRenderer.draw(pose.expression, outline: outline, in: &ctx)
    }
}
