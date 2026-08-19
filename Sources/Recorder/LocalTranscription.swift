import Foundation
import Observation
import Accelerate
import os
import WhisperKit

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

// MARK: - SampleInbox

/// Thread-safe hand-off point between the audio capture threads (producers) and
/// the transcription engine's tick loop (consumer). Each source is resampled to
/// 16 kHz mono on ingest; `drainMixed` merges both sources into one mono stream.
///
/// Called from the mic tap thread and the desktop writer thread; neither is the
/// hard-realtime IOProc, so a brief unfair lock plus array appends are fine here.
final class SampleInbox: @unchecked Sendable {

    enum Source: Int, CaseIterable {
        case desktop = 0
        case mic = 1
    }

    static let targetRate = Double(WhisperKit.sampleRate)

    /// Per-source backlog cap (60 s at 16 kHz). The tick loop drains every few
    /// seconds; anything this stale means the consumer died, so drop oldest.
    private static let maxPendingPerSource = 60 * Int(targetRate)

    /// A source with no samples and no feed within this window counts as dead
    /// (e.g. the desktop tap failed), so the other source is drained alone.
    private static let staleFeedNanos: UInt64 = 1_500_000_000

    private let lock = OSAllocatedUnfairLock()
    private var active = false
    private var pending: [[Float]] = [[], []]
    private var resamplers: [StreamResampler?] = [nil, nil]
    private var lastFeedNanos: [UInt64] = [0, 0]

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
    /// backlogs), leaving the remainder queued. With `flush: true` the remainder
    /// is appended unmixed, for the final drain when a session ends.
    func drainMixed(flush: Bool = false) -> [Float] {
        lock.withLock {
            let now = Self.nowNanos()

            func isLive(_ i: Int) -> Bool {
                if !pending[i].isEmpty { return true }
                guard lastFeedNanos[i] > 0 else { return false }
                return now &- lastFeedNanos[i] < Self.staleFeedNanos
            }

            var out: [Float] = []
            if isLive(0) && isLive(1) {
                let n = min(pending[0].count, pending[1].count)
                if n > 0 {
                    out.reserveCapacity(n)
                    for j in 0..<n {
                        out.append((pending[0][j] + pending[1][j]) * 0.5)
                    }
                    pending[0].removeFirst(n)
                    pending[1].removeFirst(n)
                }
            } else if isLive(0) || isLive(1) {
                let i = isLive(0) ? 0 : 1
                out = pending[i]
                pending[i].removeAll(keepingCapacity: true)
            }

            if flush {
                for i in 0..<pending.count where !pending[i].isEmpty {
                    out.append(contentsOf: pending[i])
                    pending[i].removeAll(keepingCapacity: true)
                }
            }
            return out
        }
    }
}

// MARK: - TranscriptLine

