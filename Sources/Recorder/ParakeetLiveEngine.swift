import AVFoundation
import FluidAudio
import Foundation
import Observation

struct WindowTranscriptMerger {
    typealias Token = TokenLineSegmenter.Token
    typealias Line = TokenLineSegmenter.Line

    static let seamJitterSeconds = 0.4
    private static let tolerance = 1e-6

    private var pending: [Token] = []

    var tail: Line? { Self.line(pending[...]) }

    mutating func absorb(_ incoming: [Token], confirmed: Bool) -> Line? {
        if let first = incoming.first, pending.isEmpty || Self.startsWord(first) {
            reconcileSeam(with: incoming)
        }
        pending.append(contentsOf: incoming)
        guard confirmed, let held = Self.wordStarts(pending).last, held > 0 else { return nil }
        let line = Self.line(pending[..<held])
        pending.removeFirst(held)
        return line
    }

    mutating func finish() -> Line? {
        defer { pending = [] }
        return Self.line(pending[...])
    }

    private mutating func reconcileSeam(with incoming: [Token]) {
        let first = incoming[0]
        if let overlap = pending.firstIndex(where: { $0.start >= first.start - Self.tolerance }) {
            let cut = Self.wordStarts(pending).last { $0 <= overlap } ?? 0
            pending.removeSubrange(cut...)
        }
        guard let last = Self.wordStarts(pending).last, let lastToken = pending.last else { return }
        let previous = Self.core(pending[last...])
        let replacement = Self.core(Self.firstWord(incoming))
        if !previous.isEmpty, replacement.count > previous.count, replacement.hasPrefix(previous),
           first.start <= lastToken.start + Self.seamJitterSeconds + Self.tolerance {
            pending.removeSubrange(last...)
        }
    }

    private static func startsWord(_ token: Token) -> Bool {
        token.text.hasPrefix(" ") || token.text.hasPrefix("▁")
    }

    private static func wordStarts(_ tokens: [Token]) -> [Int] {
        tokens.indices.filter { $0 == 0 || startsWord(tokens[$0]) }
    }

    private static func firstWord(_ tokens: [Token]) -> ArraySlice<Token> {
        let end = tokens.indices.dropFirst().first { startsWord(tokens[$0]) } ?? tokens.endIndex
        return tokens[..<end]
    }

