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
/// then ask text-marker bounds before range bounds. A collapsed range that
/// reports no width falls back to the character before the caret (keyboop,
/// MIT). Every rect must look like a caret and sit on a screen; an input box's
/// whole frame is not accepted, because standing on the wrong line reads worse
/// than staying on the recording bar.
enum CaretLocator {
    /// Real carets are thin bars; taller rects are whole documents or fields.
    static let caretHeights: ClosedRange<CGFloat> = 2...160
    static let maximumCaretWidth: CGFloat = 60

    private static let nudged = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Looks up the caret off the main thread, giving up after `budget`.
    static func locate(
        processIdentifier pid: pid_t,
        budget: Duration = .milliseconds(150)
    ) async -> CaretLookup {
        guard AXIsProcessTrusted() else { return .unavailable("not trusted") }
        let screens = NSScreen.screens.map(\.frame)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return await withTaskGroup(of: CaretLookup?.self) { group in
            group.addTask {
                query(pid: pid, screens: screens, primaryMaxY: primaryMaxY)
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
    static func query(pid: pid_t, screens: [CGRect], primaryMaxY: CGFloat) -> CaretLookup {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let justNudged = nudgeChromiumIfNeeded(app, pid: pid)

        var focused = copyElement(app, kAXFocusedUIElementAttribute)
        if focused == nil, justNudged {
            // Chromium builds its tree lazily after the nudge.
            Thread.sleep(forTimeInterval: 0.06)
            focused = copyElement(app, kAXFocusedUIElementAttribute)
        }
        guard var element = focused else { return .unavailable("no focused element") }
        AXUIElementSetMessagingTimeout(element, 0.05)

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
        for case let (axRect?, tier) in candidates {
            let rect = cocoaRect(fromAX: axRect, primaryMaxY: primaryMaxY)
            if isPlausibleCaret(rect, screens: screens) {
                return .found(CaretLocation(rect: rect, tier: tier, processIdentifier: pid))
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
    /// or nothing, for a zero-length range; the bounds of the character just
    /// before the caret end where the caret is.
    static func collapsedCaret(direct: CGRect?, characterBefore: CGRect?) -> CGRect? {
        if let direct, direct.height > 0, direct.width > 0 || direct.minX > 0 {
            return CGRect(x: direct.minX, y: direct.minY, width: max(1, direct.width), height: direct.height)
        }
        if let before = characterBefore, before.height > 0 {
            return CGRect(x: before.maxX, y: before.minY, width: 1, height: before.height)
        }
        return nil
    }

    // MARK: - AX

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
        guard let rect = parameterizedRect(element, "AXBoundsForTextMarkerRange", range) else { return nil }
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
        var before: CGRect?
        if selected.location > 0 {
            var previous = CFRange(location: selected.location - 1, length: 1)
            if let previousValue = AXValueCreate(.cfRange, &previous) {
                before = parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, previousValue)
            }
        }
        return collapsedCaret(direct: direct, characterBefore: before)
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
