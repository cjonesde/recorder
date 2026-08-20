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
