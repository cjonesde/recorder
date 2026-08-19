import XCTest
@testable import Recorder

final class DownmixTests: XCTestCase {

    private func run(
        planes: [UnsafeMutablePointer<Float>],
        channelCount: Int,
        sampleStride: Int,
        frameOffset: Int,
        frames: Int
    ) -> [Float] {
        var out = [Float](repeating: .nan, count: frames)
        planes.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                SystemAudioTap.downmixChunk(
                    channelData: p.baseAddress!,
                    channelCount: channelCount,
                    sampleStride: sampleStride,
                    frameOffset: frameOffset,
                    frames: frames,
                    into: o.baseAddress!
                )
            }
        }
        return out
    }

    func testInterleavedStereo() {
        let frames = 8
        var data = [Float]()
        for i in 0..<frames {
            data.append(Float(i))
            data.append(Float(i) + 100)
        }
        let expected = (0..<frames).map { Float($0) + 50 }
        data.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            let out = run(
                planes: [base, base + 1],
                channelCount: 2,
                sampleStride: 2,
                frameOffset: 0,
                frames: frames
            )
            XCTAssertEqual(out, expected)
        }
    }

    func testInterleavedStereoWithFrameOffset() {
        let frames = 6
        let offset = 2
        var data = [Float]()
        for i in 0..<(frames + offset) {
            data.append(Float(i) * 2)
            data.append(Float(i) * 2 + 10)
        }
        let expected = (offset..<(frames + offset)).map { Float($0) * 2 + 5 }
        data.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            let out = run(
                planes: [base, base + 1],
                channelCount: 2,
                sampleStride: 2,
                frameOffset: offset,
                frames: frames
            )
            XCTAssertEqual(out, expected)
        }
    }

    func testDeinterleavedStereo() {
        let frames = 8
        var left = (0..<frames).map { Float($0) }
        var right = (0..<frames).map { Float($0) + 100 }
        let expected = (0..<frames).map { Float($0) + 50 }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let out = run(
                    planes: [l.baseAddress!, r.baseAddress!],
                    channelCount: 2,
                    sampleStride: 1,
                    frameOffset: 0,
                    frames: frames
                )
                XCTAssertEqual(out, expected)
            }
        }
    }
}
