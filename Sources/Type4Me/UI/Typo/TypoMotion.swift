import CoreGraphics
import Foundation

/// A damped spring, stepped with the frame clock. Typo's beats are kicks to
/// its velocity, so they add up and settle the way a body does: a hop lands,
/// dips below rest (a squash on landing) and comes back.
struct TypoSpring: Equatable {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var rest: CGFloat = 0
    /// Natural frequency in hertz.
    var frequency: CGFloat
    /// 1 settles without overshoot; lower bounces.
    var damping: CGFloat

    mutating func step(_ dt: TimeInterval) {
        let w = 2 * .pi * frequency
        var remaining = max(0, dt)
        while remaining > 1e-9 {
            let h = CGFloat(min(remaining, 1.0 / 240))
            let a = -w * w * (value - rest) - 2 * damping * w * velocity
            velocity += a * h
            value += velocity * h
            remaining -= Double(h)
        }
    }

    mutating func kick(_ dv: CGFloat) { velocity += dv }

    mutating func settle() {
        value = rest
        velocity = 0
    }
}

/// Listens to the microphone level the way a dancer listens to music: finds
/// where syllables start, learns how loud this speaker usually is, and after a
/// moment of speech picks the way Typo moves to this voice.
struct TypoRhythm: Equatable {
    /// How Typo moves to the voice.
    enum Gait: Equatable, CaseIterable {
        /// Quick, lively speech: a hop on every syllable.
        case bounce
        /// Steady speech: a nod and a squash on every syllable.
        case bob
        /// Slow or soft speech: a sway from side to side.
        case sway
    }

    /// Seconds of speech heard before a gait is chosen.
    static let decideAfter: TimeInterval = 1.2
    /// A pause this long ends a phrase; the next phrase may change the gait.
    static let newPhraseAfter: TimeInterval = 1.6
    /// Syllables closer than this are one beat.
    static let minimumBeatGap: TimeInterval = 0.15
    /// How far the level must rise from its last dip to start a syllable.
    static let rise: Float = 0.07
    /// Speech is this far above the noise floor.
    static let aboveFloor: Float = 0.1
    /// Syllables a second, from the typical gap between beats. Measured on
    /// dictation recordings, ordinary speech runs about 2.8-3.6.
    static let bounceRate: Double = 3.3
    static let bobRate: Double = 2.2
    /// A longer gap between beats is a pause, not a syllable.
    static let longestGap: TimeInterval = 0.8

    private(set) var gait: Gait?
    /// The level at a typical syllable's peak for this speaker.
    private(set) var usualPeak: Float = 0.5
    private(set) var envelope: Float = 0
    private(set) var floor: Float = 0.2
    private(set) var lastBeat: TimeInterval = -.infinity
    private(set) var lastSpeech: TimeInterval = -.infinity
    private var trough: Float = 1
    private var phraseBeats = 0
    private var phraseSpeech: TimeInterval = 0
    private var phrasePeaks: Float = 0
    private var phraseGaps: [TimeInterval] = []
    private var armed = true
    private var peakSinceBeat: Float = 0

    /// A shout is clearly louder than this speaker's usual syllable.
    var shoutLevel: Float { min(0.92, max(0.72, usualPeak + 0.22)) }
    var calmLevel: Float { shoutLevel - 0.1 }
    var gate: Float { max(0.12, floor + Self.aboveFloor) }
    var isSpeaking: Bool { envelope >= gate }

