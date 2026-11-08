import Foundation

enum LiveStopReason: String, Codable, Sendable, CaseIterable {
    case desktopAudioAged
    case micAudioAged
    case handoffFull
    case engineQueueFull
    case engineFellBehind
    case desktopRingOverflow
    case engineError
    case finalizationTimedOut

    var message: String {
        switch self {
        case .desktopAudioAged: return "Desktop audio waited longer than 0.5 s before the engine took it."
        case .micAudioAged: return "Microphone audio waited longer than 0.5 s before the engine took it."
        case .handoffFull: return "The audio handoff to the engine filled up."
        case .engineQueueFull: return "The speech engine stopped accepting audio."
        case .engineFellBehind: return "The speech engine fell too far behind the audio."
        case .desktopRingOverflow: return "Desktop audio capture overflowed before it could be processed."
        case .engineError: return "The speech engine reported an error."
        case .finalizationTimedOut: return "Finishing the transcript took too long."
        }
    }
}

struct LiveStopError: LocalizedError, Equatable {
    let reason: LiveStopReason
    let detail: String?

    var errorDescription: String? {
        guard let detail, !detail.isEmpty else { return reason.message }
        return "\(reason.message) (\(detail))"
    }
}
