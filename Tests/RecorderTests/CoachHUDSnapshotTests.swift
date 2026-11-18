import AppKit
import SwiftUI
import XCTest
@testable import Recorder
import VoiceCoach

final class CoachHUDSnapshotTests: XCTestCase {
    @MainActor
    func testRenderHUDStates() throws {
        guard let path = ProcessInfo.processInfo.environment["RECORDER_COACH_SNAPSHOT"] else {
            throw XCTSkip("set RECORDER_COACH_SNAPSHOT to a folder to render the HUD")
        }
        let target = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var idle = CoachHUDState.idle(.oneOnOne)
        idle.gate = .silence
        var speaking = idle
        speaking.gate = .own
        speaking.energy = 0.35
        var fast = speaking
        fast.energy = 0.9
        fast.litCues = [.pace]
        var full = fast
        full.gate = .them
        full.litCues = [.pace, .soStarts, .risingEndings, .trailingEndings]
        full.talkShare = 0.7
        full.talkShareHigh = true
        let states: [(String, CoachHUDState, Bool)] = [("idle", idle, false), ("speaking", speaking, false), ("fast", fast, false), ("all-cues", full, false), ("paused", speaking, true)]
        for (name, state, paused) in states {
            let renderer = ImageRenderer(content: CoachHUDContent(state: state, paused: paused).padding(6).background(Color(white: 0.85)))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: target.appendingPathComponent("hud-\(name).png"))
        }
    }

    @MainActor
    func testRenderChecksList() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RECORDER_COACH_SNAPSHOT"] else {
            throw XCTSkip("set RECORDER_COACH_SNAPSHOT to a folder, and optionally RECORDER_COACH_LOG and RECORDER_COACH_AT, to render the checks list")
        }
        var monitor = CoachMonitor()
        var state = CoachHUDState.idle(.oneOnOne)
        if let log = environment["RECORDER_COACH_LOG"] {
            let until = environment["RECORDER_COACH_AT"].flatMap(Double.init) ?? .infinity
            let decoder = JSONDecoder()
            let events = try String(contentsOfFile: log, encoding: .utf8)
                .split(separator: "\n")
                .compactMap { try? decoder.decode(CoachEvent.self, from: Data($0.utf8)) }
                .filter { $0.t <= until }
            _ = monitor.absorb(events)
            state.gate = .own
            state.energy = events.last { $0.detector == .energy }?.values["energy"]
        }
        let content = VStack(spacing: CoachHUDPanel.checksGap) {
            CoachHUDContent(state: state, paused: false)
            CoachChecksList(lines: CoachCheckLine.lines(monitor: monitor, preset: .oneOnOne, promoted: [.pace]))
        }
        .frame(width: CoachHUDPanel.expandedSize.width, height: CoachHUDPanel.expandedSize.height, alignment: .top)
        .padding(10)
        .background(Color(white: 0.85))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let target = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try png.write(to: target.appendingPathComponent("hud-checks.png"))
    }
}
