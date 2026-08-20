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
