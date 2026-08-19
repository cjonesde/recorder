import Foundation

// MARK: - TranscriptLine

/// One confirmed line of the live transcript, timestamped relative to the
/// start of the recording. `speaker` is a display label ("You"/"Them" from
/// channel attribution, "Speaker N" from diarization) or nil when unknown.
struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    let speaker: String?

    var markdown: String {
        let prefix = speaker.map { "**\($0)**: " } ?? ""
        return "[\(timestampLabel)] \(prefix)\(text)"
    }

    var timestampLabel: String {
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
