import AppKit
import CoreGraphics
import os

/// How a press on a window that is ready to be shot is treated. Pure, so it
/// can be tested apart from the event tap that feeds it.
///
/// A plain click is taken for the shutter and never reaches the window. A
/// drag, a double click or a long press is the user working in the window:
/// the held press is given back to it and the rest flows through untouched.
struct DictationShutter: Equatable {
    enum Effect: Equatable {
        /// Let the current event through.
        case pass
        /// Drop the current event.
        case drop
        /// Keep the current event back.
        case hold
        /// Post every event kept back, in order.
        case flush
        /// Wait to see whether a second click follows.
        case wait
        /// The click was for the shutter: forget what was kept back and shoot.
        case shoot
    }

    enum Phase: Equatable {
        case idle
        case pressed(at: CGPoint, time: TimeInterval)
        case released(at: CGPoint, time: TimeInterval)
    }

    static let dragDistance: CGFloat = 4
    /// Held longer than this without moving is a long press, not a click.
    static let longPress: TimeInterval = 0.5

    private(set) var phase: Phase = .idle

    /// `shootable`: the press lands on the armed window with no ⌘ held.
    mutating func down(at point: CGPoint, time: TimeInterval, clickState: Int64, shootable: Bool) -> [Effect] {
        switch phase {
        case .released:
            phase = .idle
            // The second press of a double click: give the first one back.
            if clickState >= 2 { return [.hold, .flush] }
            // Something new: the click before it was for the shutter.
            return [.shoot] + fresh(point, time, clickState, shootable)
        case .pressed:
            phase = .idle
            return [.hold, .flush]
        case .idle:
            return fresh(point, time, clickState, shootable)
        }
    }

    private mutating func fresh(_ point: CGPoint, _ time: TimeInterval, _ clickState: Int64, _ shootable: Bool) -> [Effect] {
        guard shootable, clickState == 1 else { return [.pass] }
        phase = .pressed(at: point, time: time)
        return [.hold]
    }

    mutating func drag(to point: CGPoint) -> [Effect] {
        guard case .pressed(let start, _) = phase else { return [.pass] }
        guard hypot(point.x - start.x, point.y - start.y) > Self.dragDistance else { return [.drop] }
        phase = .idle
        return [.hold, .flush]
    }

    mutating func up(at point: CGPoint, time: TimeInterval) -> [Effect] {
        guard case .pressed(let start, let pressedAt) = phase else { return [.pass] }
        let moved = hypot(point.x - start.x, point.y - start.y) > Self.dragDistance
        if moved || time - pressedAt > Self.longPress {
            phase = .idle
            return [.hold, .flush]
        }
        phase = .released(at: start, time: time)
        return [.hold, .wait]
    }

    /// No second click came in time.
    mutating func timeout() -> [Effect] {
        guard case .released = phase else { return [] }
        phase = .idle
        return [.shoot]
    }

    /// Collecting stopped mid-click: whatever was held goes back to the window.
    mutating func cancel() -> [Effect] {
        guard phase != .idle else { return [] }
        phase = .idle
        return [.flush]
    }
}

/// Lets a window that is ready be shot with one click, and starts the box
/// capture on ⌥S, while the user talks. A session event tap on its own thread
/// so the mouse never waits for the main thread; it only looks at left-button
/// presses and key presses, and only while collecting.
final class DictationPointerTap: @unchecked Sendable {
    struct Armed: Equatable {
        let id: CGWindowID
        /// Window-server coordinates (top-left origin).
        let frame: CGRect
    }

    /// Events this tap posts back carry this, so it lets them pass.
    static let marker: Int64 = 0x7434_6D65

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let lock = OSAllocatedUnfairLock(initialState: Shared())
    private struct Shared {
        var armed: Armed?
        /// Type4Me's own windows that take clicks (the bar, the tray).
        var ownFrames: [CGRect] = []
        var regionActive = false
    }

    // Tap thread only.
    private var shutter = DictationShutter()
    private var held: [CGEvent] = []
    private var heldWindow: Armed?
    private var waitToken = 0

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    private let onShoot: @Sendable (Armed) -> Void
    private let onRegionKey: @Sendable () -> Void
    private let onEscape: @Sendable () -> Void

    init(
        onShoot: @escaping @Sendable (Armed) -> Void,
        onRegionKey: @escaping @Sendable () -> Void,
        onEscape: @escaping @Sendable () -> Void
    ) {
        self.onShoot = onShoot
        self.onRegionKey = onRegionKey
        self.onEscape = onEscape
    }

