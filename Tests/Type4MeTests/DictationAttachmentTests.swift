import AppKit
import XCTest
@testable import Type4Me

final class DictationDeliveryTests: XCTestCase {
    func testWordsAloneArePastedUnchanged() {
        XCTAssertEqual(DictationDelivery.text(speech: "你好", quotes: []), "你好")
    }

    private func q(_ text: String, after prefix: String = "", at fraction: Double? = nil) -> PlacedQuote {
        PlacedQuote(text: text, spokenPrefix: prefix, spokenFraction: fraction)
    }

    func testAShortQuoteGoesInsideTheSentenceWhereTheUserWasTalking() {
        XCTAssertEqual(
            DictationDelivery.text(speech: "我觉得这句写得不好。", quotes: [q("The quick brown fox", after: "我觉得这句")]),
            "我觉得这句“The quick brown fox”写得不好。"
        )
        XCTAssertEqual(
            DictationDelivery.text(speech: "我觉得这句写得不好。", quotes: [q("春眠不觉晓", after: "我觉得这句")]),
            "我觉得这句「春眠不觉晓」写得不好。"
        )
    }

    func testTheRecognizerRevisingAndAddingPunctuationStillFindsThePlace() {
        // Heard while talking: no punctuation, a word later revised.
        let text = DictationDelivery.text(
            speech: "Look at this line, and tell me why it fails.",
            quotes: [q("let y = x / 0", after: "look at this line")]
        )
        XCTAssertEqual(text, "Look at this line “let y = x / 0”, and tell me why it fails.")
    }

    func testAQuoteNeverSplitsAWord() {
        let text = DictationDelivery.text(speech: "Please explain the function here", quotes: [q("f(x)", after: "please explain the func")])
        XCTAssertEqual(text, "Please explain the function “f(x)” here")
    }

    func testPunctuationAlreadySaidStaysBeforeTheQuote() {
        let text = DictationDelivery.text(speech: "看这段：写得好吗", quotes: [q("一段文字", after: "看这段：")])
        XCTAssertEqual(text, "看这段：「一段文字」写得好吗")
    }

    func testALongOrMultiLineQuoteIsItsOwnMarkedBlock() {
        let text = DictationDelivery.text(
            speech: "这里为什么报错？我看不懂",
            quotes: [q("let x = 1\nlet y = x / 0", after: "这里为什么报错")]
        )
        XCTAssertEqual(text, "这里为什么报错？\n\n> let x = 1\n> let y = x / 0\n\n我看不懂")
        XCTAssertFalse(DictationDelivery.isInline(String(repeating: "a", count: DictationDelivery.inlineQuoteLimit + 1)))
    }

    func testAQuoteTakenBeforeAnyWordsGoesFirstAndOneAfterThemGoesLast() {
        XCTAssertEqual(DictationDelivery.text(speech: "帮我看看", quotes: [q("报错信息")]), "「报错信息」帮我看看")
        XCTAssertEqual(DictationDelivery.text(speech: "帮我看看", quotes: [q("报错信息", after: "帮我看看")]), "帮我看看「报错信息」")
        XCTAssertEqual(
            DictationDelivery.text(speech: "帮我看看", quotes: [q("a\nb")]),
            "> a\n> b\n\n帮我看看"
        )
        XCTAssertEqual(DictationDelivery.text(speech: "", quotes: [q("只有引用")]), "「只有引用」")
    }

    func testWithNothingHeardYetTheTimeOfTheQuoteGivesThePlace() {
        // Batch recognition shows no words while talking.
        let text = DictationDelivery.text(speech: "第一句话。第二句话。", quotes: [q("中间", at: 0.5)])
        XCTAssertEqual(text, "第一句话。「中间」第二句话。")
    }

    func testARewrittenTextFallsBackToAboutTheSamePlace() {
        // A mode rewrote the words; the heard words are not in them.
        let speech = "Please review the attached code carefully."
        let index = DictationDelivery.insertionIndex(for: q("x", after: "um can you check"), in: speech)
        XCTAssertGreaterThan(speech.distance(from: speech.startIndex, to: index), 0)
        XCTAssertLessThan(speech.distance(from: speech.startIndex, to: index), speech.count)
    }

    func testQuotesKeepTheOrderTheyWereTaken() {
        let text = DictationDelivery.text(speech: "对比一下", quotes: [q("甲", after: "对比"), q("乙", after: "对比")])
        XCTAssertEqual(text, "对比「甲」「乙」一下")
    }

