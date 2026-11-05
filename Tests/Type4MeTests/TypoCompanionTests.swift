import AppKit
import XCTest
@testable import Type4Me

final class TypoPerformanceTests: XCTestCase {
    private let timing = TypoPerformance.Timing.standard
    private typealias Peek = TypoPerformance.Peek

    private func listening(at t: TimeInterval = 0) -> TypoPerformance {
        var p = TypoPerformance()
        p.begin(at: t)
        p.update(level: 0.4, at: t + timing.enter + 0.01)
        return p
    }

    func testStartsHiddenAndInvisible() {
        let p = TypoPerformance()
        XCTAssertEqual(p.stage, .hidden)
        XCTAssertFalse(p.isVisible)
        XCTAssertEqual(p.pose(at: 0).opacity, 0)
    }

    func testRisesFromBehindTheBarWithOvershootThenPeeks() {
        var p = TypoPerformance()
        p.begin(at: 10)
        XCTAssertEqual(p.stage, .entering)
        XCTAssertEqual(p.pose(at: 10).sink, 1, accuracy: 0.001, "starts fully hidden behind the bar")
        XCTAssertLessThan(p.pose(at: 10 + timing.enter * 0.7).sink, Peek.bar.listening, "springs a little higher than its resting peek")
        p.update(level: 0, at: 10 + timing.enter + 0.01)
        XCTAssertEqual(p.stage, .listening)
        XCTAssertEqual(p.pose(at: 10 + timing.enter + 0.02).sink, Peek.bar.listening, accuracy: 0.001)
    }

    func testMouthFollowsVoice() {
        var p = listening()
        p.update(level: 0.6, at: 1)
        let talking = p.pose(at: 1).expression
        XCTAssertEqual(talking.mouth, .talk)
        XCTAssertGreaterThan(talking.mouthOpen, 0.3)
        p.update(level: 0.1, at: 1.1)
        XCTAssertEqual(p.pose(at: 1.1).expression.mouth, .smile)
    }

    func testBlinksBrieflyOncePerPeriod() {
        var p = TypoPerformance()
        p.begin(at: 0)
        p.update(level: 0.4, at: timing.enter)
        let start = timing.enter
        XCTAssertEqual(p.pose(at: start + 1).expression.eyeL, .open)
        let blink = p.pose(at: start + timing.blinkPeriod - timing.blinkLength / 2).expression
        XCTAssertEqual(blink.eyeL, .line)
        XCTAssertEqual(blink.eyeR, .line)
        XCTAssertEqual(p.pose(at: start + timing.blinkPeriod + 0.05).expression.eyeL, .open)
    }

    func testShoutingIsHeldBeforeTypoBristlesAndStandsFullyOut() {
        var p = listening()
        p.update(level: 0.9, at: 1.0)
        p.update(level: 0.9, at: 1.2)
        XCTAssertFalse(p.isLoud, "a brief peak is not shouting")
        p.update(level: 0.4, at: 1.25)
        p.update(level: 0.9, at: 2.0)
        p.update(level: 0.9, at: 2.0 + timing.loudHold)
        XCTAssertTrue(p.isLoud)

        let bristling = p.pose(at: 2.0 + timing.loudHold + timing.loudRise)
        XCTAssertEqual(bristling.expression.spikiness, 1)
        XCTAssertEqual(bristling.expression.eyeL, .ring)
        XCTAssertEqual(bristling.expression.bubble, .exclaim)
        XCTAssertEqual(bristling.sink, 0, accuracy: 0.001, "jumps fully out from behind the bar")
        XCTAssertGreaterThan(p.pose(at: 2.0 + timing.loudHold + 0.01).sink, 0.2, "rises out gradually, not in one frame")
    }

    func testCalmsDownAndSettlesBackToItsPeek() {
        var p = listening()
        p.update(level: 0.9, at: 1.0)
        p.update(level: 0.9, at: 1.4)
        XCTAssertTrue(p.isLoud)
        p.update(level: 0.4, at: 1.5)
        p.update(level: 0.4, at: 1.6)
        XCTAssertTrue(p.isLoud, "stays bristled through a short dip")
        p.update(level: 0.4, at: 1.5 + timing.loudRelease)
        XCTAssertFalse(p.isLoud)
        let settled = p.pose(at: 1.5 + timing.loudRelease + timing.loudRise)
        XCTAssertEqual(settled.expression.spikiness, 0)
        XCTAssertEqual(settled.sink, Peek.bar.listening, accuracy: 0.001)
    }

