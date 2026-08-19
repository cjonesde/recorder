import Foundation
import Accelerate
import os
import WhisperKit

// MARK: - StreamResampler

/// Streaming linear-interpolation resampler for one mono source. Keeps the last
/// input sample and the fractional read position across chunks, so chunk
/// boundaries stay continuous.
final class StreamResampler {
    let inputRate: Double
    let outputRate: Double
    private var pos = 0.0
    private var prev: Float?

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    func process(_ src: UnsafePointer<Float>, count: Int, into out: inout [Float]) {
        guard count > 0 else { return }
        let hasPrev = prev != nil
        let inLen = count + (hasPrev ? 1 : 0)
        let step = inputRate / outputRate

        @inline(__always) func sample(_ i: Int) -> Float {
            hasPrev ? (i == 0 ? prev! : src[i - 1]) : src[i]
        }

        while pos + 1 < Double(inLen) {
            let i = Int(pos)
            let f = Float(pos - Double(i))
            let s0 = sample(i)
            let s1 = sample(i + 1)
            out.append(s0 + (s1 - s0) * f)
            pos += step
        }

        prev = sample(inLen - 1)
        pos -= Double(inLen - 1)
    }
}

// MARK: - DrainedAudio

/// One tick's worth of audio handed from the inbox to the engine: the mixed
/// mono stream plus per-channel mean-square energy blocks (100 ms each) on the
/// same global sample timeline. The envelopes power the live "You"/"Them"
/// speaker attribution (mic-dominant vs desktop-dominant).
struct DrainedAudio {
    var samples: [Float] = []
    var desktopEnergy: [Float] = []
    var micEnergy: [Float] = []

    var isEmpty: Bool { samples.isEmpty }
}

// MARK: - SampleInbox

/// Thread-safe hand-off point between the audio capture threads (producers) and
/// the transcription engine's tick loop (consumer). Each source is resampled to
/// 16 kHz mono on ingest; `drain` merges both sources into one mono stream and
/// reports per-channel energy so speech can be attributed to a channel.
///
/// Called from the mic tap thread and the desktop writer thread; neither is the
/// hard-realtime IOProc, so a brief unfair lock plus array appends are fine here.
final class SampleInbox: @unchecked Sendable {

    enum Source: Int, CaseIterable {
        case desktop = 0
        case mic = 1
    }

    static let targetRate = Double(WhisperKit.sampleRate)

    /// Energy envelope resolution: one mean-square value per 100 ms block.
    static let energyBlockSamples = Int(targetRate) / 10

    /// Per-source backlog cap (60 s at 16 kHz). The tick loop drains every few
    /// seconds; anything this stale means the consumer died, so drop oldest.
    private static let maxPendingPerSource = 60 * Int(targetRate)

    /// When both sources are live but one backlog runs more than this far ahead,
    /// the difference is treated as a capture gap (e.g. the desktop tap's
    /// watchdog rebuild) and the lagging channel is padded with silence. Bounds
    /// the index-pairing skew that per-source clocks would otherwise accumulate.
    private static let skewCapSamples = Int(targetRate)

    /// A source with no samples and no feed within this window counts as dead
    /// (e.g. the desktop tap failed), so the other source is drained alone.
    private static let staleFeedNanos: UInt64 = 1_500_000_000

    private let lock = OSAllocatedUnfairLock()
    private var active = false
    private var pending: [[Float]] = [[], []]
    private var resamplers: [StreamResampler?] = [nil, nil]
    private var lastFeedNanos: [UInt64] = [0, 0]

    /// Consumer-side state, touched only by `drain`/`emitEnergyBlock`, which the
    /// engine's tick loop serializes. Kept out of the lock so the audio threads
    /// never wait on mixing.
    private var carry: [[Float]] = [[], []]
    private var blockSumSq: [Float] = [0, 0]
    private var blockFill = 0

