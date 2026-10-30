import SwiftUI

/// One expression of Typo, composed from parts that share the reference style:
/// a solid black keycap, a white oval face, solid black features, detached
/// stroke arms, and a solid black speech bubble with a white glyph.
struct TypoExpression {
    enum Eye { case open, happy, relaxed, line, dot, ring, heart, chevron, angry, sad }
    enum Mouth { case smile, grin, talk, shout, flat, frown, zigzag, tinyO, cat }
    enum Glyph { case dots, exclaim, question, interrobang, heart, zz, check, vein, note, hi }
    /// An arm is the traced reference stroke, optionally flipped upward about
    /// its shoulder end, then rotated clockwise by `degrees`.
    struct Arm { var up = false; var degrees: Double = 0 }

    var name: String
    var eyeL: Eye = .open
    var eyeR: Eye = .open
    var look: CGSize = .zero
    var mouth: Mouth = .smile
    var armL = Arm()
    var armR = Arm()
    var bubble: Glyph? = nil
    var showBubble = true
    var spiky = false
    var squash: CGFloat = 1
    var tilt: Double = 0
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
    static let groundPivot = CGPoint(x: 950, y: 1250)
    static let bubbleCenter = CGPoint(x: 1618, y: 650)
}

struct TypoCharacter: View {
    var expression: TypoExpression
    /// Visible region of the 2000 x 2000 design space.
    var crop = CGRect(x: 330, y: 400, width: 1520, height: 980)

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / crop.width, size.height / crop.height)
            ctx.translateBy(x: (size.width - crop.width * s) / 2, y: (size.height - crop.height * s) / 2)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            TypoRenderer.draw(expression, in: &ctx)
        }
    }
}

enum TypoRenderer {
    typealias G = TypoGeometry

    static func draw(_ e: TypoExpression, in ctx: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(G.ink)
        let paper = GraphicsContext.Shading.color(G.paper)

        if e.showBubble {
            ctx.fill(TypoPath.smooth(TypoReference.bubble, closed: true), with: ink)
            if let glyph = e.bubble { drawGlyph(glyph, in: &ctx) }
        }
        if e.shout { drawShoutLines(in: &ctx) }
        if e.sweat { drawSweat(in: &ctx) }

        var body = ctx
        let p = G.groundPivot
        body.translateBy(x: p.x, y: p.y)
        body.rotate(by: .degrees(e.tilt))
        body.scaleBy(x: 1 / sqrt(e.squash), y: e.squash)
        body.translateBy(x: -p.x, y: -p.y)

        drawArm(TypoReference.armLShape, pivot: G.armLPivot, pose: e.armL, in: &body)
        drawArm(TypoReference.armRShape, pivot: G.armRPivot, pose: e.armR, in: &body)
        let bodyPath = e.spiky ? spikyBody() : TypoPath.smooth(TypoReference.body, closed: true)
        body.fill(bodyPath, with: ink)
        body.fill(TypoPath.smooth(TypoReference.faceContour, closed: true), with: paper)

        var face = body
        face.clip(to: TypoPath.smooth(TypoReference.faceContour, closed: true))
        drawEye(e.eyeL, center: G.eyeLCenter, contour: TypoReference.eyeL, isLeft: true, look: e.look, in: &face)
        drawEye(e.eyeR, center: G.eyeRCenter, contour: TypoReference.eyeR, isLeft: false, look: e.look, in: &face)
        drawMouth(e.mouth, in: &face)
        if e.blush { drawBlush(in: &face) }
        if e.tears { drawTears(in: &face) }
        if e.impact { drawImpact(in: &body) }
    }

    // MARK: - Parts

    private static func drawArm(_ shape: [CGPoint], pivot: CGPoint, pose: TypoExpression.Arm, in ctx: inout GraphicsContext) {
        var c = ctx
        c.translateBy(x: pivot.x, y: pivot.y)
        c.rotate(by: .degrees(pose.degrees))
        if pose.up { c.scaleBy(x: 1, y: -1) }
        c.translateBy(x: -pivot.x, y: -pivot.y)
        c.fill(TypoPath.smooth(shape, closed: true), with: .color(G.ink))
    }

