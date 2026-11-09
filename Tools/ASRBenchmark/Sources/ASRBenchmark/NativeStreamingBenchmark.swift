import AVFoundation
import CoreMedia
import Foundation
import Speech
import FluidAudio
import Darwin

final class InputBufferLifetimes: @unchecked Sendable {
    private let lock = NSLock()
    private var lifetimes: [Double] = []
    private var bytes = 0
    private var peakBytes = 0

    func allocated(_ count: Int) {
        lock.withLock { bytes += count; peakBytes = max(peakBytes, bytes) }
    }

    func released(_ count: Int, created: Double) {
        lock.withLock {
            bytes -= count
            lifetimes.append(ProcessInfo.processInfo.systemUptime - created)
        }
    }

    func snapshot() -> (lifetimes: [Double], peak: Int, remaining: Int) {
        lock.withLock { (lifetimes, peakBytes, bytes) }
    }
}

struct StreamEvent: Codable, Sendable {
    let wallSeconds: Double
    let audioThroughSeconds: Double
    let final: Bool
    let text: String
}

@available(macOS 26, *)
enum NativeStreamingBenchmark {
    static func run(audio: String, language: String, output: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw NSError(domain: "Unsupported speech locale: \(language)", code: 1)
        }
        let module = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange]
        )
        let loadStart = ProcessInfo.processInfo.systemUptime
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              [.pcmFormatFloat32, .pcmFormatInt16].contains(format.commonFormat) else {
            throw NSError(domain: "Unsupported analyzer audio format", code: 2)
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let samples = try AudioConverter(sampleRate: format.sampleRate)
            .resampleAudioFile(URL(fileURLWithPath: audio))
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        let start = ProcessInfo.processInfo.systemUptime
        let collector = Task { () throws -> [StreamEvent] in
            var events: [StreamEvent] = []
            for try await result in module.results {
                events.append(StreamEvent(
                    wallSeconds: ProcessInfo.processInfo.systemUptime - start,
                    audioThroughSeconds: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                    final: result.isFinal,
                    text: String(result.text.characters)
                ))
            }
            return events
        }
        let analysis = Task { try await analyzer.analyzeSequence(inputs) }
        let chunkSize = Int(format.sampleRate / 10)
        var droppedChunks = 0
        let lifetimes = InputBufferLifetimes()
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            let count = min(chunkSize, samples.count - offset)
            let due = start + Double(offset + count) / format.sampleRate
            let delay = due - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let buffer = try makeBuffer(format: format, count: count, lifetimes: lifetimes)
            if let target = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { source in
                    target.update(from: source.baseAddress! + offset, count: count)
                }
            } else if let target = buffer.int16ChannelData?[0] {
                for i in 0..<count {
                    target[i] = Int16(max(-32768, min(32767, samples[offset + i] * 32768)))
                }
            }
            let input = AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: Int64(offset), timescale: Int32(format.sampleRate)))
            if case .dropped = continuation.yield(input) { droppedChunks += 1 }
        }
        continuation.finish()
        _ = try await analysis.value
        let finishStart = ProcessInfo.processInfo.systemUptime
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let events = try await collector.value
        await analyzer.cancelAndFinishNow()
        let memory = lifetimes.snapshot()
        let result = StreamingMeasurement(
            backend: "apple", language: language,
            audioSeconds: Double(samples.count) / format.sampleRate,
            loadSecondsIncludingDownload: loadSeconds,
            finishSeconds: ProcessInfo.processInfo.systemUptime - finishStart,
            droppedChunks: droppedChunks, events: events,
            finalText: events.filter(\.final).map(\.text).joined(separator: " "),
            inputBufferLifetimeSeconds: memory.lifetimes,
            peakInputBytes: memory.peak, remainingInputBytes: memory.remaining
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: URL(fileURLWithPath: output))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func makeBuffer(format: AVAudioFormat, count: Int, lifetimes: InputBufferLifetimes) throws -> AVAudioPCMBuffer {
        let bytes = count * Int(format.streamDescription.pointee.mBytesPerFrame)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: format.channelCount, mDataByteSize: UInt32(bytes), mData: storage
        ))
        let created = ProcessInfo.processInfo.systemUptime
        lifetimes.allocated(bytes)
        let buffer = withUnsafePointer(to: &list) { list in
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: { releasedList in
                let storage = releasedList.pointee.mBuffers.mData!
                _ = memset_s(storage, bytes, 0, bytes)
                storage.deallocate()
                lifetimes.released(bytes, created: created)
            })
        }
        guard let buffer else {
            storage.deallocate()
            lifetimes.released(bytes, created: created)
            throw NSError(domain: "Cannot allocate analyzer input", code: 3)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}

struct StreamingMeasurement: Codable {
    let backend: String
    let language: String
    let audioSeconds: Double
    let loadSecondsIncludingDownload: Double
    let finishSeconds: Double
    let droppedChunks: Int
    let events: [StreamEvent]
    let finalText: String
    var inputBufferLifetimeSeconds: [Double]? = nil
    var peakInputBytes: Int? = nil
    var remainingInputBytes: Int? = nil
}