    func testTerminalsGetPathsAndOtherAppsGetImages() {
        XCTAssertTrue(DictationDelivery.pastesPaths(into: "com.apple.Terminal"))
        XCTAssertTrue(DictationDelivery.pastesPaths(into: "com.googlecode.iterm2"))
        XCTAssertTrue(DictationDelivery.pastesPaths(into: "dev.warp.Warp-Stable"))
        XCTAssertTrue(DictationDelivery.pastesPaths(into: "com.mitchellh.ghostty"))
        XCTAssertFalse(DictationDelivery.pastesPaths(into: "com.anthropic.claudefordesktop"))
        XCTAssertFalse(DictationDelivery.pastesPaths(into: "com.google.Chrome"))
        XCTAssertFalse(DictationDelivery.pastesPaths(into: nil))
    }

    func testAPathWithSpacesIsOneShellWord() {
        XCTAssertEqual(DictationDelivery.shellQuoted("/tmp/a.png"), "/tmp/a.png")
        XCTAssertEqual(
            DictationDelivery.shellQuoted("/Users/me/Library/Caches/Type 4/it's.png"),
            "'/Users/me/Library/Caches/Type 4/it'\\''s.png'"
        )
    }

    @MainActor
    func testALongQuoteIsCutAndTrimmed() {
        XCTAssertEqual(DictationAttachments.trimmedQuote("  hi \n"), "hi")
        let long = String(repeating: "字", count: DictationAttachments.maxQuoteCharacters + 50)
        let cut = DictationAttachments.trimmedQuote(long)
        XCTAssertEqual(cut.count, DictationAttachments.maxQuoteCharacters + 1)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testTheTargetGoneMessageIsInBothLanguages() {
        let key = "tf_language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("zh", forKey: key)
        XCTAssertEqual(InjectionOutcome.copiedTargetGone.completionMessage, "已复制，原输入框不在了")
        UserDefaults.standard.set("en", forKey: key)
        XCTAssertEqual(InjectionOutcome.copiedTargetGone.completionMessage, "Copied — the original box is gone")
    }
}

final class DictationDestinationPlanTests: XCTestCase {
    func testNeverLeftPastesAsBefore() {
        XCTAssertEqual(DictationDestination.plan(isTerminated: false, frontmostPID: 7, targetPID: 7, windowStillFocused: true), .pasteHere)
        XCTAssertEqual(DictationDestination.plan(isTerminated: false, frontmostPID: 7, targetPID: 7, windowStillFocused: nil), .pasteHere)
        XCTAssertEqual(
            DictationDestination.plan(isTerminated: false, frontmostPID: 7, targetPID: 7, windowStillFocused: true, elementStillFocused: nil),
            .pasteHere, "a box the app rebuilt can't be asked; that is not leaving"
        )
    }

    func testAnotherAppOrWindowInFrontMeansBringingTheTargetBack() {
        XCTAssertEqual(DictationDestination.plan(isTerminated: false, frontmostPID: 9, targetPID: 7, windowStillFocused: true), .bringBack)
        XCTAssertEqual(DictationDestination.plan(isTerminated: false, frontmostPID: nil, targetPID: 7, windowStillFocused: nil), .bringBack)
        XCTAssertEqual(DictationDestination.plan(isTerminated: false, frontmostPID: 7, targetPID: 7, windowStillFocused: false), .bringBack)
    }

    func testTheBoxLosingFocusInItsOwnWindowIsRefocused() {
        XCTAssertEqual(
            DictationDestination.plan(isTerminated: false, frontmostPID: 7, targetPID: 7, windowStillFocused: true, elementStillFocused: false),
            .refocus
        )
    }

    func testAQuitAppIsGone() {
        XCTAssertEqual(DictationDestination.plan(isTerminated: true, frontmostPID: 7, targetPID: 7, windowStillFocused: true), .gone)
    }
}

final class DictationPointerGestureTests: XCTestCase {
    private typealias C = DictationPointerCollector
    private let own: pid_t = 1
    private let elsewhere = (id: CGWindowID(200), owner: pid_t(5))

    func testADragOrMultiClickSelectsTextToQuote() {
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 40, y: 0), clickCount: 1, window: elsewhere, ownPID: own), .selection)
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 2, window: elsewhere, ownPID: own), .selection, "double-click selects a word")
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 3, window: elsewhere, ownPID: own), .selection, "triple-click selects a line")
    }

    func testAPlainClickIsNoQuote() {
        // Shooting a window is the shutter's job; a click no longer shoots by itself.
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 2, y: 1), clickCount: 1, window: elsewhere, ownPID: own), .none)
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 50, y: 0), clickCount: 1, window: (id: 300, owner: own), ownPID: own), .none)
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 50, y: 0), clickCount: 1, window: nil, ownPID: own), .none)
    }
}

