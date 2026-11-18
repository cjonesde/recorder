import AppKit
import XCTest
@testable import Recorder

final class MenuBarPillTests: XCTestCase {
    func testIdleAndTransitionStatesKeepTheSymbol() {
        for state in [RecorderState.idle, .preparing, .finishing] {
            XCTAssertNil(MenuBarPill(state: state, elapsed: 12))
        }
    }

    func testClockShowsMinutesThenHours() {
        XCTAssertEqual(MenuBarPill.clock(0), "00:00")
        XCTAssertEqual(MenuBarPill.clock(65.9), "01:05")
        XCTAssertEqual(MenuBarPill.clock(3725), "1:02:05")
    }

    func testRecordingPillIsRedWithTheTime() throws {
        let pill = try XCTUnwrap(MenuBarPill(state: .recording, elapsed: 252))
        XCTAssertEqual(pill.clock, "04:12")
        XCTAssertEqual(pill.accessibilityLabel, "Recording, 04:12")
        try assertFill(of: pill, red: 0xB3, green: 0x1D, blue: 0x3D)
    }

    func testPausedPillIsOchre() throws {
        let pill = try XCTUnwrap(MenuBarPill(state: .paused, elapsed: 252))
        XCTAssertEqual(pill.accessibilityLabel, "Paused, 04:12")
        try assertFill(of: pill, red: 0xE1, green: 0xB9, blue: 0x32)
    }

    func testPillWidensPastAnHour() throws {
        let short = try XCTUnwrap(MenuBarPill(state: .recording, elapsed: 59))
        let long = try XCTUnwrap(MenuBarPill(state: .recording, elapsed: 3600))
        XCTAssertGreaterThan(long.width, short.width)
        let image = short.image(scale: 2)
        XCTAssertEqual(image.size.height, MenuBarPill.height)
        XCTAssertEqual(image.size.width, short.width)
        XCTAssertFalse(image.isTemplate)
    }

    private func assertFill(of pill: MenuBarPill, red: Int, green: Int, blue: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = pill.image(scale: 2)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep, file: file, line: line)
        XCTAssertEqual(bitmap.colorSpace.localizedName, NSColorSpace.sRGB.localizedName, file: file, line: line)
        var sample = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&sample, atX: bitmap.pixelsWide - 6, y: bitmap.pixelsHigh / 2)
        XCTAssertEqual(Array(sample.prefix(4)), [red, green, blue, 255], file: file, line: line)
    }
}
