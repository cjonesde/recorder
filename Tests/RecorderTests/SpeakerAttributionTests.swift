import AVFoundation
import CoreMedia
import XCTest
@testable import Recorder

private func energyChunk(start: TimeInterval, desktop: Float, mic: Float, duration: TimeInterval = 0.1) -> StreamingAudioInput.Chunk {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let buffer = try! ErasingPCMBuffer.make(format: format, count: 1600)
    return StreamingAudioInput.Chunk(buffer: buffer, startTime: CMTime(seconds: start, preferredTimescale: 16000),
                                     duration: duration, desktopEnergy: desktop, micEnergy: mic)
}

final class SpeakerAttributionTests: XCTestCase {
    func testLineConfirmedTwentyFiveSecondsLateStillGetsALabel() {
        let log = StreamingEnergyLog()
        for i in 0..<400 { log.record(energyChunk(start: Double(i) * 0.1, desktop: 0, mic: 1)) }
        XCTAssertEqual(log.speaker(start: 15, end: 17), "You")
    }

    func testDesktopDominanceIsThem() {
        let log = StreamingEnergyLog()
        log.record(energyChunk(start: 0, desktop: 5, mic: 1))
        XCTAssertEqual(log.speaker(start: 0, end: 0.1), "Them")
    }

    func testAmbiguousAndSilentAreNil() {
        let log = StreamingEnergyLog()
        log.record(energyChunk(start: 0, desktop: 3, mic: 1))
        log.record(energyChunk(start: 0.1, desktop: 0, mic: 0))
        XCTAssertNil(log.speaker(start: 0, end: 0.1))
        XCTAssertNil(log.speaker(start: 0.1, end: 0.2))
    }

    func testUnknownRangeIsNil() {
        let log = StreamingEnergyLog()
        XCTAssertNil(log.speaker(start: 0, end: 1))
    }
}
