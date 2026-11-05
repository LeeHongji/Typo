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
    /// A little taller than the line it stands on, so it sits with the words
    /// rather than towering over them.
    static let heightPerLine: CGFloat = 1.3
    static let bodyHeights: ClosedRange<CGFloat> = 18...30
    /// Beside the caret Typo is small, so its bubble is drawn larger to keep the glyph legible.
    static let bubbleScale: CGFloat = 1.4
    /// How high Typo hops, in design units, when the caret it follows moves to another line.
    static let followHop: CGFloat = 160

    static func bodyHeight(forCaretHeight h: CGFloat) -> CGFloat {
        min(bodyHeights.upperBound, max(bodyHeights.lowerBound, h * heightPerLine))
    }

    static func scale(bodyHeight: CGFloat) -> CGFloat {
        bodyHeight / TypoGeometry.bodyHeight
    }

    /// Where Typo's feet go: on the caret's bottom edge, just after it (or
    /// after the rest of the line's text, `textEnd`, so no words are covered),
    /// or just before the caret when there is no room on the right, on the
    /// screen or inside the text box `field` (a line that runs to the box's
    /// edge would put Typo outside it).
    static func feet(
        beside caret: CGRect, textEnd: CGFloat? = nil, field: CGRect? = nil,
        bodyHeight: CGFloat, screen: CGRect
    ) -> CGPoint {
        let gap = bodyHeight * 0.25
        let halfBody = bodyHeight * 0.75
        let reachRight = bodyHeight * 1.7
        let right = max(caret.maxX, textEnd ?? caret.maxX) + gap + halfBody
        let inField = field.map { right + halfBody <= $0.maxX } ?? true
        let x = right + reachRight <= screen.maxX && inField ? right : caret.minX - gap - halfBody
        return CGPoint(x: x, y: caret.minY)
    }

    /// What Typo does when the caret beside it moves.
    enum CaretMove: Equatable {
        /// The user moved it while talking: walk or hop along.
        case walk
        /// After the talking the move is the text landing: leap onto it then,
        /// not later when the bar hides (by which time Typo would only have
        /// been carried there, and the leap would find nothing left to do).
        case leap
        case ignore
    }

    static func caretMove(during stage: TypoPerformance.Stage) -> CaretMove {
        switch stage {
        case .entering, .listening: return .walk
        case .thinking, .reacting, .exiting(.leap): return .leap
        case .hidden, .exiting: return .ignore
        }
    }

    /// Which way Typo looks for the new text: it appears at the caret.
    static func gaze(feet: CGPoint, caret: CGRect) -> CGFloat {
        feet.x >= caret.maxX ? -1 : 1
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
    private let sprites = TypoSpriteView(frame: .zero)
    /// Typo's feet in the panel's view coordinates (origin top-left).
    private var line: CGPoint = .zero
    private var scale: CGFloat = 0.04
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
    private var panelFrame: CGRect = .zero
    private var watcher: CaretWatcher?
    /// With a watcher a caret move is heard at once; this is only a safety net
    /// for what sends no notification, such as scrolling.
    private static let safetyFollow: TimeInterval = 1.0
    /// Fastest the caret is re-read after a notification.
    private static let followGap: TimeInterval = 0.03
    /// A move to a new caret position: a short slide along the line, or a
    /// small hop when the caret changed lines.
    private struct Glide {
        let from: CGPoint
        let to: CGPoint
        let start: TimeInterval
        /// Peak of the hop in design units; 0 slides along the line.
        let hopHeight: CGFloat
        let duration: TimeInterval

        init(from: CGPoint, to: CGPoint, start: TimeInterval, bodyHeight: CGFloat) {
            self.from = from
            self.to = to
            self.start = start
            let bodies = hypot(to.x - from.x, to.y - from.y) / bodyHeight
            let hops = abs(to.y - from.y) > 2 || bodies > 4
            hopHeight = hops ? TypoCaretLayout.followHop * min(3, 1 + bodies / 6) : 0
            duration = hops ? min(0.5, 0.26 + bodies * 0.012) : 0.18
        }
    }
    private var glide: Glide?

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
        // Typo already finished its leap while the bar lingered: the bar is
        // going, so hand Typo back to it for next time.
        if !performance.isVisible, placement.mode == .caret { placement.mode = .bar }
        guard placement.mode == .caret, performance.isVisible, !isExiting, !pendingLeap else { return }
        let now = CACurrentMediaTime()
        guard style == .output, let start else {
            performance.finish(exitAfterMessage, at: now)
            startTicking()
            return
        }
        // The text landed but no caret move was heard (an app that posts no
        // notification): look once more, briefly, before pressing in place.
        pendingLeap = true
        let session = self.session
        Task { [weak self] in
            let target = await Self.caretAfterPaste(start: start)
            guard let self, self.session == session else { return }
            self.pendingLeap = false
            let now = CACurrentMediaTime()
            if let target {
                self.leap(to: target, at: now)
            } else {
                DebugFileLogger.log("typo caret: no leap target, pressing in place")
                self.performance.finish(.success, at: now)
            }
            self.startTicking()
        }
    }

    // MARK: - Session

    private func beginSession() {
        session += 1
        // A leap still waiting for its landing belongs to the session just replaced.
        pendingLeap = false
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
            if lookup == CaretLocator.noFocusedElement || lookup == CaretLocator.timedOut {
                // The first query after waking Chromium's accessibility tree
                // often comes back empty or late; the tree is ready a moment later.
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
                + (found.textEnd.map { " textEnd=\(Int($0))" } ?? "")
        )
        start = found
        bodyHeight = TypoCaretLayout.bodyHeight(forCaretHeight: found.rect.height)
        feet = TypoCaretLayout.feet(beside: found.rect, textEnd: found.textEnd, field: found.field, bodyHeight: bodyHeight, screen: screen.visibleFrame)
        glide = nil
        placePanel(feet: [feet])
        if let frame = panel?.frame {
            DebugFileLogger.log(
                "typo caret: placed feet=\(Int(feet.x)),\(Int(feet.y)) body=\(Int(bodyHeight)) "
                    + "panel=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) "
                    + "screen=\(Int(screen.frame.minX)),\(Int(screen.frame.minY)),\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            )
        }
        performance = TypoPerformance(peek: .caret, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        performance.gaze = TypoCaretLayout.gaze(feet: feet, caret: found.rect)
        performance.begin(at: CACurrentMediaTime())
        placement.mode = .caret
        lastFollow = CACurrentMediaTime()
        watcher?.stop()
        watcher = CaretWatcher(processIdentifier: found.processIdentifier)
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

    /// By the time the bar hides the text landed a while ago, so the caret is
    /// normally reported already; look every 30 ms (a warm lookup costs 1-2 ms)
    /// for a little longer in case the app is slow.
    private static let pasteWait: TimeInterval = 0.3

    private static func caretAfterPaste(start: CaretLocation) async -> CaretLocation? {
        let deadline = ContinuousClock.now + .seconds(pasteWait)
        var first = true
        while true {
            let lookup = await CaretLocator.locate(processIdentifier: start.processIdentifier, trace: first)
            first = false
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if let target = TypoCaretLayout.leapTarget(start: start, after: lookup.location, frontmost: frontmost) {
                return target
            }
            guard frontmost == start.processIdentifier, ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Leaps from where Typo stands to beside `target`, the caret after the new
    /// text. A leap already in the air takes the newer landing instead.
    private func leap(to target: CaretLocation, at now: TimeInterval) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: target.rect.midX, y: target.rect.midY)) })
        else { return }
        endGlide()
        start = target
        let landing = TypoCaretLayout.feet(
            beside: target.rect, textEnd: target.textEnd, field: target.field,
            bodyHeight: bodyHeight, screen: screen.visibleFrame
        )
        let offset = TypoCaretLayout.designOffset(from: feet, to: landing, scale: scale)
        if isLeaping {
            performance.retarget(offset, at: now)
        } else {
            performance.gaze = TypoCaretLayout.gaze(feet: landing, caret: target.rect)
            performance.finish(.leap(offset), at: now)
        }
        DebugFileLogger.log("typo caret: leap to \(Int(landing.x)),\(Int(landing.y)) air=\(String(format: "%.2f", performance.leap.air))s somersault=\(performance.leap.somersault)")
        placePanel(feet: [feet, landing], arc: performance.leap.arc * scale)
        startTicking()
    }

    private var isLeaping: Bool {
        if case .exiting(.leap) = performance.stage { return true }
        return false
    }

    // MARK: - Frames

    private func tick() {
        let now = CACurrentMediaTime()
        if performance.isVisible, !pendingLeap {
            if !isExiting { followPhase(at: now) }
            // Keep listening for caret moves in the air too: the paste can land in steps.
            if !isExiting || isLeaping { followCaretIfDue(at: now) }
        }
        performance.heard(state.transcriptionText, at: now)
        performance.update(level: state.audioLevel.current, at: now)
        var pose = performance.pose(at: now)
        pose.expression.bubbleScale = TypoCaretLayout.bubbleScale
        pose.hop += advanceGlide(at: now)
        if performance.isVisible || pendingLeap {
            if let panel, !panel.isVisible { panel.orderFrontRegardless() }
            sprites.update(pose: pose, line: line, scale: scale)
        } else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            watcher?.stop()
            watcher = nil
            // Hand Typo back to the bar (and the Appearance preview) once the
            // caret-side performance is over, but not while the bar is still
            // up after a leap: it would pop a second Typo onto the bar.
            if placement.mode == .caret, state.barPhase == .hidden { placement.mode = .bar }
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

    /// Re-reads the caret when the app says it moved, and once a second regardless
    /// so Typo also follows scrolling or a moved window.
    private func followCaretIfDue(at now: TimeInterval) {
        guard !followInFlight, let start else { return }
        let heard = now - lastFollow >= Self.followGap && watcher?.takeChange() == true
        guard heard || now - lastFollow >= Self.safetyFollow else { return }
        lastFollow = now
        // Floating panels of other apps can rise above Typo; keep it on top.
        panel?.orderFrontRegardless()
        followInFlight = true
        let session = self.session
        Task { [weak self] in
            let lookup = await CaretLocator.locate(processIdentifier: start.processIdentifier)
            guard let self, self.session == session else { return }
            self.followInFlight = false
            guard let found = lookup.location, !self.pendingLeap,
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: found.rect.midX, y: found.rect.midY)) })
            else { return }
            let now = CACurrentMediaTime()
            switch TypoCaretLayout.caretMove(during: self.performance.stage) {
            case .walk:
                let next = TypoCaretLayout.feet(beside: found.rect, textEnd: found.textEnd, field: found.field, bodyHeight: self.bodyHeight, screen: screen.visibleFrame)
                guard hypot(next.x - self.feet.x, next.y - self.feet.y) > 2 else { return }
                self.start = found
                self.performance.gaze = TypoCaretLayout.gaze(feet: next, caret: found.rect)
                self.move(to: next, at: now)
            case .leap:
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard let target = TypoCaretLayout.leapTarget(start: start, after: found, frontmost: frontmost) else { return }
                self.leap(to: target, at: now)
            case .ignore:
                return
            }
        }
    }

    /// Slides along the line, or hops when the caret changed lines or went
    /// far, higher and a little longer the farther it goes. Only a move to
    /// another screen is not a walk: there Typo just appears.
    private func move(to next: CGPoint, at now: TimeInterval) {
        let from = glide.map { glidePoint($0, at: now) } ?? feet
        feet = next
        let sameScreen = NSScreen.screens.contains { $0.frame.contains(from) && $0.frame.contains(next) }
        guard !performance.reduceMotion, sameScreen else {
            glide = nil
            placePanel(feet: [next])
            return
        }
        let move = Glide(from: from, to: next, start: now, bodyHeight: bodyHeight)
        placePanel(feet: [from, next], arc: move.hopHeight * TypoCaretLayout.scale(bodyHeight: bodyHeight), standing: from)
        glide = move
    }

    private func glideProgress(_ g: Glide, at now: TimeInterval) -> Double {
        min(1, max(0, (now - g.start) / g.duration))
    }

    private func glidePoint(_ g: Glide, at now: TimeInterval) -> CGPoint {
        let p = glideProgress(g, at: now)
        let eased = CGFloat(1 - pow(1 - p, 3))
        return CGPoint(x: g.from.x + (g.to.x - g.from.x) * eased, y: g.from.y + (g.to.y - g.from.y) * eased)
    }

    /// Moves Typo's line along the current glide; answers the hop to add, in design units.
    private func advanceGlide(at now: TimeInterval) -> CGFloat {
        guard let g = glide else { return 0 }
        let p = glideProgress(g, at: now)
        if p >= 1 {
            endGlide()
            return 0
        }
        line = lineInPanel(glidePoint(g, at: now))
        return CGFloat(sin(p * .pi)) * g.hopHeight
    }

    private func endGlide() {
        guard glide != nil else { return }
        glide = nil
        placePanel(feet: [feet])
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

    /// Sizes the panel to hold Typo at each of `points` and puts its line at
    /// `standing` (by default where Typo stands now).
    private func placePanel(feet points: [CGPoint], arc: CGFloat = 0, standing: CGPoint? = nil) {
        let frame = TypoCaretLayout.panelFrame(feet: points, bodyHeight: bodyHeight, arc: arc)
        let panel = self.panel ?? makePanel(frame: frame)
        panel.setFrame(frame, display: false)
        panelFrame = frame
        scale = TypoCaretLayout.scale(bodyHeight: bodyHeight)
        line = lineInPanel(standing ?? feet)
    }

    private func lineInPanel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y)
    }

    private func makePanel(frame: CGRect) -> TypoCaretPanel {
        let panel = TypoCaretPanel(contentRect: frame)
        sprites.autoresizingMask = [.width, .height]
        panel.contentView = sprites
        self.panel = panel
        return panel
    }
}
