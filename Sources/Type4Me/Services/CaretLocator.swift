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
    /// Where the text after the caret ends on the caret's own line, when
    /// there is any: Typo stands there rather than on top of those words.
    var textEnd: CGFloat?
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

    static let timedOut = CaretLookup.unavailable("timed out")
    static let noFocusedElement = CaretLookup.unavailable("no focused element")

    private static let nudged = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    /// AX calls are blocking IPC; they run here, one at a time, never on the
    /// main thread or Swift's cooperative pool.
    private static let queue = DispatchQueue(label: "com.type4me.caret-locator", qos: .userInitiated)

    /// Looks up the caret, answering `timedOut` after `budget` seconds even
    /// when the app is still busy answering.
    static func locate(
        processIdentifier pid: pid_t,
        budget: TimeInterval = 0.5,
        trace: Bool = false
    ) async -> CaretLookup {
        guard AXIsProcessTrusted() else { return .unavailable("not trusted") }
        let screens = NSScreen.screens.map(\.frame)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (CaretLookup) -> Void = { lookup in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: lookup) }
            }
            queue.async {
                answer(query(pid: pid, screens: screens, primaryMaxY: primaryMaxY, trace: trace))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) {
                answer(timedOut)
            }
        }
    }

    /// The synchronous lookup; AX calls are IPC, so callers keep it off the main thread.
    static func query(pid: pid_t, screens: [CGRect], primaryMaxY: CGFloat, trace: Bool = false) -> CaretLookup {
        let app = AXUIElementCreateApplication(pid)
        // Most apps answer in about 50 ms; Electron apps right after they come
        // forward or open a file can take a few hundred.
        AXUIElementSetMessagingTimeout(app, 0.25)
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
        guard var element = focused else { return noFocusedElement }
        AXUIElementSetMessagingTimeout(element, 0.15)

        let role = copyString(element, kAXRoleAttribute) ?? ""
        if isSecure(element) { return .secureField }
        if !hasCaret(element), let leaf = descendToTextLeaf(from: element) {
            if isSecure(leaf) { return .secureField }
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
                // WebKit and Chromium answer these line queries too, though their
                // caret comes from text markers.
                let lineEnd = rangeLineEnd(element)
                let end = textEnd(caret: axRect, lineEnd: lineEnd)
                if trace { DebugFileLogger.log("typo caret probe: lineEnd=\(lineEnd.map { "\($0)" } ?? "nil") textEnd=\(end.map { "\($0)" } ?? "nil")") }
                return .found(CaretLocation(rect: rect, tier: tier, processIdentifier: pid, textEnd: end))
            }
        }
        if textRoles.contains(role) || textRoles.contains(copyString(element, kAXRoleAttribute) ?? ""),
           isCollapsedAtStart(element),
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
    /// nothing, or (TextEdit at the start or end of the text) the line above
    /// for a zero-length range, while the characters beside the caret are
    /// right. The character before wins when it ends where the direct rect is
    /// (or there is no direct rect); otherwise the character after, when it
    /// starts there, as right after a line break. Only then the direct rect.
    static func collapsedCaret(direct: CGRect?, characterBefore: CGRect?, characterAfter: CGRect? = nil) -> CGRect? {
        let direct = direct.flatMap { $0.height > 0 && ($0.width > 0 || $0.minX > 0) ? $0 : nil }
        func agrees(_ x: CGFloat) -> Bool { direct.map { abs($0.minX - x) <= 1.5 } ?? true }
        if let before = characterBefore, before.height > 0, agrees(before.maxX) {
            return CGRect(x: before.maxX, y: before.minY, width: 1, height: before.height)
        }
        if let after = characterAfter, after.height > 0, after.width > 0, agrees(after.minX) {
            return CGRect(x: after.minX, y: after.minY, width: 1, height: after.height)
        }
        if let direct {
            return CGRect(x: direct.minX, y: direct.minY, width: max(1, direct.width), height: direct.height)
        }
        return nil
    }

    /// The x where text after the caret ends, given the bounds of the end of
    /// the caret's line (AX coordinates, like `caret`). Bounds that end at the
    /// caret, or that lie on another line, mean no text follows it.
    static func textEnd(caret: CGRect, lineEnd: CGRect?) -> CGFloat? {
        guard let end = lineEnd, end.height > 0, end.height < max(caret.height, 4) * 1.8,
              end.maxX > caret.maxX + 2,
              abs(end.midY - caret.midY) < max(caret.height, 4) * 0.5
        else { return nil }
        return end.maxX
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

    private static func isSecure(_ element: AXUIElement) -> Bool {
        copyString(element, kAXRoleAttribute) == "AXSecureTextField"
            || copyString(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    /// An empty box has its caret at the start with nothing selected.
    private static func isCollapsedAtStart(_ element: AXUIElement) -> Bool {
        guard let range = selectedRange(element) else { return false }
        return range.location == 0 && range.length == 0
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
        guard let selected = selectedRange(element) else { return nil }
        if selected.length > 0 {
            // A selection's bounds span all of it; the caret is at its end.
            guard let last = characterRect(element, at: selected.location + selected.length - 1), last.height > 0 else { return nil }
            return CGRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
        }
        var collapsed = selected
        guard let value = AXValueCreate(.cfRange, &collapsed) else { return nil }
        let direct = parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, value)
        let before = selected.location > 0 ? characterRect(element, at: selected.location - 1) : nil
        let after = characterRect(element, at: selected.location)
        return collapsedCaret(direct: direct, characterBefore: before, characterAfter: after)
    }

    /// The last character on the caret's line, ignoring its line break, when
    /// it comes after the caret.
    private static func rangeLineEnd(_ element: AXUIElement) -> CGRect? {
        guard let selected = selectedRange(element) else { return nil }
        let index = selected.location + selected.length
        guard let line = parameterized(element, kAXLineForIndexParameterizedAttribute, index as CFNumber) as? Int,
              let lineValue = parameterized(element, kAXRangeForLineParameterizedAttribute, line as CFNumber),
              CFGetTypeID(lineValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(lineValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        var last = range.location + range.length - 1
        var lastRange = CFRange(location: last, length: 1)
        if let value = AXValueCreate(.cfRange, &lastRange),
           let character = parameterized(element, kAXStringForRangeParameterizedAttribute, value) as? String,
           character.allSatisfy(\.isNewline) {
            last -= 1
        }
        guard last >= index else { return nil }
        return characterRect(element, at: last)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var selected = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selected) else { return nil }
        return selected
    }

    private static func characterRect(_ element: AXUIElement, at location: Int) -> CGRect? {
        var range = CFRange(location: location, length: 1)
        guard location >= 0, let value = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, value)
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    private static func parameterizedRect(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CGRect? {
        guard let value = parameterized(element, attribute, parameter), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
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
