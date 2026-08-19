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
/// Two jobs:
/// 1. **Live streaming** while recording: both captures feed `inbox`, a tick
///    loop mixes them to 16 kHz mono and re-transcribes a sliding window every
///    few seconds. When the window passes ~25 s, every segment except the
///    trailing (possibly incomplete) one is confirmed and its audio dropped.
///    `confirmedLines` + `hypothesis` stream straight into the panel.
/// 2. **Offline files**: `transcribeFile` runs a saved `audio.m4a` through the
///    same model (stereo is summed to mono by WhisperKit's loader).
///
/// Models download once from the `argmaxinc/whisperkit-coreml` Hugging Face
/// repo into Application Support and load from disk thereafter.
@MainActor
@Observable
final class LocalTranscriptionEngine {

    enum EngineState: Equatable {
        case unloaded
        /// Model selected but not on disk yet; downloads on first use.
        case notDownloaded(String)
        case downloading(String, Double)
        case loading(String)
        case ready
        case failed(String)
    }

    enum EngineError: LocalizedError {
        case modelNotReady(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady(let detail):
                return "Transcription model is not ready: \(detail)"
            }
        }
    }

    /// What `endSession` produced. `complete` is false when the final tail
    /// could not be transcribed (model unavailable, decode error, or a new
    /// session superseded the finalization), so callers can fall back to a
    /// full offline transcription of the saved audio.
    struct LiveSessionResult {
        let body: String
        let complete: Bool
    }

    // MARK: Observable state

    var engineState: EngineState = .unloaded
    /// The model the user selected (may still be downloading or have failed).
    var modelName: String = WhisperModelOption.defaultModelID
    /// The model actually loaded and answering transcriptions, nil before the
    /// first successful load. Diverges from `modelName` while a switch is in
    /// flight or after a failed switch kept the previous model running.
    var loadedModelName: String? = nil
    /// Set when switching models failed and the previous model was kept.
    var loadFailureMessage: String? = nil
    var confirmedLines: [TranscriptLine] = []
    var hypothesis: String = ""
    var isSessionActive = false
    /// Bumped on every transcript change; the panel observes it to auto-scroll.
    var revision = 0

    /// ISO language code, nil = auto-detect per window.
    var language: String? = nil

    /// Whether transcripts carry speaker labels: live lines get "You"/"Them"
    /// from channel attribution, offline transcriptions get "Speaker N" from
    /// on-device diarization (SpeakerKit).
    var labelSpeakers: Bool = true

    var hasText: Bool {
        !confirmedLines.isEmpty || !hypothesis.isEmpty
    }

    // MARK: Audio plumbing

    nonisolated let inbox = SampleInbox()

    // MARK: Private state

    @ObservationIgnored private var pipe: WhisperKit?
    @ObservationIgnored private var speakerKit: SpeakerKit?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var offlineBusy = false
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var finalTickComplete = false
    @ObservationIgnored private var windowSamples: [Float] = []
    @ObservationIgnored private var windowStartSample = 0
    @ObservationIgnored private var desktopEnvelope: [Float] = []
    @ObservationIgnored private var micEnvelope: [Float] = []
    @ObservationIgnored private var desktopSpeechBlocks = 0
    @ObservationIgnored private var micSpeechBlocks = 0

    private static let sampleRate = Int(SampleInbox.targetRate)
    private static let tickInterval: Duration = .seconds(3)
    private static let confirmThresholdSamples = 25 * sampleRate
    /// A single unbroken segment may grow past the confirm threshold in the
    /// hope of a natural boundary, but never past Whisper's 30 s window.
    private static let hardWindowCapSamples = 29 * sampleRate
    /// While the model is still downloading, buffered audio is capped at 15 min;
    /// beyond that the oldest audio is dropped and a gap line is recorded.
    private static let maxWindowSamples = 15 * 60 * sampleRate
    private static let silenceRMSFloor: Float = 0.0005

    private static let envelopeBlocksPerSecond = Int(SampleInbox.targetRate) / SampleInbox.energyBlockSamples
    /// Mean-square above this counts a 100 ms block as speech (RMS ~ -60 dBFS).
    private static let speechBlockFloor: Float = 1e-6
    /// Both channels need at least this much speech before "You"/"Them" labels
    /// are trusted (prevents labeling everything in a single-channel recording).
    private static let minSpeechBlocksPerChannel = 10
    /// One channel must carry 4x the energy of the other to claim a segment.
    private static let channelDominanceRatio: Float = 4

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "LocalTranscription")

    /// ~/Library/Application Support/Recorder/WhisperModels
    private static var modelStorageBase: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Recorder", isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func localModelFolder(for name: String) -> URL {
        modelStorageBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func isDownloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: localModelFolder(for: name).appendingPathComponent("TextDecoder.mlmodelc").path
        )
    }

    // MARK: Model loading

    /// Load `name`, downloading it first when missing and `downloadIfNeeded`
    /// is set. Repeat calls for the model already loaded (or loading) are
    /// no-ops; a call for a different model supersedes any load in flight. The
    /// previously loaded model keeps serving transcriptions until the new one
    /// is ready, and is kept (with `loadFailureMessage` set) when the switch
    /// fails, so a bad download never takes down a working setup.
    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        modelName = name

        switch engineState {
        case .ready where loadedModelName == name:
            return
        case .downloading(let inFlight, _) where inFlight == name:
            return
        case .loading(let inFlight) where inFlight == name:
            return
        case .notDownloaded(let pending) where pending == name && !downloadIfNeeded:
            return
        default:
            break
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadFailureMessage = nil

        if !Self.isDownloaded(name) && !downloadIfNeeded {
            if pipe == nil {
                engineState = .notDownloaded(name)
            }
            return
        }

        do {
            let folder: URL
            if Self.isDownloaded(name) {
                folder = Self.localModelFolder(for: name)
            } else {
                engineState = .downloading(name, 0)
                folder = try await WhisperKit.download(
                    variant: name,
                    downloadBase: Self.modelStorageBase,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            guard let self, self.loadGeneration == generation else { return }
                            self.engineState = .downloading(name, fraction)
                        }
                    }
                )
            }
            guard loadGeneration == generation else { return }

            engineState = .loading(name)
            let config = WhisperKitConfig(
                model: name,
                downloadBase: Self.modelStorageBase,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .none,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)
            guard loadGeneration == generation else { return }
            pipe = loaded
            loadedModelName = name
            engineState = .ready
        } catch {
            guard loadGeneration == generation else { return }
            Self.log.error("model load failed: \(error.localizedDescription)")
            if pipe != nil, let previous = loadedModelName {
                engineState = .ready
                loadFailureMessage = "Could not switch to \(WhisperModelOption.label(for: name)): \(error.localizedDescription). Still using \(WhisperModelOption.label(for: previous))."
            } else {
                engineState = .failed(error.localizedDescription)
            }
        }
    }

    /// Wait until a model is loaded, kicking off a (re)load when the engine is
    /// idle or a previous attempt failed. Throws when loading fails again or
    /// the timeout passes.
    private func awaitReady(timeout: TimeInterval = 600) async throws -> WhisperKit {
        switch engineState {
        case .notDownloaded, .unloaded, .failed:
            await loadModel(modelName, downloadIfNeeded: true)
        default:
            break
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pipe, case .ready = engineState { return pipe }
            if case .failed(let message) = engineState {
                throw EngineError.modelNotReady(message)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw EngineError.modelNotReady("timed out waiting for the model to load")
    }

    // MARK: Live session

    func beginSession() {
        sessionGeneration += 1
        confirmedLines = []
        hypothesis = ""
        revision += 1
        windowSamples = []
        windowStartSample = 0
        desktopEnvelope = []
        micEnvelope = []
        desktopSpeechBlocks = 0
        micSpeechBlocks = 0
        inbox.begin()
        isSessionActive = true

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LocalTranscriptionEngine.tickInterval)
                guard let self, !Task.isCancelled else { return }
                await self.tick(final: false)
            }
        }
    }

    /// Finish the session: drain the last audio, transcribe the remaining
    /// window, and return the final transcript (confirmed lines as timestamped
    /// Markdown paragraphs). Every await is guarded by the session generation:
    /// if a new recording begins while this finalization is still waiting or
    /// decoding, the text confirmed so far is returned with `complete: false`
    /// and the new session's state is never touched.
    func endSession() async -> LiveSessionResult {
        guard isSessionActive else {
            return LiveSessionResult(body: transcriptBody(), complete: true)
        }
        let generation = sessionGeneration
        inbox.end()
        tickTask?.cancel()
        tickTask = nil
        isSessionActive = false
        finalTickComplete = false
        var snapshot = confirmedLines

        while ticking {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard generation == sessionGeneration else {
            return LiveSessionResult(body: Self.body(of: snapshot), complete: false)
        }
        snapshot = confirmedLines

        let modelDeadline = Date().addingTimeInterval(300)
        modelWait: while Date() < modelDeadline && generation == sessionGeneration {
            switch engineState {
            case .downloading, .loading:
                try? await Task.sleep(for: .milliseconds(250))
            default:
                break modelWait
            }
        }
        guard generation == sessionGeneration else {
            return LiveSessionResult(body: Self.body(of: snapshot), complete: false)
        }

        await tick(final: true, expectedGeneration: generation)
        guard generation == sessionGeneration else {
            return LiveSessionResult(body: Self.body(of: snapshot), complete: false)
        }
        return LiveSessionResult(body: transcriptBody(), complete: finalTickComplete)
    }

    func cancelSession() {
        sessionGeneration += 1
        inbox.end()
        tickTask?.cancel()
        tickTask = nil
        isSessionActive = false
        windowSamples = []
        windowStartSample = 0
        desktopEnvelope = []
        micEnvelope = []
        desktopSpeechBlocks = 0
        micSpeechBlocks = 0
        confirmedLines = []
        hypothesis = ""
        revision += 1
    }

    /// The transcript so far as plain text, for the panel's copy button.
    func transcript(includeHypothesis: Bool) -> String {
        var parts = confirmedLines.map(\.markdown)
        if includeHypothesis {
            let hyp = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hyp.isEmpty { parts.append(hyp) }
        }
        return parts.joined(separator: "\n\n")
    }

    private func transcriptBody() -> String {
        Self.body(of: confirmedLines)
    }

    private static func body(of lines: [TranscriptLine]) -> String {
        lines.map(\.markdown).joined(separator: "\n\n")
    }

    // MARK: Tick loop

    private func tick(final: Bool, expectedGeneration: Int? = nil) async {
        if ticking { return }
        if !final && !isSessionActive { return }
        let generation = expectedGeneration ?? sessionGeneration
        guard generation == sessionGeneration else { return }
        if final {
            while offlineBusy {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == sessionGeneration else { return }
        } else if offlineBusy {
            return
        }
        ticking = true
        defer { ticking = false }

        let fresh = inbox.drain(flush: final)
        if !fresh.isEmpty {
            windowSamples.append(contentsOf: fresh.samples)
            desktopEnvelope.append(contentsOf: fresh.desktopEnergy)
            micEnvelope.append(contentsOf: fresh.micEnergy)
            desktopSpeechBlocks += fresh.desktopEnergy.count(where: { $0 > Self.speechBlockFloor })
            micSpeechBlocks += fresh.micEnergy.count(where: { $0 > Self.speechBlockFloor })
        }
        if windowSamples.count > Self.maxWindowSamples {
            let overflow = windowSamples.count - Self.maxWindowSamples
            windowSamples.removeFirst(overflow)
            windowStartSample += overflow
            noteGap()
        }

        guard !windowSamples.isEmpty else {
            if final { finalTickComplete = true }
            return
        }
        guard let pipe else { return }
        if fresh.isEmpty && !final { return }

        if !final && windowRMS() < Self.silenceRMSFloor && hypothesis.isEmpty {
            if windowSamples.count > Self.confirmThresholdSamples {
                windowStartSample += windowSamples.count
                windowSamples.removeAll(keepingCapacity: true)
            }
            return
        }

        do {
            let results = try await pipe.transcribe(
                audioArray: windowSamples,
                decodeOptions: decodingOptions(forFile: false)
            )
            guard generation == sessionGeneration else { return }
            let segments = cleanSegments(results)

            if final {
                confirm(segments)
                hypothesis = ""
                windowStartSample += windowSamples.count
                windowSamples.removeAll()
                finalTickComplete = true
            } else if windowSamples.count >= Self.confirmThresholdSamples {
                let cutSample = segments.count > 1
                    ? min(
                        max(Int(segments[segments.count - 2].end * Float(Self.sampleRate)), 0),
                        windowSamples.count
                    )
                    : 0
                if segments.count > 1 && cutSample > 0 {
                    let trailing = segments.last!
                    confirm(Array(segments.dropLast()))
                    windowSamples.removeFirst(cutSample)
                    windowStartSample += cutSample
                    hypothesis = trailing.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if windowSamples.count >= Self.hardWindowCapSamples {
                    confirm(segments)
                    hypothesis = ""
                    windowStartSample += windowSamples.count
                    windowSamples.removeAll()
                } else {
                    hypothesis = segments
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .joined(separator: " ")
                }
            } else {
                hypothesis = segments
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
            }
            revision += 1
        } catch {
            Self.log.error("live transcription tick failed: \(error.localizedDescription)")
        }
    }

    private func windowRMS() -> Float {
        var rms: Float = 0
        windowSamples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(buf.count))
        }
        return rms
    }

    private func cleanSegments(_ results: [TranscriptionResult]) -> [TranscriptionSegment] {
        results
            .flatMap { $0.segments }
            .sorted { $0.start < $1.start }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func confirm(_ segments: [TranscriptionSegment]) {
        let base = TimeInterval(windowStartSample) / TimeInterval(Self.sampleRate)
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = base + TimeInterval(segment.start)
            let end = base + TimeInterval(segment.end)
            confirmedLines.append(TranscriptLine(
                time: start,
                text: text,
                speaker: labelSpeakers ? channelLabel(startSec: start, endSec: end) : nil
            ))
        }
    }

    /// Attribute a time span to "You" (mic-dominant) or "Them" (desktop-dominant)
    /// from the per-channel energy envelopes. Returns nil when either channel has
    /// barely spoken yet, or when neither channel clearly dominates the span.
    private func channelLabel(startSec: TimeInterval, endSec: TimeInterval) -> String? {
        guard desktopSpeechBlocks >= Self.minSpeechBlocksPerChannel,
              micSpeechBlocks >= Self.minSpeechBlocksPerChannel else { return nil }
        let perSecond = Double(Self.envelopeBlocksPerSecond)
        let count = min(desktopEnvelope.count, micEnvelope.count)
        guard count > 0 else { return nil }
        let k0 = max(0, min(Int(startSec * perSecond), count - 1))
        let k1 = max(k0 + 1, min(Int((endSec * perSecond).rounded(.up)), count))
        guard k0 < k1 else { return nil }
        var desktop: Float = 0
        var mic: Float = 0
        for k in k0..<k1 {
            desktop += desktopEnvelope[k]
            mic += micEnvelope[k]
        }
        if mic > desktop * Self.channelDominanceRatio { return "You" }
        if desktop > mic * Self.channelDominanceRatio { return "Them" }
        return nil
    }

    private func noteGap() {
        let marker = "[gap: transcription could not keep up with the recording]"
        guard confirmedLines.last?.text != marker else { return }
        let time = TimeInterval(windowStartSample) / TimeInterval(Self.sampleRate)
        confirmedLines.append(TranscriptLine(time: time, text: marker, speaker: nil))
        revision += 1
    }

    private func decodingOptions(forFile: Bool) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
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
        let pipe = try await awaitReady()
        while ticking || offlineBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        offlineBusy = true
        defer { offlineBusy = false }

        let path = url.path
        let samples = try await Task.detached(priority: .utility) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions(forFile: true)
        )
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
            downloadBase: Self.modelStorageBase.path,
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