    private static func text(_ tokens: ArraySlice<Token>) -> String {
        tokens.map(\.text).joined().replacingOccurrences(of: "▁", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func core(_ tokens: ArraySlice<Token>) -> String {
        text(tokens).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private static func line(_ tokens: ArraySlice<Token>) -> Line? {
        guard let first = tokens.first, let last = tokens.last else { return nil }
        let text = text(tokens)
        return text.isEmpty ? nil : (text: text, start: first.start, end: last.end)
    }
}

final class ParakeetFeedGate: @unchecked Sendable {
    struct Decode: Equatable, Sendable {
        let through: Double
        let seconds: Double
    }

    enum Wait: Equatable, Sendable {
        case room
        case closed
        case overdue(through: Double)
    }

    private let lock = NSLock()
    private let firstWindowSamples: Int
    private let windowStepSamples: Int
    private let roomSamples: Int
    private let overdueAfter: Duration
    private var fedSamples = 0
    private var completedWindows = 0
    private var decodeStart: Date?
    private var lastUpdate: Date?
    private var decode: Decode?
    private var waiter: CheckedContinuation<Wait, Never>?
    private var waiterTimer: Task<Void, Never>?
    private var waiterToken = 0
    private var blockedSince: ContinuousClock.Instant?
    private var closed = false
    private var draining = false

    init(config: SlidingWindowAsrConfig = .streaming, overdueAfter: Duration = .seconds(ParakeetLiveEngine.overdueWindowSeconds)) {
        self.overdueAfter = overdueAfter
        let rate = ParakeetLiveEngine.sampleRate
        firstWindowSamples = Int(((config.chunkSeconds + config.rightContextSeconds) * rate).rounded())
        windowStepSamples = Int((config.chunkSeconds * rate).rounded())
        roomSamples = Int(((config.hypothesisChunkSeconds + config.rightContextSeconds) * rate).rounded())
    }

    var fedSeconds: Double { lock.withLock { Double(fedSamples) / ParakeetLiveEngine.sampleRate } }

    var queuedSeconds: Double { lock.withLock { Double(queuedSamples) / ParakeetLiveEngine.sampleRate } }

    var hasRoom: Bool { lock.withLock { queuedSamples < roomSamples } }

    var lastDecode: Decode? { lock.withLock { decode } }

    private var nextTrigger: Int { firstWindowSamples + completedWindows * windowStepSamples }

    private var queuedSamples: Int { max(0, fedSamples - nextTrigger) }

    func add(_ samples: Int, at time: Date) {
        lock.withLock {
            let before = fedSamples
            fedSamples += samples
            if before < nextTrigger, fedSamples >= nextTrigger { decodeStart = time }
            if blockedSince == nil, queuedSamples >= roomSamples { blockedSince = .now }
        }
    }

    func windowCompleted(at time: Date) {
        let resumed: (CheckedContinuation<Wait, Never>, Task<Void, Never>?)? = lock.withLock {
            let started = decodeStart ?? lastUpdate ?? time
            let through = Double(min(nextTrigger, fedSamples)) / ParakeetLiveEngine.sampleRate
            decode = Decode(through: through, seconds: max(0, time.timeIntervalSince(started)))
            completedWindows += 1
            lastUpdate = time
            decodeStart = fedSamples >= nextTrigger ? time : nil
            blockedSince = queuedSamples >= roomSamples ? .now : nil
            guard queuedSamples < roomSamples else { return nil }
            return takeWaiter()
        }
        resumed?.1?.cancel()
        resumed?.0.resume(returning: .room)
    }

    func inputEnded(at time: Date) {
        lock.withLock {
            if decodeStart == nil { decodeStart = max(time, lastUpdate ?? time) }
        }
    }

    func finishInput() {
        let resumed = lock.withLock {
            draining = true
            return takeWaiter()
        }
        resumed?.1?.cancel()
        resumed?.0.resume(returning: .room)
    }

    func waitForRoom() async -> Wait {
        await withCheckedContinuation { continuation in
            let ready: Wait? = lock.withLock {
                if closed { return .closed }
                if draining || queuedSamples < roomSamples { return .room }
                let since = blockedSince ?? .now
                blockedSince = since
                if since + overdueAfter <= .now { return .overdue(through: dueSeconds) }
                waiterToken += 1
                let token = waiterToken
                let remaining = since + overdueAfter - .now
                waiter = continuation
                waiterTimer = Task.detached { [weak self] in
                    try? await Task.sleep(for: remaining)
                    self?.expire(token)
                }
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close() {
        let resumed = lock.withLock {
            closed = true
            return takeWaiter()
        }
        resumed?.1?.cancel()
        resumed?.0.resume(returning: .closed)
    }

    private var dueSeconds: Double { Double(nextTrigger) / ParakeetLiveEngine.sampleRate }

    private func takeWaiter() -> (CheckedContinuation<Wait, Never>, Task<Void, Never>?)? {
        guard let waiter else { return nil }
        let timer = waiterTimer
        self.waiter = nil
        waiterTimer = nil
        return (waiter, timer)
    }

    private func expire(_ token: Int) {
        let resumed: (CheckedContinuation<Wait, Never>, Double)? = lock.withLock {
            guard token == waiterToken, let waiter else { return nil }
            self.waiter = nil
            waiterTimer = nil
            return (waiter, dueSeconds)
        }
        guard let resumed else { return }
        resumed.0.resume(returning: .overdue(through: resumed.1))
    }
}

@MainActor
@Observable
final class ParakeetLiveEngine: LiveSpeechEngine {
    nonisolated static let sampleRate = 16_000.0
    nonisolated static let handoffSeconds = 10.0
    nonisolated static let overdueWindowSeconds = 9.0
    nonisolated static let libraryBufferSeconds = 26.0
    nonisolated static let computeUnitsLabel = "CPU and Neural Engine"

    nonisolated static var modelDirectory: URL {
        FluidEngineSupport.modelsDirectory.appendingPathComponent("parakeet-ultra", isDirectory: true)
    }

    nonisolated static var windowLabel: String {
        let config = SlidingWindowAsrConfig.streaming
        return String(format: "%.0f s + %.0f s + %.0f s",
                      config.chunkSeconds, config.leftContextSeconds, config.rightContextSeconds)
    }

    private struct Finalization: Sendable {
        let finished: Bool
        let error: LiveStopError?
    }

    let kind = LiveEngineKind.parakeet
    let displayName = "Parakeet Ultra"
    let finalizationTimeout: Duration = .seconds(30)
    var isLoaded: Bool { models != nil }

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
    @ObservationIgnored private var models: AsrModels?
    @ObservationIgnored private var manager: SlidingWindowAsrManager?
    @ObservationIgnored private var merger = WindowTranscriptMerger()
    @ObservationIgnored private var handoff: BoundedEngineHandoff?
    @ObservationIgnored private var gate: ParakeetFeedGate?
    @ObservationIgnored private var pump: StreamingInputPump?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var managerWork: Task<Void, Never>?
    @ObservationIgnored private var lastHandoffPeak: Double = 0
    @ObservationIgnored private var lastDecode: ParakeetFeedGate.Decode?
    @ObservationIgnored private var generation = 0
    private let energyLog = StreamingEnergyLog()

    func prepare(language: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparationInfo {
        let clock = ContinuousClock()
        let began = clock.now
        try Task.checkCancellation()
        cancelSession()
        let generation = self.generation
        let folder = Self.modelDirectory
        let firstLoad = !FileManager.default.fileExists(atPath: folder.path)
        if models == nil {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let loaded = try await AsrModels.downloadAndLoad(
                to: folder, version: .ultra, progressHandler: { progress($0.fractionCompleted) }
            )
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            models = loaded
        }
        return PreparationInfo(loadSeconds: FluidEngineSupport.seconds(clock.now - began), firstLoad: firstLoad,
                               modelBytesOnDisk: FluidEngineSupport.bytesOnDisk(folder), computeUnits: Self.computeUnitsLabel)
    }

    func startSession() throws {
        guard !isSessionActive, let models,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw LiveStopError(reason: .engineError, detail: "Parakeet was not prepared")
        }
        let generation = self.generation
        let handoff = BoundedEngineHandoff(capacitySeconds: Self.handoffSeconds, sampleRate: Self.sampleRate)
        let gate = ParakeetFeedGate()
        let manager = SlidingWindowAsrManager(config: .streaming)
        self.handoff = handoff
        self.gate = gate
        self.manager = manager
        merger = WindowTranscriptMerger()
        lastHandoffPeak = 0
        lastDecode = nil
        energyLog.resetSubmitted()
        inbox.begin(format: format)
        isSessionActive = true

        let previousWork = managerWork
        let setup = Task.detached { () async throws -> AsyncStream<SlidingWindowTranscriptionUpdate> in
            await previousWork?.value
            try await manager.loadModels(models)
            let updates = await manager.transcriptionUpdates
            try await manager.startStreaming(source: .microphone)
            return updates
        }
        reader = Task.detached { [weak self] in
            guard let updates = try? await setup.value else { return }
            for await update in updates {
                gate.windowCompleted(at: update.timestamp)
                await self?.absorb(update, generation: generation)
            }
        }
        consumer = Task.detached { [weak self] in
            do {
                _ = try await setup.value
            } catch {
                await self?.fail(error, generation: generation)
                return
            }
            feeding: while true {
                switch await gate.waitForRoom() {
                case .room: break
                case .closed: break feeding
                case .overdue(let through):
                    let detail = String(format: "Parakeet returned no result for the window ending at %.0f s", through)
                    await self?.fail(LiveStopError(reason: .engineError, detail: detail), generation: generation)
                    return
                }
                guard var samples = await handoff.next() else { break }
                let count = samples.count
                let buffer = Self.buffer(copying: samples)
                AudioMemory.discard(&samples)
                guard let buffer else {
                    await self?.fail(LiveStopError(reason: .engineError, detail: "Parakeet audio buffer"),
                                     generation: generation)
                    return
                }
                await manager.streamAudio(buffer)
                gate.add(count, at: Date())
            }
            gate.inputEnded(at: Date())
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
        guard isSessionActive, let manager, let handoff, let gate else {
            return LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
        }
        let generation = self.generation
        inbox.end()
        if let error = pump?.finish() { fail(error, generation: generation) }
        pump = nil
        inbox.discard()
        handoff.finish()
        gate.finishInput()
        let consumer = self.consumer
        let reader = self.reader
        let work = Task.detached { [weak self] () -> Finalization in
            await consumer?.value
            var outcome = Finalization(finished: false, error: nil)
            if await self?.failureMessage == nil {
                do {
                    _ = try await manager.finish()
                    outcome = Finalization(finished: true, error: nil)
                } catch {
                    outcome = Finalization(finished: false,
                                           error: LiveStopError(reason: .engineError, detail: error.localizedDescription))
                }
            }
            await manager.cancel()
            await reader?.value
            return outcome
        }
        let teardown = enqueueManagerWork {
            _ = await work.value
            await Self.release(manager)
        }
        let outcome = await FluidEngineSupport.value(of: work, within: finalizationTimeout)
        guard generation == self.generation else { return LiveSessionResult(lines: [], complete: false, stopReason: nil) }
        if let outcome {
            if let error = outcome.error { fail(error, generation: generation) }
            if outcome.finished, failureMessage == nil {
                if let line = merger.finish() { commit(line) }
                text.clearProvisional()
            }
        } else {
            fail(LiveStopError(reason: .finalizationTimedOut, detail: nil), generation: generation)
        }
        if let failureMessage { text.markIncomplete(failureMessage) }
        revision += 1
        lastHandoffPeak = handoff.peakHeldSeconds
        lastDecode = gate.lastDecode
        self.manager = nil
        self.handoff = nil
        self.consumer = nil
        self.reader = nil
        energyLog.clear()
        isSessionActive = false
        let result = LiveSessionResult(lines: confirmedLines, complete: failureMessage == nil, stopReason: stopReason)
        if outcome != nil {
            await teardown.value
            if self.gate === gate { self.gate = nil }
        }
        return result
    }

    func captureFailed(_ error: Error) { fail(error, generation: generation) }

    func cancelSession() {
        generation += 1
        inbox.discard()
        pump?.stop()
        handoff?.cancel()
        gate?.close()
        consumer?.cancel()
        if let manager {
            let consumer = consumer
            let reader = reader
            enqueueManagerWork {
                await consumer?.value
                await manager.cancel()
                await reader?.value
                await Self.release(manager)
            }
        }
        manager = nil
        pump = nil
        handoff = nil
        gate = nil
        consumer = nil
        reader = nil
        lastDecode = nil
        energyLog.clear()
        isSessionActive = false
        failureMessage = nil
        stopReason = nil
        text = StreamingTranscript()
        merger = WindowTranscriptMerger()
        revision += 1
    }

    func diagnostics() -> EngineDiagnostics {
        let handoffHeld = handoff?.heldSeconds ?? 0
        let fed = gate?.fedSeconds ?? 0
        let queued = gate?.queuedSeconds ?? 0
        let held = handoffHeld + min(fed, Self.libraryBufferSeconds) + queued
        let peak = handoff?.peakHeldSeconds ?? lastHandoffPeak
        let decodeRow: DiagnosticRow
        if let decode = gate?.lastDecode ?? lastDecode {
            decodeRow = DiagnosticRow(label: "Last window decode",
                                      value: String(format: "through %.1f s, took %.2f s", decode.through, decode.seconds),
                                      quality: .estimated)
        } else {
            decodeRow = DiagnosticRow(label: "Last window decode", value: "none yet", quality: .unknown)
        }
        return EngineDiagnostics(
            submittedThroughSeconds: energyLog.submittedThrough,
            latestProvisionalEnd: text.latestProvisionalEnd,
            latestFinalEnd: text.finalEnd > 0 ? text.finalEnd : nil,
            heldAudioSeconds: held,
            heldAudioQuality: .estimated,
            rows: [
                DiagnosticRow(label: "Handoff peak", value: String(format: "%.1f s", peak), quality: .measured),
                DiagnosticRow(label: "Fed to engine", value: String(format: "%.1f s", fed), quality: .measured),
                DiagnosticRow(label: "Queued in FluidAudio", value: String(format: "%.1f s", queued), quality: .estimated),
                DiagnosticRow(label: "Window", value: Self.windowLabel, quality: .measured),
                decodeRow
            ]
        )
    }

    func unload() async {
        cancelSession()
        guard models != nil else { return }
        models = nil
        await enqueueManagerWork {}.value
    }

    private func absorb(_ update: SlidingWindowTranscriptionUpdate, generation: Int) {
        guard generation == self.generation, isSessionActive, failureMessage == nil else { return }
        let tokens = update.tokenTimings.map {
            TokenLineSegmenter.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        if let line = merger.absorb(tokens, confirmed: update.isConfirmed) { commit(line) }
        text.clearProvisional()
        if let tail = merger.tail {
            text.update(text: tail.text, start: tail.start, end: tail.end, final: false, speaker: nil)
        }
        revision += 1
    }

    private func commit(_ line: TokenLineSegmenter.Line) {
        text.update(text: line.text, start: line.start, end: line.end, final: true,
                    speaker: speaker(start: line.start, end: line.end))
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation, failureMessage == nil else { return }
        let stop = error as? LiveStopError ?? LiveStopError(reason: .engineError, detail: error.localizedDescription)
        failureMessage = stop.localizedDescription
        stopReason = stop.reason
        inbox.discard()
        pump?.stop()
        handoff?.cancel()
        gate?.close()
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

    nonisolated private static func release(_ manager: SlidingWindowAsrManager) async {
        try? await manager.reset()
        await manager.cleanup()
    }

    nonisolated private static func buffer(copying samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
