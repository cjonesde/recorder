import XCTest
@testable import VoiceCoach

private struct FixtureCase: Decodable {
    let name: String
    let times: [Double]
    let f0: [Double]
    let start: Double
    let end: Double
    let st: [Double?]
    let contour: String
    let rise: Double
    let fall: Double
}

final class IntonationTests: XCTestCase {
    private func fixture() throws -> [FixtureCase] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "contour-fixture", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([FixtureCase].self, from: Data(contentsOf: url))
    }

    func testFixtureCoversEveryContour() throws {
        XCTAssertEqual(Set(try fixture().map(\.contour)), ["rise", "fall", "level", "unmeasured"])
    }

    func testCleanF0MatchesCoachPy() throws {
        for item in try fixture() {
            let st = cleanF0(item.f0)
            XCTAssertEqual(st.count, item.st.count, item.name)
            for (index, (mine, theirs)) in zip(st, item.st).enumerated() {
                if let theirs {
                    XCTAssertEqual(mine, theirs, accuracy: 1e-6, "\(item.name) [\(index)]")
                } else {
                    XCTAssertTrue(mine.isNaN, "\(item.name) [\(index)] expected NaN")
                }
            }
        }
    }

    func testTerminalContourMatchesCoachPy() throws {
        for item in try fixture() {
            let st = item.st.map { $0 ?? .nan }
            let result = terminalContour(times: item.times, st: st, start: item.start, end: item.end)
            XCTAssertEqual(result.contour.rawValue, item.contour, item.name)
            XCTAssertEqual(result.rise, item.rise, accuracy: 1e-6, item.name)
            XCTAssertEqual(result.fall, item.fall, accuracy: 1e-6, item.name)
        }
    }

    func testCleanF0UsesGivenReference() {
        let st = cleanF0([0, 110, 110, 110, 110, 110, 0], reference: 220)
        XCTAssertTrue(st[0].isNaN)
        XCTAssertEqual(st[1], -12, accuracy: 1e-9)
    }
}
