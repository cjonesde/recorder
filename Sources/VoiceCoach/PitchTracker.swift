import Foundation

struct PitchTracker {
    let window: Int
    let minLag: Int
    let maxLag: Int
    let threshold: Double
    let rate: Double

    init(tuning: CoachTuning) {
        window = tuning.yinWindow
        rate = tuning.analysisRate
        minLag = max(2, Int((tuning.analysisRate / tuning.pitchCeiling).rounded(.down)))
        maxLag = Int((tuning.analysisRate / tuning.pitchFloor).rounded(.up))
        threshold = tuning.yinThreshold
    }

    var span: Int { window + maxLag }

    func f0(_ samples: ArraySlice<Float>) -> Double {
        guard samples.count >= span else { return 0 }
        var difference = [Double](repeating: 0, count: maxLag + 1)
        samples.withContiguousStorageIfAvailable { buffer in
            let base = buffer.count - span
            for lag in 1...maxLag {
                var sum = 0.0
                var j = 0
                while j < window {
                    let delta = Double(buffer[base + j] - buffer[base + j + lag])
                    sum += delta * delta
                    j += 1
                }
                difference[lag] = sum
            }
        }
        var normalized = [Double](repeating: 1, count: maxLag + 1)
        var running = 0.0
        for lag in 1...maxLag {
            running += difference[lag]
            normalized[lag] = running > 0 ? difference[lag] * Double(lag) / running : 1
        }
        var lag = minLag
        while lag <= maxLag {
            if normalized[lag] < threshold {
                while lag + 1 <= maxLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                return rate / refine(normalized, at: lag)
            }
            lag += 1
        }
        return 0
    }

    private func refine(_ curve: [Double], at lag: Int) -> Double {
        guard lag > 1, lag + 1 < curve.count else { return Double(lag) }
        let left = curve[lag - 1], centre = curve[lag], right = curve[lag + 1]
        let denominator = left - 2 * centre + right
        guard abs(denominator) > 1e-12 else { return Double(lag) }
        let shift = 0.5 * (left - right) / denominator
        return Double(lag) + max(-1, min(1, shift))
    }
}
