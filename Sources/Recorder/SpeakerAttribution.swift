import Foundation

final class StreamingEnergyLog: @unchecked Sendable {
    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let desktop: Float
        let mic: Float
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var submitted: TimeInterval = 0

    func record(_ chunk: StreamingAudioInput.Chunk) {
        lock.withLock {
            submitted = max(submitted, chunk.start + chunk.duration)
            entries.append(Entry(start: chunk.start, end: chunk.start + chunk.duration,
                                 desktop: chunk.desktopEnergy, mic: chunk.micEnergy))
            entries.removeAll { $0.end < chunk.start - 60 }
        }
    }

    func clear() { lock.withLock { entries = [] } }

    var submittedThrough: TimeInterval { lock.withLock { submitted } }

    func resetSubmitted() { lock.withLock { submitted = 0 } }

    func sums(start: TimeInterval, end: TimeInterval) -> (desktop: Float, mic: Float)? {
        lock.withLock {
            guard let first = entries.first, start >= first.start - 0.1 else { return nil }
            var desktop: Float = 0, mic: Float = 0
            for entry in entries where entry.start < end && entry.end > start {
                desktop += entry.desktop
                mic += entry.mic
            }
            return (desktop, mic)
        }
    }

    func speaker(start: TimeInterval, end: TimeInterval) -> String? {
        guard let (desktop, mic) = sums(start: start, end: end) else { return nil }
        guard max(desktop, mic) > 0.0001 else { return nil }
        if mic > desktop * 4 { return "You" }
        if desktop > mic * 4 { return "Them" }
        return nil
    }
}
