import XCTest
@testable import Type4Me

/// A voice saying `rate` syllables a second for `seconds`, as the mic meter
/// would report it: a quiet floor, and each syllable rising to `peak` and
/// falling back into a dip before the next.
private func voice(rate: Double, seconds: Double, peak: Float = 0.6, dip: Float = 0.32, floor: Float = 0.05) -> (Double) -> Float {
    { t in
        guard t >= 0, t < seconds else { return floor }
        let phase = (t * rate).truncatingRemainder(dividingBy: 1)
        // Rise quickly, fall slowly, like a spoken syllable.
        let shape = phase < 0.25 ? phase / 0.25 : 1 - (phase - 0.25) / 0.75
        return dip + (peak - dip) * Float(shape)
    }
}

private let frame = 1.0 / 60

final class TypoRhythmTests: XCTestCase {
    private func hear(_ level: (Double) -> Float, seconds: Double, into rhythm: inout TypoRhythm) -> [Double] {
        var beats: [Double] = []
        var t = 0.0
        while t < seconds {
            if rhythm.hear(level(t), dt: frame, at: t) != nil { beats.append(t) }
            t += frame
        }
        return beats
    }

    func testFindsOneBeatPerSyllable() {
        var r = TypoRhythm()
        let beats = hear(voice(rate: 4, seconds: 3), seconds: 3.5, into: &r)
        XCTAssertEqual(beats.count, 12, accuracy: 1, "one beat for each of the 12 syllables")
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, TypoRhythm.minimumBeatGap)
    }

    func testSilenceAndASteadyHumHaveNoBeats() {
        var quiet = TypoRhythm()
        XCTAssertTrue(hear({ _ in 0.05 }, seconds: 3, into: &quiet).isEmpty)
        var hum = TypoRhythm()
        let beats = hear({ _ in 0.5 }, seconds: 3, into: &hum)
        XCTAssertLessThanOrEqual(beats.count, 1, "only the hum's start, never a beat while it holds")
    }

    func testQuickSpeechBouncesSteadySpeechBobsSlowSpeechSways() {
        var quick = TypoRhythm()
        _ = hear(voice(rate: 5, seconds: 2.5), seconds: 2.5, into: &quick)
        XCTAssertEqual(quick.gait, .bounce)

        var steady = TypoRhythm()
        _ = hear(voice(rate: 3.2, seconds: 2.5), seconds: 2.5, into: &steady)
        XCTAssertEqual(steady.gait, .bob)

        var slow = TypoRhythm()
        _ = hear(voice(rate: 1.8, seconds: 3), seconds: 3, into: &slow)
        XCTAssertEqual(slow.gait, .sway)
    }

    func testASoftVoiceSways() {
        var soft = TypoRhythm()
        _ = hear(voice(rate: 5, seconds: 2.5, peak: 0.26, dip: 0.12), seconds: 2.5, into: &soft)
        XCTAssertEqual(soft.gait, .sway)
    }

    func testDecidesOnlyAfterAMomentOfSpeech() {
        var r = TypoRhythm()
        _ = hear(voice(rate: 5, seconds: 0.6), seconds: 0.6, into: &r)
        XCTAssertNil(r.gait, "half a second is too little to judge a voice")
    }

    func testANewPhraseCanMoveDifferently() {
        var r = TypoRhythm()
        _ = hear(voice(rate: 5, seconds: 2.5), seconds: 2.5, into: &r)
        XCTAssertEqual(r.gait, .bounce)
        // A pause, then slow words.
        let slow = voice(rate: 1.8, seconds: 3)
        var t = 2.5
        while t < 2.5 + TypoRhythm.newPhraseAfter + 0.2 { _ = r.hear(0.05, dt: frame, at: t); t += frame }
        let start = t
        while t < start + 3 { _ = r.hear(slow(t - start), dt: frame, at: t); t += frame }
        XCTAssertEqual(r.gait, .sway)
    }

    func testShoutingIsMeasuredAgainstThisSpeakersUsualLoudness() {
        var calm = TypoRhythm()
        XCTAssertLessThanOrEqual(calm.shoutLevel, 0.8, "a new speaker shouts at the old fixed level or below")
        var loud = TypoRhythm()
        _ = hear(voice(rate: 4, seconds: 3, peak: 0.75, dip: 0.5), seconds: 3, into: &loud)
        XCTAssertGreaterThan(loud.shoutLevel, 0.85, "a loud talker's ordinary words are not a shout")
        XCTAssertLessThanOrEqual(loud.shoutLevel, 0.92, "a real shout still counts")
        _ = hear(voice(rate: 4, seconds: 3, peak: 0.45, dip: 0.25), seconds: 3, into: &calm)
        XCTAssertEqual(calm.shoutLevel, 0.72, accuracy: 0.03)
    }
}

final class TypoSpringTests: XCTestCase {
    func testAKickRisesLandsBelowRestAndSettles() {
        var s = TypoSpring(frequency: 3, damping: 0.45)
        s.kick(4000)
        var peak: CGFloat = 0
        var lowest: CGFloat = 0
        for _ in 0..<120 {
            s.step(frame)
            peak = max(peak, s.value)
            lowest = min(lowest, s.value)
        }
        XCTAssertGreaterThan(peak, 90, "a full beat is a visible hop")
        XCTAssertLessThan(peak, 200)
        XCTAssertLessThan(lowest, -5, "it lands through its rest: the landing squash")
        XCTAssertEqual(s.value, 0, accuracy: 2, "settled within two seconds")
    }

    func testALongFrameDoesNotBlowUp() {
        var s = TypoSpring(frequency: 4.5, damping: 0.35)
        s.kick(2)
        s.step(0.5)
        XCTAssertLessThan(abs(s.value), 1)
    }
}

