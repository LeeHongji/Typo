import CoreGraphics
import XCTest
@testable import Type4Me

final class CaretLocatorTests: XCTestCase {
    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let sideScreen = CGRect(x: 1440, y: 100, width: 1920, height: 1080)

    func testAXRectsFlipToAppKitAgainstThePrimaryDisplay() {
        let ax = CGRect(x: 100, y: 200, width: 2, height: 18)
        let cocoa = CaretLocator.cocoaRect(fromAX: ax, primaryMaxY: 900)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 682, width: 2, height: 18))
    }

    func testFlipIsMeasuredFromThePrimaryDisplayOnASecondScreen() {
        let ax = CGRect(x: 2000, y: -150, width: 1, height: 20)
        let cocoa = CaretLocator.cocoaRect(fromAX: ax, primaryMaxY: 900)
        XCTAssertEqual(cocoa.minY, 1030)
        XCTAssertTrue(CaretLocator.isPlausibleCaret(cocoa, screens: [mainScreen, sideScreen]))
    }

    func testOnlyThinCaretsOnAScreenArePlausible() {
        let screens = [mainScreen]
        XCTAssertTrue(CaretLocator.isPlausibleCaret(CGRect(x: 300, y: 400, width: 1, height: 18), screens: screens))
        XCTAssertFalse(CaretLocator.isPlausibleCaret(CGRect(x: 300, y: 400, width: 1, height: 1), screens: screens), "too short")
        XCTAssertFalse(CaretLocator.isPlausibleCaret(CGRect(x: 300, y: 100, width: 1, height: 600), screens: screens), "a whole document")
        XCTAssertFalse(CaretLocator.isPlausibleCaret(CGRect(x: 100, y: 400, width: 900, height: 18), screens: screens), "a whole field")
        XCTAssertFalse(CaretLocator.isPlausibleCaret(CGRect(x: -500, y: 400, width: 1, height: 18), screens: screens), "off screen")
        XCTAssertFalse(CaretLocator.isPlausibleCaret(CGRect(x: CGFloat.nan, y: 400, width: 1, height: 18), screens: screens))
    }

    func testCollapsedCaretUsesTheDirectRectWhenItHasAPosition() {
        let rect = CaretLocator.collapsedCaret(direct: CGRect(x: 120, y: 300, width: 0, height: 17), characterBefore: nil)
        XCTAssertEqual(rect, CGRect(x: 120, y: 300, width: 1, height: 17))
    }

    func testCollapsedCaretFallsBackToTheEndOfThePreviousCharacter() {
        let rect = CaretLocator.collapsedCaret(
            direct: .zero,
            characterBefore: CGRect(x: 110, y: 300, width: 8, height: 17)
        )
        XCTAssertEqual(rect, CGRect(x: 118, y: 300, width: 1, height: 17))
        XCTAssertNil(CaretLocator.collapsedCaret(direct: nil, characterBefore: nil))
    }

    /// Regression: TextEdit reports a collapsed caret at the end of the text
    /// one line too high (y 137) while the character before it is on the
    /// caret's real line (y 150); Typo stood on the line above.
    func testCollapsedCaretTrustsThePreviousCharacterWhenTheyAgreeOnX() {
        let rect = CaretLocator.collapsedCaret(
            direct: CGRect(x: 363.19, y: 137, width: 0, height: 13),
            characterBefore: CGRect(x: 356.56, y: 150, width: 6.63, height: 13)
        )
        XCTAssertEqual(rect?.minY, 150)
        XCTAssertEqual(rect!.minX, 363.19, accuracy: 0.01)
    }

    func testCollapsedCaretAfterALineBreakKeepsTheDirectRect() {
        let rect = CaretLocator.collapsedCaret(
            direct: CGRect(x: 191, y: 163, width: 0, height: 13),
            characterBefore: CGRect(x: 356, y: 150, width: 7, height: 13)
        )
        XCTAssertEqual(rect, CGRect(x: 191, y: 163, width: 1, height: 13))
    }

    /// Regression: at the very start of a TextEdit document the collapsed
    /// caret is also reported one line too high (y 118); the first character
    /// is on the real line (y 134).
    func testCollapsedCaretTrustsTheNextCharacterWhenTheyAgreeOnX() {
        let rect = CaretLocator.collapsedCaret(
            direct: CGRect(x: 191, y: 118, width: 0, height: 16),
            characterBefore: nil,
            characterAfter: CGRect(x: 191, y: 134, width: 11, height: 16)
        )
        XCTAssertEqual(rect, CGRect(x: 191, y: 134, width: 1, height: 16))
    }

    func testCaretAtTheStartUsesTheCharacterAfterIt() {
        let rect = CaretLocator.collapsedCaret(
            direct: CGRect(x: 0, y: 0, width: 0, height: 0),
            characterBefore: nil,
            characterAfter: CGRect(x: 322, y: 192, width: 8, height: 15)
        )
        XCTAssertEqual(rect, CGRect(x: 322, y: 192, width: 1, height: 15))
    }

    /// Regression: an empty Codex box reports its whole frame as the caret
    /// range, and an empty Chrome textarea reports nothing; the caret is at
    /// the start of the box, not at its right edge.
    func testEmptyBoxCaretSitsAtItsStart() {
        let codex = CaretLocator.fieldStartCaret(frame: CGRect(x: 381, y: 803, width: 453, height: 60))!
        XCTAssertEqual(codex.minX, 381, accuracy: 8)
        XCTAssertEqual(codex.minY, 806, accuracy: 8)
        let chrome = CaretLocator.fieldStartCaret(frame: CGRect(x: 309, y: 179, width: 444, height: 119))!
        XCTAssertEqual(chrome.minX, 322, accuracy: 8)
        XCTAssertEqual(chrome.minY, 192, accuracy: 8)
        let oneLine = CaretLocator.fieldStartCaret(frame: CGRect(x: 100, y: 100, width: 300, height: 22))!
        XCTAssertEqual(oneLine.midY, 111, accuracy: 0.01, "a one-line box centres the caret")
        XCTAssertNil(CaretLocator.fieldStartCaret(frame: CGRect(x: 0, y: 0, width: 1400, height: 900)), "a whole window is not a box")
    }
}

