# Speaker Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcribe the two recorded channels separately so the microphone speaker is identified structurally as "You", and name the remaining voices by matching them against stored voiceprints that the user builds by correcting labels.

**Architecture:** The offline path stops summing the stereo file to mono and decodes `ch0` (desktop) and `ch1` (mic) separately through the existing single model host, diarizing only the desktop channel. Pure value types carry the result (`OfflineTranscription`), resolve names (`SpeakerNaming`), and hold voiceprints (`SpeakerProfile`), so everything except the decode itself is testable without a model or a filesystem. `SpeakerProfileStore` owns disk I/O against an injected base directory.

**Tech Stack:** Swift 6 tools with `.swiftLanguageMode(.v5)`, SwiftUI, XCTest, WhisperKit 1.1.0, SpeakerKit (same package), Accelerate (vDSP).

**Spec:** `docs/superpowers/specs/2026-08-20-speaker-profiles-design.md`

## Global Constraints

- Swift language mode is v5. Pre-existing Swift 6 concurrency warnings are not in scope to fix.
- Platform floor is macOS 15, set in `Package.swift`.
- `MathOps.cosineDistance` in SpeakerKit is **internal**, not public. We implement our own cosine distance with the identical convention: `clamp(1 - dot / (|a| * |b|), 0, 2)`, returning the sentinel `1.0` for empty, length-mismatched, or zero-magnitude input.
- Cosine distance convention is `[0, 2]`: `0` identical direction, `1` orthogonal, `2` opposite.
- `matchDistance = 0.45`, `minSpeechSeconds = 6`. Both live only in `SpeakerNaming`.
- Voice profiles are **off by default**. When off, no centroid is ever written to disk.
- Embeddings never go in the recording folder. Only the pending uuid may appear in `transcript.json`.
- Speaker ids are opaque: `you` for the microphone, `s1`, `s2`, ... for desktop clusters. Display names live in `TranscriptDocument.speakerNames`.
- Never use an em dash (`\u{2014}`) anywhere, including test fixtures. `TranscriptDocumentTests` already asserts this for rendered markdown.
- Match the surrounding comment style: `///` doc comments explaining non-obvious rationale.
- Run the full suite with `swift test`. Skipped tests are the env-gated hardware checks and are expected.

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `Sources/Recorder/SpeakerProfile.swift` | `VoiceCentroid`, `SpeakerProfile`, FIFO append, cosine distance, nearest-of-any |
| `Sources/Recorder/SpeakerProfileStore.swift` | `profiles.json` and `pending/` on disk, enrollment, retraction, deletion |
| `Sources/Recorder/SpeakerNaming.swift` | the two constants, greedy precedence resolution |
| `Sources/Recorder/OfflineTranscription.swift` | `TimedText`, `DiarizedSpan`, `ClusterEvidence`, `OfflineTranscription`, the builder |
| `Tests/RecorderTests/SpeakerProfileTests.swift` | Task 1 |
| `Tests/RecorderTests/SpeakerProfileStoreTests.swift` | Tasks 2 and 3 |
| `Tests/RecorderTests/SpeakerNamingTests.swift` | Task 4 |
| `Tests/RecorderTests/OfflineTranscriptionTests.swift` | Task 5 |
| `Tests/RecorderTests/SpeakerDiarizationVerificationTests.swift` | Task 12, env-gated |

**Modified:**

| File | Change |
| --- | --- |
| `Sources/Recorder/LocalTranscription.swift` | `transcribeFile` returns `OfflineTranscription`, decodes per channel |
| `Sources/Recorder/TranscriptDocument.swift` | gains `speakerCentroidsID` |
| `Sources/Recorder/Preferences.swift` | gains `voiceProfiles` |
| `Sources/Recorder/RecorderModel.swift` | owns the store, builds the document, applies renames |
| `Sources/Recorder/PreferencesView.swift` | Speakers tab |
| `Sources/Recorder/RecorderPanel.swift` | rename chips |

---

### Task 1: Voice centroids, profiles, and matching

**Files:**
- Create: `Sources/Recorder/SpeakerProfile.swift`
- Test: `Tests/RecorderTests/SpeakerProfileTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `VoiceCentroid(vector:sampleSeconds:addedAt:)`, `SpeakerProfile(id:name:createdAt:updatedAt:centroids:)`, `SpeakerProfile.maxCentroids: Int`, `mutating func appendCentroid(_:)`, `mutating func removeCentroid(addedAt:)`, `VoiceMatching.cosineDistance(_:_:) -> Float`, `VoiceMatching.nearest(to:in:) -> (profileID: UUID, distance: Float)?`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerProfileTests`
Expected: FAIL to compile, "cannot find type 'VoiceCentroid' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Accelerate

// MARK: - VoiceCentroid

/// One stored voiceprint: the mean speaker embedding of a single diarized cluster.
///
/// `addedAt` doubles as the identity of this centroid within a profile, which is how a
/// correction retracts exactly the centroid a recording contributed without touching
/// the rest.
struct VoiceCentroid: Codable, Equatable {
    var vector: [Float]
    var sampleSeconds: Double
    var addedAt: Date
}

// MARK: - SpeakerProfile

/// One person, and up to `maxCentroids` recordings of how they sound.
///
/// Several centroids rather than one running mean: matching is nearest-of-any, which
/// survives a change of microphone or room far better than an average of them does.
struct SpeakerProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var centroids: [VoiceCentroid]

    static let maxCentroids = 8

    /// Append, evicting oldest-first past the cap.
    mutating func appendCentroid(_ centroid: VoiceCentroid) {
        centroids.append(centroid)
        if centroids.count > Self.maxCentroids {
            centroids.removeFirst(centroids.count - Self.maxCentroids)
        }
        updatedAt = centroid.addedAt
    }

    mutating func removeCentroid(addedAt stamp: Date) {
        centroids.removeAll { $0.addedAt == stamp }
    }
}

// MARK: - VoiceMatching

