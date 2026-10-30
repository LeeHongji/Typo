import SwiftUI
import AppKit

@MainActor
func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote", path)
}

struct StickerSheet: View {
    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(380), spacing: 16), count: 4)
        LazyVGrid(columns: cols, spacing: 18) {
            ForEach(Array(TypoExpression.pack.enumerated()), id: \.offset) { _, e in
                VStack(spacing: 4) {
                    TypoCharacter(expression: e).frame(width: 380, height: 250)
                    Text(e.name).font(.system(size: 20, weight: .medium)).foregroundColor(.black)
                }
            }
        }
        .padding(20)
    }
}

MainActor.assumeIsolated {
    let mode = CommandLine.arguments[1]
    if mode == "reference" {
        render(TypoReferencePose(), width: 2000, height: 2000, to: CommandLine.arguments[2])
    } else if mode == "sheet" {
        render(StickerSheet(), width: 1640, height: 1240, to: CommandLine.arguments[2])
    } else if mode == "detail" {
        let picks = CommandLine.arguments[3].split(separator: ",").map { TypoExpression.pack[Int($0)!] }
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(780), spacing: 10), count: 2), spacing: 10) {
            ForEach(Array(picks.enumerated()), id: \.offset) { _, e in TypoCharacter(expression: e).frame(width: 780, height: 500) }
        }
        render(grid, width: 1580, height: CGFloat((picks.count + 1) / 2) * 510, to: CommandLine.arguments[2])
    } else if mode == "arms" {
        let angles: [Double] = [14, 30, 45, 60, -40, -60]
        let views = angles.map { a -> TypoExpression in
            var e = TypoExpression.pack[1]; e.armR = .init(up: true, degrees: a); e.name = "\(Int(a))"; return e }
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(520), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(views.enumerated()), id: \.offset) { _, e in
                ZStack(alignment: .topLeading) { TypoCharacter(expression: e).frame(width: 520, height: 340); Text(e.name).font(.system(size: 28, weight: .bold)).foregroundColor(.red) }
            }
        }
        render(grid, width: 1572, height: 700, to: CommandLine.arguments[2])
    } else if mode == "expr" {
        let e = TypoExpression.pack[Int(CommandLine.arguments[3])!]
        render(TypoCharacter(expression: e, crop: CGRect(x: 0, y: 0, width: 2000, height: 2000)), width: 2000, height: 2000, to: CommandLine.arguments[2])
    }
}
