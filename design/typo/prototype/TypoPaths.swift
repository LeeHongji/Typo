import SwiftUI

enum TypoPath {
    /// Smooth closed or open curve through traced points. Corners sharper than
    /// `cornerAngle` keep their point so notches and the bubble tail stay crisp.
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
            let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y), v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            let l = (hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy))
            guard l > 0 else { return false }
            let cosv = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / l))
            return acos(cosv) > cornerAngle
        }
        path.move(to: at(0))
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            // Tangent direction from the neighbours, length capped by this
            // segment so short-long transitions never overshoot into spikes.
            let seg = hypot(p2.x - p1.x, p2.y - p1.y) / 3
            func dir(_ a: CGPoint, _ b: CGPoint) -> CGVector {
                let l = hypot(b.x - a.x, b.y - a.y)
                return l > 0 ? CGVector(dx: (b.x - a.x) / l, dy: (b.y - a.y) / l) : .zero
            }
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

/// The reference pose drawn from traced geometry, used to verify fidelity.
struct TypoReferencePose: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 2000
            ctx.scaleBy(x: s, y: s)
            let ink = GraphicsContext.Shading.color(.black)
            ctx.fill(TypoPath.smooth(TypoReference.armLShape, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.armRShape, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.body, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.faceContour, closed: true), with: .color(.white))
            ctx.fill(TypoPath.smooth(TypoReference.eyeL, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.eyeR, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.mouthShape, closed: true), with: ink)
            ctx.fill(TypoPath.smooth(TypoReference.bubble, closed: true), with: ink)
        }
    }
}
