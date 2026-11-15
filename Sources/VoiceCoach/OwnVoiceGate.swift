import Foundation

struct OwnVoiceGate {
    let tuning: CoachTuning
    private(set) var micFloorDB: Double = .nan
    private let risePerFrame: Double

    init(tuning: CoachTuning) {
        self.tuning = tuning
        risePerFrame = tuning.floorRiseDBPerSecond * tuning.frameSeconds
    }

    func isMicSpeech(_ db: Double) -> Bool {
        let floor = micFloorDB.isNaN ? FrameAnalyzer.floorDB : micFloorDB
        return db > max(floor + tuning.speechAboveFloorDB, tuning.speechMinimumDB)
    }

    func isTapActive(_ db: Double) -> Bool { db > tuning.tapQuietDB }

    mutating func classify(micDB: Double, desktopDB: [Double?], currentDesktopDB: Double?) -> GateState {
        guard desktopDB.allSatisfy({ $0 != nil }) else { return .unknown }
        let tapNear = desktopDB.contains { isTapActive($0!) }
        if !tapNear { updateFloor(micDB) }
        let speech = isMicSpeech(micDB)
        if tapNear {
            if speech, let current = currentDesktopDB, micDB > current + tuning.overlapMarginDB {
                return .overlap
            }
            return .them
        }
        return speech ? .own : .silence
    }

    private mutating func updateFloor(_ db: Double) {
        if micFloorDB.isNaN || db < micFloorDB {
            micFloorDB = db
        } else {
            micFloorDB += risePerFrame
        }
    }
}
