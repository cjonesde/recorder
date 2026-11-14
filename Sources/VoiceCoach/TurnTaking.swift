import Foundation

struct TurnTaking {
    static let windowSeconds = 300.0
    static let minimumSeconds = 30.0
    static let overlapRun = 0.3
    static let themBefore = 0.5
    static let yieldWindow = 1.0
    static let talkThroughShare = 0.2

    let tuning: CoachTuning
    private var window: [GateState] = []
    private var windowHead = 0
    private var own = 0
    private var them = 0
    private var overlap = 0
    private var themRun = 0
    private var overlapRunFrames = 0
    private var overlapStartedAfterThem = false
    private var overlapCounted = false
    private var previous: GateState = .silence
    private var pendingYield: (from: Double, until: Double, overlapFrames: Int)?
    private(set) var interruptedThem = 0
    private(set) var wasInterrupted = 0

    init(tuning: CoachTuning) {
        self.tuning = tuning
    }

    var talkShare: Double? {
        let total = own + them + overlap
        guard Double(total) * tuning.frameSeconds >= Self.minimumSeconds else { return nil }
        return Double(own + overlap) / Double(total)
    }

    mutating func observe(t: Double, gate: GateState) {
        window.append(gate)
        count(gate, by: 1)
        if window.count - windowHead > tuning.frames(Self.windowSeconds) {
            count(window[windowHead], by: -1)
            windowHead += 1
        }
        if windowHead > 8192 {
            window.removeFirst(windowHead)
            windowHead = 0
        }
        trackInterruptions(t: t, gate: gate)
        previous = gate
    }

    private mutating func count(_ gate: GateState, by delta: Int) {
        switch gate {
        case .own: own += delta
        case .them: them += delta
        case .overlap: overlap += delta
        case .silence, .unknown: break
        }
    }

    private mutating func trackInterruptions(t: Double, gate: GateState) {
        if gate == .overlap {
            if overlapRunFrames == 0 {
                overlapStartedAfterThem = Double(themRun) * tuning.frameSeconds >= Self.themBefore
                overlapCounted = false
            }
            overlapRunFrames += 1
            if overlapStartedAfterThem, !overlapCounted, Double(overlapRunFrames) * tuning.frameSeconds >= Self.overlapRun {
                interruptedThem += 1
                overlapCounted = true
            }
        } else {
            overlapRunFrames = 0
        }
        if gate == .them {
            themRun += 1
        } else if gate != .overlap {
            themRun = 0
        }
        if (gate == .them || gate == .overlap) && previous == .own && pendingYield == nil {
            let onset = t + tuning.gateLead
            pendingYield = (onset, onset + Self.yieldWindow, 0)
        }
        if var pending = pendingYield {
            if t >= pending.from && (gate == .overlap || gate == .own) { pending.overlapFrames += 1 }
            if t >= pending.until {
                let frames = Self.yieldWindow / tuning.frameSeconds
                if Double(pending.overlapFrames) < frames * Self.talkThroughShare { wasInterrupted += 1 }
                pendingYield = nil
            } else {
                pendingYield = pending
            }
        }
    }

    func talkShareSample() -> [String: Double] {
        talkShare.map { ["talkShare": $0] } ?? [:]
    }

    func interruptionSample() -> [String: Double] {
        ["interruptedThem": Double(interruptedThem), "wasInterrupted": Double(wasInterrupted)]
    }
}
