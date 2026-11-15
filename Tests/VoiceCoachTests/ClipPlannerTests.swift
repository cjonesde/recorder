import XCTest
@testable import VoiceCoach

final class ClipPlannerTests: XCTestCase {
    private func drive(_ planner: inout ClipPlanner, until end: Double, gate: (Double) -> GateState) -> [ClipOutcome] {
        var outcomes: [ClipOutcome] = []
        var index = 0
        while true {
            let t = Double(index + 1) * 0.01
            if t > end + 1e-9 { break }
            outcomes += planner.observe(index: index, t: t, gate: gate(t))
            index += 1
        }
        return outcomes
    }

    func testClipKeptWhenTapQuietThroughout() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "pace-10000", detector: .pace, at: 10)
        let outcomes = drive(&planner, until: 13) { t in t.truncatingRemainder(dividingBy: 1) < 0.6 ? .own : .silence }
        XCTAssertEqual(outcomes, [.keep(ClipRequest(id: "pace-10000", detector: .pace, start: 4, end: 12))])
    }

    func testClipSkippedWhenThemSpeaksInWindow() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "pace-10000", detector: .pace, at: 10)
        let outcomes = drive(&planner, until: 13) { t in (7...7.5).contains(t) ? .them : .own }
        XCTAssertEqual(outcomes, [.skip(id: "pace-10000", reason: "other side audible")])
    }

    func testUnknownFramesSkipAsGap() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "pace-10000", detector: .pace, at: 10)
        let outcomes = drive(&planner, until: 13) { t in (11...11.2).contains(t) ? .unknown : .own }
        XCTAssertEqual(outcomes, [.skip(id: "pace-10000", reason: "gap")])
    }

    func testClipWindowClampedAtStart() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "so-2000", detector: .soStarts, at: 2)
        let outcomes = drive(&planner, until: 5) { _ in .own }
        XCTAssertEqual(outcomes, [.keep(ClipRequest(id: "so-2000", detector: .soStarts, start: 0, end: 4))])
    }

    func testPastWindowDecidedFromHistory() {
        var planner = ClipPlanner(tuning: .default)
        _ = drive(&planner, until: 12) { _ in .own }
        planner.register(id: "so-5000", detector: .soStarts, at: 5)
        let outcomes = planner.observe(index: 1200, t: 12.01, gate: .own)
        XCTAssertEqual(outcomes, [.keep(ClipRequest(id: "so-5000", detector: .soStarts, start: 0, end: 7))])
    }

    func testEngineEmitsClipForEveryTrigger() {
        var signal = Synth.noise(seconds: 1, db: -65, seed: 5)
        signal += speech(seconds: 14, syllables: 6)
        let run = feed(makeCoach { $0.baselineRate = 4 }, mic: signal, desktop: quietDesktop(seconds: 15.5))
        let trigger = run.triggers(.pace).first
        XCTAssertNotNil(trigger)
        XCTAssertEqual(run.clips.map(\.id), [trigger?.id].compactMap { $0 })
        XCTAssertEqual(run.events.filter { $0.kind == .clip }.first?.note, "planned")
    }

    func testFlushDecidesPendingClipsUpToTheLastFrame() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "pace-10000", detector: .pace, at: 10)
        XCTAssertEqual(drive(&planner, until: 11) { _ in .own }, [])
        XCTAssertEqual(planner.flush(at: 11), [.keep(ClipRequest(id: "pace-10000", detector: .pace, start: 4, end: 11))])
        XCTAssertEqual(planner.flush(at: 11), [])
    }

    func testFlushStillSkipsWhenTheOtherSideWasAudible() {
        var planner = ClipPlanner(tuning: .default)
        planner.register(id: "pace-10000", detector: .pace, at: 10)
        _ = drive(&planner, until: 11) { t in (10.2...10.4).contains(t) ? .them : .own }
        XCTAssertEqual(planner.flush(at: 11), [.skip(id: "pace-10000", reason: "other side audible")])
    }

    func testRegisteredWindowOverridesTheDefault() {
        var planner = ClipPlanner(tuning: .default)
        _ = drive(&planner, until: 20) { _ in .own }
        planner.register(id: "soStarts-3000", detector: .soStarts, at: 3, window: 2...15.5)
        let outcomes = planner.observe(index: 2000, t: 20.01, gate: .own)
        XCTAssertEqual(outcomes, [.keep(ClipRequest(id: "soStarts-3000", detector: .soStarts, start: 2, end: 15.5))])
    }

    func testLongLineArrivingLateIsStillInHistory() {
        var planner = ClipPlanner(tuning: .default)
        _ = drive(&planner, until: 30) { _ in .own }
        planner.register(id: "soStarts-10000", detector: .soStarts, at: 10, window: 9...25)
        let outcomes = planner.observe(index: 3000, t: 30.01, gate: .own)
        XCTAssertEqual(outcomes, [.keep(ClipRequest(id: "soStarts-10000", detector: .soStarts, start: 9, end: 25))])
    }

    func testEngineFlushResolvesClipsStillWaitingForTheirEnd() {
        let coach = makeCoach()
        var signal = Synth.noise(seconds: 1, db: -65, seed: 5)
        signal += speech(seconds: 8)
        feed(coach, mic: signal, desktop: quietDesktop(seconds: 9.5))
        let id = coach.fire(.pace, at: 8.5)
        XCTAssertTrue(coach.advance().clips.isEmpty)
        let output = coach.flush()
        let clip = try? XCTUnwrap(output.clips.first)
        XCTAssertEqual(output.clips.map(\.id), [id])
        XCTAssertEqual(clip?.start ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertGreaterThan(clip?.end ?? 0, 8.5)
        XCTAssertLessThanOrEqual(clip?.end ?? 99, 9.01)
        XCTAssertTrue(output.events.contains { $0.kind == .clip && $0.id == id && $0.note == "planned" })
    }
}