    func testLongSilenceShowsListeningBubble() {
        var p = listening()
        p.update(level: 0.05, at: 1.0)
        p.update(level: 0.05, at: 2.5)
        XCTAssertNil(p.pose(at: 2.5).expression.bubble)
        p.update(level: 0.05, at: 1.0 + timing.quietBubble + 0.3)
        let pose = p.pose(at: 1.0 + timing.quietBubble + 0.3)
        XCTAssertEqual(pose.expression.bubble, .dots)
        XCTAssertEqual(pose.expression.bubbleOpacity, 1, accuracy: 0.001)
        p.update(level: 0.5, at: 4)
        XCTAssertNil(p.pose(at: 4).expression.bubble, "speaking again clears the bubble")
    }

    func testThinkingPeeksLowerWithAQuestion() {
        var p = listening()
        p.think(at: 2)
        XCTAssertEqual(p.stage, .thinking)
        let pose = p.pose(at: 2.5)
        XCTAssertEqual(pose.expression.bubble, .question)
        XCTAssertEqual(pose.expression.mouth, .flat)
        XCTAssertEqual(pose.sink, Peek.bar.thinking, accuracy: 0.001)
    }

    /// Regression: the caret-side Typo used the bar's peek depths, so the
    /// line it stands on clipped up to half of its body.
    func testBesideTheCaretTypoStandsFullyOutInEveryCalmState() {
        var p = TypoPerformance(timing: timing, peek: .caret)
        p.begin(at: 0)
        p.update(level: 0, at: 1)
        XCTAssertEqual(p.pose(at: 1).sink, 0, accuracy: 0.001, "listening")
        p.think(at: 2)
        XCTAssertEqual(p.pose(at: 2.5).sink, 0, accuracy: 0.001, "thinking")
        p.react(.done, at: 3)
        XCTAssertEqual(p.pose(at: 3.5).sink, 0, accuracy: 0.001, "reacting")
    }

    func testThinkIsIgnoredWhileHidden() {
        var p = TypoPerformance()
        p.think(at: 1)
        XCTAssertEqual(p.stage, .hidden)
    }

    func testReactsHappilyOrStartledWhileTheBarShowsAMessage() {
        var p = listening()
        p.react(.done, at: 2)
        XCTAssertEqual(p.pose(at: 2.1).expression.eyeL, .happy)
        p.react(.failed, at: 2.5)
        let startled = p.pose(at: 2.6).expression
        XCTAssertEqual(startled.bubble, .interrobang)
        XCTAssertTrue(startled.sweat)
        XCTAssertEqual(p.pose(at: 2.6).sink, Peek.bar.reacting, accuracy: 0.001)
    }

    func testSuccessHopsPressesLikeAKeyAndSinksWithinTheBarsExit() {
        XCTAssertLessThanOrEqual(timing.successTotal, 0.33, "must finish while the bar collapses")
        var p = listening()
        p.finish(.success, at: 5)
        XCTAssertEqual(p.stage, .exiting(.success))

        let hop = p.pose(at: 5 + timing.successHop / 2)
        XCTAssertGreaterThan(hop.hop, 40)
        XCTAssertEqual(hop.expression.eyeL, .happy)

        let press = p.pose(at: 5 + timing.successHop + timing.successPress * 0.95)
        XCTAssertLessThan(press.squash, 0.8)
        XCTAssertEqual(press.expression.eyeL, .chevron)
        XCTAssertTrue(press.expression.impact)

        XCTAssertGreaterThan(p.pose(at: 5 + timing.successTotal - 0.01).sink, 0.85)
        p.update(level: 0, at: 5 + timing.successTotal)
        XCTAssertEqual(p.stage, .hidden)
    }

