import Foundation

struct FrameAnalysis {
    let index: Int
    let t: Double
    let micDB: Double
    let gate: GateState
    let f0: Double
    let floorDB: Double
    var remoteAudible = false

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
    private var deficits: [Int] = []
    private var desktopArrived = false
    private var gate: OwnVoiceGate
    private var voice: VoiceConfirmer
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
    private var endings: EndingsDetector
    private var clipPlanner: ClipPlanner
    private var prosody = ProsodyProxies()
    private var turns: TurnTaking

    public init(config: CoachConfig, random: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.config = config
        self.tuning = config.tuning
        self.random = BoxedRandom(base: random)
        micFrames = FrameAnalyzer(tuning: config.tuning)
        desktopFrames = FrameAnalyzer(tuning: config.tuning)
        gate = OwnVoiceGate(tuning: config.tuning)
        voice = VoiceConfirmer()
        pitch = PitchTracker(tuning: config.tuning)
        pace = PaceDetector(tuning: config.tuning, baselineRate: config.baselineRate)
        energy = EnergyMeter(baselineLevelDB: config.baselineLevelDB)
        sentenceStarts = SentenceStartCounter(language: config.language)
        endings = EndingsDetector(tuning: config.tuning)
        clipPlanner = ClipPlanner(tuning: config.tuning)
        turns = TurnTaking(tuning: config.tuning)
    }

    public func ingest(_ source: CoachSource, _ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        scratch.removeAll(keepingCapacity: true)
        switch source {
        case .mic:
            micDownsampler.process(samples, rate: sampleRate, into: &scratch)
            pendingMic.append(contentsOf: micFrames.push(scratch))
        case .desktop:
            desktopDownsampler.process(samples, rate: sampleRate, into: &scratch)
            let frames = desktopFrames.push(scratch)
            for frame in frames { desktopLevels.append(frame.db) }
            if !frames.isEmpty { desktopArrived = true }
        }
    }

    static let immediateRealignFrames = 50
    static let steadyRealignFrames = 20
    static let realignSlackFrames = 5
    static let deficitWindow = 20

    private var desktopAligned: Int { desktopBase + desktopLevels.count }

