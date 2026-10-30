import SwiftUI
import AppKit

struct Frame { let label: String; let pose: TypoPerformance.Pose }

func script() -> [Frame] {
    var p = TypoPerformance()
    var frames: [Frame] = []
    var t = 0.0
    func snap(_ label: String, _ at: Double) { frames.append(Frame(label: label, pose: p.pose(at: at))) }
    p.begin(at: 0)
    for s in [0.08, 0.16, 0.25, 0.33] { p.update(level: 0, at: s); snap(String(format: "出场 %.2fs", s), s) }
    t = 0.4; p.update(level: 0, at: t)
    p.update(level: 0.55, at: 0.6); snap("说话 中音量", 0.6)
    p.update(level: 0.75, at: 0.8); snap("说话 大音量", 0.8)
    p.update(level: 0.9, at: 1.0); p.update(level: 0.9, at: 1.35); snap("炸毛", 1.35)
    p.update(level: 0.9, at: 1.4); snap("炸毛 抖动", 1.4)
    p.update(level: 0.1, at: 1.5); p.update(level: 0.1, at: 1.8)
    p.update(level: 0.1, at: 3.9); snap("安静 2 秒", 3.9)
    p.update(level: 0.1, at: 0.36 + 3.4 - 0.05); snap("眨眼", 0.36 + 3.4 - 0.05)
    p.think(at: 8); snap("思考", 8.3)
    p.finish(.success, at: 9)
    let tm = p.timing
    for (l, a) in [("起跳", tm.successHop * 0.5), ("落地按下", tm.successHop + tm.successLand * 0.95), ("回弹", tm.successHop + tm.successLand + tm.successRebound * 0.6), ("下沉", tm.successHop + tm.successLand + tm.successRebound + tm.successSink * 0.5)] {
        snap(l, 9 + a)
    }
    var c = TypoPerformance(); c.begin(at: 0); c.update(level: 0, at: 0.5); c.finish(.cancelled, at: 1)
    frames.append(Frame(label: "取消", pose: c.pose(at: 1.05)))
    var f = TypoPerformance(); f.begin(at: 0); f.update(level: 0, at: 0.5); f.finish(.failed, at: 1)
    frames.append(Frame(label: "失败", pose: f.pose(at: 1.1)))
    return frames
}

struct Cell: View {
    let frame: Frame; let dark: Bool
    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(dark ? Color(white: 0.13) : Color(white: 0.96))
                Canvas { ctx, size in TypoRenderer.draw(frame.pose, in: &ctx, size: size) }
                    .frame(width: 150, height: 98)
            }.frame(width: 160, height: 104)
            Text(frame.label).font(.system(size: 11, weight: .medium)).foregroundColor(.black)
        }
    }
}

struct Sheet: View {
    let frames = script()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([false, true], id: \.self) { dark in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(160), spacing: 6), count: 9), spacing: 6) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, f in Cell(frame: f, dark: dark) }
                }
            }
        }.padding(10).background(Color.white)
    }
}

MainActor.assumeIsolated {
    let r = ImageRenderer(content: Sheet().frame(width: 1500))
    r.scale = 2
    try! NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("wrote")
}