    /// Feeds one frame; answers the strength (0...1) of a syllable that just started.
    mutating func hear(_ level: Float, dt: TimeInterval, at t: TimeInterval) -> CGFloat? {
        guard dt > 0 else { return nil }
        let tau: Double = level > envelope ? 0.015 : 0.08
        envelope += (level - envelope) * Float(1 - exp(-dt / tau))
        // The floor falls at once to a quieter level. It climbs back, over
        // seconds, only on what is not speech (a fan, a noisy room), so a
        // long run of words never raises it to their own level.
        if envelope < floor {
            floor = envelope
        } else if envelope < floor + Self.aboveFloor {
            floor += (envelope - floor) * Float(1 - exp(-dt / 4.0))
        }
        // After a beat the syllable is still rising; only once it has peaked
        // and fallen back a little can the next one start.
        if armed {
            trough = min(trough, envelope)
        } else {
            peakSinceBeat = max(peakSinceBeat, envelope)
            trough = envelope
            if envelope <= peakSinceBeat - Self.rise / 2 {
                armed = true
                // A syllable louder than usual nudges the baseline up a little at a time,
                // so a loud talker is learned but one shout is not.
                usualPeak += (min(peakSinceBeat, usualPeak + 0.15) - usualPeak) * 0.15
                phrasePeaks += peakSinceBeat
            }
        }

        guard isSpeaking else { return nil }
        if t - lastSpeech > Self.newPhraseAfter {
            phraseBeats = 0
            phraseSpeech = 0
            phrasePeaks = 0
            phraseGaps = []
        }
        lastSpeech = t
        phraseSpeech += dt

        guard armed, envelope - trough >= Self.rise, t - lastBeat >= Self.minimumBeatGap else { return nil }
        let strength = CGFloat(min(1, max(0.5, (envelope - trough) / 0.18)))
        let previousBeat = lastBeat
        lastBeat = t
        armed = false
        peakSinceBeat = envelope
        if phraseBeats > 0 { phraseGaps.append(t - previousBeat) }
        phraseBeats += 1
        decideGait()
        return strength
    }

    private mutating func decideGait() {
        // The typical gap between syllables, not the average, and without
        // pauses: a breath inside a phrase should not make quick words look slow.
        let gaps = phraseGaps.filter { $0 <= Self.longestGap }.sorted()
        guard phraseSpeech >= Self.decideAfter, gaps.count >= 5 else { return }
        let rate = 1 / gaps[gaps.count / 2]
        let peak = phrasePeaks / Float(max(1, phraseBeats - 1))
        let soft = peak < gate + 0.15
        if soft || rate < Self.bobRate {
            gait = .sway
        } else if rate >= Self.bounceRate {
            gait = .bounce
        } else {
            gait = .bob
        }
    }
}

/// Typo's body between beats: springs for its hop, squash and tilt, little
/// things it does while it waits, and its reactions to the words as they
/// appear. Stepped once a frame; the pose reads the latest state.
struct TypoMotion: Equatable {
    enum Fidget: Equatable, CaseIterable {
        case lookAround
        case doubleBlink
        case glance
        case stretch
    }

    enum Cue: Equatable {
        /// New words appeared: a nod toward them.
        case nod
        /// The words asked something.
        case question
        /// The words exclaimed.
        case exclaim
        /// Talking again after dozing off.
        case wake
    }

    /// Without a beat for this long Typo rests, and fidgets now and then.
    static let restAfter: TimeInterval = 0.9
    static let fidgetLength: TimeInterval = 0.9
    /// Quiet this long and Typo dozes off.
    static let dozeAfter: TimeInterval = 8
    static let cueLength: [Cue: TimeInterval] = [.nod: 0.4, .question: 1.0, .exclaim: 0.7, .wake: 0.45]
    static let nodGap: TimeInterval = 0.5

    var rhythm = TypoRhythm()
    var hop = TypoSpring(frequency: 3, damping: 0.45)
    /// Offset from Typo's natural height: positive stretches, negative squashes.
    var squash = TypoSpring(frequency: 4.5, damping: 0.35)
    var tilt = TypoSpring(frequency: 1.6, damping: 0.6)
    private(set) var lastStep: TimeInterval?
    private(set) var restingSince: TimeInterval?
    private(set) var fidget: Fidget?
    private(set) var fidgetStart: TimeInterval = -.infinity
    private var nextFidget: TimeInterval = .infinity
    private(set) var cue: Cue?
    private(set) var cueStart: TimeInterval = -.infinity
    private var swaySide: CGFloat = 1
    private var heardCount = 0
    private var random: UInt64

