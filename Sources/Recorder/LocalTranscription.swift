import Foundation
import Observation
import Accelerate
import AVFoundation
import os
import WhisperKit
import SpeakerKit

// MARK: - Model catalog

/// One selectable on-device Whisper model. All entries are multilingual
/// (German + English included); English-only `.en` variants are deliberately
/// excluded from the catalog.
struct WhisperModelOption: Identifiable, Equatable {
    /// WhisperKit variant name in the `argmaxinc/whisperkit-coreml` repo.
    let id: String
    let label: String
    let detail: String

    static let catalog: [WhisperModelOption] = [
        WhisperModelOption(
            id: "openai_whisper-tiny",
            label: "Tiny",
            detail: "~110 MB, fastest, lowest accuracy"
        ),
        WhisperModelOption(
            id: "openai_whisper-base",
            label: "Base",
            detail: "~150 MB, fast, fine for quick notes"
        ),
        WhisperModelOption(
            id: "openai_whisper-small_216MB",
            label: "Small (compressed)",
            detail: "~220 MB, good accuracy"
        ),
        WhisperModelOption(
            id: "openai_whisper-small",
            label: "Small",
            detail: "~490 MB, good accuracy"
        ),
        WhisperModelOption(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            label: "Large v3 Turbo (compressed)",
            detail: "~630 MB, best accuracy"
        ),
    ]

    static let defaultModelID = "openai_whisper-base"

    static func label(for id: String) -> String {
        catalog.first(where: { $0.id == id })?.label ?? id
    }
}

/// Selectable transcription languages. "auto" detects the language per window,
/// which handles mixed German/English meetings.
enum TranscriptionLanguage {
    static let options: [(id: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("de", "German"),
        ("en", "English"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
    ]
}

// MARK: - LocalTranscriptionEngine

/// On-device transcription via WhisperKit (CoreML Whisper on Apple Silicon).
///
/// Owns the model host, the live streaming transcriber, and the offline path that runs
/// a saved `audio.m4a` through the same model with on-device diarization.
@MainActor
@Observable
final class LocalTranscriptionEngine {

    let host: WhisperModelHost
    let live: LiveTranscriber

    init() {
        let host = WhisperModelStorage.makeHost()
        self.host = host
        self.live = LiveTranscriber(host: host)
    }

    // MARK: Model state

    var engineState: ModelLoadState { host.state }
    var modelName: String { host.selectedModel }
    var loadedModelName: String? { host.loadedModel }
    var loadFailureMessage: String? { host.loadFailureMessage }

    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        await host.loadModel(name, downloadIfNeeded: downloadIfNeeded)
    }

    // MARK: Live surface

    var confirmedLines: [TranscriptLine] { live.confirmedLines }
    var hypothesis: String { live.hypothesis }
    var isSessionActive: Bool { live.isSessionActive }
    var revision: Int { live.revision }
    var hasText: Bool { live.hasText }

    var language: String? {
        get { live.language }
        set { live.language = newValue }
    }

    var labelSpeakers: Bool {
        get { live.labelSpeakers }
        set { live.labelSpeakers = newValue }
    }

    nonisolated var inbox: SampleInbox { live.inbox }

    func beginSession() { live.beginSession() }
    func cancelSession() { live.cancelSession() }

    func endSession() async -> LiveTranscriber.LiveSessionResult {
        await live.endSession()
    }

    func transcript(includeHypothesis: Bool) -> String {
        live.transcript(includeHypothesis: includeHypothesis)
    }

    // MARK: Private state

    @ObservationIgnored private var speakerKit: SpeakerKit?

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "LocalTranscription")

