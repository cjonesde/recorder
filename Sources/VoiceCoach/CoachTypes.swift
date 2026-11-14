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

public struct CoachLine: Sendable, Equatable {
    public let time: Double
    public let text: String
    public let isOwn: Bool

    public init(time: Double, text: String, isOwn: Bool) {
        self.time = time
        self.text = text
        self.isOwn = isOwn
    }
}

public struct CoachEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case session
        case sample
        case trigger
        case clip
        case preset
        case gap
    }

    public let t: Double
    public let kind: Kind
    public let detector: DetectorID?
    public let values: [String: Double]
    public let shown: Bool?
    public let note: String?
    public let id: String?

    public init(t: Double, kind: Kind, detector: DetectorID? = nil, values: [String: Double] = [:], shown: Bool? = nil, note: String? = nil, id: String? = nil) {
        self.t = (t * 1000).rounded() / 1000
        self.kind = kind
        self.detector = detector
        self.values = values.filter { $0.value.isFinite }.mapValues { ($0 * 10_000).rounded() / 10_000 }
        self.shown = shown
        self.note = note
        self.id = id
    }
}

public struct CoachHUDState: Equatable, Sendable {
    public var energy: Double?
    public var gate: GateState
    public var litCues: Set<DetectorID>
    public var talkShare: Double?
    public var talkShareHigh: Bool
    public var preset: CoachPreset

    public static func idle(_ preset: CoachPreset) -> CoachHUDState {
        CoachHUDState(energy: nil, gate: .silence, litCues: [], talkShare: nil, talkShareHigh: false, preset: preset)
    }
}

public struct ClipRequest: Equatable, Sendable {
    public let id: String
    public let detector: DetectorID
    public let start: Double
    public let end: Double

    public init(id: String, detector: DetectorID, start: Double, end: Double) {
        self.id = id
        self.detector = detector
        self.start = start
        self.end = end
    }
}

public struct CoachOutput: Sendable {
    public var hud: CoachHUDState
    public var events: [CoachEvent]
    public var clips: [ClipRequest]
}

public struct CoachSessionSummary: Codable, Equatable, Sendable {
    public let language: String
    public let ownSpeechSeconds: Double
    public let articulationRate: Double?
    public let levelDB: Double?

    public init(language: String, ownSpeechSeconds: Double, articulationRate: Double?, levelDB: Double?) {
        self.language = language
        self.ownSpeechSeconds = ownSpeechSeconds
        self.articulationRate = articulationRate
        self.levelDB = levelDB
    }
}