final class TypoMotionPerformanceTests: XCTestCase {
    private let timing = TypoPerformance.Timing.standard

    /// Runs a caret-side performance over `seconds` of `level`, answering the poses.
    private func perform(
        _ level: (Double) -> Float, seconds: Double, reduceMotion: Bool = false,
        text: ((Double) -> String)? = nil, from p: inout TypoPerformance, start: Double = 0
    ) -> [(Double, TypoPerformance.Pose)] {
        var poses: [(Double, TypoPerformance.Pose)] = []
        var t = start
        while t < start + seconds {
            if let text { p.heard(text(t - start), at: t) }
            p.update(level: level(t - start), at: t)
            poses.append((t, p.pose(at: t)))
            t += frame
        }
        return poses
    }

    private func listening(reduceMotion: Bool = false) -> TypoPerformance {
        var p = TypoPerformance(peek: .caret, reduceMotion: reduceMotion)
        p.begin(at: -timing.enter - 0.02)
        p.update(level: 0.05, at: -0.01)
        return p
    }

    func testHopsToTheSyllablesAndComesBackDownAfterTheWords() {
        var p = listening()
        let poses = perform(voice(rate: 5, seconds: 3), seconds: 4.5, from: &p)
        let talking = poses.filter { $0.0 > 1.5 && $0.0 < 3 }
        XCTAssertGreaterThan(talking.map(\.1.hop).max() ?? 0, 60, "a quick voice makes Typo hop")
        // It comes down between syllables, so each one reads as its own hop.
        let lows = talking.filter { $0.1.hop < 10 }.count
        XCTAssertGreaterThan(lows, 5)
        XCTAssertTrue(talking.contains { $0.1.squash < 0.97 }, "it lands with a squash")
        let after = poses.filter { $0.0 > 4.2 }
        XCTAssertLessThan(after.map(\.1.hop).max() ?? 0, 3, "still once the words stop")
    }

    func testASlowVoiceSwaysFromSideToSide() {
        var p = listening()
        let poses = perform(voice(rate: 1.8, seconds: 5), seconds: 5, from: &p)
        let tilts = poses.filter { $0.0 > 2 }.map(\.1.tiltDegrees)
        XCTAssertGreaterThan(tilts.max() ?? 0, 2)
        XCTAssertLessThan(tilts.min() ?? 0, -2)
    }

    func testReducedMotionKeepsStillToTheVoice() {
        var p = listening(reduceMotion: true)
        let poses = perform(voice(rate: 5, seconds: 3), seconds: 3, reduceMotion: true, from: &p)
        XCTAssertEqual(poses.map(\.1.hop).max() ?? 1, 0)
        XCTAssertEqual(poses.map(\.1.tiltDegrees).max() ?? 1, 0)
    }

    func testNodsAsWordsAppearAndReactsToTheirMarks() {
        var p = listening()
        p.update(level: 0.05, at: 0)
        p.heard("今天", at: 0)
        XCTAssertEqual(p.motion.cue, .nod)
        XCTAssertNil(p.pose(at: 0.05).expression.bubble)

        p.update(level: 0.05, at: 1)
        p.heard("今天天气好吗？", at: 1)
        XCTAssertEqual(p.motion.cue, .question)
        p.update(level: 0.05, at: 1.3)
        XCTAssertEqual(p.pose(at: 1.3).expression.bubble, .question)

        p.update(level: 0.05, at: 2.5)
        p.heard("今天天气好吗？真好！", at: 2.5)
        p.update(level: 0.05, at: 2.6)
        let cheer = p.pose(at: 2.6).expression
        XCTAssertTrue(cheer.armL.up && cheer.armR.up, "arms up at an exclamation")

        p.update(level: 0.05, at: 4)
        XCTAssertNil(p.motion.cue, "a reaction passes")
        p.heard("今天", at: 4)
        XCTAssertNil(p.motion.cue, "a partial that got shorter is not new words")
    }

    func testFidgetsWhileWaitingButNotRightAway() {
        var fidgetTimes: [Double] = []
        var replay = listening()
        var t = 0.0
        while t < 7.5 {
            replay.update(level: 0.05, at: t)
            if replay.motion.fidget != nil { fidgetTimes.append(t) }
            t += frame
        }
        XCTAssertFalse(fidgetTimes.isEmpty, "something happens within seven quiet seconds")
        XCTAssertGreaterThan(fidgetTimes.first ?? 0, TypoMotion.restAfter + 3 - 0.01, "a pause between words stays calm")
    }

    func testDozesOffInALongSilenceAndWakesWhenSpokenTo() {
        var p = listening()
        _ = perform({ _ in 0.05 }, seconds: TypoMotion.dozeAfter + 1, from: &p)
        let t = TypoMotion.dozeAfter + 1
        let dozing = p.pose(at: t).expression
        XCTAssertEqual(dozing.bubble, .zz)
        XCTAssertEqual(dozing.eyeL, .line)

        let poses = perform(voice(rate: 4, seconds: 1), seconds: 0.3, from: &p, start: t)
        XCTAssertEqual(p.motion.cue, .wake)
        XCTAssertTrue(poses.contains { $0.1.expression.eyeL == .ring }, "startled awake")
        XCTAssertNotEqual(p.pose(at: t + 0.3).expression.bubble, .zz)
    }

    func testFidgetFacesComeFromAFewCachedSteps() {
        var p = listening()
        var looks = Set<CGFloat>()
        var t = 0.0
        while t < 20 {
            p.update(level: 0.05, at: t)
            if p.motion.fidget == .lookAround { looks.insert(p.pose(at: t).expression.look.width) }
            t += frame
        }
        XCTAssertLessThanOrEqual(looks.count, 5, "each glance is one of a few drawn faces, not a new one per frame")
    }
}
