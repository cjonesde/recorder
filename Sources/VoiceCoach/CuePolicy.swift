import Foundation

public enum CuePolicy {
    public static let showProbability = 0.5

    public static func isCueOffSession(index: Int, withholding: Bool) -> Bool {
        guard withholding, index > 0 else { return false }
        switch index {
        case 1...10: return index.isMultiple(of: 5)
        case 11...20: return index.isMultiple(of: 3)
        default: return index.isMultiple(of: 2)
        }
    }

    public static func decide(_ detector: DetectorID, config: CoachConfig, random: inout some RandomNumberGenerator) -> (shown: Bool, note: String) {
        guard config.isPromoted(detector) else { return (false, "shadow") }
        guard !config.cueOffSession else { return (false, "cue-off session") }
        guard config.withholding else { return (true, "shown") }
        let shown = Double.random(in: 0..<1, using: &random) < showProbability
        return (shown, shown ? "shown" : "withheld")
    }
}
