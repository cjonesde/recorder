import Foundation

final class BoundedEngineHandoff: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        let count: Int

        init(copying source: UnsafePointer<Float>, count: Int) {
            self.count = count
            samples = .allocate(capacity: count)
            samples.initialize(from: source, count: count)
        }

        func takeSamples() -> [Float] {
            Array(UnsafeBufferPointer(start: samples, count: count))
        }

        deinit {
            AudioMemory.erase(samples, count: count)
            samples.deallocate()
        }
    }

    private let lock = NSLock()
    private let capacityFrames: Int
    private let sampleRate: Double
    private var slots: [Slot] = []
    private var heldFrames = 0
    private var peakFrames = 0
    private var finished = false
    private var closed = false
    private var waiter: CheckedContinuation<[Float]?, Never>?

    init(capacitySeconds: Double = 10, sampleRate: Double) {
        self.sampleRate = sampleRate
        capacityFrames = Int((capacitySeconds * sampleRate).rounded())
    }

    var heldSeconds: Double { lock.withLock { Double(heldFrames) / sampleRate } }

    var peakHeldSeconds: Double { lock.withLock { Double(peakFrames) / sampleRate } }

    func push(_ chunk: StreamingAudioInput.Chunk) throws {
        let frames = Int(chunk.buffer.frameLength)
        guard frames > 0, let source = chunk.buffer.floatChannelData?[0] else { return }
        let resumed: (CheckedContinuation<[Float]?, Never>, [Float])? = try lock.withLock {
            guard !closed, !finished else { return nil }
            if heldFrames + frames > capacityFrames {
                slots.removeAll()
                heldFrames = 0
                throw LiveStopError(reason: .engineFellBehind, detail: nil)
            }
            let slot = Slot(copying: source, count: frames)
            if let waiter {
                self.waiter = nil
                peakFrames = max(peakFrames, heldFrames + frames)
                return (waiter, slot.takeSamples())
            }
            slots.append(slot)
            heldFrames += frames
            peakFrames = max(peakFrames, heldFrames)
            return nil
        }
        resumed?.0.resume(returning: resumed?.1)
    }

    func next() async -> [Float]? {
        await withCheckedContinuation { continuation in
            let ready: [Float]?? = lock.withLock {
                if !slots.isEmpty {
                    let slot = slots.removeFirst()
                    heldFrames -= slot.count
                    return .some(slot.takeSamples())
                }
                if finished || closed { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish() {
        let pending: CheckedContinuation<[Float]?, Never>? = lock.withLock {
            finished = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: nil)
    }

    func cancel() {
        let pending: CheckedContinuation<[Float]?, Never>? = lock.withLock {
            closed = true
            slots.removeAll()
            heldFrames = 0
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: nil)
    }
}