    init(seed: UInt64 = 0x7970_6f) {
        random = seed
    }

    /// Advances one frame. `quietFor` is how long the voice has been silent,
    /// as the performance measures it; `animated` is false under Reduce Motion.
    mutating func step(level: Float, at t: TimeInterval, quietFor: TimeInterval?, animated: Bool) {
        let dt = lastStep.map { min(0.05, max(0, t - $0)) } ?? 0
        lastStep = t
        let wasDozing = isDozing(quietFor: quietFor)
        if let strength = rhythm.hear(level, dt: dt, at: t) {
            if wasDozing {
                show(.wake, at: t)
                if animated { hop.kick(5200) }
            } else if animated {
                beat(strength)
            }
            restingSince = nil
            fidget = nil
            nextFidget = .infinity
        }
        if t - rhythm.lastBeat >= Self.restAfter, !rhythm.isSpeaking {
            if restingSince == nil {
                restingSince = t
                // The first fidget waits a few seconds so a pause between words stays calm.
                nextFidget = t + 3 + uniform() * 2.5
                tilt.rest = 0
            }
        }
        if fidget != nil, t - fidgetStart >= Self.fidgetLength || isDozing(quietFor: quietFor) { fidget = nil }
        if fidget == nil, t >= nextFidget, !isDozing(quietFor: quietFor) {
            let kinds = Fidget.allCases
            fidget = kinds[Int(uniform() * Double(kinds.count)) % kinds.count]
            fidgetStart = t
            nextFidget = t + Self.fidgetLength + 3 + uniform() * 3
            if animated, fidget == .stretch { squash.kick(0.9) }
        }
        if let cue, t - cueStart >= (Self.cueLength[cue] ?? 0.4) { self.cue = nil }
        guard animated else {
            hop.settle()
            squash.settle()
            tilt.settle()
            return
        }
        hop.step(dt)
        squash.step(dt)
        tilt.step(dt)
    }

    private mutating func beat(_ strength: CGFloat) {
        switch rhythm.gait ?? .bob {
        case .bounce:
            // A hop already high in the air takes only part of the next kick.
            let airborne = hop.value > 40 && hop.velocity > 0
            hop.kick(8500 * strength * (airborne ? 0.35 : 1))
            squash.kick(1.4 * strength)
        case .bob:
            hop.kick(3000 * strength)
            squash.kick(-3.2 * strength)
        case .sway:
            swaySide = -swaySide
            tilt.rest = 8 * swaySide * max(0.6, strength)
            hop.kick(1200 * strength)
            squash.kick(-1.2 * strength)
        }
    }

    /// The words recognized so far; their growth and last mark make Typo react.
    mutating func heard(_ text: String, at t: TimeInterval, animated: Bool) {
        let count = text.count
        defer { heardCount = count }
        guard count > heardCount else { return }
        let added = text.suffix(count - heardCount)
        if added.contains(where: { $0 == "?" || $0 == "？" }) {
            show(.question, at: t)
            if animated { tilt.kick(70) }
        } else if added.contains(where: { $0 == "!" || $0 == "！" }) {
            show(.exclaim, at: t)
            if animated { hop.kick(3200) }
        } else if cue == nil || t - cueStart >= Self.nodGap {
            if cue == nil { show(.nod, at: t) }
            if animated { squash.kick(-1.2) }
        }
    }

    private mutating func show(_ next: Cue, at t: TimeInterval) {
        cue = next
        cueStart = t
    }

    func isDozing(quietFor: TimeInterval?) -> Bool {
        (quietFor ?? 0) >= Self.dozeAfter
    }

    /// SplitMix64, so a session's fidgets are reproducible in tests.
    private mutating func uniform() -> Double {
        random &+= 0x9E37_79B9_7F4A_7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
