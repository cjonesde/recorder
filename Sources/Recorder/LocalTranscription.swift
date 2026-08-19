import Foundation
import Observation
import Accelerate
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

    /// Transcribe a saved recording (stereo m4a; channels are summed to mono)
    /// and return the transcript body as timestamped Markdown paragraphs. With
    /// `labelSpeakers` on, the same audio is diarized on-device via SpeakerKit
    /// and each line gets a "Speaker N" label (N in order of first appearance).
    /// Serialized against the live tick loop: WhisperKit carries mutable decode
    /// state, so one pipe must never transcribe twice concurrently.
    func transcribeFile(_ url: URL) async throws -> String {
        let path = url.path
        let samples = try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value

        let options = decodingOptions(forFile: true)
        let results = try await host.withPipe { pipe in
            try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        }
        let segments = cleanSegments(results)

        var speakers: [String?] = Array(repeating: nil, count: segments.count)
        if labelSpeakers && !segments.isEmpty {
            do {
                let kit = try await diarizer()
                let diarization = try await kit.diarize(audioArray: samples)
                speakers = Self.assignSpeakers(to: segments, from: diarization.segments)
            } catch {
                Self.log.error("diarization failed, transcript left unlabeled: \(error.localizedDescription)")
            }
        }

        return zip(segments, speakers)
            .map { segment, speaker in
                TranscriptLine(
                    time: TimeInterval(segment.start),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: speaker
                ).markdown
            }
            .joined(separator: "\n\n")
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

    /// Give each transcription segment the diarized speaker with the largest
    /// time overlap. Raw cluster ids are renumbered 1..N in order of first
    /// appearance so labels read "Speaker 1", "Speaker 2", ... chronologically.
    private static func assignSpeakers(
        to segments: [TranscriptionSegment],
        from diarized: [SpeakerSegment]
    ) -> [String?] {
        let ordered = diarized
            .filter { $0.speaker.speakerId != nil }
            .sorted { $0.startTime < $1.startTime }

        var displayNumber: [Int: Int] = [:]
        for segment in ordered {
            let id = segment.speaker.speakerId!
            if displayNumber[id] == nil {
                displayNumber[id] = displayNumber.count + 1
            }
        }

        return segments.map { segment in
            var overlapByID: [Int: Float] = [:]
            for dia in ordered {
                let overlap = min(segment.end, dia.endTime) - max(segment.start, dia.startTime)
                if overlap > 0, let id = dia.speaker.speakerId {
                    overlapByID[id, default: 0] += overlap
                }
            }
            guard let best = overlapByID.max(by: { $0.value < $1.value }),
                  let number = displayNumber[best.key] else { return nil }
            return "Speaker \(number)"
        }
    }
}
