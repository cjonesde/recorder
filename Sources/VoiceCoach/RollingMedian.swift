import Foundation

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

struct RollingWindow {
    let capacity: Int
    private var storage: [Double] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    var count: Int { storage.count }

    var values: [Double] { Array(storage[head...] + storage[..<head]) }

    var median: Double? { VoiceCoach.median(storage) }

    var mean: Double? { storage.isEmpty ? nil : storage.reduce(0, +) / Double(storage.count) }
}
