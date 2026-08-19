import Foundation
import Observation
import Accelerate
import os
import WhisperKit

// MARK: - LiveTranscriber

/// Streams a transcript while recording. Both captures feed `inbox`; a tick loop mixes
/// them to 16 kHz mono and re-transcribes a sliding window every few seconds. Once the
/// window passes the confirm threshold, every segment except the trailing one is
/// confirmed and its audio dropped.
@MainActor
@Observable
final class LiveTranscriber {

    /// What `endSession` produced. `complete` is false when the final tail could not be
    /// transcribed, so callers can fall back to transcribing the saved audio.
    struct LiveSessionResult {
        let body: String
        let complete: Bool
    }

    let host: WhisperModelHost

    var confirmedLines: [TranscriptLine] = []
    var hypothesis: String = ""
    var isSessionActive = false
    /// Bumped on every transcript change; the panel observes it to auto-scroll.
    var revision = 0

    /// ISO language code, nil = auto-detect per window.
    var language: String? = nil

    /// Whether live lines carry "You"/"Them" labels from channel attribution.
    var labelSpeakers: Bool = true

    /// Cap on buffered live audio. Lowered in transcript-only mode, where this buffer is
    /// the only place audio exists.
    var maxWindowSamples = 15 * 60 * Int(SampleInbox.targetRate)

    var hasText: Bool {
        !confirmedLines.isEmpty || !hypothesis.isEmpty
    }

    nonisolated let inbox = SampleInbox()

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var finalTickComplete = false
    @ObservationIgnored private var windowSamples: [Float] = []
    @ObservationIgnored private var windowStartSample = 0
    @ObservationIgnored private var desktopEnvelope: [Float] = []
    @ObservationIgnored private var micEnvelope: [Float] = []
    @ObservationIgnored private var desktopSpeechBlocks = 0
    @ObservationIgnored private var micSpeechBlocks = 0

    private static let sampleRate = Int(SampleInbox.targetRate)
    static let tickInterval: Duration = .seconds(3)
    private static let confirmThresholdSamples = 25 * sampleRate
    /// A single unbroken segment may grow past the confirm threshold in the hope of a
    /// natural boundary, but never past Whisper's 30 s window.
    private static let hardWindowCapSamples = 29 * sampleRate
    private static let silenceRMSFloor: Float = 0.0005

    private static let envelopeBlocksPerSecond = Int(SampleInbox.targetRate) / SampleInbox.energyBlockSamples
    /// Mean-square above this counts a 100 ms block as speech (RMS ~ -60 dBFS).
    private static let speechBlockFloor: Float = 1e-6
    /// Both channels need at least this much speech before "You"/"Them" labels are
    /// trusted, which prevents labeling everything in a single-channel recording.
    private static let minSpeechBlocksPerChannel = 10
    /// One channel must carry 4x the energy of the other to claim a segment.
    private static let channelDominanceRatio: Float = 4

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "LiveTranscriber")

    init(host: WhisperModelHost) {
        self.host = host
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
                try? await Task.sleep(for: LiveTranscriber.tickInterval)
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
            switch host.state {
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
        if windowSamples.count > maxWindowSamples {
            let overflow = windowSamples.count - maxWindowSamples
            windowSamples.removeFirst(overflow)
            windowStartSample += overflow
            noteGap()
        }

        guard !windowSamples.isEmpty else {
            if final { finalTickComplete = true }
            return
        }
        guard host.loadedModel != nil else { return }
        if fresh.isEmpty && !final { return }

        if !final && windowRMS() < Self.silenceRMSFloor && hypothesis.isEmpty {
            if windowSamples.count > Self.confirmThresholdSamples {
                windowStartSample += windowSamples.count
                windowSamples.removeAll(keepingCapacity: true)
            }
            return
        }

        do {
            let window = windowSamples
            let options = decodingOptions(forFile: false)
            let results = try await host.withPipe { pipe in
                try await pipe.transcribe(audioArray: window, decodeOptions: options)
            }
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


}
