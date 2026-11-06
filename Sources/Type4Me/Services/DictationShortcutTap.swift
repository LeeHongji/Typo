import AppKit
import CoreGraphics
import os

/// The capture shortcuts while the user talks, read from a session event tap
/// on its own thread so typing never waits for the main thread. Only key
/// presses are looked at, and only while collecting; clicks are never touched.
///
/// ⌥S shoots the window in front, ⌥⇧S starts drawing a box. Other modifiers
/// held at the same time are allowed, so a held dictation key (right ⌘, say)
/// does not get in the way.
final class DictationShortcutTap: @unchecked Sendable {
    enum Shortcut: Equatable {
        case window
        case region
        /// Esc while the box is on screen.
        case cancelRegion
    }

    static let sKey: Int64 = 1
    static let escapeKey: Int64 = 53

    /// Pure: what a key press means, given whether a box is being drawn.
    static func shortcut(keyCode: Int64, flags: CGEventFlags, regionActive: Bool) -> Shortcut? {
        if regionActive, keyCode == escapeKey { return .cancelRegion }
        guard keyCode == sKey, flags.contains(.maskAlternate) else { return nil }
        return flags.contains(.maskShift) ? .region : .window
    }

    private let regionActive = OSAllocatedUnfairLock(initialState: false)
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let onShortcut: @Sendable (Shortcut) -> Void

    init(onShortcut: @escaping @Sendable (Shortcut) -> Void) {
        self.onShortcut = onShortcut
    }

    func setRegionActive(_ active: Bool) {
        regionActive.withLock { $0 = active }
    }

    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<DictationShortcutTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugFileLogger.log("attachments: shortcut tap unavailable")
            return false
        }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self?.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        thread.name = "com.type4me.dictation-shortcut-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        guard let runLoop, let tap else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        self.tap = nil
        thread = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let shortcut = Self.shortcut(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags,
                regionActive: regionActive.withLock { $0 }
            )
            guard let shortcut else { return Unmanaged.passUnretained(event) }
            // A held key repeats; act once, swallow the rest.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onShortcut(shortcut) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Whether the box capture is on screen, for the dictation hotkeys: Esc then
/// cancels the box, not the recording.
enum DictationRegionCaptureState {
    private static let active = OSAllocatedUnfairLock(initialState: false)
    static var isActive: Bool {
        get { active.withLock { $0 } }
        set { active.withLock { $0 = newValue } }
    }
}
