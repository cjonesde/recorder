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

    /// Every line's text with no timestamps or speaker labels, for checks that care only
    /// about how much speech came back.
    var spokenText: String {
        lines.map(\.text).joined(separator: " ")
    }

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
