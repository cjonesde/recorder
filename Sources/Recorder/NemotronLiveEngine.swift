import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation
import Observation

private final class NemotronFeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var fedSamples = 0
    private var rescues = 0
    private var spans = 0

    var fedSeconds: Double { lock.withLock { Double(fedSamples) / NemotronLiveEngine.sampleRate } }

    var recovery: (rescues: Int, spans: Int) { lock.withLock { (rescues, spans) } }

    func add(_ samples: Int) { lock.withLock { fedSamples += samples } }

    func setRecovery(rescues: Int, spans: Int) {
        lock.withLock {
            self.rescues = rescues
            self.spans = spans
        }
    }

    func reset() {
        lock.withLock {
            fedSamples = 0
            rescues = 0
            spans = 0
        }
    }
}

@MainActor
@Observable
final class NemotronLiveEngine: LiveSpeechEngine {
    nonisolated static let sampleRate = 16_000.0
    nonisolated static let chunkMs = 560
    nonisolated static let chunkSamples = 8_960
    nonisolated static let handoffSeconds = 10.0
    nonisolated static let libraryBufferSeconds = 10.1
    nonisolated static let recoverySpanSeconds = 15.24
    nonisolated static let recoverySwitch = "FLUIDAUDIO_DISABLE_BLANK_RESCUE"
    nonisolated static let computeUnitsLabel = "CPU and Neural Engine"

    private struct Finalization: Sendable {
        let timings: [TokenTiming]
        let finished: Bool
        let error: LiveStopError?
    }

    nonisolated static var modelsDirectory: URL { FluidEngineSupport.modelsDirectory }

    nonisolated static func variantDirectory(language: String, root: URL = modelsDirectory) -> URL {
        root.appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent(StreamingNemotronMultilingualAsrManager.languageDirectory(for: language), isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
    }

    nonisolated static var recoveryEnabled: Bool {
        guard let raw = getenv(recoverySwitch) else { return true }
        return ["0", "false", "no"].contains(String(cString: raw).lowercased())
    }

    nonisolated static func enableRecovery() {
        guard let raw = getenv(recoverySwitch), String(cString: raw) != "0" else { return }
        setenv(recoverySwitch, "0", 1)
    }

    let kind = LiveEngineKind.nemotron
    let displayName = "Nemotron 3.5 streaming"
    let finalizationTimeout: Duration = .seconds(30)
    var isLoaded: Bool { manager != nil }

    private(set) var isSessionActive = false
    private(set) var revision = 0
    private(set) var failureMessage: String?
    private(set) var stopReason: LiveStopReason?
    var labelSpeakers = true
    var onFailure: (() -> Void)?

    private var text = StreamingTranscript()
    var confirmedLines: [TranscriptLine] { text.lines }
    var hypothesis: String { text.hypothesis }

    nonisolated let inbox = StreamingAudioInput()
    @ObservationIgnored private var manager: StreamingNemotronMultilingualAsrManager?
    @ObservationIgnored private var loadedVariant: URL?
    @ObservationIgnored private var segmenter = TokenLineSegmenter()
    @ObservationIgnored private var handoff: BoundedEngineHandoff?
    @ObservationIgnored private var pump: StreamingInputPump?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var managerWork: Task<Void, Never>?
    @ObservationIgnored private var lastHandoffPeak: Double = 0
    @ObservationIgnored private var generation = 0
    private let energyLog = StreamingEnergyLog()
    private let meter = NemotronFeedMeter()

    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo {
        let clock = ContinuousClock()
        let began = clock.now
        try Task.checkCancellation()
        cancelSession()
        let generation = self.generation
        Self.enableRecovery()
        let root = Self.modelsDirectory
        let variant = Self.variantDirectory(language: language, root: root)
        let firstLoad = !FileManager.default.fileExists(atPath: variant.path)
        if manager == nil || loadedVariant != variant {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: language, chunkMs: Self.chunkMs, to: root, configuration: configuration,
                progressHandler: { progress($0.fractionCompleted) }
            )
            try Task.checkCancellation()
            let loaded = StreamingNemotronMultilingualAsrManager(configuration: configuration)
            do {
                try await loaded.loadFromShared(shared)
                await loaded.setLanguage("auto")
                try Task.checkCancellation()
                guard generation == self.generation else { throw CancellationError() }
            } catch {
                await loaded.cleanup()
                throw error
            }
            if let previous = manager {
                await enqueueManagerWork { await previous.cleanup() }.value
            }
            manager = loaded
            loadedVariant = variant
        }
        return PreparationInfo(loadSeconds: FluidEngineSupport.seconds(clock.now - began), firstLoad: firstLoad,
                               modelBytesOnDisk: FluidEngineSupport.bytesOnDisk(variant), computeUnits: Self.computeUnitsLabel)
    }

