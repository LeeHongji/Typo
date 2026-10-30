import CoreGraphics
import Foundation

/// Typo's performance for one dictation, as a pure function of events and time.
///
/// The companion window feeds it phase changes, the microphone level and a clock;
/// it answers with the pose to draw. Keeping it free of AppKit and timers makes
/// every transition reproducible in tests.
struct TypoPerformance: Equatable {
    enum Stage: Equatable {
        case hidden
        /// Rising out of the baseline.
        case entering
        case listening
        case thinking
        case exiting(Exit)
    }

    enum Exit: Equatable {
        /// Text landed: hop, press down like a key, spring back, sink.
        case success
        /// The user cancelled: a sad sink.
        case cancelled
        /// Output did not land or an error is shown: a startled sink.
        case failed
    }

    struct Timing: Equatable {
        var enter: TimeInterval = 0.36
        var loudHold: TimeInterval = 0.3
        var loudRelease: TimeInterval = 0.25
        var quietBubble: TimeInterval = 2.0
        var blinkPeriod: TimeInterval = 3.4
        var blinkLength: TimeInterval = 0.12
        var successHop: TimeInterval = 0.22
        var successLand: TimeInterval = 0.14
        var successRebound: TimeInterval = 0.16
        var successSink: TimeInterval = 0.22
        var cancelSink: TimeInterval = 0.3
        var failHold: TimeInterval = 0.3
        var failSink: TimeInterval = 0.22
        var reducedMotionFade: TimeInterval = 0.2

        static let standard = Timing()

        var successTotal: TimeInterval { successHop + successLand + successRebound + successSink }
    }

    // The meter maps -50...0 dBFS onto 0...1 (AudioCaptureEngine.calculateLevel).
    /// About -35 dB: speech has started, so the mouth opens.
    static let talkLevel: Float = 0.3
    /// About -10 dB, held for `loudHold`: shouting, so Typo bristles.
    static let loudLevel: Float = 0.8
    /// About -15 dB, held for `loudRelease`: calm again.
    static let calmLevel: Float = 0.7
    /// About -37 dB: silence for the "still listening" bubble.
    static let quietLevel: Float = 0.25

    var timing = Timing.standard
    var reduceMotion = false
    private(set) var stage: Stage = .hidden
    private(set) var stageStart: TimeInterval = 0
    private(set) var isLoud = false
    private(set) var level: Float = 0
    private var loudSince: TimeInterval?
    private var calmSince: TimeInterval?
    private var quietSince: TimeInterval?

    init(timing: Timing = .standard, reduceMotion: Bool = false) {
        self.timing = timing
        self.reduceMotion = reduceMotion
    }

    var isVisible: Bool { stage != .hidden }

    /// Durations are compared with a small tolerance so a deadline that falls
    /// exactly on a frame is not missed by floating-point rounding.
    private static func reached(_ elapsed: TimeInterval, _ duration: TimeInterval) -> Bool {
        elapsed >= duration - 1e-6
    }

    // MARK: - Events

    /// A recording started. A Typo still sinking from the previous dictation
    /// comes straight back up instead of finishing its exit.
    mutating func begin(at t: TimeInterval) {
        switch stage {
        case .hidden, .exiting:
            enter(.entering, at: t)
        case .entering, .listening, .thinking:
            break
        }
        resetVoice()
    }

    /// Recognition or post-processing is running after the user stopped talking.
    mutating func think(at t: TimeInterval) {
        switch stage {
        case .hidden, .exiting, .thinking:
            return
        case .entering, .listening:
            enter(.thinking, at: t)
            resetVoice()
        }
    }

    mutating func finish(_ exit: Exit, at t: TimeInterval) {
        switch stage {
        case .hidden, .exiting:
            return
        case .entering, .listening, .thinking:
            enter(.exiting(exit), at: t)
            resetVoice()
        }
    }

