import Foundation
import Darwin
import WhisperKit
import FluidAudio

// One model per process: peak RSS is otherwise contaminated by the previous model.
// Usage: ASRBenchmark whisper|parakeet MODEL AUDIO LANGUAGE OUTPUT [REPEATS] [FALLBACKS] [WORKERS]
@main
struct Benchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "stream-nemotron", args.count == 4 {
            try await NemotronStreamingBenchmark.run(audio: args[1], language: args[2], output: args[3])
            return
        }
        if args.first == "stream-apple", args.count == 4 {
            guard #available(macOS 26, *) else { throw NSError(domain: "Requires macOS 26", code: 1) }
            try await NativeStreamingBenchmark.run(audio: args[1], language: args[2], output: args[3])
            return
        }
        guard args.count >= 5 else {
            throw NSError(domain: "ASRBenchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Usage: ASRBenchmark whisper|parakeet MODEL AUDIO LANGUAGE OUTPUT [REPEATS] [FALLBACKS]"
            ])
        }
        let backend = args[0], model = args[1], language = args[3]
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
        let repeats = max(1, args.count > 5 ? Int(args[5]) ?? 3 : 3)
        let fallbacks = args.count > 6 ? Int(args[6]) ?? 3 : 3
        let workers = max(1, args.count > 7 ? Int(args[7]) ?? 1 : 1)
        let start = ProcessInfo.processInfo.systemUptime
        let transcribe: () async throws -> String
        if backend == "whisper" {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Recorder/WhisperModels")
            let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)")
            let kit = try await WhisperKit(WhisperKitConfig(
                model: model, downloadBase: base, modelFolder: folder.path,
                verbose: false, logLevel: .none, load: true, download: false
            ))
            let options = DecodingOptions(
                language: language == "auto" ? nil : language,
                temperatureFallbackCount: fallbacks,
                usePrefillPrompt: true, detectLanguage: language == "auto",
                skipSpecialTokens: true, suppressBlank: true,
                concurrentWorkerCount: workers, chunkingStrategy: .vad
            )
            transcribe = {
                try await kit.transcribe(audioArray: samples, decodeOptions: options)
                    .map(\.text).joined(separator: " ")
            }
        } else if backend == "parakeet" {
            let version: AsrModelVersion
            switch model {
            case "ultra": version = .ultra
            case "redux": version = .redux
            case "v3": version = .v3
            default: throw NSError(domain: "ASRBenchmark", code: 2)
            }
            // Keep experimental downloads inside this tool's workspace.
            let cache = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/asr-models", isDirectory: true)
                .appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
            let models = try await AsrModels.downloadAndLoad(to: cache, version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            transcribe = {
                var state = try TdtDecoderState()
                return try await manager.transcribe(samples, decoderState: &state).text
            }
        } else {
            throw NSError(domain: "ASRBenchmark", code: 3)
        }
        let loadSeconds = ProcessInfo.processInfo.systemUptime - start
        let firstStart = ProcessInfo.processInfo.systemUptime
        let firstText = try await transcribe()
        let firstSeconds = ProcessInfo.processInfo.systemUptime - firstStart
        var durations: [Double] = []
        var texts: [String] = []
        for _ in 0..<repeats {
            let start = ProcessInfo.processInfo.systemUptime
            texts.append(try await transcribe())
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let result: [String: Any] = [
            "backend": backend, "model": model, "audio": args[2], "language": language,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "audioSeconds": Double(samples.count) / 16000,
            "loadSecondsIncludingDownload": loadSeconds,
            "firstDecodeSeconds": firstSeconds, "warmDecodeSeconds": durations,
            "warmMedianSeconds": median,
            "warmRealtimeMultiplier": Double(samples.count) / 16000 / median,
            "peakRSSBytes": usage.ru_maxrss,
            "firstText": firstText, "warmTexts": texts, "fallbacks": fallbacks,
            "workers": workers
        ]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        print(String(decoding: json, as: UTF8.self))
    }
}
