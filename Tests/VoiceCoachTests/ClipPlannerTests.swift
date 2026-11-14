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
}
