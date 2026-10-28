#!/usr/bin/swift
// 监控豆包输入法 ASR 状态指示器窗口和文件变化
// 用法: swift doubao_monitor.swift

import CoreGraphics
import ApplicationServices
import Foundation
import Darwin

setbuf(stdout, nil)

let startTime = Date()
func ts() -> String {
    String(format: "[%.2fs]", Date().timeIntervalSince(startTime))
}

// ASR history db path
let asrDBPath = NSHomeDirectory() + "/Library/Application Support/DoubaoIme/Recorder/asrHistory.db"

func getDBModTime() -> Date? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: asrDBPath)
    return attrs?[.modificationDate] as? Date
}

struct DoubaoWindow: CustomStringConvertible {
    let id: Int
    let name: String
    let layer: Int
    let x: Int, y: Int, w: Int, h: Int
    let alpha: Double
    let onScreen: Bool

    var description: String {
        "id=\(id) name=\"\(name)\" layer=\(layer) (\(x),\(y) \(w)x\(h)) alpha=\(String(format:"%.1f", alpha)) onScreen=\(onScreen)"
    }
}

func getDoubaoWindows() -> [DoubaoWindow] {
    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var result: [DoubaoWindow] = []
    for w in windowList {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if owner.contains("豆包") || owner.contains("DoubaoIme") {
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            result.append(DoubaoWindow(
                id: w[kCGWindowNumber as String] as? Int ?? 0,
                name: w[kCGWindowName as String] as? String ?? "(nil)",
                layer: w[kCGWindowLayer as String] as? Int ?? -1,
                x: Int(bounds["X"] as? Double ?? 0),
                y: Int(bounds["Y"] as? Double ?? 0),
                w: Int(bounds["Width"] as? Double ?? 0),
                h: Int(bounds["Height"] as? Double ?? 0),
                alpha: w[kCGWindowAlpha as String] as? Double ?? -1,
                onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false
            ))
        }
    }
    return result
}

func getFocusInfo() -> (app: String, cursor: Int?, textLen: Int?) {
    let sys = AXUIElementCreateSystemWide()
    var focusedApp: AnyObject?
    AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &focusedApp)

    var appName = "?"
    if let app = focusedApp {
        var t: AnyObject?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXTitleAttribute as CFString, &t)
        appName = (t as? String) ?? "?"
    }

    var cursor: Int? = nil
    var textLen: Int? = nil
    if let app = focusedApp {
        var el: AnyObject?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &el)
        if let element = el as! AXUIElement? {
            var rv: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rv) == .success {
                var range = CFRange()
                if AXValueGetValue(rv as! AXValue, .cfRange, &range) { cursor = range.location }
            }
            var nv: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &nv) == .success {
                textLen = nv as? Int
            }
        }
    }
    return (appName, cursor, textLen)
}

print("=== 豆包输入法 ASR 监控 v2 ===")
print("监控: 窗口变化 + asrHistory.db 修改 + 光标位置")
print("触发豆包语音识别后观察输出\n")

// 初始状态
var lastWindows = getDoubaoWindows()
var lastDBTime = getDBModTime()
var lastOnScreenIDs = Set(lastWindows.filter(\.onScreen).map(\.id))
var asrActive = false
var asrStartCursor: Int? = nil

print("\(ts()) 初始状态: \(lastWindows.count) 个豆包窗口, onScreen: \(lastOnScreenIDs)")
for w in lastWindows { print("  \(w)") }
print("\(ts()) asrHistory.db 修改时间: \(lastDBTime?.description ?? "N/A")")
let initInfo = getFocusInfo()
print("\(ts()) 焦点: \(initInfo.app), cursor=\(initInfo.cursor.map(String.init) ?? "N/A"), textLen=\(initInfo.textLen.map(String.init) ?? "N/A")")
print("")

var pollCount = 0

let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    pollCount += 1

    let windows = getDoubaoWindows()
    let onScreenIDs = Set(windows.filter(\.onScreen).map(\.id))
    let info = getFocusInfo()

    // 检测 onScreen 窗口变化
    let appeared = onScreenIDs.subtracting(lastOnScreenIDs)
    let disappeared = lastOnScreenIDs.subtracting(onScreenIDs)

    if !appeared.isEmpty || !disappeared.isEmpty {
        print("\(ts()) >>> 窗口变化!")
        if !appeared.isEmpty {
            print("\(ts())   新出现: \(appeared)")
            for w in windows where appeared.contains(w.id) {
                print("\(ts())   \(w)")
            }
            // ASR 可能开始了
            if !asrActive {
                asrActive = true
                asrStartCursor = info.cursor
                print("\(ts())   -> ASR 可能开始! startCursor=\(info.cursor.map(String.init) ?? "N/A") app=\(info.app)")
            }
        }
        if !disappeared.isEmpty {
            print("\(ts())   消失了: \(disappeared)")
            // ASR 可能结束了
            if asrActive {
                asrActive = false
                print("\(ts())   -> ASR 可能结束! endCursor=\(info.cursor.map(String.init) ?? "N/A") textLen=\(info.textLen.map(String.init) ?? "N/A")")
                if let start = asrStartCursor, let end = info.cursor {
                    print("\(ts())   -> ASR 范围: [\(start), \(end)), 长度=\(end - start)")
                }
            }
        }
        lastOnScreenIDs = onScreenIDs
    }

    // 检测窗口列表变化（含离屏）
    let currentIDs = Set(windows.map(\.id))
    let prevIDs = Set(lastWindows.map(\.id))
    if currentIDs != prevIDs {
        let newIDs = currentIDs.subtracting(prevIDs)
        let goneIDs = prevIDs.subtracting(currentIDs)
        if !newIDs.isEmpty || !goneIDs.isEmpty {
            print("\(ts()) 窗口列表变化: new=\(newIDs) gone=\(goneIDs)")
            for w in windows where newIDs.contains(w.id) {
                print("\(ts())   新窗口: \(w)")
            }
        }
    }

    // 检测 bounds 变化（窗口位置/大小可能随光标移动）
    for w in windows {
        if let prev = lastWindows.first(where: { $0.id == w.id }) {
            if prev.x != w.x || prev.y != w.y || prev.w != w.w || prev.h != w.h || prev.onScreen != w.onScreen {
                print("\(ts()) 窗口移动/变化: \(w)")
            }
        }
    }

    // 检测 DB 修改
    let dbTime = getDBModTime()
    if dbTime != lastDBTime {
        print("\(ts()) >>> asrHistory.db 被修改! \(lastDBTime?.description ?? "nil") -> \(dbTime?.description ?? "nil")")
        lastDBTime = dbTime
    }

    // ASR 进行中时每 500ms 打印光标
    if asrActive && pollCount % 5 == 0 {
        print("\(ts()) [ASR中] cursor=\(info.cursor.map(String.init) ?? "?") textLen=\(info.textLen.map(String.init) ?? "?")")
    }

    lastWindows = windows
}

RunLoop.main.run()
