import Foundation
import Observation

enum RecordingPhase: String, Codable, Sendable {
    case preparing, recording, finishing
}

struct DebugEvent: Codable, Equatable, Sendable {
    let t: Double
    let phase: RecordingPhase
    let kind: String
    let detail: String?
}

struct DiagnosticSample: Codable, Equatable, Sendable {
    let t: Double
    let phase: RecordingPhase
    let reading: MetricsReading
    let swapGrowthBytes: Int64?
    let swapInsSinceStart: UInt64?
    let swapOutsSinceStart: UInt64?
    let textBehindRough: Double?
    let textBehindFinal: Double?
    let heldAudioSeconds: Double?
    let heldAudioQuality: MetricQuality
    let longestMainThreadStall: Double
    let audioFilesOnDisk: [String]
}

@MainActor
@Observable
final class DiagnosticsRecorder {
    static let nonAudioFiles: Set<String> = ["transcript.md", "transcript.json", "debug.json"]

    let engine: LiveEngineKind
    let settings: [String: String]
    let measuresSpeechService: Bool
    private(set) var phase: RecordingPhase = .preparing
    private(set) var samples: [DiagnosticSample] = []
    private(set) var events: [DebugEvent] = []
    private(set) var preparation: PreparationInfo?
    private(set) var stops: [LiveStopReason] = []
    private(set) var engineRows: [DiagnosticRow] = []
    private(set) var hasSeenFirstText = false
    private(set) var hasSeenFirstFinalText = false

    @ObservationIgnored private let source: SystemMetricsSource
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let startedAt: TimeInterval
    @ObservationIgnored private let baseline: MetricsReading
    @ObservationIgnored private var captureStartedAt: TimeInterval?

    init(source: SystemMetricsSource, now: @escaping () -> TimeInterval, engine: LiveEngineKind, settings: [String: String], measuresSpeechService: Bool? = nil) {
        self.source = source
        self.now = now
        self.engine = engine
        self.settings = settings
        self.measuresSpeechService = measuresSpeechService ?? (engine == .apple)
        startedAt = now()
        baseline = source.read(includeSpeechService: self.measuresSpeechService)
    }

    private var elapsed: Double { now() - startedAt }

    func setPhase(_ phase: RecordingPhase) {
        self.phase = phase
    }

    func record(_ kind: String, detail: String?) {
        events.append(DebugEvent(t: elapsed, phase: phase, kind: kind, detail: detail))
    }

    func setPreparation(_ info: PreparationInfo) {
        preparation = info
    }

    func recordStop(_ reason: LiveStopReason) {
        guard !stops.contains(reason) else { return }
        stops.append(reason)
        record("safety stop", detail: reason.rawValue)
    }

    func captureStarted(stall: Double) {
        captureStartedAt = now()
        record("capture started", detail: String(format: "longest main-thread stall %.3f s", stall))
    }

    func noteText(hypothesis: String, finalLines: Int) {
        if !hasSeenFirstText, !hypothesis.isEmpty || finalLines > 0 {
            hasSeenFirstText = true
            record("first text", detail: sinceCaptureStart())
        }
        if !hasSeenFirstFinalText, finalLines > 0 {
            hasSeenFirstFinalText = true
            record("first final text", detail: sinceCaptureStart())
        }
    }

    private func sinceCaptureStart() -> String? {
        guard let captureStartedAt else { return nil }
        return String(format: "%.2f s after capture start", now() - captureStartedAt)
    }

    func sample(engine diagnostics: EngineDiagnostics, stall: Double, folder: URL?) {
        let reading = source.read(includeSpeechService: measuresSpeechService)
        engineRows = diagnostics.rows
        samples.append(DiagnosticSample(
            t: elapsed,
            phase: phase,
            reading: reading,
            swapGrowthBytes: Self.difference(reading.swapUsedBytes, baseline.swapUsedBytes),
            swapInsSinceStart: Self.increase(reading.swapIns, baseline.swapIns),
            swapOutsSinceStart: Self.increase(reading.swapOuts, baseline.swapOuts),
            textBehindRough: diagnostics.latestProvisionalEnd.map { diagnostics.submittedThroughSeconds - $0 },
            textBehindFinal: diagnostics.latestFinalEnd.map { diagnostics.submittedThroughSeconds - $0 },
            heldAudioSeconds: diagnostics.heldAudioSeconds,
            heldAudioQuality: diagnostics.heldAudioQuality,
            longestMainThreadStall: stall,
            audioFilesOnDisk: folder.map(Self.audioFiles(in:)) ?? []
        ))
    }

    var erasureRow: DiagnosticRow? {
        engineRows.first { $0.label == DiagnosticRow.erasureLabel }
    }

    private static func difference(_ now: UInt64?, _ start: UInt64?) -> Int64? {
        guard let now, let start else { return nil }
        return Int64(clamping: now) - Int64(clamping: start)
    }

    private static func increase(_ now: UInt64?, _ start: UInt64?) -> UInt64? {
        guard let now, let start else { return nil }
        return now > start ? now - start : 0
    }

    static func audioFiles(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !nonAudioFiles.contains($0) && !$0.hasPrefix(".") }.sorted()
    }
}
