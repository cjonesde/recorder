import XCTest
@testable import Recorder

final class TokenLineSegmenterTests: XCTestCase {
    private func t(_ text: String, _ start: Double, _ end: Double) -> TokenLineSegmenter.Token {
        TokenLineSegmenter.Token(text: text, start: start, end: end)
    }

    func testSplitsAtPauseOfAtLeastPointEightSeconds() {
        var s = TokenLineSegmenter()
        let lines = s.confirm([t("Guten", 0, 0.4), t("Morgen", 0.4, 0.9), t("wir", 1.7, 1.9)])
        XCTAssertEqual(lines.map(\.text), ["Guten Morgen"])
        XCTAssertEqual(lines[0].start, 0); XCTAssertEqual(lines[0].end, 0.9)
    }

    func testDoesNotSplitAtPointSevenSeconds() {
        var s = TokenLineSegmenter()
        XCTAssertTrue(s.confirm([t("a", 0, 0.2), t("b", 0.9, 1.0)]).isEmpty)
    }

    func testSplitsAtSentenceEndAndKeepsTail() {
        var s = TokenLineSegmenter()
        let tokens = [t("Hello.", 0, 0.5), t("How", 0.6, 0.8), t("are", 0.8, 1.0)]
        XCTAssertEqual(s.confirm(tokens).map(\.text), ["Hello."])
        XCTAssertEqual(s.tail(tokens), "How are")
    }

    func testTokensBeforeConfirmedBoundaryAreNeverEmittedAgain() {
        var s = TokenLineSegmenter()
        _ = s.confirm([t("Hello.", 0, 0.5)])
        let again = s.confirm([t("Hello.", 0, 0.5), t("inserted", 0.2, 0.3), t("Bye.", 2, 2.4)])
        XCTAssertEqual(again.map(\.text), ["Bye."])
    }

    func testJoinsSentencePiecesByWordBoundaryMarker() {
        var s = TokenLineSegmenter()
        let tokens = [t("▁Gu", 0, 0.08), t("ten", 0.08, 0.16), t("▁Mor", 0.24, 0.32), t("gen", 0.32, 0.4),
                      t(".", 0.4, 0.48), t("▁Wie", 0.56, 0.64), t("▁geht", 0.64, 0.72)]
        XCTAssertEqual(s.confirm(tokens).map(\.text), ["Guten Morgen."])
        XCTAssertEqual(s.confirmedThrough, 0.48)
        XCTAssertEqual(s.tail(tokens), "Wie geht")
    }

    func testStandaloneBoundaryMarkerDoesNotProduceAnEmptyWord() {
        var s = TokenLineSegmenter()
        let tokens = [t("▁Hallo", 0, 0.08), t("▁", 0.08, 0.16), t("▁Welt", 0.16, 0.24), t("!", 0.24, 0.32)]
        XCTAssertEqual(s.confirm(tokens).map(\.text), ["Hallo Welt!"])
    }

    func testSentenceEndInsideAWordDoesNotSplit() {
        var s = TokenLineSegmenter()
        let tokens = [t("▁3", 0, 0.08), t(".", 0.08, 0.16), t("5", 0.16, 0.24), t("▁Prozent", 0.24, 0.32)]
        XCTAssertTrue(s.confirm(tokens).isEmpty)
        XCTAssertEqual(s.tail(tokens), "3.5 Prozent")
    }

    func testEmitsOneLinePerBoundaryUpToTheLastOne() {
        var s = TokenLineSegmenter()
        let tokens = [t("Ja.", 0, 0.3), t("Gut.", 0.4, 0.7), t("Und", 0.8, 1.0)]
        let lines = s.confirm(tokens)
        XCTAssertEqual(lines.map(\.text), ["Ja.", "Gut."])
        XCTAssertEqual(lines.map(\.start), [0, 0.4])
        XCTAssertEqual(lines.map(\.end), [0.3, 0.7])
        XCTAssertEqual(s.confirmedThrough, 0.7)
    }

    func testFinishConfirmsTheTail() {
        var s = TokenLineSegmenter()
        let tokens = [t("Hello.", 0, 0.5), t("How", 0.6, 0.8), t("are", 0.8, 1.0)]
        _ = s.confirm(tokens)
        let rest = s.finish(tokens)
        XCTAssertEqual(rest.map(\.text), ["How are"])
        XCTAssertEqual(rest.first?.start, 0.6)
        XCTAssertEqual(rest.first?.end, 1.0)
        XCTAssertEqual(s.tail(tokens), "")
    }
}
