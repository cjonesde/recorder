import XCTest
@testable import Recorder

final class LiveEngineKindTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "liveEngine")
        UserDefaults.standard.removeObject(forKey: "showDebugInfo")
        super.tearDown()
    }

    func testLabelsNameEachEngine() {
        XCTAssertEqual(LiveEngineKind.apple.label, "Apple")
        XCTAssertEqual(LiveEngineKind.nemotron.label, "Nemotron")
        XCTAssertEqual(LiveEngineKind.parakeet.label, "Parakeet")
    }

    func testOnlyAppleUsesTheLanguagePicker() {
        for kind in LiveEngineKind.allCases {
            XCTAssertEqual(kind.usesLanguagePicker, kind == .apple, "\(kind)")
        }
    }

    func testDefaultEngineIsApple() {
        XCTAssertEqual(LiveEngineKind.default, .apple)
    }

    func testUnknownStoredEngineFallsBackToApple() {
        UserDefaults.standard.set("whisper", forKey: "liveEngine")
        XCTAssertEqual(Preferences.liveEngine, .apple)
    }

    func testStoredEngineRoundTrips() {
        Preferences.liveEngine = .parakeet
        XCTAssertEqual(Preferences.liveEngine, .parakeet)
    }

    func testDebugInfoIsOffByDefaultAndRoundTrips() {
        XCTAssertFalse(Preferences.showDebugInfo)
        Preferences.showDebugInfo = true
        XCTAssertTrue(Preferences.showDebugInfo)
    }

    @MainActor
    func testModelPersistsEngineAndDebugChoices() {
        let model = RecorderModel()
        model.liveEngine = .nemotron
        model.showDebugInfo = true
        XCTAssertEqual(Preferences.liveEngine, .nemotron)
        XCTAssertTrue(Preferences.showDebugInfo)
    }

    @MainActor
    func testEngineCannotChangeWhileRecordingOrFinishing() {
        let model = RecorderModel()
        for state in [RecorderState.preparing, .recording, .paused, .finishing] {
            model.state = state
            XCTAssertFalse(model.canChangeLiveEngine, "\(state)")
        }
        model.state = .idle
        XCTAssertTrue(model.canChangeLiveEngine)
    }
}
