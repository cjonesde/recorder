import XCTest
@testable import Recorder

@MainActor
final class SpeakerProfileStoreTests: XCTestCase {

    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func centroid(_ vector: [Float], at offset: TimeInterval = 0) -> VoiceCentroid {
        VoiceCentroid(vector: vector, sampleSeconds: 30, addedAt: Date(timeIntervalSince1970: offset))
    }

    func testEnrollCreatesAProfileAndPersistsIt() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let id = try store.enroll(centroid: centroid([1, 0]), named: "Anna")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Anna")
        XCTAssertEqual(store.profiles.first?.id, id)

        let reopened = SpeakerProfileStore(baseURL: baseURL)
        XCTAssertEqual(reopened.profiles.first?.id, id)
        XCTAssertEqual(reopened.profiles.first?.centroids.first?.vector, [1, 0])
    }

    func testEnrollingAnExistingNameAppendsRatherThanDuplicating() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let first = try store.enroll(centroid: centroid([1, 0], at: 0), named: "Anna")
        let second = try store.enroll(centroid: centroid([0, 1], at: 1), named: "Anna")

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.centroids.count, 2)
    }

    func testEnrollMatchesTheNameCaseInsensitively() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let first = try store.enroll(centroid: centroid([1, 0]), named: "Anna")
        let second = try store.enroll(centroid: centroid([0, 1], at: 1), named: "  anna ")
        XCTAssertEqual(first, second)
    }

    func testEnrollEvictsOldestPastTheCap() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        for index in 0...SpeakerProfile.maxCentroids {
            _ = try store.enroll(centroid: centroid([Float(index), 1], at: TimeInterval(index)), named: "Anna")
        }
        XCTAssertEqual(store.profiles.first?.centroids.count, SpeakerProfile.maxCentroids)
        XCTAssertEqual(store.profiles.first?.centroids.first?.addedAt, Date(timeIntervalSince1970: 1))
    }

    func testRetractRemovesOnlyThatCentroid() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let id = try store.enroll(centroid: centroid([1, 0], at: 0), named: "Anna")
        _ = try store.enroll(centroid: centroid([0, 1], at: 5), named: "Anna")

        try store.retract(centroidAddedAt: Date(timeIntervalSince1970: 0), from: id)

        XCTAssertEqual(store.profiles.first?.centroids.count, 1)
        XCTAssertEqual(store.profiles.first?.centroids.first?.vector, [0, 1])
    }

    func testRetractingTheLastCentroidRemovesTheProfile() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let id = try store.enroll(centroid: centroid([1, 0], at: 0), named: "Anna")
        try store.retract(centroidAddedAt: Date(timeIntervalSince1970: 0), from: id)
        XCTAssertTrue(store.profiles.isEmpty, "a profile with no voiceprints left is not a profile")
    }

    func testDeleteRemovesOneProfile() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let anna = try store.enroll(centroid: centroid([1, 0]), named: "Anna")
        _ = try store.enroll(centroid: centroid([0, 1], at: 1), named: "Ben")

        try store.delete(profileID: anna)

        XCTAssertEqual(store.profiles.map(\.name), ["Ben"])
        XCTAssertEqual(SpeakerProfileStore(baseURL: baseURL).profiles.map(\.name), ["Ben"])
    }

    func testDeleteAllVoiceDataClearsEverything() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        _ = try store.enroll(centroid: centroid([1, 0]), named: "Anna")

        try store.deleteAllVoiceData()

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.path))
        XCTAssertTrue(SpeakerProfileStore(baseURL: baseURL).profiles.isEmpty)
    }

    func testCorruptProfilesFileIsQuarantinedRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let profilesURL = baseURL.appendingPathComponent("profiles.json")
        try Data("not json at all".utf8).write(to: profilesURL)

        let store = SpeakerProfileStore(baseURL: baseURL)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("profiles.json.corrupt").path),
            "the unreadable file must be kept, not silently overwritten"
        )
    }
}
