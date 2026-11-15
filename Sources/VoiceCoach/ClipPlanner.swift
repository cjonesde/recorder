import Foundation

enum ClipOutcome: Equatable {
    case keep(ClipRequest)
    case skip(id: String, reason: String)
}

struct ClipPlanner {
    static let historySeconds = 32.0

    let tuning: CoachTuning
    private var gates: [GateState] = []
    private var firstIndex = 0
    private var pending: [ClipRequest] = []

    init(tuning: CoachTuning) {
        self.tuning = tuning
    }

    mutating func register(id: String, detector: DetectorID, at t: Double, window: ClosedRange<Double>? = nil) {
        let span = window ?? max(0, t - tuning.clipBefore)...(t + tuning.clipAfter)
        pending.append(ClipRequest(id: id, detector: detector, start: span.lowerBound, end: span.upperBound))
    }

    mutating func flush(at t: Double) -> [ClipOutcome] {
        let due = pending
        pending.removeAll()
        return due.map { request in
            guard request.end > t else { return decide(request) }
            guard t > request.start else { return .skip(id: request.id, reason: "session ended") }
            return decide(ClipRequest(id: request.id, detector: request.detector, start: request.start, end: t))
        }
    }

    mutating func observe(index: Int, t: Double, gate: GateState) -> [ClipOutcome] {
        if gates.isEmpty { firstIndex = index }
        gates.append(gate)
        let capacity = tuning.frames(Self.historySeconds)
        if gates.count > capacity + capacity / 4 {
            let drop = gates.count - capacity
            gates.removeFirst(drop)
            firstIndex += drop
        }
        let due = pending.filter { t >= $0.end - 1e-9 }
        guard !due.isEmpty else { return [] }
        pending.removeAll { t >= $0.end - 1e-9 }
        return due.map(decide)
    }

    private func decide(_ request: ClipRequest) -> ClipOutcome {
        let first = Int((request.start / tuning.frameSeconds).rounded()) - 1
        let last = Int((request.end / tuning.frameSeconds).rounded()) - 1
        let from = max(first, 0)
        guard from >= firstIndex, last < firstIndex + gates.count else {
            return .skip(id: request.id, reason: "gap")
        }
        let window = gates[(from - firstIndex)...(last - firstIndex)]
        if window.contains(where: { $0 == .them || $0 == .overlap }) {
            return .skip(id: request.id, reason: "other side audible")
        }
        if window.contains(.unknown) {
            return .skip(id: request.id, reason: "gap")
        }
        return .keep(request)
    }
}
