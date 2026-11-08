import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech

struct StreamingTranscript {
    struct Part {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private(set) var lines: [TranscriptLine] = []
    private var provisional: [Part] = []
    private(set) var finalEnd: TimeInterval = 0

    var latestProvisionalEnd: Double? { provisional.map(\.end).max() }

    var hypothesis: String { provisional.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") }

    mutating func update(text: String, start: TimeInterval, end: TimeInterval, final: Bool, speaker: String?) {
        guard start.isFinite, end.isFinite, end >= start, end > finalEnd else { return }
        provisional.removeAll { $0.start < end && $0.end > start || $0.start == start }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            if !text.isEmpty { lines.append(TranscriptLine(time: max(0, start), text: text, speaker: speaker)) }
            finalEnd = end
            provisional.removeAll { $0.end <= end }
        } else if !text.isEmpty {
            provisional.append(Part(start: start, end: end, text: text))
        }
    }

    mutating func markIncomplete(_ reason: String) {
        for part in provisional.sorted(by: { $0.start < $1.start }) {
            lines.append(TranscriptLine(time: part.start, text: "[unconfirmed] \(part.text)", speaker: nil))
        }
        provisional = []
        lines.append(TranscriptLine(time: finalEnd, text: "[incomplete: \(reason)]", speaker: nil))
    }
}

@MainActor
@Observable
final class AppleLiveTranscriber: LiveSpeechEngine {
    let kind = LiveEngineKind.apple
    let finalizationTimeout: Duration = .seconds(10)
    var displayName: String { "Apple SpeechTranscriber (\(localeIdentifier))" }
    var isLoaded: Bool { loadedLocale != nil }

    private(set) var isSessionActive = false
    private(set) var revision = 0
    private(set) var failureMessage: String?
    private(set) var stopReason: LiveStopReason?
    private(set) var localeIdentifier = ""
    var labelSpeakers = true
    var onFailure: (() -> Void)?

    private var text = StreamingTranscript()
    var confirmedLines: [TranscriptLine] { text.lines }
    var hypothesis: String { text.hypothesis }

    nonisolated let inbox = StreamingAudioInput()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var module: SpeechTranscriber?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var loadedLocale: String?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private var pump: StreamingInputPump?
    @ObservationIgnored private var generation = 0
    private let energyLog = StreamingEnergyLog()

    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo {
        let clock = ContinuousClock()
        let began = clock.now
        try Task.checkCancellation()
        cancelSession()
        let generation = self.generation
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw StreamingSpeechError.unavailableLanguage
        }
        try Task.checkCancellation()
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              format.channelCount == 1, [.pcmFormatFloat32, .pcmFormatInt16].contains(format.commonFormat) else {
            throw StreamingSpeechError.unsupportedFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        self.analyzer = analyzer
        self.module = module
        self.format = format
        localeIdentifier = locale.identifier
        let firstLoad = loadedLocale != locale.identifier
        loadedLocale = locale.identifier
        let elapsed = clock.now - began
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return PreparationInfo(loadSeconds: seconds, firstLoad: firstLoad, modelBytesOnDisk: nil, computeUnits: "Managed by macOS")
    }

    func startSession() throws {
        guard !isSessionActive, let analyzer, let module, let format else {
            throw LiveStopError(reason: .engineError, detail: "Apple speech was not prepared")
        }
        let generation = self.generation
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        self.continuation = continuation
        energyLog.resetSubmitted()
        inbox.begin(format: format)
        isSessionActive = true

        resultTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self, generation == self.generation else { return }
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    self.text.update(text: String(result.text.characters), start: start, end: end,
                                     final: result.isFinal, speaker: self.speaker(start: start, end: end))
                    self.revision += 1
                }
            } catch {
                self?.fail(error, generation: generation)
            }
        }
        analysisTask = Task.detached { [weak self] in
            do { _ = try await analyzer.analyzeSequence(inputs) }
            catch { await self?.fail(error, generation: generation) }
        }
        let energyLog = energyLog
        let pump = StreamingInputPump(
            inbox: inbox,
            deliver: { chunk in
                energyLog.record(chunk)
                guard case .enqueued = continuation.yield(AnalyzerInput(buffer: chunk.buffer, bufferStartTime: chunk.startTime)) else {
                    throw LiveStopError(reason: .engineQueueFull, detail: nil)
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.fail(error, generation: generation) }
            }
        )
        self.pump = pump
        pump.start()
    }

    func endSession() async -> LiveSessionResult {
        guard isSessionActive, let analyzer else {
            return LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
        }
        let generation = self.generation
        inbox.end()
        if let error = pump?.finish() { fail(error, generation: generation) }
        pump = nil
        inbox.discard()
        continuation?.finish()
        continuation = nil
        let finalizationTimeout = finalizationTimeout
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            self?.fail(LiveStopError(reason: .finalizationTimedOut, detail: nil), generation: generation)
            await analyzer.cancelAndFinishNow()
        }
        await analysisTask?.value
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { fail(error, generation: generation) }
        await resultTask?.value
        timeout.cancel()
        await analyzer.cancelAndFinishNow()
        guard generation == self.generation else { return LiveSessionResult(lines: [], complete: false, stopReason: nil) }
        if let failureMessage { text.markIncomplete(failureMessage); revision += 1 }
        self.analyzer = nil
        module = nil
        format = nil
        analysisTask = nil
        resultTask = nil
        energyLog.clear()
        isSessionActive = false
        return LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
    }

    func captureFailed(_ error: Error) { fail(error, generation: generation) }

    func cancelSession() {
        generation += 1
        inbox.discard()
        pump?.stop()
        analysisTask?.cancel()
        resultTask?.cancel()
        continuation?.finish()
        continuation = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        module = nil
        format = nil
        pump = nil
        analysisTask = nil
        resultTask = nil
        energyLog.clear()
        isSessionActive = false
        failureMessage = nil
        stopReason = nil
        text = StreamingTranscript()
        revision += 1
    }

    func diagnostics() -> EngineDiagnostics {
        EngineDiagnostics(
            submittedThroughSeconds: energyLog.submittedThrough,
            latestProvisionalEnd: text.latestProvisionalEnd,
            latestFinalEnd: text.finalEnd > 0 ? text.finalEnd : nil,
            heldAudioSeconds: inbox.pendingSeconds,
            heldAudioQuality: .measured,
            rows: [DiagnosticRow(label: "Inside Apple", value: "unknown", quality: .unknown)]
        )
    }

    func unload() async {
        cancelSession()
        loadedLocale = nil
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation, failureMessage == nil else { return }
        let stop = error as? LiveStopError ?? LiveStopError(reason: .engineError, detail: error.localizedDescription)
        failureMessage = stop.localizedDescription
        stopReason = stop.reason
        inbox.discard()
        continuation?.finish()
        pump?.stop()
        onFailure?()
    }

    private func speaker(start: TimeInterval, end: TimeInterval) -> String? {
        labelSpeakers ? energyLog.speaker(start: start, end: end) : nil
    }
}
