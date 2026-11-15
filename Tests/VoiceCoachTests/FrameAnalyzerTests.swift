import XCTest
@testable import VoiceCoach

final class FrameAnalyzerTests: XCTestCase {
    func testLevelOfFullScaleSineIsMinus3dB() {
        var analyzer = FrameAnalyzer(tuning: .default)
        let sine = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let frames = analyzer.push(sine)
        XCTAssertEqual(frames.count, 100)
        for frame in frames.dropFirst(3) { XCTAssertEqual(frame.db, -3.01, accuracy: 0.2) }
    }

    func testSilenceIsFloor() {
        var analyzer = FrameAnalyzer(tuning: .default)
        let frames = analyzer.push([Float](repeating: 0, count: 3200))
        XCTAssertEqual(frames.map(\.db), [Double](repeating: -120, count: 20))
    }

    func testFramesAreNumberedAcrossPushes() {
        var analyzer = FrameAnalyzer(tuning: .default)
        let first = analyzer.push([Float](repeating: 0.1, count: 250))
        let second = analyzer.push([Float](repeating: 0.1, count: 250))
        XCTAssertEqual(first.map(\.index), [0])
        XCTAssertEqual(second.map(\.index), [1, 2])
    }

    func testWindowEndsAtFrame() {
        var analyzer = FrameAnalyzer(tuning: .default)
        let ramp = (0..<1600).map { Float($0) }
        _ = analyzer.push(ramp)
        let window = analyzer.window(endingAt: 4, length: 100)
        XCTAssertEqual(window.map(Array.init), (700..<800).map(Float.init))
        XCTAssertNil(analyzer.window(endingAt: 20, length: 100))
    }

    func testRollingWindowMedian() {
        var window = RollingWindow(capacity: 3)
        for v in [5.0, 1, 9, 3] { window.append(v) }
        XCTAssertEqual(window.values, [1, 9, 3])
        XCTAssertEqual(window.median, 3)
        XCTAssertEqual(median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(median([]))
    }
}
