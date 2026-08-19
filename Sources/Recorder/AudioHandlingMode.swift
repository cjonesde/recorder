import Foundation

/// What a recording is allowed to leave on disk.
///
/// The high-quality pass needs audio to survive the recording, so choosing it is
/// choosing retention. One control keeps that trade a single unambiguous statement
/// rather than a pair of coupled toggles.
enum AudioHandlingMode: String, CaseIterable, Identifiable {
    case transcriptOnly
    case keepAudio
    case keepAudioAndPolish

    var id: String { rawValue }

    static let `default`: AudioHandlingMode = .keepAudioAndPolish

    var label: String {
        switch self {
        case .transcriptOnly: return "Transcript only"
        case .keepAudio: return "Keep audio"
        case .keepAudioAndPolish: return "Keep audio and run a high-quality pass"
        }
    }

    var detail: String {
        switch self {
        case .transcriptOnly:
            return "No audio is ever written to disk. Only transcript.md and transcript.json are saved."
        case .keepAudio:
            return "Saves audio.m4a next to the live transcript."
        case .keepAudioAndPolish:
            return "Saves audio.m4a, then re-transcribes it with the high-quality model and names speakers."
        }
    }

    var retainsAudio: Bool {
        self != .transcriptOnly
    }

    var runsPolishPass: Bool {
        self == .keepAudioAndPolish
    }

    /// True when this mode combined with the live setting would save nothing at all.
    func producesNothing(liveTranscriptionEnabled: Bool) -> Bool {
        self == .transcriptOnly && !liveTranscriptionEnabled
    }
}

/// The outcome of asking to change mode while a recording is in progress.
enum AudioHandlingChange: Equatable {
    case apply
    /// The requested mode would keep audio the recording never wrote.
    case refuseUpgrade
    /// The requested mode combined with the live setting would save nothing.
    case refuseNothingProduced

    static func decide(
        from active: AudioHandlingMode,
        to requested: AudioHandlingMode,
        liveTranscriptionEnabled: Bool
    ) -> AudioHandlingChange {
        if requested.producesNothing(liveTranscriptionEnabled: liveTranscriptionEnabled) {
            return .refuseNothingProduced
        }
        if requested.retainsAudio && !active.retainsAudio {
            return .refuseUpgrade
        }
        return .apply
    }

    /// Whether applying this change means closing and deleting the partial audio.
    static func deletesPartialAudio(
        from active: AudioHandlingMode,
        to requested: AudioHandlingMode
    ) -> Bool {
        active.retainsAudio && !requested.retainsAudio
    }
}

