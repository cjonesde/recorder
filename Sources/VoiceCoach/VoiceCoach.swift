import Foundation

struct FrameAnalysis {
    let index: Int
    let t: Double
    let micDB: Double
    let gate: GateState
    let f0: Double
    let floorDB: Double

    var isOwn: Bool { gate == .own }
}

struct BoxedRandom: RandomNumberGenerator {
    var base: any RandomNumberGenerator

    mutating func next() -> UInt64 { base.next() }
}

public final class VoiceCoach {
    public private(set) var config: CoachConfig
    public private(set) var ownSpeechSeconds = 0.0

    private let tuning: CoachTuning
    private var random: BoxedRandom
    private var micDownsampler = Downsampler()
    private var desktopDownsampler = Downsampler()
    private var micFrames: FrameAnalyzer
    private var desktopFrames: FrameAnalyzer
    private var pendingMic: [LevelFrame] = []
    private var pendingHead = 0
    private var desktopLevels: [Double] = []
    private var desktopBase = 0
    private var gate: OwnVoiceGate
    private let pitch: PitchTracker
    private var events: [CoachEvent] = []
    private var clips: [ClipRequest] = []
    private var litUntil: [DetectorID: Double] = [:]
    private var lastGate: GateState = .silence
    private var lastTime = 0.0
    private var started = false
    private var stalled = false
    private var nextTick = 1.0
    private var gateCounts: [GateState: Int] = [:]
    private var scratch: [Float] = []
    private var pace: PaceDetector
    private var energy: EnergyMeter
    private var sentenceStarts: SentenceStartCounter

    public init(config: CoachConfig, random: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.config = config
        self.tuning = config.tuning
        self.random = BoxedRandom(base: random)
        micFrames = FrameAnalyzer(tuning: config.tuning)
        desktopFrames = FrameAnalyzer(tuning: config.tuning)
        gate = OwnVoiceGate(tuning: config.tuning)
        pitch = PitchTracker(tuning: config.tuning)
        pace = PaceDetector(tuning: config.tuning, baselineRate: config.baselineRate)
        energy = EnergyMeter(baselineLevelDB: config.baselineLevelDB)
        sentenceStarts = SentenceStartCounter(language: config.language)
    }

    public func ingest(_ source: CoachSource, _ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        scratch.removeAll(keepingCapacity: true)
        switch source {
        case .mic:
            micDownsampler.process(samples, rate: sampleRate, into: &scratch)
            pendingMic.append(contentsOf: micFrames.push(scratch))
        case .desktop:
            desktopDownsampler.process(samples, rate: sampleRate, into: &scratch)
            for frame in desktopFrames.push(scratch) { desktopLevels.append(frame.db) }
        }
    }

    public func ingest(_ line: CoachLine) {
        observe(line)
    }

    public func setPreset(_ preset: CoachPreset) {
        guard preset != config.preset else { return }
        config.preset = preset
        events.append(CoachEvent(t: lastTime, kind: .preset, note: "override \(preset.rawValue)"))
    }

    public func advance() -> CoachOutput {
        if !started {
            started = true
            events.append(sessionEvent())
        }
        let leadFrames = tuning.leadFrames
        let desktopCount = desktopFrames.framesProduced
        let micLatest = micFrames.framesProduced
        while pendingHead < pendingMic.count {
            let frame = pendingMic[pendingHead]
            if desktopCount > frame.index + leadFrames {
                stalled = false
            } else if frame.index + tuning.stallFrames < micLatest {
                if !stalled {
                    stalled = true
                    events.append(CoachEvent(t: time(of: frame.index), kind: .gap, note: "system audio stalled"))
                }
            } else {
                break
            }
            process(frame)
            pendingHead += 1
        }
        compact()
        let output = CoachOutput(hud: hud(at: lastTime), events: events, clips: clips)
        events.removeAll(keepingCapacity: true)
        clips.removeAll(keepingCapacity: true)
        return output
    }

    public func finish() -> CoachSessionSummary {
        CoachSessionSummary(language: config.language, ownSpeechSeconds: ownSpeechSeconds, articulationRate: pace.sessionRateMedian, levelDB: energy.sessionLevelMedian)
    }

    private func time(of index: Int) -> Double { Double(index + 1) * tuning.frameSeconds }

    private func desktopLevel(_ index: Int) -> Double? {
        if index < 0 { return FrameAnalyzer.floorDB }
        let offset = index - desktopBase
        guard offset >= 0, offset < desktopLevels.count else { return nil }
        return desktopLevels[offset]
    }

