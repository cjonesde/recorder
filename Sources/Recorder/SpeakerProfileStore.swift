import Foundation
import Observation
import os

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

// MARK: - SpeakerProfileStore

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
    ///
    /// `nonisolated` because it is the default argument of `init`, which Swift evaluates
    /// at the call site rather than inside the actor.
    nonisolated static var defaultBaseURL: URL {
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
