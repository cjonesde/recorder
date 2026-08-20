import XCTest
@testable import Recorder

final class SpeakerNamingTests: XCTestCase {

    private func profile(_ name: String, _ vector: [Float], id: UUID = UUID()) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            centroids: [VoiceCentroid(vector: vector, sampleSeconds: 30, addedAt: Date(timeIntervalSince1970: 0))]
        )
    }

    private func evidence(_ vector: [Float], seconds: Double = 30) -> ClusterEvidence {
        ClusterEvidence(centroid: vector, speechSeconds: seconds)
    }

    func testAMatchWithinThresholdWins() {
        let anna = profile("Anna", [1, 0])
        let result = SpeakerNaming.resolve(
            clusters: ["s1": evidence([1, 0.01])],
            defaultNames: ["s1": "Speaker 1"],
            profiles: [anna]
        )
        XCTAssertEqual(result["s1"]?.name, "Anna")
        XCTAssertEqual(result["s1"]?.profileID, anna.id)
    }

    func testAMatchOutsideThresholdFallsBackToTheDefaultName() {
        let result = SpeakerNaming.resolve(
            clusters: ["s1": evidence([0, 1])],
            defaultNames: ["s1": "Speaker 1"],
            profiles: [profile("Anna", [1, 0])]
        )
        XCTAssertEqual(result["s1"]?.name, "Speaker 1")
        XCTAssertNil(result["s1"]?.profileID)
    }

    func testAShortClusterNeverMatches() {
        let result = SpeakerNaming.resolve(
            clusters: ["s1": evidence([1, 0], seconds: SpeakerNaming.minSpeechSeconds - 0.1)],
            defaultNames: ["s1": "Speaker 1"],
            profiles: [profile("Anna", [1, 0])]
        )
        XCTAssertEqual(result["s1"]?.name, "Speaker 1", "too little speech to name a person by")
        XCTAssertNil(result["s1"]?.profileID)
    }

    func testTheMicSpeakerIsNeverMatchedAgainstProfiles() {
        let result = SpeakerNaming.resolve(
            clusters: [SpeakerNaming.micSpeakerID: evidence([1, 0])],
            defaultNames: [SpeakerNaming.micSpeakerID: "You"],
            profiles: [profile("Anna", [1, 0])]
        )
        XCTAssertEqual(result[SpeakerNaming.micSpeakerID]?.name, "You")
        XCTAssertNil(result[SpeakerNaming.micSpeakerID]?.profileID)
    }

    func testOneProfileIsUsedAtMostOncePerRecording() {
        let anna = profile("Anna", [1, 0])
        let result = SpeakerNaming.resolve(
            clusters: [
                "s1": evidence([1, 0.2]),
                "s2": evidence([1, 0.01]),
            ],
            defaultNames: ["s1": "Speaker 1", "s2": "Speaker 2"],
            profiles: [anna]
        )
        XCTAssertEqual(result["s2"]?.name, "Anna", "the closer cluster takes the profile")
        XCTAssertEqual(result["s1"]?.name, "Speaker 1", "two people in one room cannot both be Anna")
    }

    func testEachClusterTakesItsOwnNearestProfile() {
        let anna = profile("Anna", [1, 0])
        let ben = profile("Ben", [0, 1])
        let result = SpeakerNaming.resolve(
            clusters: ["s1": evidence([0, 1]), "s2": evidence([1, 0])],
            defaultNames: ["s1": "Speaker 1", "s2": "Speaker 2"],
            profiles: [anna, ben]
        )
        XCTAssertEqual(result["s1"]?.name, "Ben")
        XCTAssertEqual(result["s2"]?.name, "Anna")
    }

    func testNoProfilesLeavesEveryDefaultIntact() {
        let result = SpeakerNaming.resolve(
            clusters: ["s1": evidence([1, 0])],
            defaultNames: ["s1": "Speaker 1"],
            profiles: []
        )
        XCTAssertEqual(result["s1"]?.name, "Speaker 1")
    }
}