    func testLeapFlipsAcrossToTheNewLinePressesAndSinksThere() {
        var p = listening()
        let offset = CGSize(width: 3000, height: 400)
        p.finish(.leap(offset), at: 5)
        let crouch = p.pose(at: 5 + timing.leapCrouch * 0.9)
        XCTAssertLessThan(crouch.sink, TypoPerformance.Peek.bar.listening, "rises out of the line before take-off")

        let midAir = p.pose(at: 5 + timing.leapCrouch + p.leap.air / 2)
        XCTAssertGreaterThan(midAir.hop, 300)
        XCTAssertEqual(midAir.spinDegrees, 180, accuracy: 1, "halfway through the somersault")
        XCTAssertEqual(midAir.travel.width, 1500, accuracy: 1)

        let landed = timing.leapCrouch + p.leap.air
        let press = p.pose(at: 5 + landed + timing.leapPress * 0.95)
        XCTAssertEqual(press.travel, offset)
        XCTAssertEqual(press.expression.eyeL, .chevron)
        XCTAssertLessThan(press.squash, 0.8)
        XCTAssertEqual(press.hop, 0)

        let sinking = p.pose(at: 5 + p.exitDuration(.leap(offset)) - 0.01)
        XCTAssertEqual(sinking.travel, offset, "sinks into the new line, not the old one")
        XCTAssertGreaterThan(sinking.sink, 0.85)
        p.update(level: 0, at: 5 + p.exitDuration(.leap(offset)))
        XCTAssertEqual(p.stage, .hidden)
        XCTAssertLessThan(p.exitDuration(.leap(offset)), 1.4, "about a second from take-off to gone")
    }

    func testReducedMotionLeapFadesInPlace() {
        var p = TypoPerformance(reduceMotion: true)
        p.begin(at: 0)
        p.update(level: 0, at: timing.enter + 0.01)
        p.finish(.leap(CGSize(width: 3000, height: 0)), at: 2)
        let pose = p.pose(at: 2 + timing.reducedMotionFade / 2)
        XCTAssertEqual(pose.travel, .zero)
        XCTAssertEqual(pose.spinDegrees, 0)
        XCTAssertEqual(pose.opacity, 0.5, accuracy: 0.01)
    }

    func testExitStartsFromWhereverTypoWas() {
        var p = listening()
        p.update(level: 0.9, at: 1.0)
        p.update(level: 0.9, at: 1.5)
        p.finish(.cancelled, at: 2)
        XCTAssertEqual(p.pose(at: 2).sink, 0, accuracy: 0.02, "a bristling Typo sinks from fully out, without a jump")
    }

    func testCancelSinksSadly() {
        var p = listening()
        p.finish(.cancelled, at: 3)
        let pose = p.pose(at: 3.1)
        XCTAssertEqual(pose.expression.eyeL, .sad)
        XCTAssertEqual(pose.expression.mouth, .frown)
        p.update(level: 0, at: 3 + timing.cancelSink)
        XCTAssertEqual(p.stage, .hidden)
    }

    func testFinishTwiceKeepsTheFirstExit() {
        var p = listening()
        p.finish(.success, at: 3)
        p.finish(.cancelled, at: 3.05)
        XCTAssertEqual(p.stage, .exiting(.success))
    }

    func testNewRecordingInterruptsAnExit() {
        var p = listening()
        p.finish(.success, at: 3)
        p.begin(at: 3.2)
        XCTAssertEqual(p.stage, .entering)
    }

    func testReducedMotionFadesWithoutHopsOrShakes() {
        var p = TypoPerformance(reduceMotion: true)
        p.begin(at: 0)
        let entering = p.pose(at: timing.enter / 2)
        XCTAssertEqual(entering.sink, Peek.bar.listening, accuracy: 0.001)
        XCTAssertEqual(entering.opacity, 0.5, accuracy: 0.01)

        p.update(level: 0.9, at: timing.enter + 0.01)
        p.update(level: 0.9, at: timing.enter + 0.5)
        let loud = p.pose(at: timing.enter + 0.5)
        XCTAssertEqual(loud.shake, 0)
        XCTAssertEqual(loud.hop, 0)

        p.finish(.success, at: 2)
        XCTAssertEqual(p.pose(at: 2).hop, 0)
        XCTAssertEqual(p.pose(at: 2 + timing.reducedMotionFade / 2).opacity, 0.5, accuracy: 0.01)
        p.update(level: 0, at: 2 + timing.reducedMotionFade)
        XCTAssertEqual(p.stage, .hidden)
    }
}

@MainActor
final class TypoDirectorTests: XCTestCase {
    private func cue(_ phase: FloatingBarPhase, exit: FloatingBarHideStyle? = nil, kind: FeedbackKind = .standard) -> TypoBuddyCue {
        TypoBuddyCue(phase: phase, exitStyle: exit, feedbackKind: kind)
    }

    func testRecordingThenProcessingThenOutput() {
        let d = TypoDirector()
        d.apply(cue(.recording), reduceMotion: false, at: 0)
        XCTAssertEqual(d.performance.stage, .entering)
        d.apply(cue(.processing), reduceMotion: false, at: 1)
        XCTAssertEqual(d.performance.stage, .thinking)
        d.apply(cue(.hidden, exit: .output), reduceMotion: false, at: 2)
        XCTAssertEqual(d.performance.stage, .exiting(.success))
    }

