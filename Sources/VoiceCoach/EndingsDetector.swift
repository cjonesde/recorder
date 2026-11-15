import Foundation

struct PhraseEnding: Equatable {
    let end: Double
    let contour: Contour
    let rise: Double
    let fall: Double
    let trailing: Bool
    let detectedAt: Double
    var question = false
}

struct EndingsDetector {
    static let minimumRun = 0.5
    static let pause = 0.4
    static let pendingSeconds = 3.0
    static let questionLookback = 10.0
    static let questionEndWindow = 1.5
    static let questionSlack = 1.0
    static let window = 8
    static let minimumMeasured = 5
    static let risingThreshold = 0.30
    static let trailingCount = 3
    static let trailingDropDB = 6.0
    static let trailingSpan = 0.3
    static let refractory = 45.0
    static let historySeconds = 3.0
    static let freshness = 5.0

    private struct Frame {
        let t: Double
        let f0: Double
        let db: Double
        let own: Bool
    }

    let tuning: CoachTuning
    private var history: [Frame] = []
    private var historyHead = 0
    private var runStart: Double?
    private var lastOwn: Double?
    private var runLevels: [(t: Double, db: Double)] = []
    private var f0Histogram = [Int](repeating: 0, count: 601)
    private var voicedCount = 0
    private(set) var pending: [PhraseEnding] = []
    private(set) var recent: [PhraseEnding] = []
    private(set) var questions = 0
    private var questionSpans: [ClosedRange<Double>] = []
    private var lastRising = -Double.infinity
    private var lastTrailing = -Double.infinity
    private var committed = 0
    private var committedAtRising = 0
    private var committedAtTrailing = 0
    private var lastCommit = -Double.infinity

    init(tuning: CoachTuning) {
        self.tuning = tuning
    }

    var sessionF0: Double? {
        guard voicedCount >= 5 else { return nil }
        var seen = 0
        for (hz, count) in f0Histogram.enumerated() {
            seen += count
            if seen * 2 >= voicedCount { return Double(max(hz, 1)) }
        }
        return nil
    }

    mutating func observe(_ frame: FrameAnalysis) {
        history.append(Frame(t: frame.t, f0: frame.isOwn ? frame.f0 : 0, db: frame.micDB, own: frame.isOwn))
        while historyHead < history.count && history[historyHead].t < frame.t - Self.historySeconds { historyHead += 1 }
        if historyHead > 2048 {
            history.removeFirst(historyHead)
            historyHead = 0
        }
        if frame.isOwn && frame.f0 > 0 {
            f0Histogram[max(0, min(600, Int(frame.f0.rounded())))] += 1
            voicedCount += 1
        }
        if frame.isOwn {
            if runStart == nil || frame.t - (lastOwn ?? frame.t) >= Self.pause {
                runStart = frame.t
                runLevels.removeAll(keepingCapacity: true)
            }
            lastOwn = frame.t
            runLevels.append((frame.t, frame.micDB))
            if runLevels.count > 6000 { runLevels.removeFirst(3000) }
        } else if let start = runStart, let last = lastOwn, frame.t - last >= Self.pause {
            runStart = nil
            if last - start >= Self.minimumRun { evaluate(end: last, now: frame.t) }
        }
    }

    private mutating func evaluate(end: Double, now: Double) {
        let window = history[historyHead...].filter { $0.t >= end - 0.71 && $0.t <= end + 0.25 + 1e-9 }
        let st = cleanF0(window.map(\.f0), reference: sessionF0)
        let result = terminalContour(times: window.map(\.t), st: st, start: end - 0.4, end: end)
        let tail = runLevels.filter { $0.t > end - Self.trailingSpan }.map(\.db)
        let body = runLevels.filter { $0.t <= end - Self.trailingSpan }.map(\.db)
        var trailing = false
        if !tail.isEmpty, let bodyMedian = sortedMedian(body) {
            trailing = tail.reduce(0, +) / Double(tail.count) < bodyMedian - Self.trailingDropDB
        }
        var ending = PhraseEnding(end: end, contour: result.contour, rise: result.rise, fall: result.fall, trailing: trailing, detectedAt: now)
        ending.question = questionSpans.contains { $0.contains(end) }
        pending.append(ending)
    }

    mutating func observe(_ line: CoachLine) {
        guard line.isOwn, line.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return }
        let span = Self.questionSpan(of: line)
        questionSpans.removeAll { $0.upperBound < span.lowerBound - 2 * Self.questionLookback }
        questionSpans.append(span)
        for index in pending.indices where span.contains(pending[index].end) {
            pending[index].question = true
        }
        let answered = recent.filter { span.contains($0.end) }.count
        if answered > 0 {
            recent.removeAll { span.contains($0.end) }
            questions += answered
        }
    }

    static func questionSpan(of line: CoachLine) -> ClosedRange<Double> {
        guard let end = line.end, end >= line.time else { return line.time...(line.time + questionLookback) }
        return max(line.time - questionSlack, end - questionEndWindow)...(end + questionSlack)
    }

    mutating func tick(at t: Double) -> [DetectorID] {
        let due = pending.filter { t >= $0.detectedAt + Self.pendingSeconds }
        pending.removeAll { t >= $0.detectedAt + Self.pendingSeconds }
        for ending in due {
            if ending.question {
                questions += 1
            } else {
                recent.append(ending)
                committed += 1
                lastCommit = t
            }
        }
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        var fired: [DetectorID] = []
        guard t - lastCommit <= Self.freshness else { return fired }
        let measured = recent.filter { $0.contour != .unmeasured }
        if committed > committedAtRising, measured.count >= Self.minimumMeasured, let rate = risingRate, rate > Self.risingThreshold, t - lastRising >= Self.refractory {
            lastRising = t
            committedAtRising = committed
            fired.append(.risingEndings)
        }
        if committed > committedAtTrailing, recent.filter(\.trailing).count >= Self.trailingCount, t - lastTrailing >= Self.refractory {
            lastTrailing = t
            committedAtTrailing = committed
            fired.append(.trailingEndings)
        }
        return fired
    }

    var risingRate: Double? {
        let measured = recent.filter { $0.contour != .unmeasured }
        guard !measured.isEmpty else { return nil }
        return Double(measured.filter { $0.contour == .rise }.count) / Double(measured.count)
    }

    var trailingRate: Double? {
        guard !recent.isEmpty else { return nil }
        return Double(recent.filter(\.trailing).count) / Double(recent.count)
    }

    func risingSample() -> [String: Double] {
        var values: [String: Double] = [
            "measured": Double(recent.filter { $0.contour != .unmeasured }.count),
            "rises": Double(recent.filter { $0.contour == .rise }.count),
            "levels": Double(recent.filter { $0.contour == .level }.count),
            "falls": Double(recent.filter { $0.contour == .fall }.count),
            "questions": Double(questions),
        ]
        if let risingRate { values["risingRate"] = risingRate }
        return values
    }

    func trailingSample() -> [String: Double] {
        var values: [String: Double] = [
            "phrases": Double(recent.count),
            "trailing": Double(recent.filter(\.trailing).count),
        ]
        if let trailingRate { values["trailingRate"] = trailingRate }
        return values
    }
}
