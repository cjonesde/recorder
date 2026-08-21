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

    func testPendingRoundTrips() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let pending = PendingSpeakers(
            id: "abc-123",
            createdAt: Date(timeIntervalSince1970: 100),
            clusters: [
                "s1": PendingSpeakers.Cluster(vector: [1, 0], speechSeconds: 42, appliedProfileID: nil)
            ]
        )

        try store.writePending(pending)

        let loaded = store.loadPending(id: "abc-123")
        XCTAssertEqual(loaded?.clusters["s1"]?.vector, [1, 0])
        XCTAssertEqual(loaded?.clusters["s1"]?.speechSeconds, 42)
        XCTAssertNil(loaded?.clusters["s1"]?.appliedProfileID)
    }

    func testLoadingAnUnknownPendingIDIsNilRatherThanAnError() {
        XCTAssertNil(SpeakerProfileStore(baseURL: baseURL).loadPending(id: "does-not-exist"))
    }

    func testPruneDropsOnlyEntriesPastTheirLifetime() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        let now = Date(timeIntervalSince1970: 60 * 60 * 24 * 100)
        let fresh = PendingSpeakers(
            id: "fresh",
            createdAt: now.addingTimeInterval(-60 * 60 * 24 * 5),
            clusters: [:]
        )
        let stale = PendingSpeakers(
            id: "stale",
            createdAt: now.addingTimeInterval(-60 * 60 * 24 * 31),
            clusters: [:]
        )
        try store.writePending(fresh)
        try store.writePending(stale)

        store.prunePending(olderThan: 60 * 60 * 24 * 30, now: now)

        XCTAssertNotNil(store.loadPending(id: "fresh"))
        XCTAssertNil(store.loadPending(id: "stale"))
    }

    func testDeleteAllVoiceDataAlsoClearsPending() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(PendingSpeakers(id: "abc", createdAt: Date(timeIntervalSince1970: 0), clusters: [:]))

        try store.deleteAllVoiceData()

        XCTAssertNil(store.loadPending(id: "abc"))
    }

    private func pendingWithOneCluster(
        speechSeconds: Double = 30,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PendingSpeakers {
        PendingSpeakers(
            id: "rec1",
            createdAt: createdAt,
            clusters: ["s1": PendingSpeakers.Cluster(
                vector: [1, 0],
                speechSeconds: speechSeconds,
                appliedProfileID: nil
            )]
        )
    }

    func testApplyingANameEnrollsAndRecordsTheProfile() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(pendingWithOneCluster())

        let profileID = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")

        XCTAssertEqual(store.profiles.first?.name, "Anna")
        XCTAssertEqual(store.profiles.first?.id, profileID)
        XCTAssertEqual(store.loadPending(id: "rec1")?.clusters["s1"]?.appliedProfileID, profileID)
    }

    func testCorrectingANameRetractsFromTheWrongProfileFirst() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(pendingWithOneCluster())
        _ = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")

        let benID = try store.applyName("Ben", toCluster: "s1", pendingID: "rec1")

        XCTAssertEqual(store.profiles.map(\.name), ["Ben"], "Anna kept no voiceprint, so Anna is gone")
        XCTAssertEqual(store.loadPending(id: "rec1")?.clusters["s1"]?.appliedProfileID, benID)
    }

    func testConfirmingTheSameNameReinforcesWithoutDuplicating() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(pendingWithOneCluster())
        let first = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")
        let second = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(
            store.profiles.first?.centroids.count, 1,
            "the same cluster must not stack up centroids in one profile"
        )
    }

    func testAShortClusterIsNeverEnrolled() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(pendingWithOneCluster(speechSeconds: SpeakerNaming.minSpeechSeconds - 0.1))

        let profileID = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")

        XCTAssertNil(profileID)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testApplyingANameWithNoPendingRecordEnrollsNothing() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        XCTAssertNil(try store.applyName("Anna", toCluster: "s1", pendingID: "missing"))
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testAnEarlierRecordingCanReinforceAProfileItAlreadyContributedTo() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(pendingWithOneCluster(createdAt: Date(timeIntervalSince1970: 0)))
        try store.writePending(PendingSpeakers(
            id: "rec2",
            createdAt: Date(timeIntervalSince1970: 500),
            clusters: ["s1": PendingSpeakers.Cluster(vector: [0, 1], speechSeconds: 30, appliedProfileID: nil)]
        ))

        let first = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1")
        let second = try store.applyName("Anna", toCluster: "s1", pendingID: "rec2")

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            store.profiles.first?.centroids.count, 2,
            "two different recordings of the same person are two voiceprints"
        )
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
