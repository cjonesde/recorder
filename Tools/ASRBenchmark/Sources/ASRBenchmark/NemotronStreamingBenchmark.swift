import Foundation
import FluidAudio
import CoreML

enum NemotronStreamingBenchmark {
    static func run(audio: String, language: String, output: String) async throws {
        // Rescue replays up to 15 seconds of audio, contrary to the target use case.
        let rescue = ProcessInfo.processInfo.environment["RECORDER_BENCH_RESCUE"] == "1"
        setenv("FLUIDAUDIO_DISABLE_BLANK_RESCUE", rescue ? "0" : "1", 1)
        let gpu = ProcessInfo.processInfo.environment["RECORDER_BENCH_GPU"] == "1"
        let configuration = MLModelConfiguration()
        configuration.computeUnits = gpu ? .cpuAndGPU : .cpuAndNeuralEngine
        let loadStart = ProcessInfo.processInfo.systemUptime
        let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: "de-DE", chunkMs: 560,
            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/asr-models"),
            configuration: configuration
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(shared)
        await manager.setLanguage(language)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audio))
        let start = ProcessInfo.processInfo.systemUptime
        var events: [StreamEvent] = []
        var previous = ""
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let count = min(1600, samples.count - offset)
            let due = start + Double(offset + count) / 16000
            let delay = due - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            _ = try await manager.process(samples: Array(samples[offset..<offset + count]))
            let text = await manager.getPartialTranscript()
            if text != previous {
                let through = await manager.getTokenTimings().last?.endTime ?? 0
                events.append(StreamEvent(wallSeconds: ProcessInfo.processInfo.systemUptime - start,
                                          audioThroughSeconds: through, final: false, text: text))
                previous = text
            }
        }
        let finishStart = ProcessInfo.processInfo.systemUptime
        let final = try await manager.finishWithTokenTimings()
        events.append(StreamEvent(wallSeconds: ProcessInfo.processInfo.systemUptime - start,
                                  audioThroughSeconds: final.timings.last?.endTime ?? 0,
                                  final: true, text: final.text))
        let result = StreamingMeasurement(
            backend: "nemotron-latin-560ms-\(rescue ? "rescue" : "no-rescue")-\(gpu ? "gpu" : "ane")", language: language,
            audioSeconds: Double(samples.count) / 16000,
            loadSecondsIncludingDownload: loadSeconds,
            finishSeconds: ProcessInfo.processInfo.systemUptime - finishStart,
            droppedChunks: 0, events: events, finalText: final.text
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: URL(fileURLWithPath: output))
        print(String(decoding: data, as: UTF8.self))
    }
}