    func testCancelledRecordingSinksSadly() {
        let d = TypoDirector()
        d.apply(cue(.recording), reduceMotion: false, at: 0)
        d.apply(cue(.hidden, exit: .standard), reduceMotion: false, at: 1)
        XCTAssertEqual(d.performance.stage, .exiting(.cancelled))
    }

    /// A notice queued during recording (an input-device switch) is shown as a
    /// `.done` message right after the text lands. Typo must stay happy.
    func testNoticeAfterSuccessfulOutputKeepsTypoHappy() {
        let d = TypoDirector()
        d.apply(cue(.recording), reduceMotion: false, at: 0)
        d.apply(cue(.done, kind: .standard), reduceMotion: false, at: 1)
        XCTAssertEqual(d.performance.stage, .reacting(.done))
        d.apply(cue(.hidden, exit: .standard), reduceMotion: false, at: 3)
        XCTAssertEqual(d.performance.stage, .exiting(.success))
    }

    func testFailuresLookStartled() {
        let d = TypoDirector()
        d.apply(cue(.processing), reduceMotion: false, at: 0)
        d.apply(cue(.done, kind: .warning), reduceMotion: false, at: 1)
        XCTAssertEqual(d.performance.stage, .reacting(.failed))
        d.apply(cue(.hidden, exit: .standard), reduceMotion: false, at: 2)
        XCTAssertEqual(d.performance.stage, .exiting(.failed))

        let e = TypoDirector()
        e.apply(cue(.recording), reduceMotion: false, at: 0)
        e.apply(cue(.error), reduceMotion: false, at: 1)
        XCTAssertEqual(e.performance.stage, .reacting(.failed))
    }

    func testFeedbackKindsMapToReactions() {
        XCTAssertEqual(TypoDirector.reaction(for: .standard), .done)
        XCTAssertEqual(TypoDirector.reaction(for: .macActionSuccess), .done)
        XCTAssertEqual(TypoDirector.reaction(for: .warning), .failed)
        XCTAssertEqual(TypoDirector.reaction(for: .macActionFailure), .failed)
        XCTAssertEqual(TypoDirector.reaction(for: .macActionUnsure), .failed)
    }

    func testHiddenBarWithoutExitPutsTypoAway() {
        let d = TypoDirector()
        d.apply(cue(.recording), reduceMotion: false, at: 0)
        d.apply(cue(.hidden), reduceMotion: false, at: 1)
        XCTAssertEqual(d.performance.stage, .exiting(.cancelled))
    }

    func testReduceMotionIsCapturedWhenTypoAppears() {
        let d = TypoDirector()
        d.apply(cue(.recording), reduceMotion: true, at: 0)
        XCTAssertTrue(d.performance.reduceMotion)
    }
}

final class TypoBuddyMetricsTests: XCTestCase {
    func testCompanionIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "TypoBuddyMetricsTests-\(UUID().uuidString)")!
        XCTAssertFalse(TypoCompanionSettings.isEnabled(defaults))
        defaults.set(true, forKey: TypoCompanionSettings.enabledKey)
        XCTAssertTrue(TypoCompanionSettings.isEnabled(defaults))
    }

    func testTypoSitsOverTheFinishControl() {
        XCTAssertEqual(TypoBuddyMetrics.regular.anchorX, TF.recordingLeadingInset + TF.recordingFinishControlSize / 2)
        XCTAssertLessThan(TypoBuddyMetrics.compact.bodyHeight, TypoBuddyMetrics.regular.bodyHeight)
    }

    func testTypoFitsInsideThePanelShadowInset() {
        for metrics in [TypoBuddyMetrics.regular, .compact] {
            XCTAssertLessThanOrEqual(metrics.leadingOverhang, TF.floatingPanelShadowInset,
                                     "Typo's arms must not be clipped by the bar window")
        }
    }

    func testHeadroomCoversTheTallestPoses() {
        for metrics in [TypoBuddyMetrics.regular, .compact] {
            let outline = 1.5 / metrics.scale
            // Bristling stands fully out with shout lines topping at y 450 (10-unit caps).
            let bristling = TypoGeometry.baselineY - 450 + 10 + outline
            // The success hop lifts the ears (y 556) by up to 70 units.
            let hopping = TypoGeometry.baselineY - 556 + 70 + outline
            let tallest = max(bristling, hopping) * metrics.scale
            XCTAssertGreaterThanOrEqual(metrics.headroom, tallest)
            XCTAssertLessThan(metrics.headroom, metrics.bodyHeight * 1.4, "keeps the bar window compact")
        }
    }

    func testBubbleFitsBesideTypoOverTheCapsule() {
        XCTAssertLessThan(TypoBuddyMetrics.regular.trailingExtent, TF.barWidthCompact)
        XCTAssertLessThan(TypoBuddyMetrics.compact.trailingExtent, TF.compactIndicatorWidth)
    }
}

