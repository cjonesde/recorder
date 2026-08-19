import XCTest
@testable import Recorder

/// `SampleInbox.drain` pairs the two captures by sample index, so when one channel
/// delivers fewer samples than its declared rate promises, the other runs away and
/// the skew guard inserts silence to keep the indices aligned.
///
/// That padding is a symptom of a broken capture, never normal operation. It hid the
/// desktop-tap sample-rate bug by making a starved channel look merely quiet, so it
/// is now counted and logged.
final class SampleInboxSkewTests: XCTestCase {

    private func ingest(_ inbox: SampleInbox, _ source: SampleInbox.Source, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            inbox.ingest(source, buf.baseAddress!, count: buf.count, rate: SampleInbox.targetRate)
        }
    }

    func testNoPaddingWhenBothChannelsKeepUp() {
        let inbox = SampleInbox()
        inbox.begin()
        defer { inbox.end() }

        let oneSecond = [Float](repeating: 0.1, count: Int(SampleInbox.targetRate))
        ingest(inbox, .desktop, oneSecond)
        ingest(inbox, .mic, oneSecond)
        let drained = inbox.drain()

        XCTAssertFalse(drained.isEmpty)
        XCTAssertEqual(inbox.paddedSamples(for: .desktop), 0)
        XCTAssertEqual(inbox.paddedSamples(for: .mic), 0)
    }

    func testStarvedDesktopChannelIsCountedAsPadding() {
        let inbox = SampleInbox()
        inbox.begin()
        defer { inbox.end() }

        // Exactly the shape of the bug: the mic delivers two seconds while the desktop
        // tap, told the wrong rate, delivers a fraction of it.
        let rate = Int(SampleInbox.targetRate)
        ingest(inbox, .mic, [Float](repeating: 0.2, count: rate * 2))
        ingest(inbox, .desktop, [Float](repeating: 0.2, count: rate / 10))
        _ = inbox.drain()

        XCTAssertGreaterThan(
            inbox.paddedSamples(for: .desktop), 0,
            "a starved desktop channel must be recorded, not silently padded"
        )
        XCTAssertEqual(inbox.paddedSamples(for: .mic), 0)
    }

    func testPaddingCountersResetOnNewSession() {
        let inbox = SampleInbox()
        inbox.begin()
        let rate = Int(SampleInbox.targetRate)
        ingest(inbox, .mic, [Float](repeating: 0.2, count: rate * 2))
        ingest(inbox, .desktop, [Float](repeating: 0.2, count: rate / 10))
        _ = inbox.drain()
        XCTAssertGreaterThan(inbox.paddedSamples(for: .desktop), 0)
        inbox.end()

        inbox.begin()
        defer { inbox.end() }
        XCTAssertEqual(inbox.paddedSamples(for: .desktop), 0)
        XCTAssertEqual(inbox.paddedSamples(for: .mic), 0)
    }
}