final class DictationArmingTests: XCTestCase {
    func testTheWindowBroughtForwardIsArmedOnlyAfterItStaysAMoment() {
        var arming = DictationArming()
        XCTAssertNil(arming.update(front: 7, at: 10), "the click that brought it forward does not shoot it")
        XCTAssertNil(arming.update(front: 7, at: 10.2))
        XCTAssertEqual(arming.update(front: 7, at: 10.31), 7)
    }

    func testNoWindowThatMayBeShotArmsNothing() {
        var arming = DictationArming()
        XCTAssertNil(arming.update(front: nil, at: 0))
        XCTAssertNil(arming.update(front: nil, at: 5))
    }

    func testSwitchingWindowsStartsTheWaitAgain() {
        var arming = DictationArming()
        _ = arming.update(front: 7, at: 0)
        XCTAssertEqual(arming.update(front: 7, at: 1), 7)
        XCTAssertNil(arming.update(front: 8, at: 1.1))
        XCTAssertEqual(arming.update(front: 8, at: 1.5), 8)
    }

    func testAShotWindowRestsUntilTheUserGoesAwayAndComesBack() {
        var arming = DictationArming()
        _ = arming.update(front: 7, at: 0)
        XCTAssertEqual(arming.update(front: 7, at: 1), 7)
        arming.shot(7)
        XCTAssertNil(arming.update(front: 7, at: 2), "clicks there are ordinary now")
        XCTAssertNil(arming.update(front: 7, at: 9))
        _ = arming.update(front: 8, at: 10)
        _ = arming.update(front: 7, at: 11)
        XCTAssertEqual(arming.update(front: 7, at: 11.4), 7)
    }
}

final class DictationShutterTests: XCTestCase {
    private let p = CGPoint(x: 100, y: 100)

    func testAPlainClickIsTakenForTheShutterAndShotWhenNoSecondClickFollows() {
        var s = DictationShutter()
        XCTAssertEqual(s.down(at: p, time: 0, clickState: 1, shootable: true), [.hold])
        XCTAssertEqual(s.up(at: p, time: 0.1), [.hold, .wait])
        XCTAssertEqual(s.timeout(), [.shoot])
        XCTAssertEqual(s.phase, .idle)
    }

    func testADragGivesThePressBackSoTextCanBeSelected() {
        var s = DictationShutter()
        _ = s.down(at: p, time: 0, clickState: 1, shootable: true)
        XCTAssertEqual(s.drag(to: CGPoint(x: 102, y: 101)), [.drop], "a wobble is not a drag yet")
        XCTAssertEqual(s.drag(to: CGPoint(x: 110, y: 100)), [.hold, .flush])
        XCTAssertEqual(s.drag(to: CGPoint(x: 140, y: 100)), [.pass])
        XCTAssertEqual(s.up(at: CGPoint(x: 140, y: 100), time: 0.4), [.pass])
        XCTAssertEqual(s.timeout(), [])
    }

    func testADoubleClickGivesBothClicksBack() {
        var s = DictationShutter()
        _ = s.down(at: p, time: 0, clickState: 1, shootable: true)
        _ = s.up(at: p, time: 0.08)
        XCTAssertEqual(s.down(at: p, time: 0.2, clickState: 2, shootable: true), [.hold, .flush])
        XCTAssertEqual(s.up(at: p, time: 0.25), [.pass])
        XCTAssertEqual(s.down(at: p, time: 0.35, clickState: 3, shootable: true), [.pass], "a triple click goes through")
        XCTAssertEqual(s.timeout(), [])
    }

    func testALongPressIsTheUserWorkingInTheWindow() {
        var s = DictationShutter()
        _ = s.down(at: p, time: 0, clickState: 1, shootable: true)
        XCTAssertEqual(s.up(at: p, time: 0.8), [.hold, .flush])
    }

    func testAClickThatMayNotShootPassesUntouched() {
        var s = DictationShutter()
        XCTAssertEqual(s.down(at: p, time: 0, clickState: 1, shootable: false), [.pass])
        XCTAssertEqual(s.up(at: p, time: 0.1), [.pass])
        XCTAssertEqual(s.timeout(), [])
    }

    func testANewClickBeforeTheWaitEndsShootsTheFirstThenIsJudgedAlone() {
        var s = DictationShutter()
        _ = s.down(at: p, time: 0, clickState: 1, shootable: true)
        _ = s.up(at: p, time: 0.05)
        XCTAssertEqual(s.down(at: CGPoint(x: 600, y: 600), time: 0.2, clickState: 1, shootable: false), [.shoot, .pass])
    }