    private func cleanSegments(_ results: [TranscriptionResult]) -> [TranscriptionSegment] {
        results
            .flatMap { $0.segments }
            .sorted { $0.start < $1.start }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func decodingOptions(forFile: Bool) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: live.language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: live.language == nil,
            skipSpecialTokens: true,
            suppressBlank: true,
            chunkingStrategy: forFile ? .vad : nil
        )
    }

    // MARK: Offline files

    /// Transcribe a saved recording, one channel at a time.
    ///
    /// `StereoMixer` writes desktop to ch0 and mic to ch1, padded by each source's
    /// host-time offset, so the two channels are sample-aligned and their independent
    /// timelines merge by a plain sort. Decoding them separately keeps the microphone
    /// speaker identifiable by construction and spares Whisper the crosstalk of two
    /// people in one mixed signal.
    ///
    /// Serialized against the live tick loop: WhisperKit carries mutable decode state, so
    /// one pipe must never transcribe twice concurrently. The two channel passes
    /// therefore run one after the other.
    func transcribeFile(_ url: URL) async throws -> OfflineTranscription {
        let path = url.path
        guard Self.channelCount(of: url) >= 2 else {
            return try await transcribeSingleChannel(path: path)
        }

        let desktopSamples = try await Self.load(path: path, channel: 0)
        let micSamples = try await Self.load(path: path, channel: 1)

        let desktop = Self.hasSignal(desktopSamples) ? try await transcribe(desktopSamples) : []
        let mic = Self.hasSignal(micSamples) ? try await transcribe(micSamples) : []

        var diarized: [DiarizedSpan] = []
        var centroids: [Int: [Float]] = [:]
        if labelSpeakers, !desktop.isEmpty {
            (diarized, centroids) = await diarize(desktopSamples)
        }

        return OfflineTranscription.build(
            mic: mic,
            desktop: desktop,
            diarized: diarized,
            centroids: centroids
        )
    }

    /// Legacy or externally supplied recordings that are not our two-channel layout.
    /// Everything is treated as desktop audio: diarized if labelling is on, with no
    /// "You" attribution available.
    private func transcribeSingleChannel(path: String) async throws -> OfflineTranscription {
        let samples = try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        let segments = try await transcribe(samples)

        var diarized: [DiarizedSpan] = []
        var centroids: [Int: [Float]] = [:]
        if labelSpeakers, !segments.isEmpty {
            (diarized, centroids) = await diarize(samples)
        }

        return OfflineTranscription.build(
            mic: [],
            desktop: segments,
            diarized: diarized,
            centroids: centroids
        )
    }

    private func transcribe(_ samples: [Float]) async throws -> [TimedText] {
        let options = decodingOptions(forFile: true)
        let results = try await host.withPipe { pipe in
            try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        }
        return cleanSegments(results).map {
            TimedText(
                start: TimeInterval($0.start),
                end: TimeInterval($0.end),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Diarization is never allowed to fail the transcription: a failure costs the
    /// speaker labels and nothing else.
    private func diarize(_ samples: [Float]) async -> ([DiarizedSpan], [Int: [Float]]) {
        do {
            let kit = try await diarizer()
            let result = try await kit.diarize(audioArray: samples)
            let spans = result.segments.compactMap { segment in
                segment.speaker.speakerId.map {
                    DiarizedSpan(
                        start: TimeInterval(segment.startTime),
                        end: TimeInterval(segment.endTime),
                        clusterID: $0
                    )
                }
            }
            return (spans, result.speakerCentroidEmbeddings)
        } catch {
            Self.log.error("diarization failed, transcript left unlabeled: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    private static func load(path: String, channel: Int) async throws -> [Float] {
        try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(
                fromPath: path,
                channelMode: .specificChannel(channel)
            )
        }.value
    }

    private static func channelCount(of url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 1 }
        return Int(file.fileFormat.channelCount)
    }

    /// Skip a decode pass for a channel that holds nothing, which is the common case for
    /// a listen-only meeting or a solo dictation.
    private static func hasSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare) > 1e-4
    }

    /// Lazily create the SpeakerKit diarizer. Its pyannote CoreML models
    /// (segmenter + embedder + clusterer, ~50 MB total) download on first use
    /// into the same Application Support folder as the Whisper models.
    private func diarizer() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        let config = PyannoteConfig(
            downloadBase: WhisperModelStorage.base.path,
            download: true,
            load: false,
            verbose: false
        )
        let kit = try await SpeakerKit(config)
        speakerKit = kit
        return kit
    }

}