final class TypoStandingDetailTests: XCTestCase {
    private let timing = TypoPerformance.Timing.standard
    private let baseline = TypoGeometry.baselineY

    private func standing(at t: TimeInterval = 0, reduceMotion: Bool = false) -> TypoPerformance {
        var p = TypoPerformance(peek: .caret, reduceMotion: reduceMotion)
        p.begin(at: t)
        p.update(level: 0, at: t + timing.enter + 0.01)
        return p
    }

    // MARK: Bottom

    func testTheTracedBottomLeansAcrossTheLine() {
        let below = TypoReference.body.filter { $0.y > baseline + 10 }
        XCTAssertFalse(below.isEmpty, "the traced keycap dips below its line, which is what the standing body fixes")
    }

    func testStandingBodySitsLevelOnItsLine() {
        let body = TypoRenderer.standingBody(TypoReference.body)
        XCTAssertTrue(body.allSatisfy { $0.y <= baseline + 0.001 }, "nothing below the line, so clipping never cuts a corner")
        let onLine = body.filter { abs($0.y - baseline) < 0.001 }.map(\.x)
        XCTAssertGreaterThan((onLine.max() ?? 0) - (onLine.min() ?? 0), 850, "a level edge across almost the whole keycap")
        let top = TypoReference.body.filter { $0.y < 1200 }
        XCTAssertTrue(top.allSatisfy { body.contains($0) }, "the sides and top keep the traced lean")
    }

    // MARK: Shadow

    func testShadowIsFullUnderAStandingTypo() {
        let shadow = TypoShadow(standing().pose(at: 1))
        XCTAssertEqual(shadow.width, 1, accuracy: 0.02)
        XCTAssertEqual(shadow.darkness, 1, accuracy: 0.001)
    }

    func testShadowGrowsInAsTypoRisesOutOfTheLine() {
        var p = TypoPerformance(peek: .caret)
        p.begin(at: 0)
        XCTAssertEqual(TypoShadow(p.pose(at: 0)).darkness, 0, accuracy: 0.0001, "no shadow before Typo shows")
        // Typo springs out quickly, so the shadow is full well before the rise ends.
        let early = TypoShadow(p.pose(at: timing.enter * 0.05))
        let late = TypoShadow(p.pose(at: timing.enter * 0.12))
        XCTAssertGreaterThan(early.darkness, 0)
        XCTAssertLessThan(early.width, late.width)
        XCTAssertLessThan(early.darkness, late.darkness)
    }

    func testShadowShrinksAndFadesAsTypoLeavesTheGround() {
        var pose = TypoPerformance.Pose(sink: 0)
        var last = TypoShadow(pose)
        for hop in stride(from: CGFloat(100), through: 600, by: 100) {
            pose.hop = hop
            let shadow = TypoShadow(pose)
            XCTAssertLessThan(shadow.width, last.width)
            XCTAssertLessThan(shadow.darkness, last.darkness)
            last = shadow
        }
        XCTAssertEqual(last.width, 0.55, accuracy: 0.001)
        XCTAssertEqual(last.darkness, 0.4, accuracy: 0.001)
    }

    func testShadowSpreadsAndDarkensWhenTypoIsPressed() {
        let pressed = TypoShadow(TypoPerformance.Pose(sink: 0, squash: 0.7))
        XCTAssertEqual(pressed.width, 1 / sqrt(0.7), accuracy: 0.001)
        XCTAssertGreaterThan(pressed.darkness, 1.2)
    }

    func testShadowFadesWithTypo() {
        XCTAssertEqual(TypoShadow(TypoPerformance.Pose(sink: 0, opacity: 0.5)).darkness, 0.5, accuracy: 0.001)
    }

    // MARK: Breath

