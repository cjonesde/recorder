import Foundation

public enum CoachSource: Sendable {
    case mic
    case desktop
}

public enum DetectorID: String, Codable, CaseIterable, Sendable {
    case pace
    case energy
    case soStarts
    case risingEndings
    case trailingEndings
    case raisedVoice
    case talkShare
    case interruptions

    public var isPromotable: Bool {
        switch self {
        case .pace, .soStarts, .risingEndings, .trailingEndings, .talkShare: return true
        case .energy, .raisedVoice, .interruptions: return false
        }
    }

    public var showsAsTrigger: Bool {
        switch self {
        case .energy, .talkShare: return false
        default: return true
        }
    }
}

public enum GateState: String, Codable, Sendable {
    case own
    case them
    case overlap
    case silence
    case unknown
}
