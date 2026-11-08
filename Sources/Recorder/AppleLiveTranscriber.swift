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
    private var finalEnd: TimeInterval = 0

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

final class StreamingEnergyLog: @unchecked Sendable {
    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let desktop: Float
        let mic: Float
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ chunk: StreamingAudioInput.Chunk) {
        lock.withLock {
            entries.append(Entry(start: chunk.start, end: chunk.start + chunk.duration,
                                 desktop: chunk.desktopEnergy, mic: chunk.micEnergy))
            entries.removeAll { $0.end < chunk.start - 60 }
        }
    }

    func clear() { lock.withLock { entries = [] } }

    func sums(start: TimeInterval, end: TimeInterval) -> (desktop: Float, mic: Float)? {
        lock.withLock {
            guard let first = entries.first, start >= first.start - 0.1 else { return nil }
            var desktop: Float = 0, mic: Float = 0
            for entry in entries where entry.start < end && entry.end > start {
                desktop += entry.desktop
                mic += entry.mic
            }
            return (desktop, mic)
        }
    }
}

@MainActor
@Observable
final class AppleLiveTranscriber {
    struct SessionResult {
        let lines: [TranscriptLine]
        let complete: Bool
        var isEmpty: Bool { lines.isEmpty }
    }

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
    var hasText: Bool { !confirmedLines.isEmpty || !hypothesis.isEmpty }

    nonisolated let inbox = StreamingAudioInput()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private var pump: StreamingInputPump?
    @ObservationIgnored private var generation = 0
    private let energyLog = StreamingEnergyLog()

    func start(language: String) async throws {
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
        localeIdentifier = locale.identifier
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(4))
        self.continuation = continuation
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

    func endSession() async -> SessionResult {
        guard isSessionActive, let analyzer else {
            return SessionResult(lines: confirmedLines, complete: failureMessage == nil)
        }
        let generation = self.generation
        inbox.end()
        if let error = pump?.finish() { fail(error, generation: generation) }
        pump = nil
        inbox.discard()
        continuation?.finish()
        continuation = nil
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.fail(LiveStopError(reason: .finalizationTimedOut, detail: nil), generation: generation)
            await analyzer.cancelAndFinishNow()
        }
        await analysisTask?.value
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { fail(error, generation: generation) }
        await resultTask?.value
        timeout.cancel()
        await analyzer.cancelAndFinishNow()
        guard generation == self.generation else { return SessionResult(lines: [], complete: false) }
        if let failureMessage { text.markIncomplete(failureMessage); revision += 1 }
        self.analyzer = nil
        analysisTask = nil
        resultTask = nil
        energyLog.clear()
        isSessionActive = false
        return SessionResult(lines: confirmedLines, complete: failureMessage == nil)
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

    func transcript(includeHypothesis: Bool) -> String {
        (confirmedLines.map(\.markdown) + (includeHypothesis && !hypothesis.isEmpty ? [hypothesis] : []))
            .joined(separator: "\n\n")
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
        guard labelSpeakers, let (desktop, mic) = energyLog.sums(start: start, end: end) else { return nil }
        guard max(desktop, mic) > 0.0001 else { return nil }
        if mic > desktop * 4 { return "You" }
        if desktop > mic * 4 { return "Them" }
        return nil
    }
}