    func testStoppingMidClickGivesTheClickBack() {
        var s = DictationShutter()
        _ = s.down(at: p, time: 0, clickState: 1, shootable: true)
        XCTAssertEqual(s.cancel(), [.flush])
        XCTAssertEqual(s.cancel(), [])
    }
}

final class RegionCaptureTests: XCTestCase {
    func testTheBoxIsTheRectangleBetweenTheCornersAndTooSmallIsACancel() {
        XCTAssertEqual(RegionCaptureOverlay.box(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20)), CGRect(x: 10, y: 20, width: 40, height: 60))
        XCTAssertNil(RegionCaptureOverlay.box(from: .zero, to: CGPoint(x: 3, y: 40)))
    }

    func testTheCaptureCopyIsInBothLanguages() {
        let key = "tf_language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("zh", forKey: key)
        XCTAssertEqual(AttachmentCopy.area, "框选")
        XCTAssertEqual(AttachmentCopy.regionHint, "拖动框选要截的区域 · Esc 取消")
        XCTAssertEqual(AttachmentCopy.clickHint, "点击窗口截图 · ⌘+点击照常操作")
        UserDefaults.standard.set("en", forKey: key)
        XCTAssertEqual(AttachmentCopy.area, "Area")
        XCTAssertEqual(AttachmentCopy.regionHint, "Drag to capture an area · Esc to cancel")
        XCTAssertEqual(AttachmentCopy.clickHint, "Click a window to capture · ⌘-click to use it")
    }
}

final class TypoCarryingTests: XCTestCase {
    private func listening() -> TypoPerformance {
        var p = TypoPerformance(peek: .caret)
        p.begin(at: 0)
        p.update(level: 0.05, at: 0.5)
        return p
    }

    func testCatchingACardRaisesTheArmsWithSmilingEyesAndShowsTheCount() {
        var p = listening()
        p.carrying(1, at: 1)
        p.update(level: 0.05, at: 1.1)
        let pose = p.pose(at: 1.1)
        XCTAssertEqual(p.motion.cue, .caught)
        XCTAssertTrue(pose.expression.armL.up && pose.expression.armR.up)
        XCTAssertEqual(pose.expression.eyeL, .happy)
        XCTAssertEqual(pose.badge, 1)
        p.carrying(2, at: 2)
        XCTAssertEqual(p.pose(at: 2).badge, 2)
    }

    func testRemovingAChipIsNotACatch() {
        var p = listening()
        p.carrying(2, at: 1)
        p.update(level: 0.05, at: 2)
        XCTAssertNil(p.motion.cue)
        p.carrying(1, at: 2.1)
        XCTAssertNil(p.motion.cue)
        XCTAssertEqual(p.pose(at: 2.1).badge, 1)
    }

    func testTheCardsRideTheLeapAndGoInWithTheLanding() {
        var p = listening()
        p.carrying(2, at: 1)
        p.think(at: 2)
        p.finish(.leap(CGSize(width: 2000, height: 0)), at: 3)
        let timing = TypoPerformance.Timing.standard
        let landAt = 3 + timing.leapCrouch + p.leap.air
        XCTAssertEqual(p.pose(at: landAt - 0.05).badgeOpacity, 1, "still carried mid-air")
        XCTAssertEqual(p.pose(at: landAt - 0.05).badge, 2)
        XCTAssertEqual(p.pose(at: landAt + timing.leapPress).badgeOpacity, 0, accuracy: 1e-6, "gone into the text on landing")
    }

    func testANewDictationStartsEmptyHanded() {
        var p = listening()
        p.carrying(3, at: 1)
        p.finish(.success, at: 2)
        p.update(level: 0, at: 3)
        p.begin(at: 4)
        XCTAssertEqual(p.pose(at: 4).badge, 0)
    }
}

final class DictationClickThroughTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testTheDocksSeeThroughScreenOverlayIsNotWhatTheUserClicks() {
        // The Dock keeps a layer-20 window over the whole screen.
        XCTAssertTrue(DictationPointerTap.isClickThroughOverlay(layer: 20, bounds: screen, screens: [screen]))
    }

    func testMenusAndFullScreenAppsAreWhatTheUserClicks() {
        XCTAssertFalse(DictationPointerTap.isClickThroughOverlay(layer: 101, bounds: CGRect(x: 300, y: 24, width: 220, height: 300), screens: [screen]))
        XCTAssertFalse(DictationPointerTap.isClickThroughOverlay(layer: 0, bounds: screen, screens: [screen]))
    }
}