    func startSession() throws {
        guard !isSessionActive, let manager,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw LiveStopError(reason: .engineError, detail: "Nemotron was not prepared")
        }
        let generation = self.generation
        let handoff = BoundedEngineHandoff(capacitySeconds: Self.handoffSeconds, sampleRate: Self.sampleRate)
        self.handoff = handoff
        segmenter = TokenLineSegmenter()
        meter.reset()
        lastHandoffPeak = 0
        energyLog.resetSubmitted()
        inbox.begin(format: format)
        isSessionActive = true

        let previousWork = managerWork
        let meter = meter
        consumer = Task.detached { [weak self] in
            await previousWork?.value
            var seen: (count: Int, end: Double) = (0, -1)
            while var samples = await handoff.next() {
                do {
                    var offset = 0
                    while offset < samples.count {
                        let upper = min(offset + Self.chunkSamples, samples.count)
                        var slice = Array(samples[offset..<upper])
                        _ = try await manager.process(samples: slice)
                        meter.add(slice.count)
                        AudioMemory.discard(&slice)
                        offset = upper
                    }
                    AudioMemory.discard(&samples)
                } catch {
                    AudioMemory.discard(&samples)
                    await self?.fail(error, generation: generation)
                    return
                }
                let timings = await manager.getTokenTimings()
                meter.setRecovery(rescues: await manager.blankRescueCount, spans: await manager.detectedBlankSpanCount)
                let marker = (count: timings.count, end: timings.last?.endTime ?? -1)
                guard marker != seen else { continue }
                seen = marker
                await self?.absorb(timings, generation: generation)
            }
        }