    private static func stroke(_ path: Path, _ ctx: inout GraphicsContext, width: CGFloat = G.line, color: Color = G.ink) {
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func drawEye(
        _ eye: TypoExpression.Eye, center c0: CGPoint, contour: [CGPoint],
        isLeft: Bool, look: CGSize, in ctx: inout GraphicsContext
    ) {
        let c = CGPoint(x: c0.x + look.width, y: c0.y + look.height)
        let ink = GraphicsContext.Shading.color(G.ink)
        let traced = TypoPath.smooth(contour, closed: true)
            .applying(CGAffineTransform(translationX: look.width, y: look.height))
        let side: CGFloat = isLeft ? 1 : -1  // +1 points toward the face centre
        switch eye {
        case .open:
            ctx.fill(traced, with: ink)
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
            // The traced eye with its upper corner sliced off: the slice falls
            // toward the face centre for anger and away from it for sadness.
            var cut = Path()
            let inner = eye == .angry ? side : -side
            cut.move(to: CGPoint(x: c.x - 120, y: c.y + 260))
            cut.addLine(to: CGPoint(x: c.x + 120, y: c.y + 260))
            let slope: CGFloat = eye == .angry ? 145 : 120
            cut.addLine(to: CGPoint(x: c.x + 120, y: c.y - 60 + slope * inner))
            cut.addLine(to: CGPoint(x: c.x - 120, y: c.y - 60 - slope * inner))
            cut.closeSubpath()
            var e = ctx
            e.clip(to: cut)
            e.fill(traced, with: ink)
        }
    }

    private static func drawMouth(_ mouth: TypoExpression.Mouth, in ctx: inout GraphicsContext) {
        let c = G.mouthCenter
        let ink = GraphicsContext.Shading.color(G.ink)
        switch mouth {
        case .smile:
            ctx.fill(TypoPath.smooth(TypoReference.mouthShape, closed: true), with: ink)
        case .grin:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 58, y: c.y - 14))
            p.addQuadCurve(to: CGPoint(x: c.x + 58, y: c.y - 18), control: CGPoint(x: c.x, y: c.y - 24))
            p.addQuadCurve(to: CGPoint(x: c.x - 58, y: c.y - 14), control: CGPoint(x: c.x + 6, y: c.y + 104))
            p.closeSubpath()
            ctx.fill(p, with: ink)
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 10, lineJoin: .round))
        case .talk:
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 32, y: c.y - 26, width: 64, height: 76)), with: ink)
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
        case .hi: text("Hi", 140)
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
            // Manga anger mark: four arcs bowing toward a shared centre.
            for q in 0..<4 {
                var p = Path()
                let a = Double(q) * .pi / 2 + .pi / 4
                let r: CGFloat = 52
                let mid = CGPoint(x: cos(a) * r, y: sin(a) * r)
                let t = CGPoint(x: -sin(a) * 30, y: cos(a) * 30)
                p.move(to: CGPoint(x: mid.x - t.x + cos(a) * 18, y: mid.y - t.y + sin(a) * 18))
                p.addQuadCurve(to: CGPoint(x: mid.x + t.x + cos(a) * 18, y: mid.y + t.y + sin(a) * 18),
                               control: CGPoint(x: mid.x - cos(a) * 26, y: mid.y - sin(a) * 26))
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
            var p = Path()
            p.move(to: CGPoint(x: x, y: y - 34))
            p.addCurve(to: CGPoint(x: x, y: y + 22), control1: CGPoint(x: x - 26, y: y - 2), control2: CGPoint(x: x - 24, y: y + 22))
            p.addCurve(to: CGPoint(x: x, y: y - 34), control1: CGPoint(x: x + 24, y: y + 22), control2: CGPoint(x: x + 26, y: y - 2))
            ctx.fill(p, with: .color(G.ink))
        }
    }

    private static func drawSweat(in ctx: inout GraphicsContext) {
        let x: CGFloat = 1372, y: CGFloat = 548
        var p = Path()
        p.move(to: CGPoint(x: x, y: y - 50))
        p.addCurve(to: CGPoint(x: x, y: y + 34), control1: CGPoint(x: x - 38, y: y - 4), control2: CGPoint(x: x - 36, y: y + 34))
        p.addCurve(to: CGPoint(x: x, y: y - 50), control1: CGPoint(x: x + 36, y: y + 34), control2: CGPoint(x: x + 38, y: y - 4))
        ctx.fill(p, with: .color(G.paper))
        ctx.stroke(p, with: .color(G.ink), style: StrokeStyle(lineWidth: 14, lineJoin: .round))
    }

    private static func drawShoutLines(in ctx: inout GraphicsContext) {
        let lines: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 905, y: 520), CGPoint(x: 900, y: 450)),
            (CGPoint(x: 790, y: 535), CGPoint(x: 750, y: 478)),
            (CGPoint(x: 1020, y: 528), CGPoint(x: 1052, y: 465)),
        ]
        for (a, b) in lines {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            stroke(p, &ctx, width: 20)
        }
    }

    private static func drawImpact(in ctx: inout GraphicsContext) {
        let lines: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 455, y: 1290), CGPoint(x: 395, y: 1320)),
            (CGPoint(x: 470, y: 1250), CGPoint(x: 400, y: 1240)),
            (CGPoint(x: 1425, y: 1245), CGPoint(x: 1490, y: 1265)),
            (CGPoint(x: 1420, y: 1205), CGPoint(x: 1488, y: 1190)),
        ]
        for (a, b) in lines {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            stroke(p, &ctx, width: 18)
        }
    }

    /// The traced silhouette resampled evenly, with alternate samples pushed
    /// outward: the keycap's version of bristling fur.
    private static func spikyBody() -> Path {
        let flat = TypoPath.smooth(TypoReference.body, closed: true).cgPath
        var pts: [CGPoint] = []
        var last = CGPoint.zero
        flat.copy(dashingWithPhase: 0, lengths: [1, 0]).applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: last = e.points[0]; pts.append(last)
            case .addQuadCurveToPoint: last = e.points[1]; pts.append(last)
            case .addCurveToPoint: last = e.points[2]; pts.append(last)
            default: break
            }
        }
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = lengths.last ?? 1
        let count = 64
        var out = Path()
        var j = 0
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count)
            while j < lengths.count - 2 && lengths[j + 1] < target { j += 1 }
            let t = (target - lengths[j]) / max(1, lengths[j + 1] - lengths[j])
            let p = CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * t, y: pts[j].y + (pts[j + 1].y - pts[j].y) * t)
            let c = G.bodyCentroid
            let l = max(1, hypot(p.x - c.x, p.y - c.y))
            let push: CGFloat = k % 2 == 0 ? 34 : -4
            let q = CGPoint(x: p.x + (p.x - c.x) / l * push, y: p.y + (p.y - c.y) / l * push)
            if k == 0 { out.move(to: q) } else { out.addLine(to: q) }
        }
        out.closeSubpath()
        return out
    }
}

