import Foundation

final class CaptureRingDrain {

    struct Gap: Equatable {
        var heldBackFromLiveFrames: Int
        var lostFrames: Int
    }

    struct Report: Equatable {
        var drainedFrames = 0
        var paddedFrames = 0
        var gap: Gap?
    }

    static let keptAudioRingSeconds = 10.0

    static func ringCapacity(sampleRate: Double, keepsAudio: Bool) -> Int {
        keepsAudio ? Int(sampleRate * keptAudioRingSeconds) : max(Int(sampleRate / 2), 4096)
    }

    let ring: FloatRingBuffer
    let sampleRate: Double
    private let chunk: UnsafeMutablePointer<Float>
    private let chunkFrames: Int
    private var accountedDrops = 0

    private var liveBacklogFrames: Int { Int(sampleRate / 4) }

    init(ring: FloatRingBuffer, sampleRate: Double, chunk: UnsafeMutablePointer<Float>, chunkFrames: Int) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.chunk = chunk
        self.chunkFrames = chunkFrames
    }

    func drainOnce(
        persisting: Bool,
        persist: (Int) throws -> Void,
        forward: (UnsafePointer<Float>, Int) -> Void
    ) throws -> Report {
        var report = Report()
        let backlog = ring.availableFrames
        let heldBack = max(0, backlog - liveBacklogFrames)
        var stillHeldBack = heldBack
        var remaining = backlog
        while remaining > 0 {
            let n = ring.read(into: chunk, maxCount: min(chunkFrames, remaining))
            guard n > 0 else { break }
            defer { AudioMemory.erase(chunk, count: n) }
            if persisting { try persist(n) }
            report.drainedFrames += n
            remaining -= n
            let skipped = min(n, stillHeldBack)
            stillHeldBack -= skipped
            if n > skipped { forward(chunk + skipped, n - skipped) }
        }

        let dropped = ring.totalDropped
        let lost = dropped - accountedDrops
        accountedDrops = dropped
        if persisting {
            var missing = lost
            while missing > 0 {
                let n = min(chunkFrames, missing)
                chunk.update(repeating: 0, count: n)
                try persist(n)
                report.paddedFrames += n
                missing -= n
            }
        }

        if heldBack > 0 || lost > 0 {
            report.gap = Gap(heldBackFromLiveFrames: heldBack, lostFrames: lost)
        }
        return report
    }
}
