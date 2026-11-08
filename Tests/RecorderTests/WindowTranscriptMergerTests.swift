import XCTest
@testable import Recorder

final class WindowTranscriptMergerTests: XCTestCase {
    private func token(_ text: String, _ start: Double) -> TokenLineSegmenter.Token {
        TokenLineSegmenter.Token(text: text, start: start, end: start + 0.08)
    }

    func testConfirmedUpdateCommitsAllButTheLastWord() throws {
        var merger = WindowTranscriptMerger()
        let line = try XCTUnwrap(merger.absorb([token(" Hel", 1.0), token("lo", 1.08), token(",", 1.16),
                                                token(" big", 1.4), token(" world", 1.8)], confirmed: true))
        XCTAssertEqual(line.text, "Hello, big")
        XCTAssertEqual(line.start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(line.end, 1.48, accuracy: 1e-9)
        XCTAssertEqual(merger.tail?.text, "world")
        XCTAssertEqual(merger.tail?.start ?? 0, 1.8, accuracy: 1e-9)
    }

    func testSeamWordReEmittedAtTheSameStartIsNotDuplicated() throws {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" one", 1.0), token(" two", 2.0)], confirmed: true)
        let line = try XCTUnwrap(merger.absorb([token(" two", 2.0), token(" three", 3.0), token(" four", 4.0)],
                                               confirmed: true))
        XCTAssertEqual(line.text, "two three")
        XCTAssertEqual(merger.finish()?.text, "four")
    }

    func testSeamWordReEmittedEarlierReplacesEveryLaterPendingWord() throws {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" one", 1.0), token(" tw", 2.0), token("o", 2.08)], confirmed: false)
        _ = merger.absorb([token(" two", 1.92), token(" three", 3.0)], confirmed: false)
        XCTAssertEqual(merger.finish()?.text, "one two three")
    }

    func testFragmentRedecodedSlightlyLaterIsRetired() throws {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" and", 9.0), token(" an", 10.0)], confirmed: true)
        let line = try XCTUnwrap(merger.absorb([token(" analy", 10.16), token("zing", 10.24), token(" data", 11.0)],
                                               confirmed: true))
        XCTAssertEqual(line.text, "analyzing")
        XCTAssertEqual(merger.finish()?.text, "data")
    }

    func testGenuineRepetitionIsKept() {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" the", 5.0)], confirmed: true)
        _ = merger.absorb([token(" the", 5.24), token(" end", 5.6)], confirmed: false)
        XCTAssertEqual(merger.finish()?.text, "the the end")
    }

    func testUnconfirmedWindowsAccumulateAndAreFoldedIntoTheNextConfirmedLine() throws {
        var merger = WindowTranscriptMerger()
        XCTAssertNil(merger.absorb([token(" a", 1.0), token(" b", 2.0)], confirmed: false))
        XCTAssertNil(merger.absorb([token(" c", 12.0), token(" d", 13.0)], confirmed: false))
        XCTAssertEqual(merger.tail?.text, "a b c d")
        let line = try XCTUnwrap(merger.absorb([token(" e", 23.0), token(" f", 24.0)], confirmed: true))
        XCTAssertEqual(line.text, "a b c d e")
        XCTAssertEqual(line.start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(merger.tail?.text, "f")
    }

    func testEmptyConfirmedUpdateKeepsTheHeldWord() {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" only", 1.0)], confirmed: true)
        XCTAssertNil(merger.absorb([], confirmed: true))
        XCTAssertEqual(merger.tail?.text, "only")
    }

    func testLeadingContinuationPieceExtendsTheLastWord() {
        var merger = WindowTranscriptMerger()
        _ = merger.absorb([token(" box", 1.0)], confirmed: false)
        _ = merger.absorb([token("es", 1.08), token(" here", 1.5)], confirmed: false)
        XCTAssertEqual(merger.finish()?.text, "boxes here")
    }

    func testFinishWithNothingPendingReturnsNil() {
        var merger = WindowTranscriptMerger()
        XCTAssertNil(merger.finish())
        XCTAssertNil(merger.tail)
        _ = merger.absorb([token(" x", 1.0)], confirmed: false)
        XCTAssertEqual(merger.finish()?.text, "x")
        XCTAssertNil(merger.finish())
    }
}
