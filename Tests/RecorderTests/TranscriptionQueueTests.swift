import XCTest
@testable import Recorder

@MainActor
private final class ScriptedJobs {
    struct Job: Identifiable, Equatable { let id: String }

    private(set) var started: [String] = []
    private(set) var interrupted: [String] = []
    private var released: Set<String> = []
    var ignoresCancellation = false

    func perform(_ job: Job) async -> QueuedJobOutcome {
        started.append(job.id)
        while !released.contains(job.id) {
            if Task.isCancelled && !ignoresCancellation {
                interrupted.append(job.id)
                return .interrupted
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        released.remove(job.id)
        return .finished
    }

    func release(_ id: String) { released.insert(id) }
}

@MainActor
final class TranscriptionQueueTests: XCTestCase {

    private typealias Job = ScriptedJobs.Job

    private func makeQueue(_ script: ScriptedJobs) -> TranscriptionQueue<Job> {
        let queue = TranscriptionQueue<Job>()
        queue.perform = { await script.perform($0) }
        return queue
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    func testJobsRunOneAtATimeInTheOrderTheyArrived() async throws {
        let script = ScriptedJobs()
        let queue = makeQueue(script)
        queue.enqueue(Job(id: "a"))
        queue.enqueue(Job(id: "b"))
        try await waitUntil { script.started == ["a"] }
        XCTAssertEqual(queue.running?.id, "a")
        XCTAssertEqual(queue.waiting.map(\.id), ["b"])

        script.release("a")
        try await waitUntil { script.started == ["a", "b"] }
        script.release("b")
        try await waitUntil { queue.count == 0 }
    }

    func testHoldInterruptsTheRunningJobAndPutsItBackFirst() async throws {
        let script = ScriptedJobs()
        let queue = makeQueue(script)
        queue.enqueue(Job(id: "a"))
        queue.enqueue(Job(id: "b"))
        try await waitUntil { script.started == ["a"] }

        queue.hold()
        try await waitUntil { queue.running == nil }
        XCTAssertEqual(script.interrupted, ["a"])
        XCTAssertEqual(queue.waiting.map(\.id), ["a", "b"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.started, ["a"], "a held queue started another job")

        queue.release()
        try await waitUntil { script.started == ["a", "a"] }
    }

    func testAHeldQueueStartsNothingUntilReleased() async throws {
        let script = ScriptedJobs()
        let queue = makeQueue(script)
        queue.hold()
        queue.enqueue(Job(id: "a"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.started, [])
        XCTAssertEqual(queue.count, 1)

        queue.release()
        try await waitUntil { script.started == ["a"] }
    }

    func testAJobThatFinishesDespiteTheHoldIsNotRunAgain() async throws {
        let script = ScriptedJobs()
        script.ignoresCancellation = true
        let queue = makeQueue(script)
        queue.enqueue(Job(id: "a"))
        try await waitUntil { script.started == ["a"] }

        queue.hold()
        script.release("a")
        try await waitUntil { queue.running == nil }
        XCTAssertEqual(queue.count, 0)

        queue.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.started, ["a"])
    }

    func testAJobAlreadyQueuedOrRunningIsNotAddedTwice() async throws {
        let script = ScriptedJobs()
        let queue = makeQueue(script)
        queue.enqueue(Job(id: "a"))
        queue.enqueue(Job(id: "b"))
        try await waitUntil { script.started == ["a"] }

        queue.enqueue(Job(id: "a"))
        queue.enqueue(Job(id: "b"))
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(queue.contains("a"))
        XCTAssertTrue(queue.contains("b"))
        XCTAssertFalse(queue.contains("c"))
    }

    func testSummaryNamesTheRunningRecordingAndCountsTheRest() {
        XCTAssertNil(TranscriptionQueueSummary.text(running: nil, waiting: 0, recording: false))
        XCTAssertEqual(
            TranscriptionQueueSummary.text(running: "Weekly sync", waiting: 0, recording: false),
            "Transcribing “Weekly sync” locally"
        )
        XCTAssertEqual(
            TranscriptionQueueSummary.text(running: "Weekly sync", waiting: 2, recording: false),
            "Transcribing “Weekly sync” locally · 2 waiting"
        )
    }

    func testSummaryWhileRecordingSaysTheWorkWaits() {
        XCTAssertEqual(
            TranscriptionQueueSummary.text(running: nil, waiting: 1, recording: true),
            "1 local transcription waits until this recording ends"
        )
        XCTAssertEqual(
            TranscriptionQueueSummary.text(running: nil, waiting: 3, recording: true),
            "3 local transcriptions wait until this recording ends"
        )
        XCTAssertNil(TranscriptionQueueSummary.text(running: nil, waiting: 0, recording: true))
    }
}