    private func realignDesktop() {
        let deficit = micFrames.framesProduced - desktopAligned
        deficits.append(deficit)
        if deficits.count > Self.deficitWindow { deficits.removeFirst(deficits.count - Self.deficitWindow) }
        var shift = 0
        if deficit > Self.immediateRealignFrames {
            shift = deficit - Self.realignSlackFrames
        } else if deficits.count >= Self.deficitWindow / 2, let low = deficits.min(), low > Self.steadyRealignFrames {
            shift = low - Self.realignSlackFrames
        } else if deficits.count >= Self.deficitWindow / 2, let high = deficits.max(), high < -Self.steadyRealignFrames {
            let consumedThrough = (pendingHead < pendingMic.count ? pendingMic[pendingHead].index : micFrames.framesProduced) + tuning.leadFrames
            let removable = max(0, desktopAligned - consumedThrough - 1)
            shift = -min(-high - Self.realignSlackFrames, removable)
        }
        guard shift != 0 else { return }
        if shift > 0 {
            desktopLevels.append(contentsOf: repeatElement(.nan, count: shift))
        } else {
            desktopLevels.removeLast(-shift)
        }
        deficits.removeAll()
        let seconds = Double(shift) * tuning.frameSeconds
        events.append(CoachEvent(t: lastTime, kind: .gap, values: ["shift": seconds], note: String(format: "system audio realigned %+.2f s", seconds)))
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
        if desktopArrived {
            desktopArrived = false
            realignDesktop()
        }
        let leadFrames = tuning.leadFrames
        let desktopCount = desktopAligned
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

    public func flush() -> CoachOutput {
        record(clipPlanner.flush(at: lastTime), at: lastTime)
        let output = CoachOutput(hud: hud(at: lastTime), events: events, clips: clips)
        events.removeAll(keepingCapacity: true)
        clips.removeAll(keepingCapacity: true)
        return output
    }

    public func clearCues() {
        litUntil.removeAll()
    }

    public func finish() -> CoachSessionSummary {
        CoachSessionSummary(language: config.language, ownSpeechSeconds: ownSpeechSeconds, articulationRate: pace.sessionRateMedian, levelDB: energy.sessionLevelMedian)
    }

    private func time(of index: Int) -> Double { Double(index + 1) * tuning.frameSeconds }

    private func desktopLevel(_ index: Int) -> Double? {
        if index < 0 { return FrameAnalyzer.floorDB }
        let offset = index - desktopBase
        guard offset >= 0, offset < desktopLevels.count, !desktopLevels[offset].isNaN else { return nil }
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
        var analysis = FrameAnalysis(index: i, t: time(of: i), micDB: frame.db, gate: state, f0: f0, floorDB: gate.micFloorDB)
        if state == .overlap {
            let recent = tuning.frames(TurnTaking.audibleRecentSeconds)
            analysis.remoteAudible = ((i - recent)...i).contains { desktopLevel($0).map(gate.isTapActive) ?? false }
        }
        for confirmed in voice.push(analysis) { consume(confirmed) }
    }

    private func consume(_ analysis: FrameAnalysis) {
        let i = analysis.index
        let t = analysis.t
        let state = analysis.gate
        if state == .own { ownSpeechSeconds += tuning.frameSeconds }
        gateCounts[state, default: 0] += 1
        lastGate = state
        lastTime = t
        observe(analysis)
        record(clipPlanner.observe(index: i, t: t, gate: state), at: t)
        if t >= nextTick - 1e-9 {
            tick(at: t)
            nextTick += 1
        }
    }

    private func record(_ outcomes: [ClipOutcome], at t: Double) {
        for outcome in outcomes {
            switch outcome {
            case .keep(let request):
                clips.append(request)
                events.append(CoachEvent(t: t, kind: .clip, detector: request.detector, values: ["start": request.start, "end": request.end], note: "planned", id: request.id))
            case .skip(let id, let reason):
                events.append(CoachEvent(t: t, kind: .clip, note: reason, id: id))
            }
        }
    }

    static let desktopRetainedFrames = 6000

    private func compact() {
        if pendingHead > 4096 {
            pendingMic.removeFirst(pendingHead)
            pendingHead = 0
        }
        let nextMic = pendingHead < pendingMic.count ? pendingMic[pendingHead].index : micFrames.framesProduced
        let keepFrom = min(nextMic, desktopAligned - Self.desktopRetainedFrames) - tuning.hangoverFrames - 1
        let drop = min(keepFrom - desktopBase, desktopLevels.count)
        if drop > 4096 {
            desktopLevels.removeFirst(drop)
            desktopBase += drop
        }
    }

    private func observe(_ frame: FrameAnalysis) {
        let syllablesBefore = pace.totalSyllables
        pace.observe(frame)
        energy.observe(frame)
        endings.observe(frame)
        prosody.observe(frame, newPeak: pace.totalSyllables > syllablesBefore ? pace.lastPeak : nil)
        turns.observe(t: frame.t, gate: frame.gate, remoteAudible: frame.remoteAudible)
    }

    private func observe(_ line: CoachLine) {
        endings.observe(line)
        guard config.transcriptCues, line.isOwn else { return }
        let result = sentenceStarts.observe(line)
        guard result.sentences > 0 else { return }
        let t = max(line.time, 0)
        if sentenceStarts.shouldTrigger(at: max(t, lastTime)) {
            fire(.soStarts, at: t, values: sentenceStarts.sample(), clip: Self.clipWindow(for: line, from: t))
        }
    }

    static let lineClipLead = 1.0
    static let lineClipTail = 0.5
    static let lineClipLimit = 15.0

    static func clipWindow(for line: CoachLine, from start: Double) -> ClosedRange<Double>? {
        guard let end = line.end, end > start else { return nil }
        return max(0, start - lineClipLead)...(min(end, start + lineClipLimit) + lineClipTail)
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
        let endingTriggers = endings.tick(at: t)
        events.append(CoachEvent(t: t, kind: .sample, detector: .risingEndings, values: endings.risingSample()))
        events.append(CoachEvent(t: t, kind: .sample, detector: .trailingEndings, values: endings.trailingSample()))
        for detector in endingTriggers {
            fire(detector, at: t, values: detector == .risingEndings ? endings.risingSample() : endings.trailingSample())
        }
        let rateRatio = pace.rate.flatMap { rate in pace.effectiveBaseline.map { rate / $0 } }
        let prosodyTick = prosody.tick(at: t, levelOffsetDB: energy.offsetDB, rateRatio: rateRatio)
        events.append(CoachEvent(t: t, kind: .sample, detector: .raisedVoice, values: prosodyTick.values))
        if prosodyTick.trigger { fire(.raisedVoice, at: t, values: prosodyTick.values) }
        events.append(CoachEvent(t: t, kind: .sample, detector: .talkShare, values: turns.talkShareSample()))
        events.append(CoachEvent(t: t, kind: .sample, detector: .interruptions, values: turns.interruptionSample()))
    }

    @discardableResult
    func fire(_ detector: DetectorID, at t: Double, values: [String: Double] = [:], clip window: ClosedRange<Double>? = nil) -> String {
        let decision = CuePolicy.decide(detector, config: config, random: &random)
        let id = "\(detector.rawValue)-\(Int((t * 1000).rounded()))"
        events.append(CoachEvent(t: t, kind: .trigger, detector: detector, values: values, shown: decision.shown, note: decision.note, id: id))
        if decision.shown { litUntil[detector] = max(t, lastTime) + tuning.cueSeconds }
        clipPlanner.register(id: id, detector: detector, at: t, window: window)
        return id
    }

    private func hud(at t: Double) -> CoachHUDState {
        var state = CoachHUDState.idle(config.preset)
        state.gate = lastGate
        state.energy = energy.value(at: t)
        if config.isPromoted(.talkShare), let share = turns.talkShare {
            state.talkShare = share
            state.talkShareHigh = config.preset.talkShareHigh.map { share > $0 } ?? false
        }
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
