import AVFoundation
import CoreMedia
import Darwin
import Foundation

enum StreamingSpeechError: LocalizedError {
    case unavailableLanguage
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unavailableLanguage: return "Apple speech recognition does not support the selected language on this Mac."
        case .unsupportedFormat: return "Apple speech recognition returned an unsupported audio format."
        }
    }
}

final class BufferLifetimeLog: @unchecked Sendable {
    struct Summary: Equatable, Sendable {
        let median: Double
        let longest: Double
        let released: Int
    }

    static let recentCapacity = 1_000

    private let lock = NSLock()
    private var epoch = 0
    private var recent: [Double] = []
    private var nextSlot = 0
    private var longest: Double = 0
    private var released = 0

    func begin() -> Int {
        lock.withLock {
            epoch += 1
            recent = []
            nextSlot = 0
            longest = 0
            released = 0
            return epoch
        }
    }

    var currentEpoch: Int { lock.withLock { epoch } }

    func record(_ seconds: Double, epoch: Int) {
        lock.withLock {
            guard epoch == self.epoch, seconds.isFinite, seconds >= 0 else { return }
            if recent.count < Self.recentCapacity {
                recent.append(seconds)
            } else {
                recent[nextSlot] = seconds
            }
            nextSlot = (nextSlot + 1) % Self.recentCapacity
            longest = max(longest, seconds)
            released += 1
        }
    }

    var summary: Summary? {
        lock.withLock {
            guard !recent.isEmpty else { return nil }
            let sorted = recent.sorted()
            let middle = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            return Summary(median: median, longest: longest, released: released)
        }
    }
}

enum ErasingPCMBuffer {
    static func make(format: AVAudioFormat, count: Int, lifetimes: BufferLifetimeLog? = nil) throws -> AVAudioPCMBuffer {
        guard format.channelCount == 1,
              [.pcmFormatFloat32, .pcmFormatInt16].contains(format.commonFormat), count > 0 else {
            throw StreamingSpeechError.unsupportedFormat
        }
        let bytes = count * Int(format.streamDescription.pointee.mBytesPerFrame)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: storage
        ))
        let created = ProcessInfo.processInfo.systemUptime
        let epoch = lifetimes?.currentEpoch ?? 0
        let buffer = withUnsafePointer(to: &list) {
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: $0) { released in
                let data = released.pointee.mBuffers.mData!
                _ = memset_s(data, bytes, 0, bytes)
                data.deallocate()
                lifetimes?.record(ProcessInfo.processInfo.systemUptime - created, epoch: epoch)
            }
        }
        guard let buffer else {
            _ = memset_s(storage, bytes, 0, bytes)
            storage.deallocate()
            throw StreamingSpeechError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}

/// Capture callbacks and the consumer share this lock. No audio array escapes it;
/// the only output is an owned PCM allocation that erases itself on release.
final class StreamingAudioInput: @unchecked Sendable {
    enum Source: Int { case desktop, mic }

    struct Chunk {
        let buffer: AVAudioPCMBuffer
        let startTime: CMTime
        var start: TimeInterval { CMTimeGetSeconds(startTime) }
        let duration: TimeInterval
        let desktopEnergy: Float
        let micEnergy: Float
    }

    private final class Channel {
        let samples: UnsafeMutablePointer<Float>
        let scratch: UnsafeMutablePointer<Float>
        let capacity: Int
        let resampler: RealtimeResampler
        var count = 0
        var oldest: TimeInterval = 0
        var lastFeed: TimeInterval = 0

        init(rate: Double) {
            capacity = Int(rate / 2)
            samples = .allocate(capacity: capacity)
            scratch = .allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
            scratch.initialize(repeating: 0, count: capacity)
            resampler = RealtimeResampler(outputRate: rate)
        }

        func clear() {
            AudioMemory.erase(samples, count: capacity)
            AudioMemory.erase(scratch, count: capacity)
            count = 0
            resampler.reset(inputRate: 0)
        }

        func consume(_ n: Int) {
            guard n > 0 else { return }
            let remaining = count - n
            memmove(samples, samples + n, remaining * MemoryLayout<Float>.stride)
            AudioMemory.erase(samples + remaining, count: n)
            count = remaining
            oldest += Double(n) / resampler.outputRate
        }

        deinit {
            clear()
            samples.deallocate()
            scratch.deallocate()
        }
    }