extension TypoExpression {
    static let pack: [TypoExpression] = {
        let up = Arm(up: true)
        let wave = Arm(up: true, degrees: -10)
        let spread = Arm(up: true, degrees: 60)
        let cheerL = Arm(up: true, degrees: -18), cheerR = spread
        return [
            TypoExpression(name: "原图 Reference"),
            TypoExpression(name: "打招呼 Hi", mouth: .cat, armL: wave, bubble: .hi),
            TypoExpression(name: "开心 Happy", eyeL: .happy, eyeR: .happy, mouth: .grin, armL: cheerL, armR: cheerR, bubble: .note),
            TypoExpression(name: "眨眼 Wink", eyeR: .happy, mouth: .cat, armL: wave, bubble: .heart),
            TypoExpression(name: "聆听 Listening", look: CGSize(width: 34, height: -20), mouth: .smile, bubble: .dots),
            TypoExpression(name: "说话 Talking", mouth: .talk, bubble: .dots),
            TypoExpression(name: "炸毛 Too loud", eyeL: .ring, eyeR: .ring, mouth: .shout, armL: cheerL, armR: cheerR, bubble: .exclaim, spiky: true, shout: true),
            TypoExpression(name: "思考 Thinking", look: CGSize(width: -18, height: -26), mouth: .flat, armL: Arm(up: true, degrees: 10), bubble: .question),
            TypoExpression(name: "害羞 Shy", eyeL: .relaxed, eyeR: .relaxed, mouth: .smile, armL: Arm(degrees: -8), armR: Arm(degrees: 8), bubble: .heart, blush: true),
            TypoExpression(name: "惊讶 Surprised", eyeL: .dot, eyeR: .dot, mouth: .tinyO, armL: up, armR: spread, bubble: .interrobang, sweat: true),
            TypoExpression(name: "委屈 Sad", eyeL: .sad, eyeR: .sad, mouth: .frown, armL: Arm(degrees: 10), armR: Arm(degrees: -10), showBubble: false, tilt: -3, tears: true),
            TypoExpression(name: "生气 Angry", eyeL: .angry, eyeR: .angry, mouth: .zigzag, bubble: .vein),
            TypoExpression(name: "困了 Sleepy", eyeL: .line, eyeR: .line, mouth: .tinyO, armL: Arm(degrees: 6), armR: Arm(degrees: -6), bubble: .zz, tilt: 4),
            TypoExpression(name: "按下 Pressed", eyeL: .chevron, eyeR: .chevron, mouth: .zigzag, armL: cheerL, armR: cheerR, showBubble: false, squash: 0.74, impact: true),
            TypoExpression(name: "喜欢 Love", eyeL: .heart, eyeR: .heart, mouth: .grin, armL: up, armR: spread, bubble: .heart),
            TypoExpression(name: "完成 Done", eyeL: .happy, eyeR: .happy, mouth: .smile, armL: wave, bubble: .check),
        ]
    }()
}
