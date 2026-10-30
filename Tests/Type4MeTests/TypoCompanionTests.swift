import AppKit
import XCTest
@testable import Type4Me

final class TypoPerformanceTests: XCTestCase {
    private let timing = TypoPerformance.Timing.standard

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

    func testRisesOutOfTheBaselineWithOvershootThenListens() {
        var p = TypoPerformance()
        p.begin(at: 10)
        XCTAssertEqual(p.stage, .entering)
        XCTAssertEqual(p.pose(at: 10).sink, 1, accuracy: 0.001, "starts fully below the line")
        XCTAssertLessThan(p.pose(at: 10 + timing.enter * 0.7).sink, 0, "springs slightly above the line")
        p.update(level: 0, at: 10 + timing.enter + 0.01)
        XCTAssertEqual(p.stage, .listening)
        XCTAssertEqual(p.pose(at: 10 + timing.enter + 0.02).sink, 0)
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

    func testBristlesOnlyWhenShoutingIsHeld() {
        var p = listening()
        p.update(level: 0.9, at: 1.0)
        p.update(level: 0.9, at: 1.2)
        XCTAssertFalse(p.isLoud, "a brief peak is not shouting")
        p.update(level: 0.4, at: 1.25)
        p.update(level: 0.9, at: 2.0)
        p.update(level: 0.9, at: 2.0 + timing.loudHold)
        XCTAssertTrue(p.isLoud)
        let pose = p.pose(at: 2.0 + timing.loudHold)
        XCTAssertEqual(pose.expression.spikiness, 1)
        XCTAssertEqual(pose.expression.eyeL, .ring)
        XCTAssertEqual(pose.expression.bubble, .exclaim)
        XCTAssertTrue(pose.expression.shout)
    }

    func testCalmsDownAfterReleaseWindow() {
        var p = listening()
        p.update(level: 0.9, at: 1.0)
        p.update(level: 0.9, at: 1.4)
        XCTAssertTrue(p.isLoud)
        p.update(level: 0.4, at: 1.5)
        p.update(level: 0.4, at: 1.6)
        XCTAssertTrue(p.isLoud, "stays bristled through a short dip")
        p.update(level: 0.4, at: 1.5 + timing.loudRelease)
        XCTAssertFalse(p.isLoud)
        XCTAssertEqual(p.pose(at: 1.8).expression.spikiness, 0)
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

    func testThinkingAfterRecording() {
        var p = listening()
        p.think(at: 2)
        XCTAssertEqual(p.stage, .thinking)
        let pose = p.pose(at: 2.5)
        XCTAssertEqual(pose.expression.bubble, .question)
        XCTAssertEqual(pose.expression.mouth, .flat)
        XCTAssertEqual(pose.sink, 0)
    }

    func testThinkIsIgnoredWhileHidden() {
        var p = TypoPerformance()
        p.think(at: 1)
        XCTAssertEqual(p.stage, .hidden)
    }

    func testSuccessHopsPressesLikeAKeyThenSinks() {
        var p = listening()
        p.finish(.success, at: 5)
        XCTAssertEqual(p.stage, .exiting(.success))

        let hop = p.pose(at: 5 + timing.successHop / 2)
        XCTAssertGreaterThan(hop.hop, 100)
        XCTAssertEqual(hop.expression.eyeL, .happy)

        let press = p.pose(at: 5 + timing.successHop + timing.successLand * 0.9)
        XCTAssertLessThan(press.squash, 0.8)
        XCTAssertEqual(press.expression.eyeL, .chevron)
        XCTAssertTrue(press.expression.impact)

        let sinking = p.pose(at: 5 + timing.successTotal - 0.01)
        XCTAssertGreaterThan(sinking.sink, 0.8)

        p.update(level: 0, at: 5 + timing.successTotal)
        XCTAssertEqual(p.stage, .hidden)
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

    func testFailureHoldsSurprisedBeforeSinking() {
        var p = listening()
        p.finish(.failed, at: 3)
        let hold = p.pose(at: 3 + timing.failHold / 2)
        XCTAssertEqual(hold.expression.bubble, .interrobang)
        XCTAssertEqual(hold.sink, 0)
        XCTAssertGreaterThan(p.pose(at: 3 + timing.failHold + timing.failSink * 0.9).sink, 0.5)
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
        XCTAssertEqual(entering.sink, 0)
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

final class TypoCompanionRoutingTests: XCTestCase {
    func testTypoPerformsOnlyTheWordlessPhases() {
        for phase in [FloatingBarPhase.preparing, .recording, .finishing, .processing] {
            XCTAssertTrue(TypoCompanionRouting.handles(phase), "\(phase)")
        }
        for phase in [FloatingBarPhase.hidden, .recovering, .done, .error] {
            XCTAssertFalse(TypoCompanionRouting.handles(phase), "\(phase)")
        }
    }

    func testCompanionIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "TypoCompanionRoutingTests-\(UUID().uuidString)")!
        XCTAssertFalse(TypoCompanionSettings.isEnabled(defaults))
        defaults.set(true, forKey: TypoCompanionSettings.enabledKey)
        XCTAssertTrue(TypoCompanionSettings.isEnabled(defaults))
    }

    @MainActor
    func testDisabledCompanionLeavesShowRequestsToTheBar() {
        let defaults = UserDefaults(suiteName: "TypoCompanionRoutingTests-\(UUID().uuidString)")!
        let state = AppState()
        state.startRecording(showsPanel: false)
        let controller = TypoCompanionController(state: state, defaults: defaults)
        XCTAssertFalse(controller.takeShowRequest())
        XCTAssertFalse(controller.isPerforming)
    }

    @MainActor
    func testEnabledCompanionTakesRecordingAndReleasesMessages() {
        let defaults = UserDefaults(suiteName: "TypoCompanionRoutingTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: TypoCompanionSettings.enabledKey)
        let state = AppState()
        state.startRecording(showsPanel: false)
        let controller = TypoCompanionController(state: state, defaults: defaults)
        XCTAssertTrue(controller.takeShowRequest())
        XCTAssertTrue(controller.isPerforming)

        state.showError("boom")
        XCTAssertFalse(controller.takeShowRequest(), "errors are shown by the bar")
        XCTAssertTrue(controller.isPerforming, "Typo is still sinking away")
    }
}

final class TypoCompanionLayoutTests: XCTestCase {
    func testTypoStandsOnTheCapsuleBottomEdge() {
        let capsule = NSRect(x: 600, y: 40, width: 220, height: 44)
        let frame = TypoCompanionLayout.panelFrame(forCapsule: capsule)
        let v = TypoGeometry.viewport
        let scale = frame.width / v.width
        let baseline = frame.minY + (v.maxY - TypoGeometry.baselineY) * scale
        XCTAssertEqual(baseline, capsule.minY, accuracy: 1)
        let bodyCentre = frame.minX + (978 - v.minX) * scale
        XCTAssertEqual(bodyCentre, capsule.midX, accuracy: 1)
    }
}
