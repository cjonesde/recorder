import Foundation

public enum CoachPreset: String, Codable, CaseIterable, Sendable {
    case presentation
    case oneOnOne
    case group

    public var paceRatio: Double {
        switch self {
        case .presentation: return 1.10
        case .oneOnOne: return 1.20
        case .group: return 1.15
        }
    }

    public var talkShareHigh: Double? {
        switch self {
        case .presentation: return nil
        case .oneOnOne: return 0.65
        case .group: return 0.40
        }
    }
}

extension CoachPreset {
    public static func pick(attendeeCount: Int?) -> CoachPreset {
        guard let attendeeCount else { return .presentation }
        switch attendeeCount {
        case ...2: return .oneOnOne
        case 3...7: return .group
        default: return .presentation
        }
    }
}
