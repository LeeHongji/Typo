import ApplicationServices
import Foundation
import os

/// Hears when the text caret of an app may have moved, without polling.
///
/// Apps post accessibility notifications for caret moves, text edits and focus
/// changes; one observer on the application element receives those of every
/// element inside it (checked in TextEdit, Safari and Chrome). The notifications
/// arrive on a thread of their own, so the main thread is never blocked by an
/// app that answers accessibility calls slowly. The watcher only says "something
/// changed"; the caller then asks `CaretLocator` where the caret is, at most once
/// per change however many notifications a burst of typing posts.
final class CaretWatcher: @unchecked Sendable {
    private static let notifications = [
        kAXSelectedTextChangedNotification,
        kAXValueChangedNotification,
        kAXFocusedUIElementChangedNotification,
    ]

    private let changed = OSAllocatedUnfairLock(initialState: false)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(processIdentifier pid: pid_t) {
        let thread = Thread { [self] in listen(to: pid) }
        thread.name = "com.type4me.caret-watcher"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// True once if the caret may have moved since the last call.
    func takeChange() -> Bool {
        changed.withLock { flag in
            defer { flag = false }
            return flag
        }
    }

    /// Stops listening within a fraction of a second. The watcher must be
    /// stopped: its thread owns it until then.
    func stop() {
        stopped.withLock { $0 = true }
    }

    private func listen(to pid: pid_t) {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<CaretWatcher>.fromOpaque(refcon).takeUnretainedValue().changed.withLock { $0 = true }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, app, name as CFString, me)
        }
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        // Wake now and then to notice stop(); a stop that arrives before the
        // loop runs would otherwise be lost.
        while !stopped.withLock({ $0 }) {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
        CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
