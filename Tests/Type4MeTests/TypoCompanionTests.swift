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

        let midAir = p.pose(at: 5 + timing.leapCrouch + timing.leapAir / 2)
        XCTAssertGreaterThan(midAir.hop, 300)
        XCTAssertEqual(midAir.spinDegrees, 180, accuracy: 1, "halfway through the somersault")
        XCTAssertEqual(midAir.travel.width, 1500, accuracy: 1)

        let landed = timing.leapCrouch + timing.leapAir
        let press = p.pose(at: 5 + landed + timing.leapPress * 0.95)
        XCTAssertEqual(press.travel, offset)
        XCTAssertEqual(press.expression.eyeL, .chevron)
        XCTAssertLessThan(press.squash, 0.8)
        XCTAssertEqual(press.hop, 0)

        let sinking = p.pose(at: 5 + timing.leapTotal - 0.01)
        XCTAssertEqual(sinking.travel, offset, "sinks into the new line, not the old one")
        XCTAssertGreaterThan(sinking.sink, 0.85)
        p.update(level: 0, at: 5 + timing.leapTotal)
        XCTAssertEqual(p.stage, .hidden)
        XCTAssertLessThan(timing.leapTotal, 1.1, "matches the video's roughly one-second landing")
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
