import Foundation

struct OwnVoiceGate {
    let tuning: CoachTuning
    private(set) var micFloorDB: Double = .nan
    private(set) var echoGainDB: Double?
    private let risePerFrame: Double
    private var echoGains: [Double] = []
    private var echoHead = 0
    private var echoSinceRefresh = 0

    init(tuning: CoachTuning) {
        self.tuning = tuning
        risePerFrame = tuning.floorRiseDBPerSecond * tuning.frameSeconds
    }

    func isMicSpeech(_ db: Double) -> Bool {
        let floor = micFloorDB.isNaN ? FrameAnalyzer.floorDB : micFloorDB
        return db > max(floor + tuning.speechAboveFloorDB, tuning.speechMinimumDB)
    }

    func isTapActive(_ db: Double) -> Bool { db > tuning.tapQuietDB }

    mutating func classify(micDB: Double, desktopDB: [Double?]) -> GateState {
        let echoReach = tuning.hangoverFrames + tuning.frames(tuning.echoAheadSeconds)
        var loudest = -Double.infinity
        var echoSource = -Double.infinity
        for (offset, level) in desktopDB.enumerated() {
            guard let level else { return .unknown }
            loudest = max(loudest, level)
            if offset <= echoReach { echoSource = max(echoSource, level) }
        }
        guard isTapActive(loudest) else {
            updateFloor(micDB)
            return isMicSpeech(micDB) ? .own : .silence
        }
        learnEcho(micDB - echoSource, source: echoSource)
        let expectedEcho = echoSource + max(echoGainDB ?? 0, tuning.echoFloorDB)
        return isMicSpeech(micDB) && micDB > expectedEcho + tuning.overlapMarginDB ? .overlap : .them
    }

    private mutating func learnEcho(_ gain: Double, source: Double) {
        guard source > tuning.echoLearnAboveDB else { return }
        if echoGains.count < tuning.echoHistoryFrames {
            echoGains.append(gain)
        } else {
            echoGains[echoHead] = gain
            echoHead = (echoHead + 1) % tuning.echoHistoryFrames
        }
        echoSinceRefresh += 1
        guard echoGains.count >= tuning.echoMinimumFrames, echoSinceRefresh >= tuning.echoRefreshFrames else { return }
        echoSinceRefresh = 0
        let sorted = echoGains.sorted()
        echoGainDB = sorted[Int((Double(sorted.count - 1) * tuning.echoPercentile).rounded())]
    }

    private mutating func updateFloor(_ db: Double) {
        if micFloorDB.isNaN || db < micFloorDB {
            micFloorDB = db
        } else {
            micFloorDB += risePerFrame
        }
    }
}
