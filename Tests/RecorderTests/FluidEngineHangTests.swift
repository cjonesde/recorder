import AVFoundation
import FluidAudio
import XCTest
@testable import Recorder

final class FakeNemotronManager: NemotronStreamingManager, @unchecked Sendable {
    private let lock = NSLock()
    private let hangsOnFinish: Bool
    private var resets = 0
    private var cleanups = 0

    init(hangsOnFinish: Bool) { self.hangsOnFinish = hangsOnFinish }

    var resetCalls: Int { lock.withLock { resets } }
    var cleanupCalls: Int { lock.withLock { cleanups } }

    func feed(_ samples: [Float]) async throws {}
    func currentTimings() async -> [TokenTiming] { [] }
    func recoveryCounts() async -> (rescues: Int, spans: Int) { (0, 0) }

    func finishTimings() async throws -> [TokenTiming] {
        if hangsOnFinish { try? await Task.sleep(for: .seconds(3_600)) }
        return []
    }

    func reset() async { lock.withLock { resets += 1 } }
    func cleanup() async { lock.withLock { cleanups += 1 } }
}

final class FakeParakeetSession: ParakeetStreamingSession, @unchecked Sendable {
    private let lock = NSLock()
    private let hangsOnFinish: Bool
    private var releases = 0

    init(hangsOnFinish: Bool) { self.hangsOnFinish = hangsOnFinish }

    var releaseCalls: Int { lock.withLock { releases } }

    func start() async throws -> AsyncStream<SlidingWindowTranscriptionUpdate> {
        AsyncStream { $0.finish() }
    }

    func stream(_ buffer: sending AVAudioPCMBuffer) async {}

    func finish() async throws {
        if hangsOnFinish { try? await Task.sleep(for: .seconds(3_600)) }
    }

    func cancel() async {}
    func release() async { lock.withLock { releases += 1 } }
}

final class Handout<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T]
    private var handed = 0

    init(_ items: [T]) { self.items = items }

    var count: Int { lock.withLock { handed } }

    func next() -> T {
        lock.withLock {
            handed += 1
            return items.removeFirst()
        }
    }
}

@MainActor
final class FluidEngineHangTests: XCTestCase {
    private let watchdog: Duration = .milliseconds(200)

    private func finishesWithin(_ limit: Duration, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        let work = Task { @MainActor () -> Bool in
            await body()
            return true
        }
        return await FluidEngineSupport.value(of: work, within: limit) ?? false
    }

    func testNemotronDropsAManagerThatHangsPastTheWatchdog() async throws {
        let hung = FakeNemotronManager(hangsOnFinish: true)
        let healthy = FakeNemotronManager(hangsOnFinish: false)
        let managers = Handout<FakeNemotronManager>([hung, healthy])
        let engine = NemotronLiveEngine(finalizationTimeout: watchdog, loader: { _, _, _ in managers.next() })

        _ = try await engine.prepare(language: "en-US", progress: { _ in })
        try engine.startSession()
        let began = ContinuousClock.now
        let first = await engine.endSession()
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        XCTAssertEqual(first.stopReason, .finalizationTimedOut)
        XCTAssertFalse(first.complete)
        XCTAssertFalse(engine.isLoaded)

        let unloaded = await finishesWithin(.seconds(2)) { await engine.unload() }
        XCTAssertTrue(unloaded, "unload waited on the hung manager")

        _ = try await engine.prepare(language: "en-US", progress: { _ in })
        XCTAssertEqual(managers.count, 2)
        try engine.startSession()
        let second = await engine.endSession()
        XCTAssertTrue(second.complete)
        XCTAssertNil(second.stopReason)
        XCTAssertEqual(healthy.resetCalls, 1)
        XCTAssertEqual(hung.resetCalls, 0)
    }

    func testParakeetDropsASessionThatHangsPastTheWatchdog() async throws {
        let hung = FakeParakeetSession(hangsOnFinish: true)
        let healthy = FakeParakeetSession(hangsOnFinish: false)
        let sessions = Handout<FakeParakeetSession>([hung, healthy])
        let loads = Handout<Int>([1, 2])
        let engine = ParakeetLiveEngine(finalizationTimeout: watchdog, loader: { _, _ in
            _ = loads.next()
            return { sessions.next() }
        })

        _ = try await engine.prepare(language: "en-US", progress: { _ in })
        try engine.startSession()
        let began = ContinuousClock.now
        let first = await engine.endSession()
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        XCTAssertEqual(first.stopReason, .finalizationTimedOut)
        XCTAssertFalse(first.complete)
        XCTAssertFalse(engine.isLoaded)

        let unloaded = await finishesWithin(.seconds(2)) { await engine.unload() }
        XCTAssertTrue(unloaded, "unload waited on the hung session")

        _ = try await engine.prepare(language: "en-US", progress: { _ in })
        XCTAssertEqual(loads.count, 2)
        try engine.startSession()
        let second = await engine.endSession()
        XCTAssertTrue(second.complete)
        XCTAssertNil(second.stopReason)
        XCTAssertEqual(healthy.releaseCalls, 1)
        XCTAssertEqual(hung.releaseCalls, 0)
    }

    func testSelectingAnotherEngineAfterANemotronHangReturnsPromptly() async throws {
        let engine = LocalTranscriptionEngine(factory: { [watchdog] kind in
            switch kind {
            case .nemotron:
                return NemotronLiveEngine(finalizationTimeout: watchdog, loader: { _, _, _ in FakeNemotronManager(hangsOnFinish: true) })
            default:
                return FakeLiveEngine(kind: kind)
            }
        })
        await engine.select(.nemotron)
        try await engine.beginSession(language: "en-US")
        let result = await engine.endSession()
        XCTAssertEqual(result.stopReason, .finalizationTimedOut)

        let selected = await finishesWithin(.seconds(2)) { await engine.select(.parakeet) }
        XCTAssertTrue(selected, "select waited on the hung manager")
        XCTAssertEqual(engine.engine.kind, .parakeet)
        try await engine.beginSession(language: "en-US")
        XCTAssertTrue(engine.isSessionActive)
    }

    func testSelectingAnotherEngineAfterAParakeetHangReturnsPromptly() async throws {
        let engine = LocalTranscriptionEngine(factory: { [watchdog] kind in
            switch kind {
            case .parakeet:
                return ParakeetLiveEngine(finalizationTimeout: watchdog, loader: { _, _ in { FakeParakeetSession(hangsOnFinish: true) } })
            default:
                return FakeLiveEngine(kind: kind)
            }
        })
        await engine.select(.parakeet)
        try await engine.beginSession(language: "en-US")
        let result = await engine.endSession()
        XCTAssertEqual(result.stopReason, .finalizationTimedOut)

        let selected = await finishesWithin(.seconds(2)) { await engine.select(.nemotron) }
        XCTAssertTrue(selected, "select waited on the hung session")
        XCTAssertEqual(engine.engine.kind, .nemotron)
    }
}
