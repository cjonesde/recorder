import Foundation
import VoiceCoach

struct CoachMonitor: Equatable, Sendable {
    struct Check: Equatable, Sendable {
        var values: [String: Double] = [:]
        var note: String?
        var flags = 0
        var lastFlag: Double?
    }

    static let flaggingSeconds = CoachTuning.default.cueSeconds

    private(set) var checks: [DetectorID: Check] = [:]
    private(set) var now = 0.0

    mutating func absorb(_ events: [CoachEvent]) -> Bool {
        var changed = false
        for event in events {
            guard let detector = event.detector else { continue }
            switch event.kind {
            case .sample:
                checks[detector, default: Check()].values = event.values
                checks[detector, default: Check()].note = event.note
            case .trigger:
                checks[detector, default: Check()].flags += 1
                checks[detector, default: Check()].lastFlag = event.t
            default:
                continue
            }
            now = max(now, event.t)
            changed = true
        }
        return changed
    }

    func isFlagging(_ detector: DetectorID) -> Bool {
        guard let last = checks[detector]?.lastFlag else { return false }
        return now - last < Self.flaggingSeconds
    }
}

struct CoachCheckLine: Equatable, Identifiable {
    let detector: DetectorID
    let title: String
    let reading: String
    let limit: String
    let status: String
    let flags: Int?
    let flagging: Bool

    var id: DetectorID { detector }

    static let order: [DetectorID] = [.pace, .talkShare, .soStarts, .risingEndings, .trailingEndings, .raisedVoice, .interruptions, .energy]

    static func lines(monitor: CoachMonitor, preset: CoachPreset, promoted: Set<DetectorID>) -> [CoachCheckLine] {
        order.map { line(for: $0, monitor: monitor, preset: preset, promoted: promoted) }
    }

    private static func line(for detector: DetectorID, monitor: CoachMonitor, preset: CoachPreset, promoted: Set<DetectorID>) -> CoachCheckLine {
        let check = monitor.checks[detector]
        let values = check?.values ?? [:]
        let reading = check == nil ? "Waiting for audio" : self.reading(detector, values: values, note: check?.note)
        var flagging = monitor.isFlagging(detector)
        if detector == .talkShare {
            flagging = false
            if let share = values["talkShare"], let high = preset.talkShareHigh { flagging = share > high }
        }
        let counts = detector.showsAsTrigger && detector != .interruptions
        return CoachCheckLine(
            detector: detector,
            title: title(detector),
            reading: reading,
            limit: limit(detector, preset: preset),
            status: status(detector, promoted: promoted),
            flags: counts ? check?.flags ?? 0 : nil,
            flagging: flagging
        )
    }

    static func title(_ detector: DetectorID) -> String {
        switch detector {
        case .pace: return "Pace"
        case .talkShare: return "Talk share"
        case .soStarts: return "\u{201C}So\u{201D} at sentence start"
        case .risingEndings: return "Rising endings"
        case .trailingEndings: return "Trailing endings"
        case .raisedVoice: return "Raised voice"
        case .interruptions: return "Interruptions"
        case .energy: return "Energy"
        }
    }

    private static func status(_ detector: DetectorID, promoted: Set<DetectorID>) -> String {
        switch detector {
        case .energy: return "On the bar"
        case .raisedVoice, .interruptions: return "Log only"
        default: return promoted.contains(detector) ? "On the bar" : "Logged only"
        }
    }

    private static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    private static func signed(_ value: Double) -> String { String(format: "%+.1f", value) }

    private static func number(_ value: Double) -> String { String(format: "%g", value) }

    private static func reading(_ detector: DetectorID, values: [String: Double], note: String?) -> String {
        func count(_ key: String) -> Int { Int(values[key] ?? 0) }
        switch detector {
        case .pace:
            if let ratio = values["ratio"] { return "\(percent(ratio))% of your usual pace" }
            switch note {
            case "not speaking": return "Not speaking"
            case "no baseline": return "Learning your usual pace"
            default: return "Measuring"
            }
        case .talkShare:
            guard let share = values["talkShare"] else { return "Needs \(Int(CoachLimits.talkShareMinimumSeconds)) s of talking" }
            return "You: \(percent(share))% of the talking"
        case .soStarts:
            if note == "engine lags" { return "Needs the Apple engine" }
            let starts = count("starts")
            let sentences = count("sentences")
            guard let rate = values["rate"], sentences >= CoachLimits.soMinimum else {
                return "Needs \(CoachLimits.soMinimum) sentences (\(sentences) so far)"
            }
            return "\(percent(rate))% of recent sentences, \(starts) of \(sentences) this call"
        case .risingEndings:
            let measured = count("measured")
            guard measured > 0 else { return "No measured endings yet" }
            return "\(count("rises")) of your last \(measured) endings rose"
        case .trailingEndings:
            let phrases = count("phrases")
            guard phrases > 0 else { return "No sentence endings yet" }
            return "\(count("trailing")) of your last \(phrases) endings faded out"
        case .raisedVoice:
            let parts = [values["pitchOffsetST"].map { "pitch \(signed($0)) st" }, values["levelOffsetDB"].map { "level \(signed($0)) dB" }].compactMap { $0 }
            guard !parts.isEmpty else { return "Learning your usual voice" }
            let text = parts.joined(separator: ", ") + " vs usual"
            return text.prefix(1).uppercased() + text.dropFirst()
        case .interruptions:
            return "You cut in \(count("interruptedThem"))\u{00D7}, they cut in \(count("wasInterrupted"))\u{00D7}"
        case .energy:
            if let offset = values["offsetDB"] { return "Level \(signed(offset)) dB vs usual" }
            if let level = values["levelDB"] { return "Level \(Int(level.rounded())) dB" }
            return "Waiting for your voice"
        }
    }

    private static func limit(_ detector: DetectorID, preset: CoachPreset) -> String {
        switch detector {
        case .pace:
            return "Flags at \(percent(preset.paceRatio))% for \(CoachLimits.paceSeconds) s"
        case .talkShare:
            return preset.talkShareHigh.map { "High above \(percent($0))%" } ?? "No limit for presentations"
        case .soStarts:
            return "Flags at \(percent(CoachLimits.soShare))% of the last \(CoachLimits.soWindow) sentences"
        case .risingEndings:
            return "Flags each rise of \(number(CoachLimits.risingSemitones)) st or more, at most every \(number(CoachLimits.endingsRefractory)) s"
        case .trailingEndings:
            return "Flags at \(CoachLimits.trailingCount) of the last \(CoachLimits.endingsWindow)"
        case .raisedVoice:
            return "Flags at +\(number(CoachLimits.raisedPitchST)) st and +\(number(CoachLimits.raisedLevelDB)) dB for \(CoachLimits.raisedSeconds) s"
        case .interruptions:
            return "Counted, never flags"
        case .energy:
            return "The bar in the capsule"
        }
    }
}
