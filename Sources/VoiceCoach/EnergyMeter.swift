import Foundation

struct EnergyMeter {
    static let windowFrames = 300
    static let sessionBaselineFrames = 3000
    static let holdSeconds = 20.0
    static let lowOffset = -9.0
    static let span = 15.0

    let baselineLevelDB: Double?
    private var window = RollingWindow(capacity: EnergyMeter.windowFrames)
    private var histogram = [Int](repeating: 0, count: 241)
    private var ownFrames = 0
    private var lastOwnT = -Double.infinity

    init(baselineLevelDB: Double?) {
        self.baselineLevelDB = baselineLevelDB
    }

    mutating func observe(_ frame: FrameAnalysis) {
        guard frame.isOwn else { return }
        window.append(frame.micDB)
        lastOwnT = frame.t
        ownFrames += 1
        let bin = Int(((frame.micDB + 120) * 2).rounded())
        histogram[max(0, min(histogram.count - 1, bin))] += 1
    }

    var sessionLevelMedian: Double? {
        guard ownFrames > 0 else { return nil }
        var seen = 0
        for (bin, count) in histogram.enumerated() {
            seen += count
            if seen * 2 >= ownFrames { return Double(bin) / 2 - 120 }
        }
        return nil
    }

    var effectiveBaseline: Double? {
        if let baselineLevelDB { return baselineLevelDB }
        return ownFrames >= Self.sessionBaselineFrames ? sessionLevelMedian : nil
    }

    var levelDB: Double? { window.median }

    var offsetDB: Double? {
        guard let level = levelDB, let baseline = effectiveBaseline else { return nil }
        return level - baseline
    }

    func value(at t: Double) -> Double? {
        guard t - lastOwnT <= Self.holdSeconds, let offset = offsetDB else { return nil }
        return min(1, max(0, (offset - Self.lowOffset) / Self.span))
    }

    func sample(at t: Double) -> [String: Double] {
        var values: [String: Double] = [:]
        if let levelDB { values["levelDB"] = levelDB }
        if let offsetDB { values["offsetDB"] = offsetDB }
        if let energy = value(at: t) { values["energy"] = energy }
        return values
    }
}
