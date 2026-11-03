import CoreGraphics
import Foundation

/// Typo's performance for one dictation, as a pure function of events and time.
///
/// Typo peeks over the top edge of the recording bar's capsule. `Pose.sink`
/// says how much of it is hidden behind that edge: 0 stands fully out, 1 is
/// fully hidden. The bar feeds events and a clock; the performance answers with
/// the pose to draw, so every transition is reproducible in tests.
struct TypoPerformance: Equatable {
    enum Stage: Equatable {
        case hidden
        /// Rising from behind the capsule.
        case entering
        case listening
        case thinking
        /// Holding a face while the bar shows a completion or error message.
        case reacting(Reaction)
        case exiting(Exit)
    }

    enum Reaction: Equatable {
        case done
        case failed
    }

    enum Exit: Equatable {
        /// Text landed: a small hop, a key-like press, then down behind the bar.
        case success
        /// The user cancelled: a sad sink.
        case cancelled
        /// The bar is leaving after an error: a startled sink.
        case failed
    }

    struct Timing: Equatable {
        var enter: TimeInterval = 0.36
        var loudHold: TimeInterval = 0.3
        var loudRelease: TimeInterval = 0.25
        /// How long Typo takes to stand fully out when bristling, and to settle back.
        var loudRise: TimeInterval = 0.15
        var quietBubble: TimeInterval = 2.0
        var blinkPeriod: TimeInterval = 3.4
        var blinkLength: TimeInterval = 0.12
        // The success exit fits inside the bar's 0.3 s exit collapse.
        var successHop: TimeInterval = 0.08
        var successPress: TimeInterval = 0.1
        var successSink: TimeInterval = 0.14
        var cancelSink: TimeInterval = 0.28
        var failSink: TimeInterval = 0.24
        var reducedMotionFade: TimeInterval = 0.2

        static let standard = Timing()

        var successTotal: TimeInterval { successHop + successPress + successSink }
    }

