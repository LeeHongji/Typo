import AppKit
import ApplicationServices
import os

/// Where the text caret is on screen, in AppKit coordinates (origin at the
/// bottom-left of the primary display).
struct CaretLocation: Equatable, Sendable {
    enum Tier: String, Sendable {
        /// WebKit, Chromium and Electron text-marker bounds.
        case textMarker
        /// AppKit `AXBoundsForRange` on the selected range.
        case boundsForRange
        /// An empty text box reports no caret geometry at all; the caret is at
        /// the start of the box.
        case fieldStart
    }

    let rect: CGRect
    let tier: Tier
    let processIdentifier: pid_t
}

enum CaretLookup: Equatable, Sendable {
    case found(CaretLocation)
    /// A password field is focused; Typo must not attach to it.
    case secureField
    case unavailable(String)

    var location: CaretLocation? {
        if case .found(let location) = self { return location }
        return nil
    }
}

/// Finds the text caret of the frontmost app through the Accessibility API.
///
/// Tiers follow SuperCmd's ax-caret-query (MIT): wake Chromium/Electron once,
/// refuse secure fields, descend from a focused container to the text leaf,
/// then ask text-marker bounds before range bounds. For a collapsed range the
/// character before the caret is preferred (keyboop, MIT): TextEdit reports
/// the collapsed range at the end of the text one line too high, while the
/// character before it is right. A text-marker range as wide as a whole box is
/// not a caret (Electron reports that for an empty box). Only when the box is
/// empty, and so has no text geometry at all, is its frame used, placing the
/// caret at its start. Every rect must look like a caret and sit on a screen.
enum CaretLocator {
    /// Real carets are thin bars; taller rects are whole documents or fields.
    static let caretHeights: ClosedRange<CGFloat> = 2...160
    static let maximumCaretWidth: CGFloat = 60

