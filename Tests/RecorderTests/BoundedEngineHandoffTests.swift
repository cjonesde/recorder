import AVFoundation
import CoreMedia
import XCTest
@testable import Recorder

private func chunk(seconds: Double, value: Float = 0, rate: Double = 16000) -> StreamingAudioInput.Chunk {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let count = Int((seconds * rate).rounded())
    let buffer = try! ErasingPCMBuffer.make(format: format, count: count)
    for i in 0..<count { buffer.floatChannelData![0][i] = value }
    return StreamingAudioInput.Chunk(buffer: buffer, startTime: .zero, duration: seconds, desktopEnergy: 0, micEnergy: 0)
}

final class BoundedEngineHandoffTests: XCTestCase {
    func testRejectsMoreThanTenSecondsAndErasesBacklog() throws {
        let handoff = BoundedEngineHandoff(capacitySeconds: 10, sampleRate: 16000)
        for _ in 0..<100 { try handoff.push(chunk(seconds: 0.1)) }
        XCTAssertEqual(handoff.heldSeconds, 10, accuracy: 0.001)
        XCTAssertThrowsError(try handoff.push(chunk(seconds: 0.1))) {
            XCTAssertEqual(($0 as? LiveStopError)?.reason, .engineFellBehind)
        }
        XCTAssertEqual(handoff.heldSeconds, 0)
        XCTAssertEqual(handoff.peakHeldSeconds, 10, accuracy: 0.001)
    }

    func testNextReturnsInOrderAndFinishEndsTheStream() async throws {
        let handoff = BoundedEngineHandoff(capacitySeconds: 10, sampleRate: 16000)
        try handoff.push(chunk(seconds: 0.1, value: 0.1))
        try handoff.push(chunk(seconds: 0.1, value: 0.2))
        handoff.finish()
        let first = await handoff.next()
        let second = await handoff.next()
        XCTAssertEqual(first?.first ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(second?.first ?? 0, 0.2, accuracy: 0.0001)
        let end = await handoff.next()
        XCTAssertNil(end)
        XCTAssertEqual(handoff.heldSeconds, 0)
    }

    func testWaitingNextIsWokenByPush() async throws {
        let handoff = BoundedEngineHandoff(sampleRate: 16000)
        let waiter = Task { await handoff.next() }
        try await Task.sleep(for: .milliseconds(50))
        try handoff.push(chunk(seconds: 0.1, value: 0.3))
        let samples = await waiter.value
        XCTAssertEqual(samples?.first ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(handoff.heldSeconds, 0)
    }

    func testCancelWakesWaitingNextWithNilExactlyOnce() async throws {
        let handoff = BoundedEngineHandoff(sampleRate: 16000)
        let waiter = Task { await handoff.next() }
        try await Task.sleep(for: .milliseconds(50))
        handoff.cancel()
        handoff.cancel()
        handoff.finish()
        let samples = await waiter.value
        XCTAssertNil(samples)
    }

    func testCancelErasesHeldAudioAndRejectsLaterPushes() async throws {
        let handoff = BoundedEngineHandoff(sampleRate: 16000)
        try handoff.push(chunk(seconds: 0.1, value: 0.5))
        handoff.cancel()
        XCTAssertEqual(handoff.heldSeconds, 0)
        let samples = await handoff.next()
        XCTAssertNil(samples)
        try handoff.push(chunk(seconds: 0.1, value: 0.5))
        XCTAssertEqual(handoff.heldSeconds, 0)
    }

    func testFinishWakesWaitingNextWithNil() async throws {
        let handoff = BoundedEngineHandoff(sampleRate: 16000)
        let waiter = Task { await handoff.next() }
        try await Task.sleep(for: .milliseconds(50))
        handoff.finish()
        let samples = await waiter.value
        XCTAssertNil(samples)
    }

    func testPeakTracksMaximumHeld() async throws {
        let handoff = BoundedEngineHandoff(sampleRate: 16000)
        try handoff.push(chunk(seconds: 0.5))
        try handoff.push(chunk(seconds: 0.5))
        _ = await handoff.next()
        XCTAssertEqual(handoff.heldSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(handoff.peakHeldSeconds, 1.0, accuracy: 0.001)
    }
}
