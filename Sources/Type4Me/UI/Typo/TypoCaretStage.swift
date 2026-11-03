import AppKit
import QuartzCore
import SwiftUI

/// Where Typo performs this dictation. The recording bar draws its own Typo
/// only in `.bar`, so there is never more than one on screen.
@MainActor
@Observable
final class TypoPlacement {
    static let shared = TypoPlacement()

    enum Mode: Equatable {
        case bar
        /// The caret lookup is still running; neither place shows Typo yet.
        case deciding
        case caret
    }

    var mode: Mode = .bar
}

/// Sizing and placement of the caret-side Typo, in AppKit screen points.
enum TypoCaretLayout {
    static let heightPerLine: CGFloat = 1.8
    static let bodyHeights: ClosedRange<CGFloat> = 22...44

    static func bodyHeight(forCaretHeight h: CGFloat) -> CGFloat {
        min(bodyHeights.upperBound, max(bodyHeights.lowerBound, h * heightPerLine))
    }

    static func scale(bodyHeight: CGFloat) -> CGFloat {
        bodyHeight / TypoGeometry.bodyHeight
    }

    /// Where Typo's feet go: on the caret's bottom edge, just after it, or just
    /// before it when there is no room on the right of the screen.
    static func feet(beside caret: CGRect, bodyHeight: CGFloat, screen: CGRect) -> CGPoint {
        let gap = bodyHeight * 0.25
        let halfBody = bodyHeight * 0.75
        let reachRight = bodyHeight * 1.7
        let right = caret.maxX + gap + halfBody
        let x = right + reachRight <= screen.maxX ? right : caret.minX - gap - halfBody
        return CGPoint(x: x, y: caret.minY)
    }

    /// A window that holds Typo standing at each of `feet`, plus the arc of a
    /// leap between them.
    static func panelFrame(feet points: [CGPoint], bodyHeight: CGFloat, arc: CGFloat = 0) -> CGRect {
        let boxes = points.map { p in
            CGRect(
                x: p.x - bodyHeight * 1.1,
                y: p.y - bodyHeight * 0.35,
                width: bodyHeight * 2.8,
                height: bodyHeight * 1.7 + arc
            )
        }
        let union = boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
        return union.integral
    }

    /// The caret after a paste is a leap target only in the same app and only
    /// when it actually moved; an unchanged caret means the app has not
    /// reported the new text yet.
    static func leapTarget(start: CaretLocation, after: CaretLocation?, frontmost pid: pid_t?) -> CaretLocation? {
        guard let after, after.processIdentifier == start.processIdentifier, pid == start.processIdentifier else {
            return nil
        }
        let moved = hypot(after.rect.maxX - start.rect.maxX, after.rect.minY - start.rect.minY)
        return moved > 1 ? after : nil
    }

    /// Converts a screen-space displacement into Typo's design units (y down).
    static func designOffset(from a: CGPoint, to b: CGPoint, scale: CGFloat) -> CGSize {
        CGSize(width: (b.x - a.x) / scale, height: -(b.y - a.y) / scale)
    }
}

@MainActor
@Observable
final class TypoCaretModel {
    var pose = TypoPerformance.Pose(opacity: 0)
    /// Typo's feet, in the panel's view coordinates (origin top-left).
    var line: CGPoint = .zero
    var scale: CGFloat = 0.04
}

private final class TypoCaretPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Typo standing beside the text caret of the app being dictated into. The
/// recording bar forwards its show and hide requests; when the caret cannot be
/// found, the bar keeps Typo instead.
@MainActor
final class TypoCaretStage {
    private let state: AppState
    private let placement: TypoPlacement
    private let model = TypoCaretModel()
    private var performance = TypoPerformance(peek: .caret)
    private var panel: TypoCaretPanel?
    private var timer: Timer?
    private var session = 0
    private var start: CaretLocation?
    private var feet: CGPoint = .zero
    private var bodyHeight: CGFloat = TypoCaretLayout.bodyHeights.lowerBound
    private var pendingLeap = false
    private var followInFlight = false
    private var lastFollow: TimeInterval = 0