    /// How deep Typo sits behind the capsule edge in each calm state.
    enum Peek {
        static let listening: CGFloat = 0.3
        static let thinking: CGFloat = 0.42
        static let reacting: CGFloat = 0.22
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
    private var loudChangedAt: TimeInterval = -.infinity
    private var loudSince: TimeInterval?
    private var calmSince: TimeInterval?
    private var quietSince: TimeInterval?
    /// Where the exit started from, so the sink never jumps.
    private var exitFromSink: CGFloat = Peek.listening

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
        case .hidden, .exiting, .reacting:
            enter(.entering, at: t)
            resetVoice()
        case .entering, .listening, .thinking:
            break
        }
    }

    /// Recognition or post-processing is running after the user stopped talking.
    mutating func think(at t: TimeInterval) {
        switch stage {
        case .entering, .listening, .reacting:
            enter(.thinking, at: t)
            resetVoice()
        case .hidden, .exiting, .thinking:
            break
        }
    }

    /// The bar shows a completion or error message; Typo keeps a matching face.
    mutating func react(_ reaction: Reaction, at t: TimeInterval) {
        switch stage {
        case .hidden:
            enter(.reacting(reaction), at: t)
        case .entering, .listening, .thinking:
            enter(.reacting(reaction), at: t)
            resetVoice()
        case .reacting(let current) where current != reaction:
            enter(.reacting(reaction), at: t)
        case .reacting, .exiting:
            break
        }
    }

    mutating func finish(_ exit: Exit, at t: TimeInterval) {
        switch stage {
        case .hidden, .exiting:
            return
        case .entering, .listening, .thinking, .reacting:
            exitFromSink = max(0, min(1, pose(at: t).sink))
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
        case .hidden, .thinking, .reacting:
            break
        }
    }

    func exitDuration(_ exit: Exit) -> TimeInterval {
        if reduceMotion { return timing.reducedMotionFade }
        switch exit {
        case .success: return timing.successTotal
        case .cancelled: return timing.cancelSink
        case .failed: return timing.failSink
        }
    }

    private mutating func enter(_ next: Stage, at t: TimeInterval) {
        stage = next
        stageStart = t
    }

    private mutating func resetVoice() {
        isLoud = false
        loudChangedAt = -.infinity
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
                    loudChangedAt = t
                    calmSince = nil
                    loudSince = nil
                }
            } else {
                calmSince = nil
            }
        } else if level >= Self.loudLevel {
            if loudSince == nil { loudSince = t }
            if let since = loudSince, Self.reached(t - since, timing.loudHold) {
                isLoud = true
                loudChangedAt = t
            }
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
        /// 0 stands fully out over the capsule edge; 1 is hidden behind it.
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
                pose.sink = Peek.listening
                pose.opacity = p
            } else {
                pose.sink = 1 - (1 - Peek.listening) * Self.easeOutBack(p)
            }
        case .listening:
            pose.expression = listeningFace(at: t)
            let shift = reduceMotion ? 1 : CGFloat(min(1, (t - loudChangedAt) / timing.loudRise))
            pose.sink = isLoud ? Peek.listening * (1 - shift) : Peek.listening * shift
            if isLoud {
                pose.expression = Self.bristled
                pose.shake = reduceMotion ? 0 : CGFloat(sin(t * 70)) * 9
            } else if !reduceMotion {
                let voice = max(0, level - Self.talkLevel) / (1 - Self.talkLevel)
                pose.hop = CGFloat(abs(sin(t * .pi * 2.4))) * 14 * CGFloat(min(1, voice * 2))
            }
        case .thinking:
            pose.sink = Peek.thinking
            var e = TypoExpression()
            e.look = CGSize(width: -18, height: -26)
            e.mouth = .flat
            e.bubble = .question
            e.bubbleOpacity = min(1, age / 0.18)
            pose.expression = e
            pose.tiltDegrees = reduceMotion ? 0 : sin(t * 1.7) * 2.5
        case .reacting(let reaction):
            pose.sink = Peek.reacting
            pose.expression = Self.face(for: reaction)
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

    static func face(for reaction: Reaction) -> TypoExpression {
        var e = TypoExpression()
        switch reaction {
        case .done:
            e.eyeL = .happy
            e.eyeR = .happy
            e.mouth = .smile
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

    private func exitPose(_ exit: Exit, age: TimeInterval) -> Pose {
        var pose = Pose()
        pose.sink = exitFromSink
        let tm = timing
        if reduceMotion {
            pose.expression = exitFace(exit)
            pose.opacity = max(0, 1 - age / tm.reducedMotionFade)
            return pose
        }
        func sinkFrom(_ start: CGFloat, progress p: Double) -> CGFloat {
            start + (1 - start) * CGFloat(p * p)
        }
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
                pose.hop = CGFloat(sin(p * .pi)) * 70
            } else if age < tm.successHop + tm.successPress {
                let p = (age - tm.successHop) / tm.successPress
                var pressed = TypoExpression()
                pressed.eyeL = .chevron
                pressed.eyeR = .chevron
                pressed.mouth = .zigzag
                pressed.armL = .init(up: true, degrees: -18)
                pressed.armR = .init(up: true, degrees: 60)
                pressed.impact = true
                pose.expression = pressed
                pose.squash = 1 - 0.3 * CGFloat(sin(p * .pi / 2))
            } else {
                let p = min(1, (age - tm.successHop - tm.successPress) / tm.successSink)
                happy.mouth = .smile
                pose.expression = happy
                pose.squash = 0.7 + 0.3 * CGFloat(p)
                pose.sink = sinkFrom(exitFromSink, progress: p)
            }
        case .cancelled:
            pose.expression = exitFace(exit)
            pose.sink = sinkFrom(exitFromSink, progress: min(1, age / tm.cancelSink))
        case .failed:
            pose.expression = exitFace(exit)
            pose.sink = sinkFrom(exitFromSink, progress: min(1, age / tm.failSink))
        }
        return pose
    }

    private func exitFace(_ exit: Exit) -> TypoExpression {
        switch exit {
        case .success:
            return Self.face(for: .done)
        case .failed:
            return Self.face(for: .failed)
        case .cancelled:
            var e = TypoExpression()
            e.eyeL = .sad
            e.eyeR = .sad
            e.mouth = .frown
            e.armL = .init(degrees: 10)
            e.armR = .init(degrees: -10)
            return e
        }
    }

    /// Overshoots slightly past 1 before settling, like a key springing up.
    static func easeOutBack(_ p: Double) -> CGFloat {
        let c1 = 1.70158, c3 = c1 + 1
        let x = p - 1
        return CGFloat(1 + c3 * x * x * x + c1 * x * x)
    }
}
