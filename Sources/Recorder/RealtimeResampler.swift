import Foundation

/// Allocation-free linear-interpolation resampler for use inside a realtime audio
/// callback. Converts one mono stream from `inputRate` to a fixed `outputRate`,
/// carrying interpolation state across calls.
final class RealtimeResampler {

    let outputRate: Double

    private(set) var inputRate: Double = 0

    private var pos = 0.0
    private var prev: Float = 0
    private var hasPrev = false

    var isPassThrough: Bool { inputRate == outputRate }

    init(outputRate: Double) {
        self.outputRate = outputRate
    }

    /// Adopt a new input rate and drop carried interpolation state. Only safe while
    /// the producer is stopped.
    func reset(inputRate: Double) {
        self.inputRate = inputRate
        pos = 0
        prev = 0
        hasPrev = false
    }

    /// The largest input frame count whose conversion is guaranteed to fit in
    /// `capacity` output samples.
    func maxInputFrames(forOutputCapacity capacity: Int) -> Int {
        guard capacity > 2, inputRate > 0 else { return max(0, capacity) }
        if isPassThrough { return capacity }
        let outputsPerInput = outputRate / inputRate
        return max(1, Int((Double(capacity) - 2) / outputsPerInput))
    }

    /// Convert `count` mono samples from `src` into `out`, returning how many samples
    /// were written. Reaching `capacity` truncates the output while still advancing the
    /// stream position, so the channel's timeline never drifts.
    func process(
        _ src: UnsafePointer<Float>,
        count: Int,
        into out: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard count > 0, capacity > 0, inputRate > 0 else { return 0 }

        if isPassThrough {
            let n = min(count, capacity)
            out.update(from: src, count: n)
            return n
        }

        let inLen = count + (hasPrev ? 1 : 0)
        let step = inputRate / outputRate

        @inline(__always) func sample(_ i: Int) -> Float {
            hasPrev ? (i == 0 ? prev : src[i - 1]) : src[i]
        }

        var written = 0
        while pos + 1 < Double(inLen) && written < capacity {
            let i = Int(pos)
            let f = Float(pos - Double(i))
            let s0 = sample(i)
            let s1 = sample(i + 1)
            out[written] = s0 + (s1 - s0) * f
            written += 1
            pos += step
        }

        prev = sample(inLen - 1)
        hasPrev = true
        pos -= Double(inLen - 1)
        return written
    }
}
