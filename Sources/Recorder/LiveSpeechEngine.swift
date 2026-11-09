import Foundation

struct LiveSessionResult {
    let lines: [TranscriptLine]
    let complete: Bool
    let stopReason: LiveStopReason?
    var isEmpty: Bool { lines.isEmpty }
}

enum MetricQuality: String, Codable, Sendable {
    case measured, estimated, unknown
}

struct DiagnosticRow: Codable, Equatable, Sendable {
    let label: String
    let value: String
    let quality: MetricQuality

    static let erasureLabel = "Erasure"
    static let erasureNotGuaranteed = DiagnosticRow(label: erasureLabel, value: "not guaranteed", quality: .unknown)
}

struct PreparationInfo: Codable, Equatable, Sendable {
    let loadSeconds: Double
    let firstLoad: Bool
    let modelBytesOnDisk: Int64?
    let computeUnits: String
}

struct EngineDiagnostics: Equatable, Sendable {
    let submittedThroughSeconds: Double
    let latestProvisionalEnd: Double?
    let latestFinalEnd: Double?
    let heldAudioSeconds: Double?
    let heldAudioQuality: MetricQuality
    let rows: [DiagnosticRow]
}

@MainActor
protocol LiveSpeechEngine: AnyObject {
    var kind: LiveEngineKind { get }
    var displayName: String { get }
    var isLoaded: Bool { get }
    var finalizationTimeout: Duration { get }
    var confirmedLines: [TranscriptLine] { get }
    var hypothesis: String { get }
    var revision: Int { get }
    var isSessionActive: Bool { get }
    var failureMessage: String? { get }
    var stopReason: LiveStopReason? { get }
    var labelSpeakers: Bool { get set }
    var onFailure: (() -> Void)? { get set }
    nonisolated var inbox: StreamingAudioInput { get }
    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo
    func startSession() throws
    func endSession() async -> LiveSessionResult
    func cancelSession()
    func captureFailed(_ error: Error)
    func diagnostics() -> EngineDiagnostics
    func unload() async
}

final class LiveInboxRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: StreamingAudioInput?

    var current: StreamingAudioInput? { lock.withLock { inbox } }

    func set(_ inbox: StreamingAudioInput?) {
        lock.withLock { self.inbox = inbox }
    }

    func ingest(_ source: StreamingAudioInput.Source, _ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        lock.withLock { inbox }?.ingest(source, samples, count: count, rate: rate)
    }
}