    private static let nudged = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Looks up the caret off the main thread, giving up after `budget`.
    static func locate(
        processIdentifier pid: pid_t,
        budget: Duration = .milliseconds(300),
        trace: Bool = false
    ) async -> CaretLookup {
        guard AXIsProcessTrusted() else { return .unavailable("not trusted") }
        let screens = NSScreen.screens.map(\.frame)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return await withTaskGroup(of: CaretLookup?.self) { group in
            group.addTask {
                query(pid: pid, screens: screens, primaryMaxY: primaryMaxY, trace: trace)
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .unavailable("timed out")
        }
    }

    /// The synchronous lookup; AX calls are IPC, so callers keep it off the main thread.
    static func query(pid: pid_t, screens: [CGRect], primaryMaxY: CGFloat, trace: Bool = false) -> CaretLookup {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let justNudged = nudgeChromiumIfNeeded(app, pid: pid)

        var focused = copyElement(app, kAXFocusedUIElementAttribute)
        // Chromium builds its tree lazily after the nudge; the first answer
        // can take a few hundred milliseconds.
        var retries = justNudged ? 3 : 0
        while focused == nil, retries > 0 {
            Thread.sleep(forTimeInterval: 0.07)
            focused = copyElement(app, kAXFocusedUIElementAttribute)
            retries -= 1
        }
        guard var element = focused else { return .unavailable("no focused element") }
        AXUIElementSetMessagingTimeout(element, 0.1)

        let role = copyString(element, kAXRoleAttribute) ?? ""
        let subrole = copyString(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) {
            return .secureField
        }
        if !hasCaret(element), let leaf = descendToTextLeaf(from: element) {
            element = leaf
        }

        let candidates: [(CGRect?, CaretLocation.Tier)] = [
            (textMarkerRect(element), .textMarker),
            (rangeRect(element), .boundsForRange),
        ]
        if trace { logProbe(element, role: role, candidates: candidates) }
        for case let (axRect?, tier) in candidates {
            let rect = cocoaRect(fromAX: axRect, primaryMaxY: primaryMaxY)
            if isPlausibleCaret(rect, screens: screens) {
                return .found(CaretLocation(rect: rect, tier: tier, processIdentifier: pid))
            }
        }
        if textRoles.contains(role) || textRoles.contains(copyString(element, kAXRoleAttribute) ?? ""),
           selectionLocation(element) == 0,
           let box = frame(element), let axRect = fieldStartCaret(frame: box) {
            let rect = cocoaRect(fromAX: axRect, primaryMaxY: primaryMaxY)
            if isPlausibleCaret(rect, screens: screens) {
                return .found(CaretLocation(rect: rect, tier: .fieldStart, processIdentifier: pid))
            }
        }
        return .unavailable("no plausible caret (role \(role))")
    }

    // MARK: - Pure helpers

    /// AX uses a top-left origin on the primary display; AppKit uses bottom-left.
    static func cocoaRect(fromAX r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    static func isPlausibleCaret(_ r: CGRect, screens: [CGRect]) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite,
              caretHeights.contains(r.height),
              r.width >= 0, r.width <= maximumCaretWidth
        else { return false }
        let centre = CGPoint(x: r.midX, y: r.midY)
        return screens.contains { $0.contains(centre) }
    }

    /// The caret rect for a collapsed selection. Apps often report no width,
    /// nothing, or (TextEdit at the end of the text) the wrong line for a
    /// zero-length range. The character just before the caret ends where the
    /// caret is, so it wins whenever the direct rect is missing or agrees with
    /// it on x; they disagree right after a line break, where the direct rect
    /// is the one on the new line. A caret at the start of the text uses the
    /// character after it.
    static func collapsedCaret(direct: CGRect?, characterBefore: CGRect?, characterAfter: CGRect? = nil) -> CGRect? {
        let direct = direct.flatMap { $0.height > 0 && ($0.width > 0 || $0.minX > 0) ? $0 : nil }
        if let before = characterBefore, before.height > 0,
           direct.map({ abs($0.minX - before.maxX) <= 1.5 }) ?? true {
            return CGRect(x: before.maxX, y: before.minY, width: 1, height: before.height)
        }
        if let direct {
            return CGRect(x: direct.minX, y: direct.minY, width: max(1, direct.width), height: direct.height)
        }
        if let after = characterAfter, after.height > 0 {
            return CGRect(x: after.minX, y: after.minY, width: 1, height: after.height)
        }
        return nil
    }

    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    static let emptyLineHeight: CGFloat = 18

    /// Where the caret sits in an empty text box (AX coordinates): at its
    /// start, one text line tall, inset like typical padding. A one-line box
    /// centres it; a taller box puts it on the first line.
    static func fieldStartCaret(frame box: CGRect) -> CGRect? {
        guard box.width >= 20, box.height >= 10, box.height <= 600 else { return nil }
        let height = min(emptyLineHeight, box.height)
        // Padding varies (Codex 0 pt, a Chrome textarea 13 pt); 6 pt stays within about 7 pt of both.
        let inset = min(6, max(0, (box.height - height) / 2))
        return CGRect(x: box.minX + inset, y: box.minY + inset, width: 1, height: height)
    }

    // MARK: - AX

    /// Geometry only (AX top-left coordinates), never text, for per-app diagnosis.
    private static func logProbe(_ element: AXUIElement, role: String, candidates: [(CGRect?, CaretLocation.Tier)]) {
        func fmt(_ r: CGRect?) -> String {
            guard let r else { return "nil" }
            return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))"
        }
        var range = "nil"
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &r) { range = "\(r.location)+\(r.length)" }
        }
        var count: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
        var markerRaw: CGRect?
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker {
            markerRaw = parameterizedRect(element, "AXBoundsForTextMarkerRange", marker)
        }
        let tiers = "markerRaw=\(fmt(markerRaw)) " + candidates.map { "\($0.1.rawValue)=\(fmt($0.0))" }.joined(separator: " ")
        DebugFileLogger.log(
            "typo caret probe: role=\(role) sub=\(copyString(element, kAXSubroleAttribute) ?? "-") "
                + "chars=\((count as? Int).map(String.init) ?? "nil") sel=\(range) \(tiers) frame=\(fmt(frame(element)))"
        )
    }

    private static func selectionLocation(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    private static func nudgeChromiumIfNeeded(_ app: AXUIElement, pid: pid_t) -> Bool {
        let isNew = nudged.withLock { $0.insert(pid).inserted }
        guard isNew else { return false }
        // Chromium and Electron only build their accessibility tree for
        // assistive technology that asks; these flags are how it asks.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }

    private static func textMarkerRect(_ element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range
        else { return nil }
        // A range as wide as a whole box is the box, not a caret.
        guard let rect = parameterizedRect(element, "AXBoundsForTextMarkerRange", range),
              rect.width <= maximumCaretWidth
        else { return nil }
        return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
    }

    private static func rangeRect(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var selected = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selected) else { return nil }
        let direct = parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, value)
        if selected.length > 0 { return direct }
        func characterRect(at location: Int) -> CGRect? {
            var range = CFRange(location: location, length: 1)
            guard location >= 0, let value = AXValueCreate(.cfRange, &range) else { return nil }
            return parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, value)
        }
        let before = selected.location > 0 ? characterRect(at: selected.location - 1) : nil
        let after = selected.location == 0 ? characterRect(at: 0) : nil
        return collapsedCaret(direct: direct, characterBefore: before, characterAfter: after)
    }

    private static func parameterizedRect(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func hasCaret(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String]
        else { return false }
        return list.contains(kAXSelectedTextRangeAttribute as String)
            || list.contains("AXSelectedTextMarkerRange")
    }

    /// Web areas and scroll views often hold focus for the text inside them.
    private static func descendToTextLeaf(from root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if depth > 0, isFocused(node), hasCaret(node) { return node }
            guard depth < 6, let children = copyChildren(node) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
