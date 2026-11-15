import Foundation

struct VoiceConfirmer {
    static let minimumVoicedFrames = 3
    static let maxHoldFrames = 50

    private var held: [FrameAnalysis] = []
    private var heldVoiced = 0
    private var runConfirmed = false

    mutating func push(_ frame: FrameAnalysis) -> [FrameAnalysis] {
        guard frame.gate == .own else {
            runConfirmed = false
            return release(held.count) + [frame]
        }
        if runConfirmed { return [frame] }
        held.append(frame)
        if frame.f0 > 0 { heldVoiced += 1 }
        if heldVoiced >= Self.minimumVoicedFrames {
            runConfirmed = true
            let out = held
            held.removeAll(keepingCapacity: true)
            heldVoiced = 0
            return out
        }
        return release(held.count - Self.maxHoldFrames)
    }

    private mutating func release(_ count: Int) -> [FrameAnalysis] {
        guard count > 0 else { return [] }
        let out = held[..<count].map(Self.unconfirmed)
        heldVoiced -= held[..<count].filter { $0.f0 > 0 }.count
        held.removeFirst(count)
        return out
    }

    private static func unconfirmed(_ frame: FrameAnalysis) -> FrameAnalysis {
        FrameAnalysis(index: frame.index, t: frame.t, micDB: frame.micDB, gate: .silence, f0: 0, floorDB: frame.floorDB)
    }
}