    func testTypoBreathesWhileItWaits() {
        let p = standing()
        let squashes = stride(from: 1.0, through: 4.0, by: 0.05).map { p.pose(at: $0).squash }
        XCTAssertGreaterThan(squashes.max() ?? 0, 1.01)
        XCTAssertLessThan(squashes.min() ?? 2, 0.99)
        XCTAssertTrue(squashes.allSatisfy { abs($0 - 1) <= 0.02 }, "a breath, not a bounce")
    }

    func testBreathCarriesOnFromListeningIntoThinking() {
        var p = standing()
        let before = p.pose(at: 2).squash
        p.think(at: 2)
        XCTAssertEqual(p.pose(at: 2).squash, before, accuracy: 0.0001)
    }

    func testReducedMotionTypoHoldsStill() {
        let p = standing(reduceMotion: true)
        XCTAssertEqual(p.pose(at: 1.7).squash, 1)
    }

    // MARK: Gaze

    func testThinkingTypoLooksTowardTheNewText() {
        var p = standing()
        p.gaze = -1
        p.think(at: 2)
        let look = p.pose(at: 2.5).expression.look
        XCTAssertLessThan(look.width, 0, "the text appears at the caret, on Typo's left")
        XCTAssertGreaterThan(look.height, 0, "down at the line")
    }

    func testThinkingOnTheBarStillPonders() {
        var p = TypoPerformance()
        p.begin(at: 0)
        p.think(at: 1)
        XCTAssertEqual(p.pose(at: 1.5).expression.look, CGSize(width: -18, height: -26))
    }

    // MARK: Leap learning its landing late

    func testLeapLooksWhereItIsGoingAndCanLearnABetterLanding() {
        var p = standing()
        p.finish(.leap(CGSize(width: -1800, height: 0)), at: 5)
        let crouch = p.pose(at: 5 + timing.leapCrouch * 0.5)
        XCTAssertEqual(crouch.travel, .zero)
        XCTAssertLessThan(crouch.expression.look.width, 0, "eyes on the landing, to the left")
        XCTAssertLessThan(crouch.squash, 0.95, "crouches before take-off")

        let offset = CGSize(width: -2000, height: 300)
        p.retarget(offset, at: 5 + timing.leapCrouch * 0.5)
        XCTAssertEqual(p.stage, .exiting(.leap(offset)))
        XCTAssertEqual(p.pose(at: 5 + timing.leapCrouch + p.leap.air + timing.leapPress * 0.9).travel, offset)
        XCTAssertEqual(p.pose(at: 5 + p.exitDuration(.leap(offset)) - 0.01).travel, offset)
    }

    func testNewsOfTheLandingMidAirSlidesTheDestinationInsteadOfJumping() {
        var p = standing()
        p.finish(.leap(.zero), at: 5)
        let tAir = 5 + timing.leapCrouch + p.leap.air * 0.3
        let before = p.pose(at: tAir).travel
        p.retarget(CGSize(width: 2000, height: 0), at: tAir)
        XCTAssertEqual(p.pose(at: tAir).travel.width, before.width, accuracy: 0.001, "no jump at the moment of the news")
        var last = before.width
        for step in 1...10 {
            let w = p.pose(at: tAir + 0.01 * Double(step)).travel.width
            XCTAssertGreaterThanOrEqual(w, last)
            XCTAssertLessThan(w - last, 400, "a smooth slide")
            last = w
        }
        let landed = p.pose(at: 5 + timing.leapCrouch + p.leap.air + timing.leapPress * 0.9).travel
        XCTAssertEqual(landed.width, 2000, accuracy: 0.001)
    }

    func testRetargetLeavesOtherStagesAlone() {
        var p = standing()
        p.retarget(CGSize(width: 100, height: 0), at: 3)
        XCTAssertEqual(p.stage, .listening)
        p.finish(.success, at: 3)
        p.retarget(CGSize(width: 100, height: 0), at: 3)
        XCTAssertEqual(p.stage, .exiting(.success))
    }

    func testShortHopLeansAndALongLeapSomersaultsHigherAndLonger() {
        var near = standing()
        near.finish(.leap(CGSize(width: 600, height: 0)), at: 5)
        let hopTop = near.pose(at: 5 + timing.leapCrouch + near.leap.air / 2)
        XCTAssertEqual(hopTop.spinDegrees, 0, "a hop along the line does not flip")
        XCTAssertGreaterThan(hopTop.tiltDegrees, 5, "it leans into the hop")

        var far = standing()
        far.finish(.leap(CGSize(width: 9000, height: 400)), at: 5)
        let farTop = far.pose(at: 5 + timing.leapCrouch + far.leap.air / 2)
        XCTAssertEqual(farTop.spinDegrees, 180, accuracy: 1, "halfway through the somersault")
        XCTAssertGreaterThan(far.leap.air, near.leap.air)
        XCTAssertGreaterThan(farTop.hop, hopTop.hop)
        XCTAssertLessThanOrEqual(far.leap.air, timing.leapAirMax)

        var left = standing()
        left.finish(.leap(CGSize(width: -9000, height: 0)), at: 5)
        XCTAssertLessThan(left.pose(at: 5 + timing.leapCrouch + left.leap.air / 2).spinDegrees, 0, "flips toward where it goes")
    }

