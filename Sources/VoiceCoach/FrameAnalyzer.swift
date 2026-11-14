import Foundation

struct LevelFrame: Equatable {
    let index: Int
    let db: Double
}

struct FrameAnalyzer {
    static let floorDB = -120.0

    let hop: Int
    let levelWindow: Int
    let retained: Int
    private var history: [Float] = []
    private var historyStart = 0
    private var nextFrame = 0

    init(tuning: CoachTuning, retainedSeconds: Double = 4) {
        hop = tuning.hop
        levelWindow = tuning.levelWindow
        retained = Int(retainedSeconds * tuning.analysisRate)
    }

    var totalSamples: Int { historyStart + history.count }
    var framesProduced: Int { nextFrame }

    mutating func push(_ samples: [Float]) -> [LevelFrame] {
        history.append(contentsOf: samples)
        var frames: [LevelFrame] = []
        while (nextFrame + 1) * hop <= totalSamples {
            let end = (nextFrame + 1) * hop
            let start = max(historyStart, end - levelWindow)
            var energy = 0.0
            for i in (start - historyStart)..<(end - historyStart) {
                let v = Double(history[i])
                energy += v * v
            }
            let meanSquare = energy / Double(levelWindow)
            let db = meanSquare > 0 ? max(Self.floorDB, 10 * log10(meanSquare)) : Self.floorDB
            frames.append(LevelFrame(index: nextFrame, db: db))
            nextFrame += 1
        }
        if history.count > retained + retained / 2 {
            let drop = history.count - retained
            history.removeFirst(drop)
            historyStart += drop
        }
        return frames
    }

    func window(endingAt index: Int, length: Int) -> ArraySlice<Float>? {
        let end = (index + 1) * hop
        let start = end - length
        guard start >= historyStart, end <= totalSamples else { return nil }
        return history[(start - historyStart)..<(end - historyStart)]
    }
}
