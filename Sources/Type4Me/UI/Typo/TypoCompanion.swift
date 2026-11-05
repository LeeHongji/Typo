import QuartzCore
import SwiftUI

enum TypoCompanionSettings {
    static let enabledKey = "tf_typoCompanionEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}

/// Where Typo sits on the recording bar: centred over the finish control,
/// peeking over the capsule's top edge.
struct TypoBuddyMetrics: Equatable {
    /// Typo's centre, measured from the capsule's leading edge.
    let anchorX: CGFloat
    /// Height of Typo's body when it stands fully out.
    let bodyHeight: CGFloat

    static let regular = TypoBuddyMetrics(
        anchorX: TF.recordingLeadingInset + TF.recordingFinishControlSize / 2,
        bodyHeight: 32
    )
    static let compact = TypoBuddyMetrics(
        anchorX: TF.compactIndicatorControlWidth / 2 + 4,
        bodyHeight: 26
    )

    static func forCompact(_ compact: Bool) -> TypoBuddyMetrics { compact ? .compact : .regular }

    var scale: CGFloat { bodyHeight / TypoGeometry.bodyHeight }

    /// Room above the capsule's top edge for the tallest pose: the shout
    /// lines (round caps and white edge included) when Typo bristles.
    var headroom: CGFloat {
        ceil((TypoGeometry.baselineY - 400) * scale)
    }

    /// Canvas width from the capsule's leading edge: Typo plus its bubble.
    var trailingExtent: CGFloat {
        ceil(anchorX + (1830 - TypoRenderer.feetAnchor.x) * scale)
    }

    /// How far Typo's arms and outline reach past the capsule's leading edge.
    var leadingOverhang: CGFloat {
        max(0, ceil((TypoRenderer.feetAnchor.x - 340) * scale - anchorX))
    }
}

/// What the recording bar tells Typo each frame.
struct TypoBuddyCue: Equatable {
    var phase: FloatingBarPhase
    /// Set while the bar plays its exit; `.output` means text landed.
    var exitStyle: FloatingBarHideStyle?
    var feedbackKind: FeedbackKind
    /// The words recognized so far; Typo nods as they appear.
    var transcript: String = ""
}

/// Turns bar cues into performance events. A class so the timeline can advance
/// one long-lived performance without invalidating the bar's view state.
@MainActor
final class TypoDirector {
    private(set) var performance = TypoPerformance()

    var isVisible: Bool { performance.isVisible }

    func pose(for cue: TypoBuddyCue, level: Float, reduceMotion: Bool, at t: TimeInterval) -> TypoPerformance.Pose {
        apply(cue, reduceMotion: reduceMotion, at: t)
        performance.heard(cue.transcript, at: t)
        performance.carrying(DictationAttachments.shared.carried(at: CACurrentMediaTime()), at: t)
        performance.update(level: level, at: t)
        return performance.pose(at: t)
    }

    func apply(_ cue: TypoBuddyCue, reduceMotion: Bool, at t: TimeInterval) {
        if !performance.isVisible { performance.reduceMotion = reduceMotion }
        if let style = cue.exitStyle {
            if case .exiting = performance.stage { return }
            let exit: TypoPerformance.Exit
            switch (style, performance.stage) {
            case (.output, _), (_, .reacting(.done)):
                exit = .success
            case (_, .reacting(.failed)):
                exit = .failed
            default:
                exit = .cancelled
            }
            performance.finish(exit, at: t)
            return
        }
        switch cue.phase {
        case .preparing, .recording:
            performance.begin(at: t)
        case .finishing, .processing, .recovering:
            if !performance.isVisible { performance.begin(at: t) }
            performance.think(at: t)
        case .done:
            performance.react(Self.reaction(for: cue.feedbackKind), at: t)
        case .error:
            performance.react(.failed, at: t)
        case .hidden:
            // The bar vanished without an exit (for example a preview reset).
            performance.finish(.cancelled, at: t)
        }
    }

    static func reaction(for kind: FeedbackKind) -> TypoPerformance.Reaction {
        switch kind {
        case .standard, .macActionSuccess:
            return .done
        case .warning, .macActionFailure, .macActionUnsure:
            return .failed
        }
    }
}

/// Typo peeking over the recording bar. The view spans the capsule plus the
/// room above it; everything inside the capsule's shape is masked, so the part
/// of Typo below the edge reads as hidden behind the bar. Typo is drawn as
/// cached sprites moved by Core Animation, not redrawn every frame.
struct TypoBuddyView: View {
    let cue: TypoBuddyCue
    let meter: AudioLevelMeter
    let metrics: TypoBuddyMetrics
    let capsuleSize: CGSize
    let cornerRadius: CGFloat

    @State private var director = TypoDirector()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isIdle: Bool {
        cue.phase == .hidden && cue.exitStyle == nil && !director.isVisible
    }

    var body: some View {
        TimelineView(.animation(paused: isIdle)) { timeline in
            let pose = director.pose(
                for: cue,
                level: meter.current,
                reduceMotion: reduceMotion,
                at: timeline.date.timeIntervalSinceReferenceDate
            )
            let capsule = CGRect(
                x: metrics.leadingOverhang,
                y: metrics.headroom,
                width: capsuleSize.width,
                height: capsuleSize.height
            )
            TypoSpriteLayer(
                pose: pose,
                line: CGPoint(x: capsule.minX + metrics.anchorX, y: capsule.minY),
                scale: metrics.scale,
                clip: .behind(capsule, cornerRadius: cornerRadius)
            )
        }
        .frame(
            width: metrics.leadingOverhang + max(metrics.trailingExtent, capsuleSize.width),
            height: metrics.headroom + capsuleSize.height
        )
        .offset(x: -metrics.leadingOverhang, y: -metrics.headroom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Hosts `TypoSpriteView` in SwiftUI.
struct TypoSpriteLayer: NSViewRepresentable {
    let pose: TypoPerformance.Pose
    let line: CGPoint
    let scale: CGFloat
    let clip: TypoSpriteView.Clip

    func makeNSView(context: Context) -> TypoSpriteView { TypoSpriteView(frame: .zero) }

    func updateNSView(_ view: TypoSpriteView, context: Context) {
        view.clip = clip
        view.update(pose: pose, line: line, scale: scale)
    }
}
