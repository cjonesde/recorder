import Foundation

struct SyllablePeak: Equatable {
    let t: Double
    let db: Double
    let riseDB: Double
}

struct PaceDetector {
    static let hysteresisDB = 2.0
    static let voicedTolerance = 0.03
    static let gapFill = 0.3
    static let windowFrames = 1000
    static let minimumFrames = 500
    static let consecutiveTicks = 3
    static let refractory = 30.0
    static let sessionBaselineSeconds = 120.0
    static let speakingRecency = 1.0
    static let historyLimit = 3600

    let tuning: CoachTuning
    let baselineRate: Double?

    private var rising = true
    private var extreme = -Double.infinity
    private var extremeT = 0.0
    private var extremeOwn = false
    private var extremeFloor = 0.0
    private var dipBeforePeak = Double.infinity
    private var currentDip = Double.infinity
    private var voicedTimes: [Double] = []
    private var increments: [(t: Double, seconds: Double)] = []
    private var incrementHead = 0
    private var speakingSeconds = 0.0
    private var lastOwnT: Double?
    private var syllables: [Double] = []
    private var syllableHead = 0
    private var aboveCount = 0
    private var lastTrigger = -Double.infinity
    private(set) var ownSeconds = 0.0
    private(set) var rateHistory: [Double] = []
    private(set) var lastPeak: SyllablePeak?
    private(set) var totalSyllables = 0

    init(tuning: CoachTuning, baselineRate: Double?) {
        self.tuning = tuning
        self.baselineRate = baselineRate
    }

    var rate: Double? {
        let frames = increments.count - incrementHead
        guard frames >= Self.minimumFrames, speakingSeconds > 0 else { return nil }
        return Double(syllables.count - syllableHead) / speakingSeconds
    }

    var effectiveBaseline: Double? {
        if let baselineRate { return baselineRate }
        guard ownSeconds >= Self.sessionBaselineSeconds else { return nil }
        return median(rateHistory)
    }

    var sessionRateMedian: Double? { median(rateHistory) }

    mutating func observe(_ frame: FrameAnalysis) {
        guard frame.gate == .own || frame.gate == .silence else {
            resetPicker()
            return
        }
        if frame.f0 > 0 { voicedTimes.append(frame.t) }
        if voicedTimes.count > 200 { voicedTimes.removeFirst(100) }
        if frame.isOwn { countSpeaking(at: frame.t) }
        pick(frame)
    }

    private mutating func resetPicker() {
        rising = true
        extreme = -.infinity
        dipBeforePeak = .infinity
        currentDip = .infinity
    }

    private mutating func countSpeaking(at t: Double) {
        let step = tuning.frameSeconds
        var seconds = step
        if let last = lastOwnT, t - last <= Self.gapFill { seconds = t - last }
        lastOwnT = t
        ownSeconds += step
        increments.append((t, seconds))
        speakingSeconds += seconds
        while increments.count - incrementHead > Self.windowFrames {
            speakingSeconds -= increments[incrementHead].seconds
            incrementHead += 1
        }
        if incrementHead > 4096 {
            increments.removeFirst(incrementHead)
            incrementHead = 0
        }
        let oldest = increments[incrementHead].t
        while syllableHead < syllables.count && syllables[syllableHead] < oldest { syllableHead += 1 }
        if syllableHead > 4096 {
            syllables.removeFirst(syllableHead)
            syllableHead = 0
        }
    }

    private mutating func pick(_ frame: FrameAnalysis) {
        if rising {
            currentDip = min(currentDip, frame.micDB)
            if frame.micDB > extreme {
                extreme = frame.micDB
                extremeT = frame.t
                extremeOwn = frame.isOwn
                extremeFloor = frame.floorDB
                dipBeforePeak = currentDip
            } else if frame.micDB < extreme - Self.hysteresisDB {
                confirmPeak()
                rising = false
                extreme = frame.micDB
            }
        } else {
            if frame.micDB < extreme {
                extreme = frame.micDB
            } else if frame.micDB > extreme + Self.hysteresisDB {
                rising = true
                currentDip = extreme
                extreme = frame.micDB
                extremeT = frame.t
                extremeOwn = frame.isOwn
                extremeFloor = frame.floorDB
                dipBeforePeak = currentDip
            }
        }
    }

    private mutating func confirmPeak() {
        guard extremeOwn, extreme > extremeFloor + tuning.speechAboveFloorDB else { return }
        let voiced = voicedTimes.contains { abs($0 - extremeT) <= Self.voicedTolerance + 1e-9 }
        guard voiced else { return }
        syllables.append(extremeT)
        totalSyllables += 1
        let rise = dipBeforePeak.isFinite ? extreme - dipBeforePeak : 0
        lastPeak = SyllablePeak(t: extremeT, db: extreme, riseDB: rise)
    }

    func isSpeaking(at t: Double) -> Bool {
        guard let lastOwnT else { return false }
        return t - lastOwnT <= Self.speakingRecency
    }

    mutating func tick(at t: Double, paceRatio: Double) -> (trigger: Bool, values: [String: Double], note: String?) {
        var values: [String: Double] = [:]
        guard isSpeaking(at: t) else {
            aboveCount = 0
            if let baseline = effectiveBaseline { values["baseline"] = baseline }
            return (false, values, "not speaking")
        }
        if let rate {
            rateHistory.append(rate)
            if rateHistory.count > Self.historyLimit { rateHistory.removeFirst(rateHistory.count - Self.historyLimit) }
            values["rate"] = rate
        }
        guard let baseline = effectiveBaseline, baseline > 0 else {
            aboveCount = 0
            return (false, values, "no baseline")
        }
        values["baseline"] = baseline
        guard let rate else {
            aboveCount = 0
            return (false, values, nil)
        }
        let ratio = rate / baseline
        values["ratio"] = ratio
        aboveCount = ratio >= paceRatio ? aboveCount + 1 : 0
        guard aboveCount >= Self.consecutiveTicks, t - lastTrigger >= Self.refractory else { return (false, values, nil) }
        lastTrigger = t
        aboveCount = 0
        return (true, values, nil)
    }
}