/// Cosine comparison of speaker embeddings.
///
/// SpeakerKit's own `MathOps.cosineDistance` is internal to that module, so this
/// reproduces its convention exactly: distance in `[0, 2]`, `0` identical direction,
/// `1` orthogonal, `2` opposite, with `1.0` as the sentinel for unusable input.
/// Centroids are raw embedder output (unnormalised, pre-PLDA), which is fine because
/// the division by magnitudes normalises them here.
enum VoiceMatching {

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1.0 }

        let length = vDSP_Length(lhs.count)
        var dot: Float = 0
        var lhsSquares: Float = 0
        var rhsSquares: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, length)
        vDSP_svesq(lhs, 1, &lhsSquares, length)
        vDSP_svesq(rhs, 1, &rhsSquares, length)

        let lhsMagnitude = sqrt(lhsSquares)
        let rhsMagnitude = sqrt(rhsSquares)
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 1.0 }

        return max(0, min(2, 1 - dot / (lhsMagnitude * rhsMagnitude)))
    }

    /// Closest centroid across every profile. Ties resolve to the lowest profile id so
    /// the result does not depend on dictionary ordering.
    static func nearest(
        to embedding: [Float],
        in profiles: [SpeakerProfile]
    ) -> (profileID: UUID, distance: Float)? {
        guard !embedding.isEmpty else { return nil }

        var best: (profileID: UUID, distance: Float)?
        for profile in profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for centroid in profile.centroids where centroid.vector.count == embedding.count {
                let distance = cosineDistance(embedding, centroid.vector)
                if best == nil || distance < best!.distance {
                    best = (profile.id, distance)
                }
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerProfileTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/SpeakerProfile.swift Tests/RecorderTests/SpeakerProfileTests.swift
git commit -m "Add voice centroids, speaker profiles, and cosine matching"
```

---

### Task 2: Profile persistence

**Files:**
- Create: `Sources/Recorder/SpeakerProfileStore.swift`
- Test: `Tests/RecorderTests/SpeakerProfileStoreTests.swift`

**Interfaces:**
- Consumes: `SpeakerProfile`, `VoiceCentroid`, `VoiceMatching` from Task 1.
- Produces: `SpeakerProfileStore(baseURL:)`, `SpeakerProfileStore.defaultBaseURL: URL`, `var profiles: [SpeakerProfile]`, `func reload()`, `func enroll(centroid:named:) throws -> UUID`, `func retract(centroidAddedAt:from:) throws`, `func delete(profileID:) throws`, `func deleteAllVoiceData() throws`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Recorder

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: FAIL to compile, "cannot find 'SpeakerProfileStore' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import os

/// Voiceprint persistence.
///
/// Everything lives under one directory so "delete all voice data" is a single
/// directory removal. Embeddings are biometric data under GDPR Art. 9, which is why
/// they live in Application Support and never in the recording folder: a transcript
/// folder you share carries no voiceprint.
@MainActor
@Observable
final class SpeakerProfileStore {

    /// ~/Library/Application Support/Recorder/Speakers
    static var defaultBaseURL: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("Recorder", isDirectory: true)
            .appendingPathComponent("Speakers", isDirectory: true)
    }

    private(set) var profiles: [SpeakerProfile] = []

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private static let log = Logger(subsystem: "com.tobi.Recorder", category: "SpeakerProfileStore")

    private var profilesURL: URL { baseURL.appendingPathComponent("profiles.json") }

    init(baseURL: URL = SpeakerProfileStore.defaultBaseURL) {
        self.baseURL = baseURL
        reload()
    }

    // MARK: Reading

    func reload() {
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            profiles = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode(StoredProfiles.self, from: Data(contentsOf: profilesURL)).profiles
        } catch {
            Self.log.error("profiles.json unreadable, quarantining: \(error.localizedDescription)")
            quarantineProfiles()
            profiles = []
        }
    }

    /// Keep an unreadable file instead of overwriting it, so a decoding bug cannot
    /// destroy every profile the user built.
    private func quarantineProfiles() {
        let corrupt = baseURL.appendingPathComponent("profiles.json.corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: profilesURL, to: corrupt)
    }

    // MARK: Writing

    /// Append `centroid` to the profile called `name`, creating it when new.
    @discardableResult
    func enroll(centroid: VoiceCentroid, named name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            profiles[index].appendCentroid(centroid)
            try save()
            return profiles[index].id
        }
        var created = SpeakerProfile(
            id: UUID(),
            name: trimmed,
            createdAt: centroid.addedAt,
            updatedAt: centroid.addedAt,
            centroids: []
        )
        created.appendCentroid(centroid)
        profiles.append(created)
        try save()
        return created.id
    }

    /// Undo one contribution. A profile with no voiceprints left is removed, so a
    /// correction cannot leave an unmatchable empty entry in the list.
    func retract(centroidAddedAt stamp: Date, from profileID: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].removeCentroid(addedAt: stamp)
        if profiles[index].centroids.isEmpty {
            profiles.remove(at: index)
        }
        try save()
    }

    func delete(profileID: UUID) throws {
        profiles.removeAll { $0.id == profileID }
        try save()
    }

    func deleteAllVoiceData() throws {
        profiles = []
        if FileManager.default.fileExists(atPath: baseURL.path) {
            try FileManager.default.removeItem(at: baseURL)
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StoredProfiles(profiles: profiles)).write(to: profilesURL, options: .atomic)
    }

    private struct StoredProfiles: Codable {
        var profiles: [SpeakerProfile]
    }
}
```

Add `import Observation` at the top alongside `Foundation` if the build complains that `@Observable` is unavailable.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/SpeakerProfileStore.swift Tests/RecorderTests/SpeakerProfileStoreTests.swift
git commit -m "Persist speaker profiles, with corrupt-file quarantine"
```

---

### Task 3: Pending centroids

**Files:**
- Modify: `Sources/Recorder/SpeakerProfileStore.swift`
- Test: `Tests/RecorderTests/SpeakerProfileStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's store.
- Produces: `PendingSpeakers(id:createdAt:clusters:)`, `PendingSpeakers.Cluster(vector:speechSeconds:appliedProfileID:)`, `func writePending(_:) throws`, `func loadPending(id:) -> PendingSpeakers?`, `func prunePending(olderThan:now:)`

- [ ] **Step 1: Write the failing test**

Append to `SpeakerProfileStoreTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: FAIL to compile, "cannot find type 'PendingSpeakers' in scope".

- [ ] **Step 3: Write minimal implementation**

Add to `SpeakerProfileStore.swift`, above the class:

```swift
// MARK: - PendingSpeakers

/// The centroids of one finished transcription, held until the user names them.
///
/// Kept out of the recording folder on purpose: a transcript you hand to someone else
/// must not carry biometric data. `transcript.json` stores only this `id`.
struct PendingSpeakers: Codable, Equatable {

    struct Cluster: Codable, Equatable {
        var vector: [Float]
        var speechSeconds: Double
        /// The profile this cluster's centroid was last applied to, so a later
        /// correction knows what to retract.
        var appliedProfileID: UUID?
    }

    var id: String
    var createdAt: Date
    var clusters: [String: Cluster]
}
```

Add inside the class:

```swift
    // MARK: Pending centroids

    private var pendingDirectory: URL { baseURL.appendingPathComponent("pending", isDirectory: true) }

    private func pendingURL(id: String) -> URL {
        pendingDirectory.appendingPathComponent("\(id).json")
    }

    func writePending(_ pending: PendingSpeakers) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pending).write(to: pendingURL(id: pending.id), options: .atomic)
    }

    func loadPending(id: String) -> PendingSpeakers? {
        let url = pendingURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingSpeakers.self, from: Data(contentsOf: url))
    }

    /// Drop pending centroids nobody named. Biometric data should not outlive its
    /// purpose, and an unnamed cluster has none after a month.
    func prunePending(olderThan lifetime: TimeInterval = 60 * 60 * 24 * 30, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let pending = try? decoder.decode(PendingSpeakers.self, from: data) else { continue }
            if now.timeIntervalSince(pending.createdAt) > lifetime {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/SpeakerProfileStore.swift Tests/RecorderTests/SpeakerProfileStoreTests.swift
git commit -m "Hold per-recording centroids in pending/, pruned after 30 days"
```

---

### Task 4: Naming precedence

**Files:**
- Create: `Sources/Recorder/SpeakerNaming.swift`
- Test: `Tests/RecorderTests/SpeakerNamingTests.swift`

**Interfaces:**
- Consumes: `SpeakerProfile`, `VoiceMatching` from Task 1.
- Produces: `SpeakerNaming.matchDistance: Float`, `SpeakerNaming.minSpeechSeconds: Double`, `SpeakerNaming.micSpeakerID: String`, `SpeakerNaming.Assignment(name:profileID:)`, `SpeakerNaming.resolve(clusters:defaultNames:profiles:) -> [String: Assignment]`. `ClusterEvidence` arrives in Task 5; define it there and let this task reference it.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerNamingTests`
Expected: FAIL to compile, "cannot find 'SpeakerNaming' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Turns diarized clusters into display names.
///
/// Pure: no disk, no model, no clock. The two calibration constants live here as the
/// single place to tune them.
enum SpeakerNaming {

    /// Cosine distance at or below which a cluster is considered the same person as a
    /// stored profile.
    ///
    /// SpeakerKit declines to define a universal same-speaker threshold, so this one is
    /// ours. The anchor: SpeakerKit's own within-run clustering threshold is 0.6.
    /// Matching across recordings crosses changes of microphone, room and codec, and it
    /// attaches a named human being rather than an anonymous cluster number, so this is
    /// deliberately stricter than the value used to split clusters inside one file.
    static let matchDistance: Float = 0.45

    /// A cluster with less speech than this may neither match nor enroll. Short clusters
    /// are the ones most likely to put a real person's name on the wrong voice.
    static let minSpeechSeconds: Double = 6

    /// The speaker id of the microphone channel, which is the user by construction.
    static let micSpeakerID = "you"

    struct Assignment: Equatable {
        var name: String
        var profileID: UUID?
    }

    /// Resolve every cluster to a name, preferring a profile match and falling back to
    /// the supplied default ("You", "Speaker 1", ...).
    ///
    /// Assignment is greedy by ascending distance, and each profile is used at most once,
    /// so two clusters in one recording can never both come out as the same person.
    static func resolve(
        clusters: [String: ClusterEvidence],
        defaultNames: [String: String],
        profiles: [SpeakerProfile]
    ) -> [String: Assignment] {
        var result: [String: Assignment] = [:]
        for (id, _) in clusters {
            result[id] = Assignment(name: defaultNames[id] ?? id, profileID: nil)
        }

        var candidates: [(clusterID: String, profileID: UUID, distance: Float)] = []
        for (id, evidence) in clusters where id != micSpeakerID {
            guard evidence.speechSeconds >= minSpeechSeconds else { continue }
            for profile in profiles {
                var best: Float?
                for centroid in profile.centroids where centroid.vector.count == evidence.centroid.count {
                    let distance = VoiceMatching.cosineDistance(evidence.centroid, centroid.vector)
                    if best == nil || distance < best! { best = distance }
                }
                if let best, best <= matchDistance {
                    candidates.append((id, profile.id, best))
                }
            }
        }

        candidates.sort {
            $0.distance == $1.distance ? $0.clusterID < $1.clusterID : $0.distance < $1.distance
        }

        var takenClusters: Set<String> = []
        var takenProfiles: Set<UUID> = []
        for candidate in candidates {
            guard !takenClusters.contains(candidate.clusterID),
                  !takenProfiles.contains(candidate.profileID),
                  let profile = profiles.first(where: { $0.id == candidate.profileID }) else { continue }
            takenClusters.insert(candidate.clusterID)
            takenProfiles.insert(candidate.profileID)
            result[candidate.clusterID] = Assignment(name: profile.name, profileID: profile.id)
        }

        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerNamingTests`
Expected: PASS, 7 tests. This task compiles only once Task 5 defines `ClusterEvidence`; if you are executing strictly in order, add the four-line `ClusterEvidence` struct from Task 5 now and delete it from Task 5's step.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/SpeakerNaming.swift Tests/RecorderTests/SpeakerNamingTests.swift
git commit -m "Resolve speaker names by greedy nearest-profile assignment"
```

---

### Task 5: Structured offline result

**Files:**
- Create: `Sources/Recorder/OfflineTranscription.swift`
- Test: `Tests/RecorderTests/OfflineTranscriptionTests.swift`

**Interfaces:**
- Consumes: `TranscriptLine` (existing), `SpeakerNaming.micSpeakerID` from Task 4.
- Produces: `TimedText(start:end:text:)`, `DiarizedSpan(start:end:clusterID:)`, `ClusterEvidence(centroid:speechSeconds:)`, `OfflineTranscription(lines:clusters:speakerNames:)`, `OfflineTranscription.build(mic:desktop:diarized:centroids:) -> OfflineTranscription`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Recorder

final class OfflineTranscriptionTests: XCTestCase {

    private func text(_ start: TimeInterval, _ end: TimeInterval, _ body: String) -> TimedText {
        TimedText(start: start, end: end, text: body)
    }

    func testMicLinesAreLabelledYouWithoutDiarization() {
        let result = OfflineTranscription.build(
            mic: [text(0, 2, "hello")],
            desktop: [],
            diarized: [],
            centroids: [:]
        )
        XCTAssertEqual(result.lines.map(\.speaker), [SpeakerNaming.micSpeakerID])
        XCTAssertEqual(result.speakerNames[SpeakerNaming.micSpeakerID], "You")
        XCTAssertTrue(result.clusters.isEmpty, "the microphone never produces a voiceprint")
    }

    func testBothChannelsMergeInStartTimeOrder() {
        let result = OfflineTranscription.build(
            mic: [text(0, 1, "first"), text(4, 5, "third")],
            desktop: [text(2, 3, "second")],
            diarized: [DiarizedSpan(start: 2, end: 3, clusterID: 0)],
            centroids: [0: [1, 0]]
        )
        XCTAssertEqual(result.lines.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(result.lines.map(\.time), [0, 2, 4])
    }

    func testDesktopClustersAreNumberedByFirstSpeech() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a"), text(5, 6, "b"), text(10, 11, "c")],
            diarized: [
                DiarizedSpan(start: 0, end: 1, clusterID: 7),
                DiarizedSpan(start: 5, end: 6, clusterID: 3),
                DiarizedSpan(start: 10, end: 11, clusterID: 7),
            ],
            centroids: [7: [1, 0], 3: [0, 1]]
        )
        XCTAssertEqual(result.lines.map(\.speaker), ["s1", "s2", "s1"])
        XCTAssertEqual(result.speakerNames["s1"], "Speaker 1")
        XCTAssertEqual(result.speakerNames["s2"], "Speaker 2")
    }

    func testClusterEvidenceSumsSpeechAndCarriesTheCentroid() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a")],
            diarized: [
                DiarizedSpan(start: 0, end: 4, clusterID: 7),
                DiarizedSpan(start: 10, end: 13, clusterID: 7),
            ],
            centroids: [7: [1, 0]]
        )
        XCTAssertEqual(result.clusters["s1"]?.speechSeconds, 7)
        XCTAssertEqual(result.clusters["s1"]?.centroid, [1, 0])
    }

    func testADesktopLineWithNoOverlapIsLeftUnattributed() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(50, 51, "orphan")],
            diarized: [DiarizedSpan(start: 0, end: 1, clusterID: 0)],
            centroids: [0: [1, 0]]
        )
        XCTAssertNil(result.lines.first?.speaker)
    }

    func testALineTakesTheClusterItOverlapsMost() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 10, "mostly the second speaker")],
            diarized: [
                DiarizedSpan(start: 0, end: 2, clusterID: 4),
                DiarizedSpan(start: 2, end: 10, clusterID: 9),
            ],
            centroids: [4: [1, 0], 9: [0, 1]]
        )
        XCTAssertEqual(result.lines.first?.speaker, "s2")
    }

    func testAClusterWithNoCentroidStillLabelsButProducesNoEvidence() {
        let result = OfflineTranscription.build(
            mic: [],
            desktop: [text(0, 1, "a")],
            diarized: [DiarizedSpan(start: 0, end: 1, clusterID: 7)],
            centroids: [:]
        )
        XCTAssertEqual(result.lines.first?.speaker, "s1")
        XCTAssertNil(result.clusters["s1"], "no centroid means nothing to enroll")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OfflineTranscriptionTests`
Expected: FAIL to compile, "cannot find type 'TimedText' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

// MARK: - Inputs

/// A transcribed span, decoupled from WhisperKit's `TranscriptionSegment` so the merge
/// and labelling logic is testable without a model.
struct TimedText: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// A diarized span, decoupled from SpeakerKit's `SpeakerSegment` for the same reason.
struct DiarizedSpan: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var clusterID: Int
}

/// What a desktop cluster offers the profile store: how it sounds, and how much of it
/// there was to judge by.
struct ClusterEvidence: Equatable {
    var centroid: [Float]
    var speechSeconds: Double
}

// MARK: - OfflineTranscription

/// The structured result of an offline pass over a saved recording.
///
/// Line speakers hold opaque ids (`you`, `s1`, `s2`, ...), never display names, so a
/// later rename re-renders the markdown instead of patching it.
struct OfflineTranscription: Equatable {
    var lines: [TranscriptLine]
    var clusters: [String: ClusterEvidence]
    var speakerNames: [String: String]

    /// Merge the two channels into one timeline.
    ///
    /// The microphone channel is one person by construction, so it is labelled directly
    /// and never diarized: diarizing it would risk splitting the user across several
    /// profiles. Only the desktop channel produces cluster evidence, which is what makes
    /// "the microphone never creates a profile" a property of the data flow rather than a
    /// guard that can be forgotten.
    static func build(
        mic: [TimedText],
        desktop: [TimedText],
        diarized: [DiarizedSpan],
        centroids: [Int: [Float]]
    ) -> OfflineTranscription {
        let ordered = diarized.sorted { $0.start < $1.start }

        var displayNumber: [Int: Int] = [:]
        for span in ordered where displayNumber[span.clusterID] == nil {
            displayNumber[span.clusterID] = displayNumber.count + 1
        }
        func speakerID(_ clusterID: Int) -> String? {
            displayNumber[clusterID].map { "s\($0)" }
        }

        var names: [String: String] = [:]
        if !mic.isEmpty {
            names[SpeakerNaming.micSpeakerID] = "You"
        }
        for (clusterID, number) in displayNumber {
            if let id = speakerID(clusterID) {
                names[id] = "Speaker \(number)"
            }
        }

        var clusters: [String: ClusterEvidence] = [:]
        for (clusterID, vector) in centroids {
            guard let id = speakerID(clusterID) else { continue }
            let seconds = ordered
                .filter { $0.clusterID == clusterID }
                .reduce(0.0) { $0 + ($1.end - $1.start) }
            clusters[id] = ClusterEvidence(centroid: vector, speechSeconds: seconds)
        }

        var lines: [(TimeInterval, TranscriptLine)] = mic.map {
            ($0.start, TranscriptLine(time: $0.start, text: $0.text, speaker: SpeakerNaming.micSpeakerID))
        }
        for segment in desktop {
            var overlapByCluster: [Int: TimeInterval] = [:]
            for span in ordered {
                let overlap = min(segment.end, span.end) - max(segment.start, span.start)
                if overlap > 0 {
                    overlapByCluster[span.clusterID, default: 0] += overlap
                }
            }
            let best = overlapByCluster.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }
            lines.append((
                segment.start,
                TranscriptLine(
                    time: segment.start,
                    text: segment.text,
                    speaker: best.flatMap { speakerID($0.key) }
                )
            ))
        }

        return OfflineTranscription(
            lines: lines.sorted { $0.0 < $1.0 }.map(\.1),
            clusters: clusters,
            speakerNames: names
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OfflineTranscriptionTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/OfflineTranscription.swift Tests/RecorderTests/OfflineTranscriptionTests.swift
git commit -m "Merge per-channel segments into a structured offline transcript"
```

---

### Task 6: Per-channel decode

**Files:**
- Modify: `Sources/Recorder/LocalTranscription.swift:154-244` (the `// MARK: Offline files` section)
- Test: covered by Task 5's unit tests and Task 12's gated verification. No new unit test here: this task is the I/O boundary that the pure units were extracted from.

**Interfaces:**
- Consumes: `OfflineTranscription.build` from Task 5.
- Produces: `func transcribeFile(_ url: URL) async throws -> OfflineTranscription`, replacing the current `-> String`.

- [ ] **Step 1: Replace the offline section**

Delete the existing `transcribeFile` and `assignSpeakers`, keeping `diarizer()`. Replace with:

```swift
    // MARK: Offline files

    /// Transcribe a saved recording, one channel at a time.
    ///
    /// `StereoMixer` writes desktop to ch0 and mic to ch1, padded by each source's
    /// host-time offset, so the two channels are sample-aligned and their independent
    /// timelines merge by a plain sort. Decoding them separately keeps the microphone
    /// speaker identifiable by construction and spares Whisper the crosstalk of two
    /// people in one mixed signal.
    ///
    /// Serialized against the live tick loop: WhisperKit carries mutable decode state, so
    /// one pipe must never transcribe twice concurrently. The two channel passes
    /// therefore run one after the other.
    func transcribeFile(_ url: URL) async throws -> OfflineTranscription {
        let path = url.path
        let channels = Self.channelCount(of: url)

        guard channels >= 2 else {
            return try await transcribeSingleChannel(path: path)
        }

        let desktopSamples = try await Self.load(path: path, channel: 0)
        let micSamples = try await Self.load(path: path, channel: 1)

        let desktop = Self.hasSignal(desktopSamples)
            ? try await transcribe(desktopSamples)
            : []
        let mic = Self.hasSignal(micSamples)
            ? try await transcribe(micSamples)
            : []

        var diarized: [DiarizedSpan] = []
        var centroids: [Int: [Float]] = [:]
        if labelSpeakers, !desktop.isEmpty {
            do {
                let kit = try await diarizer()
                let result = try await kit.diarize(audioArray: desktopSamples)
                diarized = result.segments.compactMap { segment in
                    segment.speaker.speakerId.map {
                        DiarizedSpan(
                            start: TimeInterval(segment.startTime),
                            end: TimeInterval(segment.endTime),
                            clusterID: $0
                        )
                    }
                }
                centroids = result.speakerCentroidEmbeddings
            } catch {
                Self.log.error("diarization failed, desktop lines left unlabeled: \(error.localizedDescription)")
            }
        }

        return OfflineTranscription.build(
            mic: mic,
            desktop: desktop,
            diarized: diarized,
            centroids: centroids
        )
    }

    /// Legacy or externally supplied recordings that are not our two-channel layout.
    /// Everything is treated as desktop audio: diarized if labelling is on, with no
    /// "You" attribution available.
    private func transcribeSingleChannel(path: String) async throws -> OfflineTranscription {
        let samples = try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        let segments = try await transcribe(samples)

        var diarized: [DiarizedSpan] = []
        var centroids: [Int: [Float]] = [:]
        if labelSpeakers, !segments.isEmpty {
            do {
                let kit = try await diarizer()
                let result = try await kit.diarize(audioArray: samples)
                diarized = result.segments.compactMap { segment in
                    segment.speaker.speakerId.map {
                        DiarizedSpan(
                            start: TimeInterval(segment.startTime),
                            end: TimeInterval(segment.endTime),
                            clusterID: $0
                        )
                    }
                }
                centroids = result.speakerCentroidEmbeddings
            } catch {
                Self.log.error("diarization failed, transcript left unlabeled: \(error.localizedDescription)")
            }
        }

        return OfflineTranscription.build(mic: [], desktop: segments, diarized: diarized, centroids: centroids)
    }

    private func transcribe(_ samples: [Float]) async throws -> [TimedText] {
        let options = decodingOptions(forFile: true)
        let results = try await host.withPipe { pipe in
            try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        }
        return cleanSegments(results).map {
            TimedText(
                start: TimeInterval($0.start),
                end: TimeInterval($0.end),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func load(path: String, channel: Int) async throws -> [Float] {
        try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(
                fromPath: path,
                channelMode: .specificChannel(channel)
            )
        }.value
    }

    private static func channelCount(of url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 1 }
        return Int(file.fileFormat.channelCount)
    }

    /// Skip a decode pass for a channel that holds nothing, which is the common case for
    /// a listen-only meeting or a solo dictation.
    private static func hasSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare) > 1e-4
    }
```

Add `import AVFoundation` to the file's imports.

- [ ] **Step 2: Fix the one call site**

`RecorderModel.swift:588` will not compile. Leave it broken for now; Task 8 rewrites it. To keep the build green between tasks, temporarily adapt it:

```swift
                let offline = try await self.live.transcribeFile(audioURL)
                let body = offline.lines.map(\.markdown).joined(separator: "\n\n")
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`, with the pre-existing Swift 6 concurrency warnings only.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS with no new failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/LocalTranscription.swift Sources/Recorder/RecorderModel.swift
git commit -m "Decode the two recorded channels separately instead of summing to mono"
```

---

### Task 7: Link the transcript to its centroids

**Files:**
- Modify: `Sources/Recorder/TranscriptDocument.swift:15-22`
- Test: `Tests/RecorderTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `TranscriptDocument.speakerCentroidsID: String?`, defaulted to `nil` so the synthesized memberwise initializer stays source-compatible with existing call sites.

- [ ] **Step 1: Write the failing test**

Append to `TranscriptDocumentTests`:

```swift
    func testTranscriptsWrittenBeforeCentroidsStillDecode() throws {
        let legacy = """
        {
          "attendees": [],
          "isPolished": false,
          "lines": [{"speakerID": "you", "text": "hello", "time": 0}],
          "model": "openai_whisper-base",
          "speakerNames": {"you": "You"},
          "startedAt": "1970-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: Data(legacy.utf8))

        XCTAssertNil(document.speakerCentroidsID)
        XCTAssertEqual(document.lines.count, 1)
    }

    func testCentroidsIDSurvivesARoundTrip() throws {
        var document = sample()
        document.speakerCentroidsID = "abc-123"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TranscriptDocument.self, from: encoder.encode(document))

        XCTAssertEqual(restored.speakerCentroidsID, "abc-123")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptDocumentTests`
Expected: FAIL to compile, "value of type 'TranscriptDocument' has no member 'speakerCentroidsID'".

- [ ] **Step 3: Write minimal implementation**

In `TranscriptDocument`, after `var speakerNames: [String: String]`:

```swift
    /// The `pending/<uuid>.json` holding this transcript's voiceprints, when profiles
    /// were enabled. Only the uuid is stored here: embeddings are biometric data and
    /// stay out of the recording folder, so a transcript you share carries none.
    var speakerCentroidsID: String?
```

In the `init(live:...)` extension, add `self.speakerCentroidsID = nil` alongside the other assignments.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptDocumentTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/TranscriptDocument.swift Tests/RecorderTests/TranscriptDocumentTests.swift
git commit -m "Link a transcript to its pending voiceprints by uuid"
```

---

### Task 8: Build the document from the structured result

**Files:**
- Modify: `Sources/Recorder/Preferences.swift`, `Sources/Recorder/RecorderModel.swift:573-610`
- Test: `Tests/RecorderTests/SpeakerProfileStoreTests.swift` (no new test; behaviour is covered by Tasks 4, 5, and 12)

**Interfaces:**
- Consumes: `OfflineTranscription`, `SpeakerNaming.resolve`, `SpeakerProfileStore`.
- Produces: `Preferences.voiceProfiles: Bool`, `RecorderModel.voiceProfilesEnabled: Bool`, `RecorderModel.speakerStore: SpeakerProfileStore`, `RecorderModel.lastDocument: TranscriptDocument?`

- [ ] **Step 1: Add the preference**

In `Preferences.Key`, add `static let voiceProfiles = "voiceProfilesEnabled"`. Then:

```swift
    /// Whether saved voiceprints are matched against new recordings, and whether renaming
    /// a speaker stores their voice. Default false: an embedding is biometric data under
    /// GDPR Art. 9, so this stays opt-in.
    static var voiceProfiles: Bool {
        get { defaults.bool(forKey: Key.voiceProfiles) }
        set { defaults.set(newValue, forKey: Key.voiceProfiles) }
    }
```

- [ ] **Step 2: Add the model state**

In `RecorderModel`, beside `speakerLabelsEnabled`:

```swift
    /// Whether voice profiles are matched and enrolled. Off by default.
    var voiceProfilesEnabled: Bool = false {
        didSet { Preferences.voiceProfiles = voiceProfilesEnabled }
    }

    let speakerStore = SpeakerProfileStore()

    /// The document behind the transcript currently shown, kept so a rename can
    /// re-render `transcript.md` from its source rather than patching the markdown.
    private(set) var lastDocument: TranscriptDocument?
```

In `loadPreferences()`, add `voiceProfilesEnabled = Preferences.voiceProfiles`.

In `onAppear()`, add `speakerStore.prunePending()`.

- [ ] **Step 3: Rewrite the transcription completion**

Replace the body of the `do` block in `startTranscription` (`RecorderModel.swift:587-603`):

```swift
                let offline = try await self.live.transcribeFile(audioURL)
                guard !offline.lines.isEmpty else {
                    self.transcriptionState = .failed("The model returned an empty transcript (silent audio?).")
                    self.statusMessage = "Transcription produced no text"
                    return
                }

                var names = offline.speakerNames
                var centroidsID: String?

                if self.voiceProfilesEnabled, !offline.clusters.isEmpty {
                    let assignments = SpeakerNaming.resolve(
                        clusters: offline.clusters,
                        defaultNames: offline.speakerNames,
                        profiles: self.speakerStore.profiles
                    )
                    for (id, assignment) in assignments {
                        names[id] = assignment.name
                    }
                    let pending = PendingSpeakers(
                        id: UUID().uuidString,
                        createdAt: Date(),
                        clusters: offline.clusters.reduce(into: [:]) { result, entry in
                            result[entry.key] = PendingSpeakers.Cluster(
                                vector: entry.value.centroid,
                                speechSeconds: entry.value.speechSeconds,
                                appliedProfileID: nil
                            )
                        }
                    )
                    do {
                        try self.speakerStore.writePending(pending)
                        centroidsID = pending.id
                    } catch {
                        Self.log.error("could not store voiceprints: \(error.localizedDescription)")
                    }
                }

                var document = TranscriptDocument(
                    meetingTitle: pending.meetingTitle,
                    attendees: pending.attendees,
                    startedAt: pending.startedAt,
                    audioName: audioURL.lastPathComponent,
                    model: self.live.loadedModelName ?? self.live.modelName,
                    isPolished: true,
                    lines: offline.lines.map {
                        TranscriptDocument.StoredLine(time: $0.time, text: $0.text, speakerID: $0.speaker)
                    },
                    speakerNames: names,
                    speakerCentroidsID: centroidsID
                )
                self.writeTranscript(document: document, pending: pending, keepStatus: false)
```

The local `pending` (a `PendingTranscription`) and the new `PendingSpeakers` share a word but not a type. If that reads badly, rename the `PendingSpeakers` local to `voiceprints`.

`document` is no longer mutated, so change `var document` to `let document` if the compiler warns.

- [ ] **Step 4: Record the document in writeTranscript**

In `writeTranscript`, after `lastTranscriptURL = markdownURL`, add:

```swift
        lastDocument = document
```

`RecorderModel` needs a logger if it lacks one. If `Self.log` is undefined, add near the other private statics:

```swift
    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "RecorderModel")
