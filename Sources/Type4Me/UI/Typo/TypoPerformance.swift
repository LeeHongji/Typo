import CoreGraphics
import Foundation

/// Typo's performance for one dictation, as a pure function of events and time.
///
/// Typo stands on an edge: the top of the recording bar's capsule, or the text
/// line beside the caret. `Pose.sink` says how much of it is hidden below that
/// edge: 0 stands fully out, 1 is fully hidden. The bar feeds events and a clock; the performance answers with
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
        /// Text landed somewhere else on screen: Typo flips over to `offset`
        /// (design units from where it stands), presses down like a key, springs
        /// back and sinks into that line.
        case leap(CGSize)
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
        var leapCrouch: TimeInterval = 0.11
        /// Air time of the shortest leap; longer leaps stay up longer, to `leapAirMax`.
        var leapAir: TimeInterval = 0.3
        var leapAirMax: TimeInterval = 0.6
        var leapPress: TimeInterval = 0.12
        var leapRebound: TimeInterval = 0.16
        /// Standing on the new text, looking at it, before going down into the line.
        var leapSettle: TimeInterval = 0.32
        var leapSink: TimeInterval = 0.2
        var cancelSink: TimeInterval = 0.28
        var failSink: TimeInterval = 0.24
        var reducedMotionFade: TimeInterval = 0.2

        static let standard = Timing()

        var successTotal: TimeInterval { successHop + successPress + successSink }
        /// A leap's length for a given air time.
        func leapTotal(air: TimeInterval) -> TimeInterval {
            leapCrouch + air + leapPress + leapRebound + leapSettle + leapSink
        }
    }

    /// How deep Typo sits below the edge it stands on in each calm state.
    struct Peek: Equatable {
        var listening: CGFloat
        var thinking: CGFloat
        var reacting: CGFloat

        /// Behind the recording bar's capsule, only the head shows.
        static let bar = Peek(listening: 0.3, thinking: 0.42, reacting: 0.22)
        /// Beside the caret nothing covers Typo, so it stands fully out of the line.
        static let caret = Peek(listening: 0, thinking: 0, reacting: 0)
    }

    // The meter maps -50...0 dBFS onto 0...1 (AudioCaptureEngine.calculateLevel).
    /// About -35 dB: speech has started, so the mouth opens.
    static let talkLevel: Float = 0.3
    /// About -37 dB: silence for the "still listening" bubble.
    static let quietLevel: Float = 0.25
    // Shouting, held for `loudHold`, is measured against this speaker's usual
    // loudness (`TypoRhythm.shoutLevel`); calm again below `calmLevel`.

    var timing = Timing.standard
    var peek = Peek.bar
    var reduceMotion = false
    /// Which way the new text will appear from where Typo stands: -1 to its
    /// left, 1 to its right, 0 unknown. Typo looks there while it thinks.
    var gaze: CGFloat = 0
    private(set) var stage: Stage = .hidden
    private(set) var stageStart: TimeInterval = 0
    private(set) var isLoud = false
    private(set) var level: Float = 0
    private var loudChangedAt: TimeInterval = -.infinity
    private var loudSince: TimeInterval?
    private var calmSince: TimeInterval?
    private var quietSince: TimeInterval?
    /// Where the exit started from, so the sink never jumps.
    private var exitFromSink: CGFloat
    /// Where a retargeted leap's destination was when it was retargeted.
    private var leapFrom: CGSize = .zero
    /// The shape of the leap under way, fixed at take-off so a retarget never
    /// changes its timing mid-air.
    private(set) var leap = Leap(offset: .zero, timing: .standard)
    private var retargetedAt: TimeInterval = -.infinity
    /// Typo's body while it listens: beats to the voice, fidgets, reactions.
    /// Stepped by `update`, so a pose reflects the last update before it.
    private(set) var motion = TypoMotion()
    /// Quote and screenshot cards Typo holds, shown as a count beside it and
    /// carried with it into the text.
    private(set) var carried = 0

    init(timing: Timing = .standard, peek: Peek = .bar, reduceMotion: Bool = false) {
        self.timing = timing
        self.peek = peek
        self.reduceMotion = reduceMotion
        exitFromSink = peek.listening
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
            motion = TypoMotion(seed: UInt64(truncatingIfNeeded: Int64((t * 1000).rounded())))
            carried = 0
        case .entering, .listening, .thinking:
            break
        }
    }

    /// How many cards Typo holds now. One more than before is a catch.
    mutating func carrying(_ count: Int, at t: TimeInterval) {
        defer { carried = count }
        guard count > carried else { return }
        switch stage {
        case .entering, .listening:
            motion.caught(at: t, animated: !reduceMotion)
        case .hidden, .thinking, .reacting, .exiting:
            break
        }
    }

    /// The words recognized so far in this dictation.
    mutating func heard(_ text: String, at t: TimeInterval) {
        switch stage {
        case .entering, .listening:
            motion.heard(text, at: t, animated: !reduceMotion)
        case .hidden, .thinking, .reacting, .exiting:
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

    /// The shape of one leap, decided by how far it goes: a short hop along
    /// the line stays low and quick and leans into it; a long leap stays up
    /// longer, climbs higher and somersaults.
    struct Leap: Equatable {
        /// Beyond about two body heights a leap turns into a somersault.
        static let somersaultDistance: CGFloat = 1500

        var air: TimeInterval
        /// Peak height above the higher of the two lines, in design units.
        var arc: CGFloat
        var somersault: Bool
        /// 1 to the right, -1 to the left: the way Typo leans and turns.
        var direction: CGFloat

        init(offset: CGSize, timing: Timing) {
            let distance = hypot(offset.width, offset.height)
            air = min(timing.leapAirMax, timing.leapAir + sqrt(Double(distance)) / 400)
            arc = TypoPerformance.leapArc(for: offset)
            somersault = distance > Self.somersaultDistance
            direction = offset.width < 0 ? -1 : 1
        }
    }

    /// How long a leap's destination takes to slide to a retargeted one.
    static let retargetBlend: TimeInterval = 0.12

    /// The landing spot of a leap already under way became known (the app
    /// reported its new caret late). The destination slides to the new one, so
    /// Typo never jumps, even when the news arrives mid-air.
    mutating func retarget(_ offset: CGSize, at t: TimeInterval) {
        guard case .exiting(.leap(let current)) = stage else { return }
        leapFrom = leapOffset(toward: current, at: t)
        retargetedAt = t
        leap.arc = max(leap.arc, Self.leapArc(for: offset))
        stage = .exiting(.leap(offset))
    }

    private func leapOffset(toward target: CGSize, at t: TimeInterval) -> CGSize {
        let p = min(1, max(0, (t - retargetedAt) / Self.retargetBlend))
        let k = CGFloat(p * p * (3 - 2 * p))
        return CGSize(
            width: leapFrom.width + (target.width - leapFrom.width) * k,
            height: leapFrom.height + (target.height - leapFrom.height) * k
        )
    }

    mutating func finish(_ exit: Exit, at t: TimeInterval) {
        switch stage {
        case .hidden, .exiting:
            return
        case .entering, .listening, .thinking, .reacting:
            exitFromSink = max(0, min(1, pose(at: t).sink))
            if case .leap(let offset) = exit {
                leapFrom = offset
                retargetedAt = -.infinity
                leap = Leap(offset: offset, timing: timing)
            }
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
        case .leap: return timing.leapTotal(air: leap.air)
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
        motion.step(level: level, at: t, quietFor: quietSince.map { t - $0 }, animated: !reduceMotion)
        if isLoud {
            if level < motion.rhythm.calmLevel {
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
        } else if level >= motion.rhythm.shoutLevel {
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
        /// Displacement from where Typo stands, in design units, while it leaps.
        var travel: CGSize = .zero
        /// Rotation about the middle of the body, for the somersault.
        var spinDegrees: Double = 0
        var tiltDegrees: Double = 0
        var opacity: Double = 1
        /// Cards held, drawn as a count at Typo's shoulder.
        var badge = 0
        /// The count fades as the cards go into the text on landing.
        var badgeOpacity: Double = 1
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
                pose.sink = peek.listening
                pose.opacity = p
            } else {
                pose.sink = 1 - (1 - peek.listening) * Self.easeOutBack(p)
                pose.squash = 1 + breath(at: t) * CGFloat(p)
            }
        case .listening:
            pose.expression = listeningFace(at: t)
            let shift = reduceMotion ? 1 : CGFloat(min(1, (t - loudChangedAt) / timing.loudRise))
            pose.sink = isLoud ? peek.listening * (1 - shift) : peek.listening * shift
            if isLoud {
                pose.expression = Self.bristled
                pose.shake = reduceMotion ? 0 : CGFloat(sin(t * 70)) * 9
            } else if !reduceMotion {
                let m = motion
                pose.hop = max(0, m.hop.value)
                // Below the line the hop spring is the landing: a squash, not a sink.
                let landing = min(0, m.hop.value) / 300
                let dozing = m.isDozing(quietFor: quietSince.map { t - $0 })
                pose.squash = 1 + m.squash.value + landing + breath(at: t) * (dozing ? 2 : 1)
                pose.tiltDegrees = Double(m.tilt.value)
            }
        case .thinking:
            pose.sink = peek.thinking
            var e = TypoExpression()
            // Up and away, pondering; or down toward where the text will land.
            e.look = gaze == 0 ? CGSize(width: -18, height: -26) : CGSize(width: 34 * gaze, height: 14)
            e.mouth = .flat
            e.bubble = .question
            e.bubbleOpacity = min(1, age / 0.18)
            pose.expression = e
            if !reduceMotion {
                pose.tiltDegrees = sin(t * 1.7) * 2.5
                pose.squash = 1 + breath(at: t)
            }
        case .reacting(let reaction):
            pose.sink = peek.reacting
            pose.expression = Self.face(for: reaction)
        case .exiting(let exit):
            pose = exitPose(exit, age: age)
            pose.badgeOpacity = badgeFade(exit, age: age)
        }
        pose.badge = carried
        return pose
    }

    /// The cards ride along through a leap and go into the text with the
    /// landing press; any other exit lets them fade at once.
    private func badgeFade(_ exit: Exit, age: TimeInterval) -> Double {
        if reduceMotion { return max(0, 1 - age / timing.reducedMotionFade) }
        switch exit {
        case .leap:
            let landAt = timing.leapCrouch + leap.air
            return max(0, min(1, 1 - (age - landAt) / timing.leapPress))
        case .success:
            return max(0, 1 - (age - timing.successHop) / timing.successPress)
        case .cancelled, .failed:
            return max(0, 1 - age / 0.12)
        }
    }

    /// A slow breath while Typo waits: about 2% taller and shorter every 3 s.
    /// It runs on the clock rather than the stage, so it carries on unbroken
    /// from listening into thinking.
    private func breath(at t: TimeInterval) -> CGFloat {
        CGFloat(sin(t * 2 * .pi / 3)) * 0.018
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
        let m = motion
        let quiet = quietSince.map { t - $0 }
        if m.isDozing(quietFor: quiet), let quiet {
            // Long quiet: eyes shut, a slow Zz.
            e.eyeL = .line
            e.eyeR = .line
            e.mouth = .flat
            e.bubble = .zz
            e.bubbleOpacity = min(1, (quiet - TypoMotion.dozeAfter) / 0.4)
            return e
        }
        if let quiet, Self.reached(quiet, timing.quietBubble) {
            e.bubble = .dots
            e.bubbleOpacity = min(1, (quiet - timing.quietBubble) / 0.2)
            e.look = CGSize(width: 30, height: -18)
        }
        if let fidget = m.fidget {
            let p = min(1, max(0, (t - m.fidgetStart) / TypoMotion.fidgetLength))
            // Few distinct steps, so each face is drawn once and then reused.
            func steps(_ x: Double) -> CGFloat { CGFloat((x * 2).rounded() / 2) }
            switch fidget {
            case .lookAround:
                e.look = CGSize(width: steps(sin(p * 2 * .pi)) * 34, height: -8)
            case .doubleBlink:
                if (0.1..<0.22).contains(p) || (0.34..<0.46).contains(p) {
                    e.eyeL = .line
                    e.eyeR = .line
                }
            case .glance:
                e.look = CGSize(width: 30 * (gaze == 0 ? 1 : gaze), height: 16)
            case .stretch:
                let up = Double(steps(sin(p * .pi)))
                e.armL = .init(up: up > 0, degrees: -18 * up)
                e.armR = .init(up: up > 0, degrees: 60 * up)
                if (0.3..<0.7).contains(p) { e.eyeL = .happy; e.eyeR = .happy }
            }
        }
        if let cue = m.cue {
            switch cue {
            case .nod:
                e.look = CGSize(width: 26 * (gaze == 0 ? 1 : gaze), height: 14)
            case .question:
                e.bubble = .question
                e.bubbleOpacity = min(1, (t - m.cueStart) / 0.12)
                e.look = CGSize(width: -14, height: -22)
            case .exclaim:
                e.armL = .init(up: true, degrees: -18)
                e.armR = .init(up: true, degrees: 60)
                e.eyeL = .open
                e.eyeR = .open
            case .wake:
                e.eyeL = .ring
                e.eyeR = .ring
                e.bubble = .exclaim
                e.bubbleOpacity = 1
            case .caught:
                e.armL = .init(up: true, degrees: -18)
                e.armR = .init(up: true, degrees: 60)
                e.eyeL = .happy
                e.eyeR = .happy
                e.mouth = .grin
            }
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
        case .leap(let offset):
            pose = leapPose(to: leapOffset(toward: offset, at: stageStart + age), age: age, from: exitFromSink)
        case .cancelled:
            pose.expression = exitFace(exit)
            pose.sink = sinkFrom(exitFromSink, progress: min(1, age / tm.cancelSink))
        case .failed:
            pose.expression = exitFace(exit)
            pose.sink = sinkFrom(exitFromSink, progress: min(1, age / tm.failSink))
        }
        return pose
    }

    /// The leap onto new text, in the spirit of the reference video: Typo
    /// crouches and leans back looking at where it is going, springs up
    /// stretched, flies a parabola (a somersault when far, a lean when near)
    /// while its shadow runs along the ground below, lands with a key-like
    /// press, rebounds, stands a moment looking at the text, then goes down
    /// into the line.
    private func leapPose(to offset: CGSize, age: TimeInterval, from startSink: CGFloat) -> Pose {
        let tm = timing
        let plan = leap
        var pose = Pose()
        var happy = TypoExpression()
        happy.eyeL = .happy
        happy.eyeR = .happy
        happy.mouth = .grin
        happy.armL = .init(up: true, degrees: -18)
        happy.armR = .init(up: true, degrees: 60)

        let airStart = tm.leapCrouch
        let landAt = airStart + plan.air
        let reboundAt = landAt + tm.leapPress
        let settleAt = reboundAt + tm.leapRebound
        let sinkAt = settleAt + tm.leapSettle
        let crouched: CGFloat = 0.8
        happy.look = CGSize(width: 26 * plan.direction, height: 0)
        if age < airStart {
            // Anticipation: down and back, eyes on the landing.
            let p = age / tm.leapCrouch
            let k = CGFloat(sin(p * .pi / 2))
            pose.expression = happy
            pose.sink = startSink * CGFloat(1 - p)
            pose.squash = 1 - (1 - crouched) * k
            pose.tiltDegrees = Double(-7 * plan.direction * k)
        } else if age < landAt {
            let p = (age - airStart) / plan.air
            let cp = CGFloat(p)
            pose.expression = happy
            pose.sink = 0
            // Even speed across with a soft arrival; the ground moves with it.
            let across = 0.85 * cp + 0.15 * cp * cp * (3 - 2 * cp)
            pose.travel = CGSize(width: offset.width * across, height: offset.height * across)
            pose.hop = 4 * plan.arc * cp * (1 - cp)
            if plan.somersault {
                let turn = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                pose.spinDegrees = 360 * turn * Double(plan.direction)
            } else {
                pose.tiltDegrees = Double(12 * plan.direction) * sin(p * .pi)
            }
            // Stretched leaving and arriving, round at the top; out of the crouch
            // over the first few frames rather than in one snap.
            let stretch = 1 + 0.14 * abs(CGFloat(cos(p * .pi)))
            let release = min(1, cp / 0.08)
            pose.squash = crouched + (stretch - crouched) * release
        } else if age < reboundAt {
            let p = (age - landAt) / tm.leapPress
            var pressed = TypoExpression()
            pressed.eyeL = .chevron
            pressed.eyeR = .chevron
            pressed.mouth = .zigzag
            pressed.armL = happy.armL
            pressed.armR = happy.armR
            pressed.impact = true
            pose.expression = pressed
            pose.sink = 0
            pose.travel = offset
            pose.squash = 1 - 0.3 * CGFloat(sin(p * .pi / 2))
        } else if age < settleAt {
            let p = (age - reboundAt) / tm.leapRebound
            happy.mouth = .smile
            happy.look = .zero
            pose.expression = happy
            pose.sink = 0
            pose.travel = offset
            pose.squash = 0.7 + 0.42 * CGFloat(sin(p * .pi / 2)) - 0.12 * CGFloat(p)
        } else if age < sinkAt {
            // A moment on the new text, looking at it.
            let p = (age - settleAt) / tm.leapSettle
            var pleased = TypoExpression()
            pleased.mouth = .smile
            pleased.look = CGSize(width: 30 * gaze, height: 12)
            if p > 0.55 && p < 0.75 {
                pleased.eyeL = .line
                pleased.eyeR = .line
            }
            pose.expression = pleased
            pose.sink = 0
            pose.travel = offset
            pose.squash = 1 + 0.02 * CGFloat(sin(p * .pi))
        } else {
            let p = min(1, (age - sinkAt) / tm.leapSink)
            var pleased = TypoExpression()
            pleased.mouth = .smile
            pleased.look = CGSize(width: 30 * gaze, height: 12)
            pose.expression = pleased
            pose.travel = offset
            pose.sink = CGFloat(p * p)
        }
        return pose
    }

    private func exitFace(_ exit: Exit) -> TypoExpression {
        switch exit {
        case .success, .leap:
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

    /// Height of a leap's arc in design units: low for a hop along the line,
    /// higher for a longer leap, and extra to climb to a line above.
    static func leapArc(for offset: CGSize) -> CGFloat {
        let distance = hypot(offset.width, offset.height)
        return min(950, 260 + distance * 0.05) + max(0, -offset.height) * 0.5
    }

    /// Overshoots slightly past 1 before settling, like a key springing up.
    static func easeOutBack(_ p: Double) -> CGFloat {
        let c1 = 1.70158, c3 = c1 + 1
        let x = p - 1
        return CGFloat(1 + c3 * x * x * x + c1 * x * x)
    }
}
