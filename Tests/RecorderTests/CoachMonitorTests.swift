import Synchronization
import XCTest
@testable import Recorder
import VoiceCoach

final class CoachMonitorTests: XCTestCase {
    private func sample(_ detector: DetectorID, at t: Double, _ values: [String: Double], note: String? = nil) -> CoachEvent {
        CoachEvent(t: t, kind: .sample, detector: detector, values: values, note: note)
    }

    private func trigger(_ detector: DetectorID, at t: Double, note: String) -> CoachEvent {
        CoachEvent(t: t, kind: .trigger, detector: detector, shown: note == "shown", note: note, id: "\(detector.rawValue)-\(Int(t * 1000))")
    }

    private func line(_ detector: DetectorID, in lines: [CoachCheckLine], file: StaticString = #filePath, line: UInt = #line) throws -> CoachCheckLine {
        try XCTUnwrap(lines.first { $0.detector == detector }, file: file, line: line)
    }

    func testListsEveryCheckTheCoachRuns() {
        let lines = CoachCheckLine.lines(monitor: CoachMonitor(), preset: .oneOnOne, promoted: [.pace])
        XCTAssertEqual(Set(lines.map(\.detector)), Set(DetectorID.allCases))
        XCTAssertEqual(lines.first?.detector, .pace)
    }

    func testSamplesAndTriggersAreCounted() {
        var monitor = CoachMonitor()
        XCTAssertTrue(monitor.absorb([sample(.trailingEndings, at: 24, ["phrases": 5, "trailing": 3]), trigger(.trailingEndings, at: 24, note: "shadow")]))
        XCTAssertFalse(monitor.absorb([CoachEvent(t: 25, kind: .gap, note: "system audio realigned")]))
        XCTAssertEqual(monitor.checks[.trailingEndings]?.flags, 1)
        XCTAssertEqual(monitor.checks[.trailingEndings]?.values["trailing"], 3)
        XCTAssertTrue(monitor.isFlagging(.trailingEndings))
        _ = monitor.absorb([sample(.trailingEndings, at: 29, ["phrases": 5, "trailing": 3])])
        XCTAssertFalse(monitor.isFlagging(.trailingEndings))
    }

    func testHiddenFlagsShowInTheListWithTheirStatus() throws {
        var monitor = CoachMonitor()
        _ = monitor.absorb([
            sample(.trailingEndings, at: 24, ["phrases": 8, "trailing": 4, "trailingRate": 0.5]),
            trigger(.trailingEndings, at: 24, note: "shadow"),
        ])
        let lines = CoachCheckLine.lines(monitor: monitor, preset: .oneOnOne, promoted: [.pace])
        let trailing = try line(.trailingEndings, in: lines)
        XCTAssertTrue(trailing.flagging)
        XCTAssertEqual(trailing.flags, 1)
        XCTAssertEqual(trailing.reading, "4 of your last 8 endings faded out")
        XCTAssertEqual(trailing.status, "Logged only")
        XCTAssertEqual(try line(.pace, in: lines).status, "On the bar")
        XCTAssertEqual(try line(.interruptions, in: lines).status, "Log only")
    }

    func testPaceReadsAgainstThePresetLimit() throws {
        var monitor = CoachMonitor()
        _ = monitor.absorb([sample(.pace, at: 300, ["ratio": 1.18, "rate": 4.1, "baseline": 3.5])])
        let pace = try line(.pace, in: CoachCheckLine.lines(monitor: monitor, preset: .oneOnOne, promoted: [.pace]))
        XCTAssertEqual(pace.reading, "118% of your usual pace")
        XCTAssertEqual(pace.limit, "Flags at 120% for 3 s")
        XCTAssertFalse(pace.flagging)
        _ = monitor.absorb([sample(.pace, at: 301, [:], note: "not speaking")])
        XCTAssertEqual(try line(.pace, in: CoachCheckLine.lines(monitor: monitor, preset: .oneOnOne, promoted: [.pace])).reading, "Not speaking")
    }

    func testTalkShareAboveTheLimitIsFlagged() throws {
        var monitor = CoachMonitor()
        _ = monitor.absorb([sample(.talkShare, at: 60, ["talkShare": 0.72])])
        let share = try line(.talkShare, in: CoachCheckLine.lines(monitor: monitor, preset: .oneOnOne, promoted: [.pace]))
        XCTAssertEqual(share.reading, "You: 72% of the talking")
        XCTAssertEqual(share.limit, "High above 65%")
        XCTAssertTrue(share.flagging)
        let presenting = try line(.talkShare, in: CoachCheckLine.lines(monitor: monitor, preset: .presentation, promoted: [.pace]))
        XCTAssertFalse(presenting.flagging)
    }

    func testInterruptionsAndEndingsReadings() throws {
        var monitor = CoachMonitor()
        _ = monitor.absorb([
            sample(.interruptions, at: 90, ["interruptedThem": 3, "wasInterrupted": 7]),
            sample(.risingEndings, at: 90, ["measured": 2, "rises": 1, "levels": 0, "falls": 1, "questions": 0]),
        ])
        let lines = CoachCheckLine.lines(monitor: monitor, preset: .group, promoted: [.pace])
        XCTAssertEqual(try line(.interruptions, in: lines).reading, "You cut in 3×, they cut in 7×")
        XCTAssertEqual(try line(.risingEndings, in: lines).reading, "1 of your last 2 endings rose")
        XCTAssertEqual(try line(.risingEndings, in: lines).limit, "Flags each rise of 2.5 st or more, at most every 45 s")
        var fresh = CoachMonitor()
        _ = fresh.absorb([sample(.risingEndings, at: 5, ["measured": 0, "rises": 0, "levels": 0, "falls": 0, "questions": 0])])
        XCTAssertEqual(try line(.risingEndings, in: CoachCheckLine.lines(monitor: fresh, preset: .group, promoted: [.pace])).reading, "No measured endings yet")
    }

    func testPumpPublishesTheChecksOncePerTick() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pump = CoachPump(folder: folder, config: CoachConfig(language: "en"), retainsAudio: false)
        let received = Mutex<[CoachMonitor]>([])
        pump.onMonitor = { monitor in received.withLock { $0.append(monitor) } }
        let quiet = [Float](repeating: 0.00001, count: 48_000 * 3)
        quiet.withUnsafeBufferPointer { buffer in
            pump.ingest(.mic, buffer.baseAddress!, count: buffer.count, rate: 48_000)
            pump.ingest(.desktop, buffer.baseAddress!, count: buffer.count, rate: 48_000)
        }
        pump.drainNow()
        _ = pump.stop()
        let last = try XCTUnwrap(received.withLock { $0.last })
        XCTAssertNotNil(last.checks[.pace])
        XCTAssertGreaterThanOrEqual(last.now, 2)
    }
}