    /// Advances time-driven transitions and the voice detectors.
    mutating func update(level newLevel: Float, at t: TimeInterval) {
        level = max(0, min(1, newLevel))
        switch stage {
        case .entering:
            if Self.reached(t - stageStart, timing.enter) {
                enter(.listening, at: stageStart + timing.enter)
                quietSince = nil
            }
            trackVoice(at: t)
        case .listening:
            trackVoice(at: t)
        case .exiting(let exit):
            if Self.reached(t - stageStart, exitDuration(exit)) { enter(.hidden, at: t) }
        case .hidden, .thinking:
            break
        }
    }

    func exitDuration(_ exit: Exit) -> TimeInterval {
        if reduceMotion { return timing.reducedMotionFade }
        switch exit {
        case .success: return timing.successTotal
        case .cancelled: return timing.cancelSink
        case .failed: return timing.failHold + timing.failSink
        }
    }

    private mutating func enter(_ next: Stage, at t: TimeInterval) {
        stage = next
        stageStart = t
    }

    private mutating func resetVoice() {
        isLoud = false
        loudSince = nil
        calmSince = nil
        quietSince = nil
    }

    private mutating func trackVoice(at t: TimeInterval) {
        if isLoud {
            if level < Self.calmLevel {
                if calmSince == nil { calmSince = t }
                if let since = calmSince, Self.reached(t - since, timing.loudRelease) {
                    isLoud = false
                    calmSince = nil
                    loudSince = nil
                }
            } else {
                calmSince = nil
            }
        } else if level >= Self.loudLevel {
            if loudSince == nil { loudSince = t }
            if let since = loudSince, Self.reached(t - since, timing.loudHold) { isLoud = true }
        } else {
            loudSince = nil
        }

        if level < Self.quietLevel {
            if quietSince == nil { quietSince = t }
        } else {
            quietSince = nil
        }
    }

    // MARK: - Pose

    struct Pose: Equatable {
        var expression = TypoExpression()
        /// 0 stands on the baseline; 1 has sunk completely below it.
        var sink: CGFloat = 1
        /// Upward offset in design units.
        var hop: CGFloat = 0
        /// Vertical scale about the feet; width compensates to keep volume.
        var squash: CGFloat = 1
        /// Horizontal jitter in design units.
        var shake: CGFloat = 0
        var tiltDegrees: Double = 0
        var opacity: Double = 1
    }

    func pose(at t: TimeInterval) -> Pose {
        let age = max(0, t - stageStart)
        var pose = Pose()
        switch stage {
        case .hidden:
            pose.opacity = 0
        case .entering:
            let p = min(1, age / timing.enter)
            pose.expression = listeningFace(at: t)
            if reduceMotion {
                pose.sink = 0
                pose.opacity = p
            } else {
                pose.sink = 1 - Self.easeOutBack(p)
            }
        case .listening:
            pose.sink = 0
            pose.expression = listeningFace(at: t)
            if isLoud {
                pose.expression = Self.bristled
                pose.shake = reduceMotion ? 0 : CGFloat(sin(t * 70)) * 9
            } else if !reduceMotion {
                let voice = max(0, level - Self.talkLevel) / (1 - Self.talkLevel)
                pose.hop = CGFloat(abs(sin(t * .pi * 2.4))) * 14 * CGFloat(min(1, voice * 2))
            }
        case .thinking:
            pose.sink = 0
            var e = TypoExpression()
            e.look = CGSize(width: -18, height: -26)
            e.mouth = .flat
            e.armL = .init(up: true, degrees: 10)
            e.bubble = .question
            e.bubbleOpacity = min(1, age / 0.18)
            pose.expression = e
            pose.tiltDegrees = reduceMotion ? 0 : sin(t * 1.7) * 2.5
        case .exiting(let exit):
            pose = exitPose(exit, age: age)
        }
        return pose
    }