    private func process(_ frame: LevelFrame) {
        let i = frame.index
        let window = ((i - tuning.hangoverFrames)...(i + tuning.leadFrames)).map(desktopLevel)
        let state = gate.classify(micDB: frame.db, desktopDB: window, currentDesktopDB: desktopLevel(i))
        var f0 = 0.0
        if state == .own, let samples = micFrames.window(endingAt: i, length: pitch.span) {
            f0 = pitch.f0(samples)
        }
        let t = time(of: i)
        let analysis = FrameAnalysis(index: i, t: t, micDB: frame.db, gate: state, f0: f0, floorDB: gate.micFloorDB)
        if state == .own { ownSpeechSeconds += tuning.frameSeconds }
        gateCounts[state, default: 0] += 1
        lastGate = state
        lastTime = t
        observe(analysis)
        if t >= nextTick - 1e-9 {
            tick(at: t)
            nextTick += 1
        }
    }

    private func compact() {
        if pendingHead > 4096 {
            pendingMic.removeFirst(pendingHead)
            pendingHead = 0
        }
        let keepFrom = (pendingHead < pendingMic.count ? pendingMic[pendingHead].index : micFrames.framesProduced) - tuning.hangoverFrames - 1
        let drop = keepFrom - desktopBase
        if drop > 4096 {
            desktopLevels.removeFirst(min(drop, desktopLevels.count))
            desktopBase += min(drop, desktopLevels.count)
        }
    }

    private func observe(_ frame: FrameAnalysis) {
        pace.observe(frame)
        energy.observe(frame)
    }

    private func observe(_ line: CoachLine) {
        guard config.transcriptCues, line.isOwn else { return }
        let result = sentenceStarts.observe(line)
        guard result.sentences > 0 else { return }
        let t = max(line.time, 0)
        if sentenceStarts.shouldTrigger(at: max(t, lastTime)) {
            fire(.soStarts, at: t, values: sentenceStarts.sample())
        }
    }

    private func tick(at t: Double) {
        let total = Double(gateCounts.values.reduce(0, +))
        if total > 0 {
            var values: [String: Double] = [:]
            for state in [GateState.own, .them, .overlap, .silence, .unknown] {
                values[state.rawValue] = Double(gateCounts[state, default: 0]) / total
            }
            events.append(CoachEvent(t: t, kind: .sample, values: values, note: "gate"))
        }
        gateCounts.removeAll(keepingCapacity: true)
        let paceTick = pace.tick(at: t, paceRatio: config.preset.paceRatio)
        events.append(CoachEvent(t: t, kind: .sample, detector: .pace, values: paceTick.values, note: paceTick.note))
        events.append(CoachEvent(t: t, kind: .sample, detector: .energy, values: energy.sample(at: t)))
        if paceTick.trigger { fire(.pace, at: t, values: paceTick.values) }
        events.append(CoachEvent(t: t, kind: .sample, detector: .soStarts, values: sentenceStarts.sample(), note: config.transcriptCues ? nil : "engine lags"))
    }

    @discardableResult
    func fire(_ detector: DetectorID, at t: Double, values: [String: Double] = [:]) -> String {
        let decision = CuePolicy.decide(detector, config: config, random: &random)
        let id = "\(detector.rawValue)-\(Int((t * 1000).rounded()))"
        events.append(CoachEvent(t: t, kind: .trigger, detector: detector, values: values, shown: decision.shown, note: decision.note, id: id))
        if decision.shown { litUntil[detector] = max(t, lastTime) + tuning.cueSeconds }
        return id
    }

    private func hud(at t: Double) -> CoachHUDState {
        var state = CoachHUDState.idle(config.preset)
        state.gate = lastGate
        state.energy = energy.value(at: t)
        state.litCues = Set(litUntil.filter { $0.value > t }.keys)
        return state
    }

    private func sessionEvent() -> CoachEvent {
        var values: [String: Double] = [
            "withholding": config.withholding ? 1 : 0,
            "cueOffSession": config.cueOffSession ? 1 : 0,
            "transcriptCues": config.transcriptCues ? 1 : 0,
        ]
        if let rate = config.baselineRate { values["baselineRate"] = rate }
        if let level = config.baselineLevelDB { values["baselineLevelDB"] = level }
        let promoted = config.promoted.map(\.rawValue).sorted().joined(separator: ",")
        return CoachEvent(t: 0, kind: .session, values: values, note: "language=\(config.language) preset=\(config.preset.rawValue) promoted=\(promoted)")
    }
}