    private let lock = NSLock()
    private var channels: [Channel] = []
    private var format: AVAudioFormat?
    private var accepting = false
    private var overrunReason: LiveStopReason?
    private var position: Int64 = 0
    let bufferLifetimes = BufferLifetimeLog()

    private static func agedReason(_ channelIndex: Int) -> LiveStopReason {
        channelIndex == Source.desktop.rawValue ? .desktopAudioAged : .micAudioAged
    }

    var pendingFrames: Int { lock.withLock { channels.reduce(0) { $0 + $1.count } } }

    var pendingSeconds: Double {
        lock.withLock {
            guard let format else { return 0 }
            return Double(channels.map(\.count).max() ?? 0) / format.sampleRate
        }
    }

    func begin(format: AVAudioFormat) {
        lock.withLock {
            channels = [Channel(rate: format.sampleRate), Channel(rate: format.sampleRate)]
            self.format = format
            accepting = true
            overrunReason = nil
            position = 0
        }
        _ = bufferLifetimes.begin()
    }

    func end() { lock.withLock { accepting = false } }

    func discard() {
        lock.withLock {
            accepting = false
            channels.removeAll()
            format = nil
        }
    }

    func ingest(_ source: Source, _ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        guard count > 0, rate.isFinite, rate > 0 else { return }
        lock.withLock {
            guard accepting else { return }
            let channel = channels[source.rawValue]
            let now = ProcessInfo.processInfo.systemUptime
            if channel.resampler.inputRate != rate { channel.resampler.reset(inputRate: rate) }
            var offset = 0
            while offset < count {
                let n = min(count - offset, channel.resampler.maxInputFrames(forOutputCapacity: channel.capacity))
                let written = channel.resampler.process(samples + offset, count: n,
                    into: channel.scratch, capacity: channel.capacity)
                defer { AudioMemory.erase(channel.scratch, count: written) }
                let failure: LiveStopReason? = channel.count + written > channel.capacity ? .handoffFull
                    : channel.count > 0 && now - channel.oldest >= 0.5 ? Self.agedReason(source.rawValue) : nil
                if let failure {
                    overrunReason = failure
                    accepting = false
                    for channel in channels { channel.clear() }
                    return
                }
                if channel.count == 0 { channel.oldest = now }
                channel.samples.advanced(by: channel.count).update(from: channel.scratch, count: written)
                channel.count += written
                channel.lastFeed = now
                offset += n
            }
        }
    }

    func drain(flush: Bool = false) throws -> Chunk? {
        try lock.withLock {
            if let overrunReason { throw LiveStopError(reason: overrunReason, detail: nil) }
            guard let format, channels.count == 2 else { return nil }
            let rate = format.sampleRate
            let desktop = channels[0], mic = channels[1]
            let now = ProcessInfo.processInfo.systemUptime
            for (index, channel) in channels.enumerated() where channel.count > 0 && now - channel.oldest > 0.5 {
                let reason = Self.agedReason(index)
                overrunReason = reason
                accepting = false
                for channel in channels { channel.clear() }
                throw LiveStopError(reason: reason, detail: nil)
            }
            let available: Int
            if flush || desktop.count == 0 && now - desktop.lastFeed > 0.1
                || mic.count == 0 && now - mic.lastFeed > 0.1 {
                available = max(desktop.count, mic.count)
            } else {
                available = min(desktop.count, mic.count)
            }
            let n = min(Int(rate / 10), available)
            guard n > 0 else { return nil }
            let buffer = try ErasingPCMBuffer.make(format: format, count: n, lifetimes: bufferLifetimes)
            var desktopEnergy: Float = 0, micEnergy: Float = 0
            for i in 0..<n {
                let d: Float = i < desktop.count ? desktop.samples[i] : 0
                let m: Float = i < mic.count ? mic.samples[i] : 0
                let mixed = max(-1, min(1, d + m))
                desktopEnergy += d * d
                micEnergy += m * m
                if let dst = buffer.floatChannelData?[0] { dst[i] = mixed }
                else { buffer.int16ChannelData![0][i] = Int16(max(-32768, min(32767, mixed * 32768))) }
            }
            desktop.consume(min(n, desktop.count))
            mic.consume(min(n, mic.count))
            let start = CMTime(value: position, timescale: Int32(rate))
            position += Int64(n)
            return Chunk(buffer: buffer, startTime: start, duration: Double(n) / rate,
                         desktopEnergy: desktopEnergy, micEnergy: micEnergy)
        }
    }
}
