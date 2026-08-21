import XCTest
@testable import Recorder

final class SpeakerProfileTests: XCTestCase {

    private func centroid(_ vector: [Float], seconds: Double = 30, at offset: TimeInterval = 0) -> VoiceCentroid {
        VoiceCentroid(vector: vector, sampleSeconds: seconds, addedAt: Date(timeIntervalSince1970: offset))
    }

    private func profile(_ name: String, _ vectors: [[Float]]) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            centroids: vectors.enumerated().map { centroid($1, at: TimeInterval($0)) }
        )
    }

    func testIdenticalVectorsHaveZeroDistance() {
        XCTAssertEqual(VoiceMatching.cosineDistance([1, 2, 3], [1, 2, 3]), 0, accuracy: 1e-5)
    }

    func testOrthogonalVectorsHaveDistanceOne() {
        XCTAssertEqual(VoiceMatching.cosineDistance([1, 0], [0, 1]), 1, accuracy: 1e-5)
    }

    func testOppositeVectorsHaveDistanceTwo() {
        XCTAssertEqual(VoiceMatching.cosineDistance([1, 0], [-1, 0]), 2, accuracy: 1e-5)
    }

    func testMagnitudeDoesNotAffectDistance() {
        XCTAssertEqual(VoiceMatching.cosineDistance([1, 2, 3], [10, 20, 30]), 0, accuracy: 1e-5)
    }

    func testMismatchedOrEmptyInputReturnsTheSentinel() {
        XCTAssertEqual(VoiceMatching.cosineDistance([1, 2], [1, 2, 3]), 1, accuracy: 1e-5)
        XCTAssertEqual(VoiceMatching.cosineDistance([], []), 1, accuracy: 1e-5)
        XCTAssertEqual(VoiceMatching.cosineDistance([0, 0], [1, 1]), 1, accuracy: 1e-5)
    }

    func testAppendEvictsTheOldestPastTheCap() {
        var subject = profile("Anna", [])
        for index in 0..<(SpeakerProfile.maxCentroids + 2) {
            subject.appendCentroid(centroid([Float(index), 0], at: TimeInterval(index)))
        }
        XCTAssertEqual(subject.centroids.count, SpeakerProfile.maxCentroids)
        XCTAssertEqual(subject.centroids.first?.addedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(subject.centroids.last?.addedAt, Date(timeIntervalSince1970: 9))
    }

    func testRemoveCentroidDropsExactlyTheMatchingStamp() {
        var subject = profile("Anna", [[1, 0], [0, 1], [1, 1]])
        subject.removeCentroid(addedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(subject.centroids.count, 2)
        XCTAssertFalse(subject.centroids.contains { $0.addedAt == Date(timeIntervalSince1970: 1) })
    }

    func testNearestReturnsTheClosestCentroidOfAnyProfile() {
        let anna = profile("Anna", [[1, 0], [0.9, 0.1]])
        let ben = profile("Ben", [[0, 1]])
        let match = VoiceMatching.nearest(to: [0, 1], in: [anna, ben])
        XCTAssertEqual(match?.profileID, ben.id)
        XCTAssertEqual(match?.distance ?? 1, 0, accuracy: 1e-5)
    }

    func testNearestIsNilWithoutUsableInput() {
        XCTAssertNil(VoiceMatching.nearest(to: [], in: [profile("Anna", [[1, 0]])]))
        XCTAssertNil(VoiceMatching.nearest(to: [1, 0], in: []))
        XCTAssertNil(VoiceMatching.nearest(to: [1, 0], in: [profile("Anna", [])]))
    }

    func testNearestSkipsCentroidsOfADifferentDimension() {
        let anna = profile("Anna", [[1, 0, 0]])
        XCTAssertNil(VoiceMatching.nearest(to: [1, 0], in: [anna]))
    }
}
