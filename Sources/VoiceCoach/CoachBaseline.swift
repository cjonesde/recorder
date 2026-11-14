import Foundation

public struct CoachBaseline: Codable, Equatable, Sendable {
    public static let keep = 10
    public static let minimumSessions = 3
    public static let minimumOwnSeconds = 120.0

    public var rates: [String: [Double]] = [:]
    public var levels: [String: [Double]] = [:]

    public init() {}

    public func rate(language: String) -> Double? {
        Self.value(rates[language])
    }

    public func level(mic: String) -> Double? {
        Self.value(levels[mic])
    }

    public mutating func record(_ summary: CoachSessionSummary, mic: String) {
        guard summary.ownSpeechSeconds >= Self.minimumOwnSeconds else { return }
        if let rate = summary.articulationRate { rates[summary.language] = Self.appending(rate, to: rates[summary.language]) }
        if let level = summary.levelDB { levels[mic] = Self.appending(level, to: levels[mic]) }
    }

    private static func value(_ history: [Double]?) -> Double? {
        guard let history, history.count >= minimumSessions else { return nil }
        return median(history)
    }

    private static func appending(_ value: Double, to history: [Double]?) -> [Double] {
        Array(((history ?? []) + [value]).suffix(keep))
    }
}
