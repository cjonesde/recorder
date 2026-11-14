import Foundation
@testable import VoiceCoach

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Synth {
    static func amplitude(forRMSDB db: Double) -> Double {
        let harmonicPower = (1...5).reduce(0.0) { $0 + 1.0 / Double($1 * $1) } / 2
        return pow(10, db / 20) / sqrt(harmonicPower)
    }

    static func voice(
        f0: (Double) -> Double,
        syllablesPerSecond: Double,
        seconds: Double,
        rate: Double = 48_000,
        levelDB: Double = -20,
        envelope: ((Double) -> Double)? = nil,
        noiseDB: Double? = -65,
        seed: UInt64 = 1
    ) -> [Float] {
        let count = Int(seconds * rate)
        let amplitude = amplitude(forRMSDB: levelDB)
        let period = 1 / syllablesPerSecond
        var phase = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            phase += 2 * .pi * f0(t) / rate
            var tone = 0.0
            for k in 1...5 { tone += sin(Double(k) * phase) / Double(k) }
            let u = t.truncatingRemainder(dividingBy: period) / period
            let burst = u < 0.6 ? 0.5 * (1 - cos(2 * .pi * u / 0.6)) : 0
            let shape = 0.1 + 0.9 * burst
            let gain = envelope?(t) ?? 1
            out[i] = Float(amplitude * tone * shape * gain)
        }
        if let noiseDB { mix(&out, noise(seconds: seconds, db: noiseDB, rate: rate, seed: seed)) }
        return out
    }

    static func steady(f0: Double, seconds: Double, rate: Double = 48_000, levelDB: Double = -20) -> [Float] {
        let count = Int(seconds * rate)
        let amplitude = amplitude(forRMSDB: levelDB)
        return (0..<count).map { i in
            let phase = 2 * .pi * f0 * Double(i) / rate
            var tone = 0.0
            for k in 1...5 { tone += sin(Double(k) * phase) / Double(k) }
            return Float(amplitude * tone)
        }
    }

    static func silence(seconds: Double, rate: Double = 48_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    static func noise(seconds: Double, db: Double, rate: Double = 48_000, seed: UInt64 = 1) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let amplitude = pow(10, db / 20) * sqrt(3.0)
        return (0..<Int(seconds * rate)).map { _ in Float(Double.random(in: -1...1, using: &rng) * amplitude) }
    }

    static func mix(_ base: inout [Float], _ other: [Float], at offset: Int = 0, gain: Float = 1) {
        for (i, v) in other.enumerated() where offset + i < base.count && offset + i >= 0 {
            base[offset + i] += v * gain
        }
    }

    static func delayed(_ signal: [Float], seconds: Double, gainDB: Double, rate: Double = 48_000) -> [Float] {
        let shift = Int(seconds * rate)
        let gain = Float(pow(10, gainDB / 20))
        var out = [Float](repeating: 0, count: signal.count)
        for i in shift..<signal.count { out[i] = signal[i - shift] * gain }
        return out
    }

    static func downsampled(_ samples: [Float], rate: Double = 48_000) -> [Float] {
        var downsampler = Downsampler()
        var out: [Float] = []
        samples.withUnsafeBufferPointer { downsampler.process($0, rate: rate, into: &out) }
        return out
    }
}