    func update(armed: Armed?, ownFrames: [CGRect], regionActive: Bool) {
        lock.withLock {
            $0.armed = armed
            $0.ownFrames = ownFrames
            $0.regionActive = regionActive
        }
    }

    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<DictationPointerTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugFileLogger.log("attachments: pointer tap unavailable")
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
        thread.name = "com.type4me.dictation-pointer-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return true
    }

    /// Gives back a half-finished click, then removes the tap.
    func stop() {
        guard let runLoop, let tap else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            apply(shutter.cancel(), to: nil)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        self.tap = nil
        thread = nil
    }

    // MARK: - Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        let shared = lock.withLock { $0 }
        switch type {
        case .keyDown:
            return key(event, regionActive: shared.regionActive)
        case .leftMouseDown:
            // The box capture takes its own presses.
            guard !shared.regionActive else { return Unmanaged.passUnretained(event) }
            let point = event.location
            let target = shootable(point, flags: event.flags, shared: shared)
            let effects = shutter.down(
                at: point, time: Self.seconds(event),
                clickState: event.getIntegerValueField(.mouseEventClickState),
                shootable: target != nil
            )
            let result = apply(effects, to: event)
            // After applying: a shot of the click before this one uses its own window.
            if case .pressed = shutter.phase { heldWindow = target }
            return result
        case .leftMouseDragged:
            return apply(shutter.drag(to: event.location), to: event)
        case .leftMouseUp:
            return apply(shutter.up(at: event.location, time: Self.seconds(event)), to: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func key(_ event: CGEvent, regionActive: Bool) -> Unmanaged<CGEvent>? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if regionActive, code == 53 {
            onEscape()
            return nil
        }
        // ⌥S, with no ⌘ or ⌃: draw a box to shoot.
        if code == 1, flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onRegionKey() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// The armed window, when this press lands on it and nothing is above it there.
    private func shootable(_ point: CGPoint, flags: CGEventFlags, shared: Shared) -> Armed? {
        guard let armed = shared.armed, !flags.contains(.maskCommand), armed.frame.contains(point),
              !shared.ownFrames.contains(where: { $0.contains(point) })
        else { return nil }
        return Self.topWindow(at: point, excluding: ownPID) == armed.id ? armed : nil
    }

    private func apply(_ effects: [DictationShutter.Effect], to event: CGEvent?) -> Unmanaged<CGEvent>? {
        var result: Unmanaged<CGEvent>?
        for effect in effects {
            switch effect {
            case .pass:
                result = event.map { Unmanaged.passUnretained($0) }
            case .drop:
                result = nil
            case .hold:
                if let copy = event?.copy() { held.append(copy) }
                result = nil
            case .flush:
                for e in held {
                    e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    e.post(tap: .cgSessionEventTap)
                }
                held.removeAll()
                heldWindow = nil
                result = nil
            case .wait:
                waitToken += 1
                let token = waitToken
                let interval = NSEvent.doubleClickInterval
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + interval) { [weak self] in
                    guard let self, let runLoop = self.runLoop else { return }
                    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                        guard self.waitToken == token else { return }
                        _ = self.apply(self.shutter.timeout(), to: nil)
                    }
                    CFRunLoopWakeUp(runLoop)
                }
                result = nil
            case .shoot:
                held.removeAll()
                if let window = heldWindow { onShoot(window) }
                heldWindow = nil
            }
        }
        return result
    }

    private static func seconds(_ event: CGEvent) -> TimeInterval {
        TimeInterval(event.timestamp) / 1_000_000_000
    }

    /// The front-most window under a window-server point, other than Type4Me's
    /// (its effects never take clicks; its bar and tray are checked apart).
    static func topWindow(at point: CGPoint, excluding ownPID: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        let screens = screenRects()
        for entry in list {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            if isClickThroughOverlay(layer: layer, bounds: bounds, screens: screens) { continue }
            return CGWindowID(number)
        }
        return nil
    }

    /// A window above the normal layer that covers a whole screen is a
    /// see-through overlay (the Dock keeps one over everything), not
    /// something the user clicks. Full-screen apps are on the normal layer.
    static func isClickThroughOverlay(layer: Int, bounds: CGRect, screens: [CGRect]) -> Bool {
        guard layer != 0 else { return false }
        return screens.contains { screen in
            bounds.minX <= screen.minX + 1 && bounds.minY <= screen.minY + 1
                && bounds.maxX >= screen.maxX - 1 && bounds.maxY >= screen.maxY - 1
        }
    }

    /// Display bounds in window-server coordinates.
    private static func screenRects() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
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
