import XCTest
@testable import Recorder
import VoiceCoach

final class CoachStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session(_ name: String, triggers: [(String, DetectorID, Bool)], clips: [String] = []) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(CoachPump.clipsFolderName), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var lines = [try encoder.encode(CoachEvent(t: 0, kind: .session))]
        for (id, detector, shown) in triggers {
            lines.append(try encoder.encode(CoachEvent(t: 5, kind: .trigger, detector: detector, shown: shown, note: shown ? "shown" : "withheld", id: id)))
            lines.append(try encoder.encode(CoachEvent(t: 7, kind: .clip, detector: detector, note: "planned", id: id)))
        }
        try Data(lines.joined(separator: Data([0x0A]))).write(to: folder.appendingPathComponent(CoachPump.logName))
        for id in clips {
            try Data([0]).write(to: folder.appendingPathComponent(CoachPump.clipsFolderName).appendingPathComponent("\(id).m4a"))
        }
        return folder
    }

    func testTriggersParsedWithClipsAndLabels() throws {
        let folder = try session("a", triggers: [("pace-1", .pace, true), ("so-2", .soStarts, false)], clips: ["pace-1"])
        CoachLabels.setLabel(.falseAlarm, for: "so-2", in: folder)
        let records = CoachLabels.triggers(in: folder)
        XCTAssertEqual(records.map(\.id), ["pace-1", "so-2"])
        XCTAssertNotNil(records[0].clipURL)
        XCTAssertNil(records[1].clipURL)
        XCTAssertEqual(records[1].label, .falseAlarm)
        XCTAssertFalse(records[1].shown)
    }

    func testPrecisionAggregatesLabels() throws {
        let a = try session("a", triggers: [("pace-1", .pace, true), ("pace-2", .pace, false)])
        let b = try session("b", triggers: [("pace-3", .pace, true), ("so-4", .soStarts, true)])
        CoachLabels.setLabel(.right, for: "pace-1", in: a)
        CoachLabels.setLabel(.falseAlarm, for: "pace-2", in: a)
        CoachLabels.setLabel(.right, for: "pace-3", in: b)
        CoachLabels.setLabel(.right, for: "so-4", in: b)
        CoachLabels.setLabel(nil, for: "so-4", in: b)
        let tallies = CoachLabels.tallies(root: root)
        XCTAssertEqual(tallies[.pace], LabelTally(labelled: 3, right: 2))
        XCTAssertNil(tallies[.soStarts])
    }

    func testCanPromoteNeedsTwentyAndNinetyPercent() {
        XCTAssertFalse(CoachLabels.canPromote(LabelTally(labelled: 19, right: 19)))
        XCTAssertTrue(CoachLabels.canPromote(LabelTally(labelled: 20, right: 18)))
        XCTAssertFalse(CoachLabels.canPromote(LabelTally(labelled: 20, right: 17)))
    }

    func testSessionFoldersOnlyWithLogs() throws {
        _ = try session("a", triggers: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("no-coach"), withIntermediateDirectories: true)
        XCTAssertEqual(CoachLabels.sessionFolders(root: root).map(\.lastPathComponent), ["a"])
    }
}
