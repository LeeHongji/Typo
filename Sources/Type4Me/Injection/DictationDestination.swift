import AppKit
import ApplicationServices

/// Where a dictation's words go, locked when the recording starts: the app,
/// its window and the focused text element. While the user talks they may
/// click other windows (to screenshot them) or select text elsewhere (to quote
/// it); the words still go back to this place.
struct DictationDestination: @unchecked Sendable {
    let application: NSRunningApplication
    /// The focused window of the app when recording started.
    let window: AXUIElement?
    /// The window's number in the window server, to tell its clicks apart.
    let windowID: CGWindowID?
    /// The focused element (the text box) when recording started.
    let element: AXUIElement?

    var processIdentifier: pid_t { application.processIdentifier }

    /// Reads the app's focused window and element. AX calls are IPC, so this
    /// runs off the main thread; it gives up quickly on an app that is busy.
    static func capture(_ application: NSRunningApplication) -> DictationDestination {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let window = copyElement(app, kAXFocusedWindowAttribute)
        let element = copyElement(app, kAXFocusedUIElementAttribute)
        return DictationDestination(
            application: application,
            window: window,
            windowID: frontWindowID(of: application.processIdentifier),
            element: element
        )
    }

    // MARK: - Deciding

    /// What delivery has to do first.
    enum Plan: Equatable {
        /// The user never left: paste exactly as before.
        case pasteHere
        /// The user went elsewhere: bring the place back, then paste.
        case bringBack
        /// Same window, but its text box lost focus (text was selected
        /// elsewhere in it to quote): focus the box again. If that cannot be
        /// confirmed, paste anyway, as before this lock existed.
        case refocus
        /// The app is gone: nowhere to bring back.
        case gone
    }

    /// Pure: only another app in front, or another window of the same app,
    /// counts as having left. A focused element that merely reads differently
    /// (Electron rebuilds its nodes) does not, so the common case never changes.
    static func plan(
        isTerminated: Bool,
        frontmostPID: pid_t?,
        targetPID: pid_t,
        windowStillFocused: Bool?,
        elementStillFocused: Bool? = nil
    ) -> Plan {
        if isTerminated { return .gone }
        guard frontmostPID == targetPID else { return .bringBack }
        if windowStillFocused == false { return .bringBack }
        return elementStillFocused == false ? .refocus : .pasteHere
    }

    func plan() -> Plan {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let windowStillFocused = window.map { locked in
            Self.copyElement(app, kAXFocusedWindowAttribute).map { CFEqual($0, locked) } ?? false
        }
        // A box the app has since rebuilt can't be asked; that is not "left".
        let elementStillFocused = element.flatMap { el in Self.isAlive(el) ? Self.isFocused(el, in: app) : nil }
        return Self.plan(
            isTerminated: application.isTerminated,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            targetPID: processIdentifier,
            windowStillFocused: windowStillFocused,
            elementStillFocused: elementStillFocused
        )
    }

    // MARK: - Bringing back

    enum Failure: String, Error {
        case appGone = "app gone"
        case notFrontmost = "app did not come to the front"
        case windowGone = "window gone"
        case elementGone = "text box gone"
        case focusUnconfirmed = "focus not confirmed"
    }

    /// Brings the app, its window and the text box back to the front and
    /// checks each. Call off the main thread. On failure nothing is pasted.
    func bringBack(activate: (NSRunningApplication) -> Bool) -> Result<Void, Failure> {
        guard !application.isTerminated else { return .failure(.appGone) }
        guard activate(application) else { return .failure(.notFrontmost) }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)

        if let window {
            guard Self.isAlive(window) else { return .failure(.windowGone) }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let raised = Self.waitUntil(0.6) {
                Self.copyElement(app, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
            }
            guard raised else { return .failure(.focusUnconfirmed) }
        }

        guard let element else { return .success(()) }
        guard Self.isAlive(element) else { return .failure(.elementGone) }
        if !Self.isFocused(element, in: app) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        let focused = Self.waitUntil(0.5) { Self.isFocused(element, in: app) }
        return focused ? .success(()) : .failure(.focusUnconfirmed)
    }

    // MARK: - AX

    /// Focuses the locked box again within its own window.
    func refocus() -> Bool {
        guard let element, Self.isAlive(element) else { return false }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return Self.waitUntil(0.4) { Self.isFocused(element, in: app) }
    }

    /// Whether `element` is a text box of the app being dictated into.
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    private static func isFocused(_ element: AXUIElement, in app: AXUIElement) -> Bool {
        if let current = copyElement(app, kAXFocusedUIElementAttribute), CFEqual(current, element) {
            return true
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    /// An element whose app destroyed it answers every request as invalid.
    private static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    private static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            usleep(20_000)
        } while Date() < deadline
        return condition()
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The app's frontmost ordinary window; the window list is front to back.
    static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        let entry = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return (entry?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
    }
}