    private func listeningFace(at t: TimeInterval) -> TypoExpression {
        var e = TypoExpression()
        if level >= Self.talkLevel {
            e.mouth = .talk
            e.mouthOpen = CGFloat(min(1, 0.3 + (level - Self.talkLevel) * 1.6))
        }
        let blinkPhase = (t - stageStart).truncatingRemainder(dividingBy: timing.blinkPeriod)
        if blinkPhase > timing.blinkPeriod - timing.blinkLength {
            e.eyeL = .line
            e.eyeR = .line
        }
        if let since = quietSince, Self.reached(t - since, timing.quietBubble) {
            e.bubble = .dots
            e.bubbleOpacity = min(1, (t - since - timing.quietBubble) / 0.2)
            e.look = CGSize(width: 30, height: -18)
        }
        return e
    }

    static let bristled: TypoExpression = {
        var e = TypoExpression()
        e.eyeL = .ring
        e.eyeR = .ring
        e.mouth = .shout
        e.armL = .init(up: true, degrees: -18)
        e.armR = .init(up: true, degrees: 60)
        e.bubble = .exclaim
        e.bubbleOpacity = 1
        e.spikiness = 1
        e.shout = true
        return e
    }()

    private func exitPose(_ exit: Exit, age: TimeInterval) -> Pose {
        var pose = Pose()
        pose.sink = 0
        if reduceMotion {
            pose.expression = exitFace(exit)
            pose.opacity = max(0, 1 - age / timing.reducedMotionFade)
            return pose
        }
        let tm = timing
        switch exit {
        case .success:
            var happy = TypoExpression()
            happy.eyeL = .happy
            happy.eyeR = .happy
            happy.mouth = .grin
            happy.armL = .init(up: true, degrees: -18)
            happy.armR = .init(up: true, degrees: 60)
            if age < tm.successHop {
                let p = age / tm.successHop
                pose.expression = happy
                pose.hop = CGFloat(sin(p * .pi)) * 170
                pose.squash = 1 + 0.08 * CGFloat(sin(p * .pi))
            } else if age < tm.successHop + tm.successLand {
                let p = (age - tm.successHop) / tm.successLand
                var pressed = TypoExpression()
                pressed.eyeL = .chevron
                pressed.eyeR = .chevron
                pressed.mouth = .zigzag
                pressed.armL = .init(up: true, degrees: -18)
                pressed.armR = .init(up: true, degrees: 60)
                pressed.impact = true
                pose.expression = pressed
                pose.squash = 1 - 0.28 * CGFloat(sin(p * .pi / 2))
            } else if age < tm.successHop + tm.successLand + tm.successRebound {
                let p = (age - tm.successHop - tm.successLand) / tm.successRebound
                happy.mouth = .smile
                pose.expression = happy
                pose.squash = 0.72 + 0.4 * CGFloat(sin(p * .pi / 2)) - 0.12 * CGFloat(p)
            } else {
                let p = min(1, (age - tm.successHop - tm.successLand - tm.successRebound) / tm.successSink)
                happy.mouth = .smile
                pose.expression = happy
                pose.sink = CGFloat(p * p)
            }
        case .cancelled:
            pose.expression = exitFace(exit)
            let p = min(1, age / tm.cancelSink)
            pose.sink = CGFloat(p * p)
        case .failed:
            pose.expression = exitFace(exit)
            if age > tm.failHold {
                let p = min(1, (age - tm.failHold) / tm.failSink)
                pose.sink = CGFloat(p * p)
            }
        }
        return pose
    }

    private func exitFace(_ exit: Exit) -> TypoExpression {
        var e = TypoExpression()
        switch exit {
        case .success:
            e.eyeL = .happy
            e.eyeR = .happy
        case .cancelled:
            e.eyeL = .sad
            e.eyeR = .sad
            e.mouth = .frown
            e.armL = .init(degrees: 10)
            e.armR = .init(degrees: -10)
        case .failed:
            e.eyeL = .dot
            e.eyeR = .dot
            e.mouth = .tinyO
            e.sweat = true
            e.bubble = .interrobang
            e.bubbleOpacity = 1
        }
        return e
    }

    /// Overshoots slightly past 1 before settling, like a key springing up.
    static func easeOutBack(_ p: Double) -> CGFloat {
        let c1 = 1.70158, c3 = c1 + 1
        let x = p - 1
        return CGFloat(1 + c3 * x * x * x + c1 * x * x)
    }
}
