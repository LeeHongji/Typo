import AppKit
import XCTest
@testable import Type4Me

final class DictationDeliveryTests: XCTestCase {
    func testWordsAloneArePastedUnchanged() {
        XCTAssertEqual(DictationDelivery.text(speech: "你好", quotes: []), "你好")
    }

    func testQuotesGoBeforeTheWordsEachMarkedAndFollowedByABlankLine() {
        let text = DictationDelivery.text(speech: "这里为什么报错？", quotes: ["let x = 1\nlet y = x / 0", "Division by zero"])
        XCTAssertEqual(text, "> let x = 1\n> let y = x / 0\n\n> Division by zero\n\n这里为什么报错？")
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
    private let target: CGWindowID = 100
    private let elsewhere = (id: CGWindowID(200), owner: pid_t(5))

    func testADragOrMultiClickSelectsTextToQuote() {
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 40, y: 0), clickCount: 1, window: elsewhere, ownPID: own, targetWindowID: target), .selection)
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 2, window: elsewhere, ownPID: own, targetWindowID: target), .selection, "double-click selects a word")
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 3, window: elsewhere, ownPID: own, targetWindowID: target), .selection, "triple-click selects a line")
    }

    func testASingleClickOnAnotherWindowAsksForItsScreenshot() {
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 2, y: 1), clickCount: 1, window: elsewhere, ownPID: own, targetWindowID: target), .windowClick(200))
    }

    func testClicksOnTheTargetWindowOrOurOwnOrNothingDoNotCount() {
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 1, window: (id: target, owner: 5), ownPID: own, targetWindowID: target), .none)
        XCTAssertEqual(C.classify(down: .zero, up: CGPoint(x: 50, y: 0), clickCount: 1, window: (id: 300, owner: own), ownPID: own, targetWindowID: target), .none)
        XCTAssertEqual(C.classify(down: .zero, up: .zero, clickCount: 1, window: nil, ownPID: own, targetWindowID: target), .none)
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