    /// Silence inserted per source to keep the two channels index-aligned. Always zero
    /// in healthy operation; a non-zero count means that capture delivered fewer
    /// samples than its declared rate promised.
    private var padded: [Int] = [0, 0]
    private var lastLoggedPadding: [Int] = [0, 0]

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "SampleInbox")

    private static let paddingLogInterval = Int(targetRate)

    /// Silence inserted for `source` during the current session.
    func paddedSamples(for source: Source) -> Int {
        padded[source.rawValue]
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func nowNanos() -> UInt64 {
        let t = mach_absolute_time()
        let tb = timebase
        return t / UInt64(tb.denom) * UInt64(tb.numer)
            + (t % UInt64(tb.denom)) * UInt64(tb.numer) / UInt64(tb.denom)
    }

    func begin() {
        lock.withLock {
            active = true
            pending = [[], []]
            resamplers = [nil, nil]
            lastFeedNanos = [0, 0]
        }
        carry = [[], []]
        blockSumSq = [0, 0]
        blockFill = 0
        padded = [0, 0]
        lastLoggedPadding = [0, 0]
    }

    func end() {
        lock.withLock { active = false }
    }

    /// Ingest mono samples from one source. Safe to call from audio threads;
    /// a no-op while no session is active.
    func ingest(_ source: Source, _ src: UnsafePointer<Float>, count: Int, rate: Double) {
        guard count > 0, rate > 0 else { return }
        lock.withLock {
            guard active else { return }
            let i = source.rawValue
            if resamplers[i]?.inputRate != rate {
                resamplers[i] = StreamResampler(inputRate: rate, outputRate: Self.targetRate)
            }
            resamplers[i]!.process(src, count: count, into: &pending[i])
            if pending[i].count > Self.maxPendingPerSource {
                pending[i].removeFirst(pending[i].count - Self.maxPendingPerSource)
            }
            lastFeedNanos[i] = Self.nowNanos()
        }
    }

    /// Merge and return everything both sources agree on (the overlap of their
    /// backlogs), leaving the remainder queued in `carry`. With `flush: true`
    /// the remainder is appended unmixed, for the final drain when a session
    /// ends. Partial energy blocks carry across drains so envelope block k
    /// always covers global samples [k*100ms, (k+1)*100ms).
    ///
    /// The lock is held only to swap out the producer backlogs; all mixing runs
    /// outside it so the audio threads never block on this work. Must only be
    /// called from the engine's (serialized) tick loop.
    func drain(flush: Bool = false) -> DrainedAudio {
        let (taken, recentFeed): ([[Float]], [Bool]) = lock.withLock {
            let now = Self.nowNanos()
            let recent = (0..<pending.count).map { i -> Bool in
                guard lastFeedNanos[i] > 0 else { return false }
                return now &- lastFeedNanos[i] < Self.staleFeedNanos
            }
            let taken = pending
            pending = [[], []]
            return (taken, recent)
        }

        for i in 0..<carry.count where !taken[i].isEmpty {
            carry[i].append(contentsOf: taken[i])
        }
        let live = (0..<carry.count).map { !carry[$0].isEmpty || recentFeed[$0] }

        var out = DrainedAudio()

        func emit(_ desktop: Float, _ mic: Float, mixScale: Float) {
            out.samples.append((desktop + mic) * mixScale)
            blockSumSq[0] += desktop * desktop
            blockSumSq[1] += mic * mic
            blockFill += 1
            if blockFill == Self.energyBlockSamples {
                emitEnergyBlock(into: &out)
            }
        }

        if live[0] && live[1] {
            let skew = carry[0].count - carry[1].count
            if skew > Self.skewCapSamples {
                carry[1].append(contentsOf: repeatElement(0, count: skew))
                notePadding(.mic, samples: skew)
            } else if -skew > Self.skewCapSamples {
                carry[0].append(contentsOf: repeatElement(0, count: -skew))
                notePadding(.desktop, samples: -skew)
            }
            let n = min(carry[0].count, carry[1].count)
            if n > 0 {
                out.samples.reserveCapacity(n)
                for j in 0..<n {
                    emit(carry[0][j], carry[1][j], mixScale: 0.5)
                }
                carry[0].removeFirst(n)
                carry[1].removeFirst(n)
            }
        } else if live[0] || live[1] {
            let i = live[0] ? 0 : 1
            for value in carry[i] {
                emit(i == 0 ? value : 0, i == 0 ? 0 : value, mixScale: 1)
            }
            carry[i].removeAll(keepingCapacity: true)
        }

        if flush {
            for i in 0..<carry.count where !carry[i].isEmpty {
                for value in carry[i] {
                    emit(i == 0 ? value : 0, i == 0 ? 0 : value, mixScale: 1)
                }
                carry[i].removeAll(keepingCapacity: true)
            }
            emitEnergyBlock(into: &out)
        }
        return out
    }

    /// Record silence inserted to realign a starved channel, and report it in the log.
    private func notePadding(_ source: Source, samples: Int) {
        guard samples > 0 else { return }
        let i = source.rawValue
        padded[i] += samples
        guard padded[i] - lastLoggedPadding[i] >= Self.paddingLogInterval else { return }
        lastLoggedPadding[i] = padded[i]
        let name = source == .desktop ? "desktop" : "mic"
        let seconds = Double(padded[i]) / Self.targetRate
        Self.log.warning(
            "\(name, privacy: .public) capture is behind: padded \(seconds, privacy: .public)s of silence to realign channels — that capture is delivering fewer samples than its declared rate"
        )
    }

    /// Close the current (possibly partial) energy block. Consumer-side; only
    /// called from `drain`.
    private func emitEnergyBlock(into out: inout DrainedAudio) {
        guard blockFill > 0 else { return }
        let n = Float(blockFill)
        out.desktopEnergy.append(blockSumSq[0] / n)
        out.micEnergy.append(blockSumSq[1] / n)
        blockSumSq = [0, 0]
        blockFill = 0
    }
}