    init(state: AppState, placement: TypoPlacement? = nil) {
        self.state = state
        self.placement = placement ?? .shared
    }

    // MARK: - Bar requests

    func barWillShow() {
        guard TypoCompanionSettings.isEnabled() else {
            placement.mode = .bar
            return
        }
        switch state.barPhase {
        case .preparing, .recording:
            let idle = !performance.isVisible || isExiting
            if idle && placement.mode != .deciding { beginSession() }
        default:
            break
        }
        if performance.isVisible { startTicking() }
    }

    func barWillHide(style: FloatingBarHideStyle) {
        guard placement.mode == .caret, performance.isVisible, !isExiting, !pendingLeap else { return }
        let now = CACurrentMediaTime()
        guard style == .output, let start else {
            performance.finish(exitAfterMessage, at: now)
            startTicking()
            return
        }
        pendingLeap = true
        let session = self.session
        Task { [weak self] in
            let target = await Self.caretAfterPaste(start: start)
            guard let self, self.session == session else { return }
            self.leap(to: target)
        }
    }

    // MARK: - Session

    private func beginSession() {
        session += 1
        let session = self.session
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            placement.mode = .bar
            return
        }
        placement.mode = .deciding
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? "unknown"
        Task { [weak self] in
            var lookup = await CaretLocator.locate(processIdentifier: pid, trace: true)
            if lookup == .unavailable("no focused element") {
                // The first query after waking Chromium's accessibility tree
                // often comes back empty; the tree is ready a moment later.
                try? await Task.sleep(for: .milliseconds(350))
                lookup = await CaretLocator.locate(processIdentifier: pid, trace: true)
            }
            guard let self, self.session == session else { return }
            self.decide(lookup, bundle: bundle)
        }
    }

    private func decide(_ lookup: CaretLookup, bundle: String) {
        let phase = state.barPhase
        guard phase == .preparing || phase == .recording, let found = lookup.location,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: found.rect.midX, y: found.rect.midY)) })
        else {
            if case .unavailable(let reason) = lookup {
                DebugFileLogger.log("typo caret: unavailable app=\(bundle) reason=\(reason)")
            } else if lookup == .secureField {
                DebugFileLogger.log("typo caret: secure field app=\(bundle)")
            }
            placement.mode = .bar
            return
        }
        DebugFileLogger.log(
            "typo caret: found app=\(bundle) tier=\(found.tier.rawValue) "
                + "rect=\(Int(found.rect.minX)),\(Int(found.rect.minY)),\(Int(found.rect.width))x\(Int(found.rect.height))"
        )
        start = found
        bodyHeight = TypoCaretLayout.bodyHeight(forCaretHeight: found.rect.height)
        feet = TypoCaretLayout.feet(beside: found.rect, bodyHeight: bodyHeight, screen: screen.visibleFrame)
        placePanel(feet: [feet])
        if let frame = panel?.frame {
            DebugFileLogger.log(
                "typo caret: placed feet=\(Int(feet.x)),\(Int(feet.y)) body=\(Int(bodyHeight)) "
                    + "panel=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) "
                    + "screen=\(Int(screen.frame.minX)),\(Int(screen.frame.minY)),\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            )
        }
        performance = TypoPerformance(peek: .caret, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        performance.begin(at: CACurrentMediaTime())
        placement.mode = .caret
        lastFollow = CACurrentMediaTime()
        startTicking()
    }

    private var isExiting: Bool {
        if case .exiting = performance.stage { return true }
        return false
    }

    private var exitAfterMessage: TypoPerformance.Exit {
        switch performance.stage {
        case .reacting(.done): return .success
        case .reacting(.failed): return .failed
        default: return .cancelled
        }
    }

    // MARK: - Leap

    /// The app may report the new caret a moment after the paste, so look a
    /// few times before deciding the caret did not move.
    private static func caretAfterPaste(start: CaretLocation) async -> CaretLocation? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(60)) }
            let lookup = await CaretLocator.locate(processIdentifier: start.processIdentifier, trace: attempt == 0)
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if let target = TypoCaretLayout.leapTarget(start: start, after: lookup.location, frontmost: frontmost) {
                return target
            }
        }
        return nil
    }

    private func leap(to target: CaretLocation?) {
        pendingLeap = false
        let now = CACurrentMediaTime()
        guard let target,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: target.rect.midX, y: target.rect.midY)) })
        else {
            DebugFileLogger.log("typo caret: no leap target, pressing in place")
            performance.finish(.success, at: now)
            startTicking()
            return
        }
        let scale = TypoCaretLayout.scale(bodyHeight: bodyHeight)
        let landing = TypoCaretLayout.feet(beside: target.rect, bodyHeight: bodyHeight, screen: screen.visibleFrame)
        let offset = TypoCaretLayout.designOffset(from: feet, to: landing, scale: scale)
        let arc = max(420, abs(offset.height) * 0.6 + 380) * scale
        placePanel(feet: [feet, landing], arc: arc)
        performance.finish(.leap(offset), at: now)
        startTicking()
    }

    // MARK: - Frames

    private func tick() {
        let now = CACurrentMediaTime()
        if performance.isVisible, !isExiting, !pendingLeap {
            followPhase(at: now)
            followCaretIfDue(at: now)
        }
        performance.update(level: state.audioLevel.current, at: now)
        model.pose = performance.pose(at: now)
        if performance.isVisible || pendingLeap {
            panel?.orderFrontRegardless()
        } else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            // Hand Typo back to the bar (and the Appearance preview) once the
            // caret-side performance is over.
            if placement.mode == .caret { placement.mode = .bar }
        }
    }

    private func followPhase(at now: TimeInterval) {
        if let pid = start?.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            // The user moved to another app: bow out here and let the bar's Typo carry on.
            performance.finish(.cancelled, at: now)
            placement.mode = .bar
            return
        }
        switch state.barPhase {
        case .preparing, .recording:
            performance.begin(at: now)
        case .finishing, .processing, .recovering:
            performance.think(at: now)
        case .done:
            performance.react(TypoDirector.reaction(for: state.feedbackKind), at: now)
        case .error:
            performance.react(.failed, at: now)
        case .hidden:
            performance.finish(exitAfterMessage, at: now)
        }
    }

    /// Re-reads the caret twice a second so Typo follows scrolling or a moved window.
    private func followCaretIfDue(at now: TimeInterval) {
        guard !followInFlight, now - lastFollow >= 0.5, let start else { return }
        lastFollow = now
        followInFlight = true
        let session = self.session
        Task { [weak self] in
            let lookup = await CaretLocator.locate(processIdentifier: start.processIdentifier)
            guard let self, self.session == session else { return }
            self.followInFlight = false
            guard let found = lookup.location, !self.isExiting, !self.pendingLeap,
                  hypot(found.rect.maxX - start.rect.maxX, found.rect.minY - start.rect.minY) > 2,
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: found.rect.midX, y: found.rect.midY)) })
            else { return }
            self.start = found
            self.feet = TypoCaretLayout.feet(beside: found.rect, bodyHeight: self.bodyHeight, screen: screen.visibleFrame)
            self.placePanel(feet: [self.feet])
        }
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func placePanel(feet points: [CGPoint], arc: CGFloat = 0) {
        let frame = TypoCaretLayout.panelFrame(feet: points, bodyHeight: bodyHeight, arc: arc)
        let panel = self.panel ?? makePanel(frame: frame)
        panel.setFrame(frame, display: false)
        model.scale = TypoCaretLayout.scale(bodyHeight: bodyHeight)
        model.line = CGPoint(x: feet.x - frame.minX, y: frame.maxY - feet.y)
    }

    private func makePanel(frame: CGRect) -> TypoCaretPanel {
        let panel = TypoCaretPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: TypoCaretView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

/// Draws the caret-side Typo. The part below its line is clipped, so it rises
/// out of and sinks back into the text it stands on; the line follows Typo's
/// travel during a leap.
struct TypoCaretView: View {
    let model: TypoCaretModel

    var body: some View {
        let pose = model.pose
        let line = model.line
        let scale = model.scale
        Canvas { ctx, size in
            let lineY = line.y + pose.travel.height * scale
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, lineY + 1))))
            TypoRenderer.draw(pose, in: &ctx, line: line, scale: scale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
