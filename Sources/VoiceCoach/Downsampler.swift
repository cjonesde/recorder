import Foundation

struct Downsampler {
    static let outputRate = 16_000.0
    static let cutoff = 7_000.0

    private var rate = 0.0
    private var alpha: Float = 1
    private var step = 1.0
    private var firstStage: Float = 0
    private var secondStage: Float = 0
    private var previous: Float = 0
    private var position = 0.0
    private var started = false

    private mutating func configure(rate: Double) {
        self.rate = rate
        step = rate / Self.outputRate
        alpha = rate > Self.outputRate ? Float(1 - exp(-2 * Double.pi * Self.cutoff / rate)) : 1
        position = 0
        started = false
    }

    mutating func process(_ input: UnsafeBufferPointer<Float>, rate: Double, into out: inout [Float]) {
        guard rate > 0 else { return }
        if rate != self.rate { configure(rate: rate) }
        out.reserveCapacity(out.count + Int(Double(input.count) / step) + 2)
        for sample in input {
            firstStage += alpha * (sample - firstStage)
            secondStage += alpha * (firstStage - secondStage)
            let current = secondStage
            guard started else {
                started = true
                previous = current
                out.append(current)
                position = step
                continue
            }
            while position <= 1 {
                out.append(previous + Float(position) * (current - previous))
                position += step
            }
            position -= 1
            previous = current
        }
    }
}