    func testLeapTakesOffStretchedWithoutASnap() {
        var p = standing()
        p.finish(.leap(CGSize(width: 3000, height: 0)), at: 5)
        let endOfCrouch = p.pose(at: 5 + timing.leapCrouch - 0.001).squash
        let takeOff = p.pose(at: 5 + timing.leapCrouch + 0.001).squash
        XCTAssertEqual(takeOff, endOfCrouch, accuracy: 0.05, "no one-frame jump out of the crouch")
        XCTAssertGreaterThan(p.pose(at: 5 + timing.leapCrouch + p.leap.air * 0.12).squash, 1.05, "stretched as it leaves")
        XCTAssertEqual(p.pose(at: 5 + timing.leapCrouch + p.leap.air * 0.5).squash, 1, accuracy: 0.01, "round at the top")
    }

    func testAfterLandingTypoLingersOnTheTextLookingAtIt() {
        var p = standing()
        p.gaze = -1
        let offset = CGSize(width: 3000, height: 0)
        p.finish(.leap(offset), at: 5)
        let settle = 5 + timing.leapCrouch + p.leap.air + timing.leapPress + timing.leapRebound + timing.leapSettle * 0.3
        let pose = p.pose(at: settle)
        XCTAssertEqual(pose.sink, 0, "still standing")
        XCTAssertEqual(pose.travel, offset)
        XCTAssertLessThan(pose.expression.look.width, 0, "looking at the text it landed beside")
    }

    func testLeapArcClimbsForALongerDrop() {
        let hop = TypoPerformance.leapArc(for: CGSize(width: 600, height: 0))
        XCTAssertGreaterThan(TypoPerformance.leapArc(for: CGSize(width: 6000, height: 0)), hop, "farther goes higher")
        XCTAssertGreaterThan(TypoPerformance.leapArc(for: CGSize(width: 600, height: -1000)), hop, "climbing to a line above needs more")
    }
}