/// One confirmed line of the live transcript, timestamped relative to the
/// start of the recording.
struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String

    var timestampLabel: String {
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
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

    // MARK: Observable state

    var engineState: EngineState = .unloaded
    var modelName: String = WhisperModelOption.defaultModelID
    var confirmedLines: [TranscriptLine] = []
    var hypothesis: String = ""
    var isSessionActive = false
    /// Bumped on every transcript change; the panel observes it to auto-scroll.
    var revision = 0

    /// ISO language code, nil = auto-detect per window.
    var language: String? = nil

    var hasText: Bool {
        !confirmedLines.isEmpty || !hypothesis.isEmpty
    }

    // MARK: Audio plumbing

    nonisolated let inbox = SampleInbox()

    // MARK: Private state

    @ObservationIgnored private var pipe: WhisperKit?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var offlineBusy = false
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var windowSamples: [Float] = []
    @ObservationIgnored private var windowStartSample = 0

    private static let sampleRate = Int(SampleInbox.targetRate)
    private static let tickInterval: Duration = .seconds(3)
    private static let confirmThresholdSamples = 25 * sampleRate
    /// While the model is still downloading, buffered audio is capped at 15 min;
    /// beyond that the oldest audio is dropped and a gap line is recorded.
    private static let maxWindowSamples = 15 * 60 * sampleRate
    private static let silenceRMSFloor: Float = 0.0005

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
    /// is set. Repeat calls for the model already loaded (or loading) are no-ops;
    /// a call for a different model supersedes any load in flight.
    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        if modelName == name {
            switch engineState {
            case .ready, .downloading, .loading:
                return
            case .notDownloaded where !downloadIfNeeded:
                return
            default:
                break
            }
        }

        loadGeneration += 1
        let generation = loadGeneration
        modelName = name
        pipe = nil

        if !Self.isDownloaded(name) && !downloadIfNeeded {
            engineState = .notDownloaded(name)
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
            engineState = .ready
        } catch {
            guard loadGeneration == generation else { return }
            Self.log.error("model load failed: \(error.localizedDescription)")
            engineState = .failed(error.localizedDescription)
        }
    }

    /// Wait until the current model is loaded (kicking off a download when
    /// needed). Throws when loading fails or the timeout passes.
    private func awaitReady(timeout: TimeInterval = 600) async throws -> WhisperKit {
        if case .notDownloaded = engineState {
            await loadModel(modelName, downloadIfNeeded: true)
        }
        if case .unloaded = engineState {
            await loadModel(modelName, downloadIfNeeded: true)
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
    /// window, and return the final transcript body (confirmed lines as
    /// timestamped Markdown paragraphs). Empty when nothing was transcribed.
    func endSession() async -> String {
        guard isSessionActive else { return transcriptBody() }
        inbox.end()
        tickTask?.cancel()
        tickTask = nil
        isSessionActive = false

        while ticking {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if case .downloading = engineState {
            _ = try? await awaitReady()
        }
        if case .loading = engineState {
            _ = try? await awaitReady()
        }
        await tick(final: true)
        return transcriptBody()
    }

    func cancelSession() {
        sessionGeneration += 1
        inbox.end()
        tickTask?.cancel()
        tickTask = nil
        isSessionActive = false
        windowSamples = []
        windowStartSample = 0
        confirmedLines = []
        hypothesis = ""
        revision += 1
    }

    /// The transcript so far as plain text, for the panel's copy button.
    func transcript(includeHypothesis: Bool) -> String {
        var parts = confirmedLines.map { "[\($0.timestampLabel)] \($0.text)" }
        if includeHypothesis {
            let hyp = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hyp.isEmpty { parts.append(hyp) }
        }
        return parts.joined(separator: "\n\n")
    }

    private func transcriptBody() -> String {
        confirmedLines
            .map { "[\($0.timestampLabel)] \($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: Tick loop

    private func tick(final: Bool) async {
        if ticking { return }
        if !final && !isSessionActive { return }
        if final {
            while offlineBusy {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else if offlineBusy {
            return
        }
        ticking = true
        defer { ticking = false }
        let generation = sessionGeneration

        let fresh = inbox.drainMixed(flush: final)
        if !fresh.isEmpty {
            windowSamples.append(contentsOf: fresh)
        }
        if windowSamples.count > Self.maxWindowSamples {
            let overflow = windowSamples.count - Self.maxWindowSamples
            windowSamples.removeFirst(overflow)
            windowStartSample += overflow
            noteGap()
        }

        guard let pipe else { return }
        guard !windowSamples.isEmpty else { return }
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
                } else {
                    confirm(segments)
                    hypothesis = ""
                    windowStartSample += windowSamples.count
                    windowSamples.removeAll()
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
            confirmedLines.append(TranscriptLine(time: base + TimeInterval(segment.start), text: text))
        }
    }

    private func noteGap() {
        let marker = "[gap: transcription could not keep up with the recording]"
        guard confirmedLines.last?.text != marker else { return }
        let time = TimeInterval(windowStartSample) / TimeInterval(Self.sampleRate)
        confirmedLines.append(TranscriptLine(time: time, text: marker))
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

    /// Transcribe a saved recording (stereo m4a; channels are summed to mono by
    /// WhisperKit's loader) and return the transcript body as timestamped
    /// Markdown paragraphs. Serialized against the live tick loop: WhisperKit
    /// carries mutable decode state, so one pipe must never transcribe twice
    /// concurrently.
    func transcribeFile(_ url: URL) async throws -> String {
        let pipe = try await awaitReady()
        while ticking || offlineBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        offlineBusy = true
        defer { offlineBusy = false }
        let results = try await pipe.transcribe(
            audioPath: url.path,
            decodeOptions: decodingOptions(forFile: true)
        )
        let segments = cleanSegments(results)
        return segments
            .map { segment in
                let line = TranscriptLine(
                    time: TimeInterval(segment.start),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                return "[\(line.timestampLabel)] \(line.text)"
            }
            .joined(separator: "\n\n")
    }
}