final class CaretLineEndTests: XCTestCase {
    // TextEdit, caret after the third character of "第一行文字用于测试光标位置".
    private let caret = CGRect(x: 224, y: 134, width: 1, height: 16)

    func testTextAfterTheCaretEndsAtTheLastCharacterOfTheLine() {
        XCTAssertEqual(CaretLocator.textEnd(caret: caret, lineEnd: CGRect(x: 323, y: 134, width: 11, height: 16)), 334)
    }

    func testNoTextEndAtTheEndOfTheLine() {
        XCTAssertNil(CaretLocator.textEnd(caret: caret, lineEnd: CGRect(x: 213, y: 134, width: 11, height: 16)))
        XCTAssertNil(CaretLocator.textEnd(caret: caret, lineEnd: nil))
    }

    func testBoundsOnAnotherLineOrSpanningSeveralAreIgnored() {
        XCTAssertNil(CaretLocator.textEnd(caret: caret, lineEnd: CGRect(x: 400, y: 152, width: 11, height: 16)), "the next line")
        XCTAssertNil(CaretLocator.textEnd(caret: caret, lineEnd: CGRect(x: 181, y: 118, width: 600, height: 64)), "a whole paragraph")
    }
}

final class TypoCaretLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func location(x: CGFloat, y: CGFloat, pid: pid_t = 42) -> CaretLocation {
        CaretLocation(rect: CGRect(x: x, y: y, width: 1, height: 18), tier: .boundsForRange, processIdentifier: pid)
    }

    func testTypoIsAboutTwoLinesTallWithinLimits() {
        XCTAssertEqual(TypoCaretLayout.bodyHeight(forCaretHeight: 18), 32.4, accuracy: 0.01)
        XCTAssertEqual(TypoCaretLayout.bodyHeight(forCaretHeight: 6), 22)
        XCTAssertEqual(TypoCaretLayout.bodyHeight(forCaretHeight: 60), 44)
    }

    func testTypoStandsJustAfterTheCaretOnItsBottomEdge() {
        let caret = CGRect(x: 300, y: 400, width: 1, height: 18)
        let feet = TypoCaretLayout.feet(beside: caret, bodyHeight: 32, screen: screen)
        XCTAssertGreaterThan(feet.x, caret.maxX)
        XCTAssertEqual(feet.y, caret.minY)
    }

    func testTypoMovesBeforeTheCaretAtTheRightEdgeOfTheScreen() {
        let caret = CGRect(x: 1420, y: 400, width: 1, height: 18)
        let feet = TypoCaretLayout.feet(beside: caret, bodyHeight: 32, screen: screen)
        XCTAssertLessThan(feet.x, caret.minX)
    }

    func testTypoStandsAfterTheRestOfTheLineRatherThanOnIt() {
        let caret = CGRect(x: 300, y: 400, width: 1, height: 18)
        let feet = TypoCaretLayout.feet(beside: caret, textEnd: 520, bodyHeight: 32, screen: screen)
        XCTAssertGreaterThan(feet.x - 32 * 0.75, 520, "clear of the words after the caret")
        XCTAssertEqual(feet.y, caret.minY)
        XCTAssertEqual(TypoCaretLayout.gaze(feet: feet, caret: caret), -1, "the new text appears on its left")
    }

    func testTypoGoesBeforeTheCaretWhenTheLineRunsToTheScreenEdge() {
        let caret = CGRect(x: 300, y: 400, width: 1, height: 18)
        let feet = TypoCaretLayout.feet(beside: caret, textEnd: 1420, bodyHeight: 32, screen: screen)
        XCTAssertLessThan(feet.x, caret.minX)
        XCTAssertEqual(TypoCaretLayout.gaze(feet: feet, caret: caret), 1)
    }

    func testLeapsOnlyWhenTheCaretMovedInTheSameApp() {
        let start = location(x: 300, y: 400)
        let moved = location(x: 520, y: 400)
        XCTAssertEqual(TypoCaretLayout.leapTarget(start: start, after: moved, frontmost: 42), moved)
        XCTAssertNil(TypoCaretLayout.leapTarget(start: start, after: start, frontmost: 42), "the app has not reported the new text")
        XCTAssertNil(TypoCaretLayout.leapTarget(start: start, after: moved, frontmost: 7), "the user switched apps")
        XCTAssertNil(TypoCaretLayout.leapTarget(start: start, after: location(x: 520, y: 400, pid: 9), frontmost: 42))
        XCTAssertNil(TypoCaretLayout.leapTarget(start: start, after: nil, frontmost: 42))
    }

    func testDesignOffsetPointsDownForALowerLine() {
        let offset = TypoCaretLayout.designOffset(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 300, y: 480), scale: 0.05)
        XCTAssertEqual(offset.width, 4000, accuracy: 0.001)
        XCTAssertEqual(offset.height, 400, accuracy: 0.001)
    }

    func testPanelHoldsBothStandsAndTheArc() {
        let a = CGPoint(x: 100, y: 500), b = CGPoint(x: 400, y: 460)
        let frame = TypoCaretLayout.panelFrame(feet: [a, b], bodyHeight: 30, arc: 40)
        XCTAssertLessThanOrEqual(frame.minX, a.x - 30)
        XCTAssertGreaterThanOrEqual(frame.maxX, b.x + 30)
        XCTAssertLessThanOrEqual(frame.minY, b.y - 10)
        XCTAssertGreaterThanOrEqual(frame.maxY, a.y + 30 + 40)
    }
}