@MainActor
final class TypoSpriteTests: XCTestCase {
    private func close(_ a: CGPoint, _ b: CGPoint, _ accuracy: CGFloat = 0.001, _ message: String = "") {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message)
    }

    func testFrameToFrameChangesShareOneBodyImage() {
        var a = TypoExpression()
        a.mouth = .talk
        a.mouthOpen = 0.51
        var b = a
        b.mouthOpen = 0.53
        b.bubble = .dots
        b.bubbleOpacity = 0.4
        b.bubbleScale = 1.3
        XCTAssertEqual(TypoSpriteSet.bodyKey(a), TypoSpriteSet.bodyKey(b), "a fading bubble and a mouth drifting by 2% redraw nothing")
        b.eyeL = .line
        XCTAssertNotEqual(TypoSpriteSet.bodyKey(a), TypoSpriteSet.bodyKey(b), "a blink is a new picture")
    }

    func testMouthOpennessIsSnappedToAFewSteps() {
        var e = TypoExpression()
        e.mouth = .talk
        let keys = Set(stride(from: CGFloat(0.3), through: 1, by: 0.01).map { v -> TypoExpression in
            e.mouthOpen = v
            return TypoSpriteSet.bodyKey(e)
        })
        XCTAssertLessThanOrEqual(keys.count, Int(TypoSpriteSet.mouthSteps) + 1)
    }

    func testCacheIsBoundedAndRebuiltWhenTheSizeChanges() {
        let set = TypoSpriteSet()
        set.prepare(scale: 0.05, backing: 2)
        var e = TypoExpression()
        for i in 0..<(TypoSpriteSet.capacity + 8) {
            e.look = CGSize(width: CGFloat(i), height: 0)
            XCTAssertNotNil(set.body(e))
            XCTAssertLessThanOrEqual(set.cachedCount, TypoSpriteSet.capacity)
        }
        XCTAssertTrue(set.prepare(scale: 0.04, backing: 2))
        XCTAssertEqual(set.cachedCount, 0)
        XCTAssertFalse(set.prepare(scale: 0.04, backing: 2), "the same size keeps its images")
    }

    func testSpriteImageSizeFollowsScaleAndBacking() throws {
        let set = TypoSpriteSet()
        set.prepare(scale: 0.05, backing: 2)
        let image = try XCTUnwrap(set.body(TypoExpression()))
        XCTAssertEqual(CGFloat(image.width), TypoSpriteSet.region.width * 0.05 * 2, accuracy: 2)
        XCTAssertEqual(CGFloat(image.height), TypoSpriteSet.region.height * 0.05 * 2, accuracy: 2)
    }

    func testRegionHoldsTheTallestAndWidestParts() {
        let region = TypoSpriteSet.region
        let tail = TypoGeometry.bubbleTail
        let k = TypoCaretLayout.bubbleScale
        XCTAssertLessThan(tail.x + (1790 - tail.x) * k, region.maxX, "the enlarged bubble fits")
        XCTAssertGreaterThan(tail.y - (tail.y - 512) * k, region.minY)
        XCTAssertLessThan(TypoRenderer.feetAnchor.y + 60, region.maxY, "room for the edge below the feet")
    }

    func testLayerTransformMovesTheFeetLikeTheCanvasDoes() {
        let s: CGFloat = 0.05
        var pose = TypoPerformance.Pose(sink: 0.25, hop: 100)
        pose.travel = CGSize(width: 400, height: 80)
        pose.shake = 10
        let t = TypoRenderer.layerTransform(of: pose, scale: s)
        // The feet are the layer's anchor: they land at the pose's offset, in points, y up.
        close(CGPoint.zero.applying(t), CGPoint(x: 410 * s, y: -(80 + 0.25 * TypoRenderer.sinkTravel - 100) * s))
    }

    func testLayerTransformTurnsTheSameWayAsTheCanvas() {
        var pose = TypoPerformance.Pose(sink: 0)
        pose.spinDegrees = 90
        let s: CGFloat = 0.05
        // On the canvas (y down) a clockwise quarter turn about the body's middle
        // sends a point at the head (above the middle) to the right of it.
        let canvas = TypoRenderer.motion(of: pose)
        let head = CGPoint(x: 0, y: -TypoRenderer.spinCentreHeight - 100)
        let turned = head.applying(canvas)
        XCTAssertGreaterThan(turned.x, 0)
        // The same turn through the layer's y-up, point-sized space.
        let layer = TypoRenderer.layerTransform(of: pose, scale: s)
        let layerHead = CGPoint(x: 0, y: (TypoRenderer.spinCentreHeight + 100) * s)
        let result = layerHead.applying(layer)
        close(result, CGPoint(x: turned.x * s, y: -turned.y * s), 0.001, "the layer shows what the canvas draws")
    }

    func testBubbleGrowsAboutItsTail() {
        let s: CGFloat = 0.05
        let t = TypoRenderer.bubbleTransform(scale: s, growth: 1.3)
        let tail = CGPoint(
            x: (TypoGeometry.bubbleTail.x - TypoRenderer.feetAnchor.x) * s,
            y: -(TypoGeometry.bubbleTail.y - TypoRenderer.feetAnchor.y) * s
        )
        close(tail.applying(t), tail, 0.0001, "the tail stays on Typo's body")
        let far = CGPoint(x: tail.x + 10, y: tail.y)
        XCTAssertEqual(far.applying(t).x - tail.x, 13, accuracy: 0.0001)
    }

    func testSpriteViewDrawsAndHidesWithoutACrash() {
        let view = TypoSpriteView(frame: NSRect(x: 0, y: 0, width: 140, height: 90))
        var pose = TypoPerformance.Pose(sink: 0)
        pose.expression.bubble = .question
        pose.expression.bubbleOpacity = 1
        view.update(pose: pose, line: CGPoint(x: 40, y: 70), scale: 0.05)
        XCTAssertEqual(view.layer?.sublayers?.count, 2, "shadow and Typo")
        view.clip = .behind(CGRect(x: 0, y: 50, width: 140, height: 40), cornerRadius: 20)
        view.update(pose: pose, line: CGPoint(x: 40, y: 50), scale: 0.05)
        pose.opacity = 0
        view.update(pose: pose, line: CGPoint(x: 40, y: 50), scale: 0.05)
        XCTAssertEqual(view.layer?.sublayers?.allSatisfy(\.isHidden), true)
    }
}
