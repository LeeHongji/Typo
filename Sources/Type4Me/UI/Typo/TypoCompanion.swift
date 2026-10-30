import AppKit
import QuartzCore
import SwiftUI

enum TypoCompanionSettings {
    static let enabledKey = "tf_typoCompanionEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}

/// Which floating-bar phases Typo performs in place of the bar. Messages that
/// need words (done, error, recovery) stay with the bar.
enum TypoCompanionRouting {
    static func handles(_ phase: FloatingBarPhase) -> Bool {
        switch phase {
        case .preparing, .recording, .finishing, .processing:
            return true
        case .hidden, .recovering, .done, .error:
            return false
        }
    }
}

enum TypoCompanionLayout {
    static let width: CGFloat = 150

    static var height: CGFloat {
        let v = TypoGeometry.viewport
        return (width * v.height / v.width).rounded(.up)
    }

    /// Typo stands where the bar's capsule would be: its feet on the capsule's
    /// bottom edge, its body centred on the capsule.
    static func panelFrame(forCapsule capsule: NSRect) -> NSRect {
        let v = TypoGeometry.viewport
        let scale = width / v.width
        let bodyCentreX: CGFloat = 978
        let baselineFromBottom = (v.maxY - TypoGeometry.baselineY) * scale
        return NSRect(
            x: (capsule.midX - (bodyCentreX - v.minX) * scale).rounded(),
            y: (capsule.minY - baselineFromBottom).rounded(),
            width: width,
            height: height
        )
    }
}

@MainActor
@Observable
final class TypoCompanionModel {
    var pose = TypoPerformance.Pose(opacity: 0)
}

private final class TypoCompanionPanel: NSPanel {
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

/// Owns Typo's window and drives its performance from the app state.
///
/// FloatingBarController hands it each show/hide request first; when Typo is
/// enabled and the phase is one it performs, the bar stays hidden.
@MainActor
final class TypoCompanionController {
    private let state: AppState
    private let defaults: UserDefaults
    private let model = TypoCompanionModel()
    private var performance = TypoPerformance()
    private var panel: TypoCompanionPanel?
    private var timer: Timer?

    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state
        self.defaults = defaults
    }

    var isPerforming: Bool { performance.isVisible }

    /// Returns true when Typo takes this show request instead of the bar.
    func takeShowRequest() -> Bool {
        let now = CACurrentMediaTime()
        guard TypoCompanionSettings.isEnabled(defaults), TypoCompanionRouting.handles(state.barPhase) else {
            // The bar is about to show a message; Typo steps aside.
            if performance.isVisible { performance.finish(.failed, at: now) }
            return false
        }
        if !performance.isVisible {
            performance.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            placePanel()
        }
        sync(at: now)
        startTicking()
        return true
    }

    /// Mirrors a bar hide request. A successful paste uses the output style.
    func handleHide(style: FloatingBarHideStyle) {
        guard performance.isVisible else { return }
        performance.finish(style == .output ? .success : .cancelled, at: CACurrentMediaTime())
        startTicking()
    }

    private var isExiting: Bool {
        if case .exiting = performance.stage { return true }
        return false
    }

    private func sync(at now: TimeInterval) {
        switch state.barPhase {
        case .preparing, .recording:
            performance.begin(at: now)
        case .finishing, .processing:
            if !performance.isVisible { performance.begin(at: now) }
            performance.think(at: now)
        case .hidden:
            // A session that ended without a hide request must not leave Typo behind.
            performance.finish(.cancelled, at: now)
        case .recovering, .done, .error:
            performance.finish(.failed, at: now)
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

    private func tick() {
        let now = CACurrentMediaTime()
        if performance.isVisible && !isExiting { sync(at: now) }
        performance.update(level: state.audioLevel.current, at: now)
        model.pose = performance.pose(at: now)
        if performance.isVisible {
            panel?.orderFrontRegardless()
        } else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
        }
    }

    private func placePanel() {
        let screen = FloatingBarPanel.screenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let style = RecordingIndicatorStyle.current(userDefaults: defaults)
        let baseHeight = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let centre = FloatingBarPlacementGeometry.resolveCenter(
            FloatingBarPlacementStore.load(defaults),
            visibleFrame: visible,
            baseHeight: baseHeight
        )
        let capsule = FloatingBarPlacementGeometry.baseCapsuleRect(center: centre, style: style)
        let frame = TypoCompanionLayout.panelFrame(forCapsule: capsule)
        let panel = self.panel ?? makePanel(frame: frame)
        panel.setFrame(frame, display: false)
    }

    private func makePanel(frame: NSRect) -> TypoCompanionPanel {
        let panel = TypoCompanionPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: TypoCompanionView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

/// Draws the current pose. Everything below the baseline is clipped, so Typo
/// rises out of and sinks back into the line it stands on.
struct TypoCompanionView: View {
    let model: TypoCompanionModel

    var body: some View {
        // Read outside the renderer closure so Observation tracks the pose.
        let pose = model.pose
        Canvas { ctx, size in
            TypoRenderer.draw(pose, in: &ctx, size: size)
        }
        .allowsHitTesting(false)
    }
}