```

and `import os` at the top.

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` and no new failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Recorder/Preferences.swift Sources/Recorder/RecorderModel.swift
git commit -m "Resolve speaker names from profiles when a transcription finishes"
```

---

### Task 9: Rename and enroll

**Files:**
- Modify: `Sources/Recorder/RecorderModel.swift`
- Test: `Tests/RecorderTests/SpeakerProfileStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 7, 8.
- Produces: `SpeakerProfileStore.applyName(_:toCluster:pendingID:now:) throws -> UUID?`, `RecorderModel.renameSpeaker(id:to:)`, `RecorderModel.currentSpeakers: [(id: String, name: String)]`

- [ ] **Step 1: Write the failing test**

Append to `SpeakerProfileStoreTests`:

```swift
    func testApplyingANameEnrollsAndRecordsTheProfile() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(PendingSpeakers(
            id: "rec1",
            createdAt: Date(timeIntervalSince1970: 0),
            clusters: ["s1": PendingSpeakers.Cluster(vector: [1, 0], speechSeconds: 30, appliedProfileID: nil)]
        ))

        let profileID = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(store.profiles.first?.name, "Anna")
        XCTAssertEqual(store.profiles.first?.id, profileID)
        XCTAssertEqual(store.loadPending(id: "rec1")?.clusters["s1"]?.appliedProfileID, profileID)
    }

    func testCorrectingANameRetractsFromTheWrongProfileFirst() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(PendingSpeakers(
            id: "rec1",
            createdAt: Date(timeIntervalSince1970: 0),
            clusters: ["s1": PendingSpeakers.Cluster(vector: [1, 0], speechSeconds: 30, appliedProfileID: nil)]
        ))
        _ = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 10))

        let benID = try store.applyName("Ben", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.profiles.map(\.name), ["Ben"], "Anna kept no voiceprint, so Anna is gone")
        XCTAssertEqual(store.loadPending(id: "rec1")?.clusters["s1"]?.appliedProfileID, benID)
    }

    func testReapplyingTheSameNameReinforcesRatherThanDuplicating() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(PendingSpeakers(
            id: "rec1",
            createdAt: Date(timeIntervalSince1970: 0),
            clusters: ["s1": PendingSpeakers.Cluster(vector: [1, 0], speechSeconds: 30, appliedProfileID: nil)]
        ))
        let first = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 10))
        let second = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.centroids.count, 1, "the same cluster must not stack up centroids")
    }

    func testAShortClusterIsNeverEnrolled() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        try store.writePending(PendingSpeakers(
            id: "rec1",
            createdAt: Date(timeIntervalSince1970: 0),
            clusters: ["s1": PendingSpeakers.Cluster(
                vector: [1, 0],
                speechSeconds: SpeakerNaming.minSpeechSeconds - 0.1,
                appliedProfileID: nil
            )]
        ))

        let profileID = try store.applyName("Anna", toCluster: "s1", pendingID: "rec1", now: Date(timeIntervalSince1970: 10))

        XCTAssertNil(profileID)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testApplyingANameWithNoPendingRecordEnrollsNothing() throws {
        let store = SpeakerProfileStore(baseURL: baseURL)
        XCTAssertNil(try store.applyName("Anna", toCluster: "s1", pendingID: "missing", now: Date()))
        XCTAssertTrue(store.profiles.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: FAIL to compile, "value of type 'SpeakerProfileStore' has no member 'applyName'".

- [ ] **Step 3: Write the store method**

Add to `SpeakerProfileStore`:

```swift
    /// Name a cluster, which is the only way a voiceprint is ever stored.
    ///
    /// Auto-matching names a speaker but never writes, so the database only ever grows
    /// from a correction the user actually saw. Reapplying the same name reinforces the
    /// profile without stacking duplicate centroids for one cluster, and changing the name
    /// retracts this recording's contribution from the previous profile first.
    ///
    /// Returns the profile that now holds the voiceprint, or nil when nothing was
    /// enrolled: no pending record, no centroid, or too little speech to judge by.
    @discardableResult
    func applyName(
        _ name: String,
        toCluster clusterID: String,
        pendingID: String,
        now: Date = Date()
    ) throws -> UUID? {
        guard var pending = loadPending(id: pendingID),
              var cluster = pending.clusters[clusterID],
              !cluster.vector.isEmpty,
              cluster.speechSeconds >= SpeakerNaming.minSpeechSeconds else { return nil }

        if let previous = cluster.appliedProfileID {
            if profiles.first(where: { $0.id == previous })?.name.caseInsensitiveCompare(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame {
                return previous
            }
            try retract(centroidAddedAt: pending.createdAt, from: previous)
        }

        let profileID = try enroll(
            centroid: VoiceCentroid(
                vector: cluster.vector,
                sampleSeconds: cluster.speechSeconds,
                addedAt: pending.createdAt
            ),
            named: name
        )

        cluster.appliedProfileID = profileID
        pending.clusters[clusterID] = cluster
        try writePending(pending)
        return profileID
    }
```

The centroid is stamped with `pending.createdAt`, not `now`, so retraction can find exactly the centroid this recording contributed.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerProfileStoreTests`
Expected: PASS, 18 tests.

- [ ] **Step 5: Add the model surface**

In `RecorderModel`:

```swift
    /// The speakers of the transcript currently shown, in order of first speech.
    var currentSpeakers: [(id: String, name: String)] {
        guard let document = lastDocument else { return [] }
        return document.speakerIDs.map { ($0, document.displayName(for: $0)) }
    }

    /// Rename one speaker: re-render the transcript from its source, and when voice
    /// profiles are on, teach the store what that person sounds like.
    func renameSpeaker(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let document = lastDocument,
              let pending = lastTranscription else { return }

        if voiceProfilesEnabled,
           id != SpeakerNaming.micSpeakerID,
           let centroidsID = document.speakerCentroidsID {
            do {
                try speakerStore.applyName(trimmed, toCluster: id, pendingID: centroidsID)
            } catch {
                Self.log.error("could not update voice profiles: \(error.localizedDescription)")
                statusMessage = "Renamed, but the voice profile could not be saved"
            }
        }

        writeTranscript(
            document: document.renamingSpeaker(id, to: trimmed),
            pending: pending,
            keepStatus: true
        )
    }
```

- [ ] **Step 6: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` and no new failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/Recorder/SpeakerProfileStore.swift Sources/Recorder/RecorderModel.swift Tests/RecorderTests/SpeakerProfileStoreTests.swift
git commit -m "Enroll voiceprints by correction, retracting a wrong name first"
```

---

### Task 10: Speakers preferences tab

**Files:**
- Modify: `Sources/Recorder/PreferencesView.swift:14-28` (tabs), `:162-169` (move the existing section)
- Test: none. SwiftUI layout is verified by running the app in Task 11's step 4.

**Interfaces:**
- Consumes: `RecorderModel.voiceProfilesEnabled`, `RecorderModel.speakerStore`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the tab**

In `PreferencesView.body`, after `TranscriptionPreferences()`:

```swift
            SpeakerPreferences()
                .tabItem { Label("Speakers", systemImage: "person.wave.2") }
```

Update the doc comment's tab list to mention Speakers.

- [ ] **Step 2: Move the speakers section out of Transcription**

Delete the `Section { Toggle("Label speakers" ... } header: { Text("Speakers") }` block from `TranscriptionPreferences` (`:162-169`).

- [ ] **Step 3: Add the pane**

```swift
// MARK: - Speakers

private struct SpeakerPreferences: View {
    @Environment(RecorderModel.self) private var model
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Label speakers", isOn: $model.speakerLabelsEnabled)
                Text("Live lines are labeled You (microphone) or Them (desktop audio) from the channel layout. Transcribing a saved file transcribes each channel separately, so your own voice is always You, and the other voices are separated on-device and labeled Speaker 1, 2, ... (~50 MB one-time model download).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Labels")
            }

            Section {
                Toggle("Match voices to saved profiles", isOn: $model.voiceProfilesEnabled)
                Text("Renaming a speaker stores what that voice sounds like, so the same person is recognised in later recordings. A voiceprint is biometric data under GDPR Art. 9. It is kept in Application Support, never in the recording folder, so a transcript you share carries none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Voice profiles")
            }

            Section {
                if model.speakerStore.profiles.isEmpty {
                    Text("No saved voices yet. Rename a speaker in a finished transcript to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.speakerStore.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Spacer()
                            Text("\(profile.centroids.count) sample\(profile.centroids.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                try? model.speakerStore.delete(profileID: profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete \(profile.name)'s voice profile")
                        }
                    }

                    Button("Delete all voice data", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .confirmationDialog(
                        "Delete every saved voiceprint?",
                        isPresented: $confirmingDeleteAll,
                        titleVisibility: .visible
                    ) {
                        Button("Delete all voice data", role: .destructive) {
                            try? model.speakerStore.deleteAllVoiceData()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes every profile and every stored voiceprint, including ones waiting to be named. Transcripts keep the names already written into them.")
                    }
                }
            } header: {
                Text("Saved voices")
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/PreferencesView.swift
git commit -m "Add a Speakers preferences tab with the profile list"
```

---

### Task 11: Rename chips

**Files:**
- Modify: `Sources/Recorder/RecorderPanel.swift:417-458` (the `.done` case)
- Test: none automated. Step 4 is a manual run.

**Interfaces:**
- Consumes: `RecorderModel.currentSpeakers`, `RecorderModel.renameSpeaker(id:to:)`.
- Produces: nothing.

- [ ] **Step 1: Add the chip row**

In `transcriptionSection`'s `.done` case, after `transcriptDragHandle(url)`:

```swift
                if !model.currentSpeakers.isEmpty {
                    speakerChips
                }
```

- [ ] **Step 2: Add the chip views**

Add to the same view, near `transcriptDragHandle`:

```swift
    /// One chip per speaker, in order of first speech. Renaming re-renders
    /// `transcript.md` from `transcript.json`, and teaches the voice profile store when
    /// profiles are enabled.
    private var speakerChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speakers")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(model.currentSpeakers, id: \.id) { speaker in
                    SpeakerChip(id: speaker.id, name: speaker.name) { newName in
                        model.renameSpeaker(id: speaker.id, to: newName)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
```

At file scope, beside `LevelMeter`:

```swift
// MARK: - SpeakerChip

/// A speaker's current name, click to rename.
private struct SpeakerChip: View {
    let id: String
    let name: String
    let rename: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name
            editing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: id == SpeakerNaming.micSpeakerID ? "person.fill" : "person")
                    .font(.caption2)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(
                Capsule().fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help("Rename \(name)")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename speaker")
                    .font(.callout.weight(.medium))
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(apply)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func apply() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rename(trimmed)
        editing = false
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Verify in the app**

Run: `./build.sh && open Recorder.app`

Then, by hand:
1. Preferences, Speakers: turn on "Match voices to saved profiles".
2. Record about 30 seconds with both a microphone and some desktop audio, then stop.
3. Confirm the transcript shows `You` for your own lines and `Speaker 1` for the other voice.
4. Click the `Speaker 1` chip, rename it, confirm `transcript.md` re-renders with the new name throughout.
5. Preferences, Speakers: confirm the new profile is listed with 1 sample.
6. Record again with the same other voice and confirm the name is applied automatically.

- [ ] **Step 5: Commit**

```bash
git add Sources/Recorder/RecorderPanel.swift
git commit -m "Add rename chips under a finished transcript"
```

---

### Task 12: Gated verification against real audio

**Files:**
- Create: `Tests/RecorderTests/SpeakerDiarizationVerificationTests.swift`

**Interfaces:**
- Consumes: everything.
- Produces: nothing.

This is the check that reading the SpeakerKit source was right about `centroidSource` defaulting to a value that actually populates centroids. It follows the existing gated pattern in `LiveModelVerificationTests`.

- [ ] **Step 1: Write the test**

```swift
import XCTest
import AVFoundation
@testable import Recorder

/// Verification against a real recording, gated because it downloads models and needs a
/// stereo file produced by the app.
///
/// Run with:
///   RECORDER_LIVE_SPEAKERS=1 RECORDER_AUDIO=~/Documents/Recordings/<folder>/audio.m4a swift test --filter SpeakerDiarizationVerificationTests
final class SpeakerDiarizationVerificationTests: XCTestCase {

    private func audioURL() throws -> URL {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_LIVE_SPEAKERS"] == "1",
            "set RECORDER_LIVE_SPEAKERS=1 to run the real diarization check"
        )
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RECORDER_AUDIO"],
            "set RECORDER_AUDIO to a stereo audio.m4a recorded by the app"
        )
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    @MainActor
    func testRealRecordingProducesCentroidsAndAYouSpeaker() async throws {
        let url = try audioURL()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2, "the app writes desktop to ch0 and mic to ch1")

        let engine = LocalTranscriptionEngine()
        engine.labelSpeakers = true
        let result = try await engine.transcribeFile(url)

        XCTAssertFalse(result.lines.isEmpty, "the recording produced no transcript at all")

        let speakers = Set(result.lines.compactMap(\.speaker))
        XCTAssertTrue(
            speakers.contains(SpeakerNaming.micSpeakerID),
            "no line came from the microphone channel; check the recording actually has mic audio"
        )

        for (id, evidence) in result.clusters {
            XCTAssertFalse(
                evidence.centroid.isEmpty,
                "cluster \(id) has no centroid, so centroidSource is not populating them"
            )
            XCTAssertGreaterThan(evidence.speechSeconds, 0)
        }

        XCTAssertNil(
            result.clusters[SpeakerNaming.micSpeakerID],
            "the microphone must never produce a voiceprint"
        )
    }
}
```

- [ ] **Step 2: Run it gated off**

Run: `swift test --filter SpeakerDiarizationVerificationTests`
Expected: skipped, "set RECORDER_LIVE_SPEAKERS=1 to run the real diarization check".

- [ ] **Step 3: Run it for real**

Record about a minute with both channels active through the app, then:

Run: `RECORDER_LIVE_SPEAKERS=1 RECORDER_AUDIO=~/Documents/Recordings/<folder>/audio.m4a swift test --filter SpeakerDiarizationVerificationTests`
Expected: PASS. If centroids come back empty, pass an explicit `PyannoteDiarizationOptions(centroidSource: .finalAssignment)` to `kit.diarize` in `LocalTranscription.transcribeFile` and re-run.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS, with the env-gated tests skipped.

- [ ] **Step 5: Commit**

```bash
git add Tests/RecorderTests/SpeakerDiarizationVerificationTests.swift
git commit -m "Verify centroids and You attribution against a real recording"
```

---

## Self-Review

**Spec coverage.** Per-channel decode and the mono fallback are Task 6. Structured lines are Tasks 5 and 8. `SpeakerProfileStore` is Tasks 2, 3, and 9. Naming precedence and both constants are Task 4. The duration gate appears twice on purpose: Task 4 blocks matching, Task 9 blocks enrolling. One-profile-per-recording is Task 4. Storage layout and the Art. 9 separation are Tasks 2, 3, and 7. Enrollment by correction with retraction is Task 9. UI surfaces are Tasks 10 and 11. Error handling: diarization failure is Task 6, corrupt profiles is Task 2, missing pending is Task 9, store write failure is Tasks 8 and 9. Testing is spread across every task plus Task 12.

**Known gaps, accepted.** A single-channel decode failure is not separately recovered in Task 6: a throw from either channel fails the whole transcription, which matches today's behaviour. The spec's softer wording ("keeps the other channel's transcript") would need a per-channel `try?`, deliberately left out because a silent half-transcript is worse than a visible failure with a retry button. Renaming applies to the transcript most recently produced in this session, not to arbitrary older recordings from the library; re-transcribing an older recording makes it current and therefore renameable.

**Type consistency.** `SpeakerNaming.micSpeakerID` is the one definition of `"you"` and is used in Tasks 4, 5, 9, 11, and 12. `ClusterEvidence` is defined in Task 5 and consumed in Task 4, which is why Task 4's step 4 flags the ordering. `PendingSpeakers.Cluster.vector` is `[Float]` everywhere; `ClusterEvidence.centroid` is the same shape under a different name because one is the on-disk record and the other is the in-memory result. `applyName` takes `pendingID: String` matching `TranscriptDocument.speakerCentroidsID: String?`. `SpeakerProfile.maxCentroids` is referenced by Tasks 1 and 2. `VoiceMatching.cosineDistance` is used by Tasks 1 and 4.
