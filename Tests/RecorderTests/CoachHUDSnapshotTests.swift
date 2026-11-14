import AppKit
import SwiftUI
import XCTest
@testable import Recorder
import VoiceCoach

final class CoachHUDSnapshotTests: XCTestCase {
    @MainActor
    func testRenderHUDStates() throws {
        let target = try XCTUnwrap(ProcessInfo.processInfo.environment["RECORDER_COACH_SNAPSHOT"].map { URL(fileURLWithPath: $0) }, "set RECORDER_COACH_SNAPSHOT to a folder to render the HUD")
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
}
