import CoreAudio
import XCTest
@testable import Recorder

final class TapBufferSelectionTests: XCTestCase {

    private var storage: [UnsafeMutablePointer<Float>] = []

    override func tearDown() {
        storage.forEach { $0.deallocate() }
        storage = []
        super.tearDown()
    }

    private func list(_ channels: [UInt32]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (index, count) in channels.enumerated() {
            let samples = Int(count) * 4
            let data = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            data.initialize(repeating: Float(index), count: samples)
            storage.append(data)
            list[index] = AudioBuffer(mNumberChannels: count, mDataByteSize: UInt32(samples * MemoryLayout<Float>.size), mData: data)
        }
        return list
    }

    private func firstSample(_ buffer: AudioBuffer) -> Float? {
        buffer.mData?.assumingMemoryBound(to: Float.self).pointee
    }

    func testPicksTheTapStreamAfterTheOutputDevicesOwnInput() throws {
        let input = list([2, 2])
        let view = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(input.unsafeMutablePointer); free(view.unsafeMutablePointer) }

        let selected = try XCTUnwrap(SystemAudioTap.selectTapBuffers(from: input.unsafePointer, into: view))
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: selected))

        XCTAssertEqual(buffers.count, 1)
        XCTAssertEqual(buffers.first.flatMap(firstSample), 1)
    }

    func testPicksEveryPlaneOfADeinterleavedTapAfterTheDeviceInput() throws {
        let input = list([1, 1, 1])
        let view = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(input.unsafeMutablePointer); free(view.unsafeMutablePointer) }

        let selected = try XCTUnwrap(SystemAudioTap.selectTapBuffers(from: input.unsafePointer, into: view))
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: selected))

        XCTAssertEqual(buffers.map(firstSample), [1, 2])
    }

    func testPassesATapOnlyListThroughUntouched() {
        let input = list([2])
        let view = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(input.unsafeMutablePointer); free(view.unsafeMutablePointer) }

        XCTAssertEqual(SystemAudioTap.selectTapBuffers(from: input.unsafePointer, into: view), input.unsafePointer)
    }

    func testRejectsAListWithFewerBuffersThanTheTapNeeds() {
        let input = list([1])
        let view = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(input.unsafeMutablePointer); free(view.unsafeMutablePointer) }

        XCTAssertNil(SystemAudioTap.selectTapBuffers(from: input.unsafePointer, into: view))
    }
}
