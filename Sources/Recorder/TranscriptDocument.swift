import Foundation

/// The structured transcript, and the source of truth for `transcript.md`.
///
/// Speaker labels are stored as stable ids with a separate id-to-name map, so a rename
/// re-renders the document instead of patching markdown text.
struct TranscriptDocument: Codable, Equatable {

    struct StoredLine: Codable, Equatable {
        var time: TimeInterval
        var text: String
        var speakerID: String?
    }

    var meetingTitle: String?
    var attendees: [String]
    var startedAt: Date
    var audioName: String?
    var model: String
    var isPolished: Bool
    var lines: [StoredLine]
    var speakerNames: [String: String]

    /// The `pending/<uuid>.json` holding this transcript's voiceprints, when profiles
    /// were enabled. Only the uuid is stored here: embeddings are biometric data and
    /// stay out of the recording folder, so a transcript you share carries none.
    var speakerCentroidsID: String?

    /// Speaker ids in order of first speech.
    var speakerIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for line in lines {
            guard let id = line.speakerID, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    func displayName(for id: String) -> String {
        speakerNames[id] ?? id
    }

    func renamingSpeaker(_ id: String, to name: String) -> TranscriptDocument {
        guard speakerNames[id] != nil else { return self }
        var copy = self
        copy.speakerNames[id] = name
        return copy
    }

    func renderMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var header = "# Transcript"
        if let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            header += ": \(title)"
        }

        var out = [header, ""]
        out.append("- **Recorded:** \(formatter.string(from: startedAt))")
        if !attendees.isEmpty {
            out.append("- **Invited attendees:** \(attendees.joined(separator: ", "))")
        }
        if let audioName {
            out.append("- **Audio:** `\(audioName)`")
        } else {
            out.append("- **Audio:** not retained (transcript only)")
        }
        out.append("- **Model:** WhisperKit `\(model)` (on-device)")
        out.append("- **Source:** \(isPolished ? "high-quality pass over the recorded audio" : "live transcription")")
        out.append("")
        out.append("---")
        out.append("")

        for line in lines {
            let speaker = line.speakerID.map { displayName(for: $0) }
            out.append(TranscriptLine(time: line.time, text: line.text, speaker: speaker).markdown)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func load(from url: URL) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }

    func write(jsonTo url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension TranscriptDocument {

    init(
        live lines: [TranscriptLine],
        meetingTitle: String?,
        attendees: [String],
        startedAt: Date,
        audioName: String?,
        model: String
    ) {
        self.meetingTitle = meetingTitle
        self.attendees = attendees
        self.startedAt = startedAt
        self.audioName = audioName
        self.model = model
        self.isPolished = false
        self.lines = lines.map {
            StoredLine(time: $0.time, text: $0.text, speakerID: $0.speaker)
        }
        self.speakerNames = Dictionary(
            uniqueKeysWithValues: Set(lines.compactMap(\.speaker)).map { ($0, $0) }
        )
        self.speakerCentroidsID = nil
    }
}