        let energyLog = energyLog
        let pump = StreamingInputPump(
            inbox: inbox,
            deliver: { chunk in
                energyLog.record(chunk)
                try handoff.push(chunk)
            },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.fail(error, generation: generation) }
            }
        )
        self.pump = pump
        pump.start()
    }

    func endSession() async -> LiveSessionResult {
        guard isSessionActive, let manager, let handoff else {
            return LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
        }
        let generation = self.generation
        inbox.end()
        if let error = pump?.finish() { fail(error, generation: generation) }
        pump = nil
        inbox.discard()
        handoff.finish()
        let consumer = self.consumer
        let work = Task.detached { [weak self] () -> Finalization in
            await consumer?.value
            let failed = await self?.failureMessage != nil
            if !failed {
                do {
                    let result = try await manager.finishWithTokenTimings()
                    return Finalization(timings: result.timings, finished: true, error: nil)
                } catch {
                    return Finalization(timings: await manager.getTokenTimings(), finished: false,
                                        error: LiveStopError(reason: .engineError, detail: error.localizedDescription))
                }
            }
            return Finalization(timings: await manager.getTokenTimings(), finished: false, error: nil)
        }
        let teardown = enqueueManagerWork {
            _ = await work.value
            await manager.reset()
        }
        let outcome = await FluidEngineSupport.value(of: work, within: finalizationTimeout)
        guard generation == self.generation else { return LiveSessionResult(lines: [], complete: false, stopReason: nil) }
        if let outcome {
            if let error = outcome.error { fail(error, generation: generation) }
            let tokens = pendingTokens(outcome.timings)
            if outcome.finished {
                for line in segmenter.finish(tokens) { commit(line) }
            } else {
                showTokens(tokens)
            }
        } else {
            fail(LiveStopError(reason: .finalizationTimedOut, detail: nil), generation: generation)
        }
        if let failureMessage { text.markIncomplete(failureMessage) }
        revision += 1
        lastHandoffPeak = handoff.peakHeldSeconds
        self.handoff = nil
        self.consumer = nil
        energyLog.clear()
        isSessionActive = false
        let result = LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
        if outcome != nil {
            await teardown.value
            meter.reset()
        }
        return result
    }

    func captureFailed(_ error: Error) { fail(error, generation: generation) }

    func cancelSession() {
        generation += 1
        inbox.discard()
        pump?.stop()
        handoff?.cancel()
        consumer?.cancel()
        if let manager, let consumer {
            enqueueManagerWork {
                await consumer.value
                await manager.reset()
            }
        }
        pump = nil
        handoff = nil
        consumer = nil
        energyLog.clear()
        meter.reset()
        isSessionActive = false
        failureMessage = nil
        stopReason = nil
        text = StreamingTranscript()
        segmenter = TokenLineSegmenter()
        revision += 1
    }

    func diagnostics() -> EngineDiagnostics {
        let handoffHeld = handoff?.heldSeconds ?? 0
        let fed = meter.fedSeconds
        let recovery = Self.recoveryEnabled
        let held = handoffHeld + min(fed, Self.libraryBufferSeconds) + (recovery && fed > 0 ? Self.recoverySpanSeconds : 0)
        let peak = handoff?.peakHeldSeconds ?? lastHandoffPeak
        let counts = meter.recovery
        return EngineDiagnostics(
            submittedThroughSeconds: energyLog.submittedThrough,
            latestProvisionalEnd: text.latestProvisionalEnd,
            latestFinalEnd: text.finalEnd > 0 ? text.finalEnd : nil,
            heldAudioSeconds: held,
            heldAudioQuality: .estimated,
            rows: [
                DiagnosticRow(label: "Handoff peak", value: String(format: "%.1f s", peak), quality: .measured),
                DiagnosticRow(label: "Fed to engine", value: String(format: "%.1f s", fed), quality: .measured),
                DiagnosticRow(label: "Recovery", value: recovery ? "on" : "off", quality: .measured),
                DiagnosticRow(label: "Recovery replay", value: "not observable", quality: .unknown),
                DiagnosticRow(label: "Recovered spans",
                              value: "\(counts.rescues) of \(counts.spans)", quality: .measured)
            ]
        )
    }

    func unload() async {
        cancelSession()
        guard let manager else { return }
        self.manager = nil
        loadedVariant = nil
        await enqueueManagerWork { await manager.cleanup() }.value
    }

    private func absorb(_ timings: [TokenTiming], generation: Int) {
        guard generation == self.generation, isSessionActive, failureMessage == nil else { return }
        showTokens(pendingTokens(timings))
    }

    private func showTokens(_ tokens: [TokenLineSegmenter.Token]) {
        for line in segmenter.confirm(tokens) { commit(line) }
        if let tail = segmenter.tailLine(tokens) {
            text.update(text: tail.text, start: tail.start, end: tail.end, final: false, speaker: nil)
        }
        revision += 1
    }

    private func commit(_ line: TokenLineSegmenter.Line) {
        text.update(text: line.text, start: line.start, end: line.end, final: true,
                    speaker: speaker(start: line.start, end: line.end))
    }

    private func pendingTokens(_ timings: [TokenTiming]) -> [TokenLineSegmenter.Token] {
        let from = segmenter.boundaryStart - 1e-6
        return timings.lazy.filter { $0.startTime >= from }
            .map { TokenLineSegmenter.Token(text: $0.token, start: $0.startTime, end: $0.endTime) }
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation, failureMessage == nil else { return }
        let stop = error as? LiveStopError ?? LiveStopError(reason: .engineError, detail: error.localizedDescription)
        failureMessage = stop.localizedDescription
        stopReason = stop.reason
        inbox.discard()
        pump?.stop()
        handoff?.cancel()
        onFailure?()
    }

    private func speaker(start: TimeInterval, end: TimeInterval) -> String? {
        labelSpeakers ? energyLog.speaker(start: start, end: end) : nil
    }

    @discardableResult
    private func enqueueManagerWork(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = managerWork
        let task = Task.detached {
            await previous?.value
            await body()
        }
        managerWork = task
        return task
    }
}
