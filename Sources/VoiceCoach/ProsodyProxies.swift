import Foundation

struct ProsodyProxies {
    static let windowSeconds = 5.0
    static let minimumWindowVoiced = 50
    static let minimumSessionVoiced = 500
    static let pitchThresholdST = 2.0
    static let levelThresholdDB = 4.0
    static let consecutiveTicks = 3
    static let refractory = 60.0

    private var recentF0: [(t: Double, hz: Double)] = []
    private var recentHead = 0
    private var recentPeaks: [(t: Double, rise: Double)] = []
    private var histogram = [Int](repeating: 0, count: 601)
    private var voiced = 0
    private var aboveCount = 0
    private var lastTrigger = -Double.infinity
    private var now = 0.0

    var sessionF0: Double? {
        guard voiced >= Self.minimumSessionVoiced else { return nil }
        var seen = 0
        for (hz, count) in histogram.enumerated() {
            seen += count
            if seen * 2 >= voiced { return Double(max(hz, 1)) }
        }
        return nil
    }

    var pitchOffsetST: Double? {
        let window = recentF0[recentHead...].filter { $0.t > now - Self.windowSeconds }
        guard window.count >= Self.minimumWindowVoiced, let reference = sessionF0 else { return nil }
        return sortedMedian(window.map { 12 * log2($0.hz / reference) })
    }

    var onsetSlope: Double? {
        let window = recentPeaks.filter { $0.t > now - Self.windowSeconds }
        guard !window.isEmpty else { return nil }
        return window.map(\.rise).reduce(0, +) / Double(window.count)
    }

    mutating func observe(_ frame: FrameAnalysis, newPeak: SyllablePeak?) {
        now = frame.t
        if frame.isOwn && frame.f0 > 0 {
            recentF0.append((frame.t, frame.f0))
            histogram[max(0, min(600, Int(frame.f0.rounded())))] += 1
            voiced += 1
        }
        while recentHead < recentF0.count && recentF0[recentHead].t <= frame.t - Self.windowSeconds { recentHead += 1 }
        if recentHead > 2048 {
            recentF0.removeFirst(recentHead)
            recentHead = 0
        }
        if let newPeak {
            recentPeaks.append((newPeak.t, newPeak.riseDB))
            recentPeaks.removeAll { $0.t <= frame.t - Self.windowSeconds }
        }
    }

    mutating func tick(at t: Double, levelOffsetDB: Double?, rateRatio: Double?) -> (trigger: Bool, values: [String: Double]) {
        var values: [String: Double] = [:]
        let pitch = pitchOffsetST
        if let pitch { values["pitchOffsetST"] = pitch }
        if let levelOffsetDB { values["levelOffsetDB"] = levelOffsetDB }
        if let rateRatio { values["rateRatio"] = rateRatio }
        if let onsetSlope { values["onsetSlope"] = onsetSlope }
        let raised = (pitch ?? 0) >= Self.pitchThresholdST && (levelOffsetDB ?? 0) >= Self.levelThresholdDB
        aboveCount = raised ? aboveCount + 1 : 0
        guard aboveCount >= Self.consecutiveTicks, t - lastTrigger >= Self.refractory else { return (false, values) }
        lastTrigger = t
        aboveCount = 0
        return (true, values)
    }
}
