import AVFoundation
import Foundation
import Observation
import Synchronization
import VoiceCoach

final class CoachRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pump: CoachPump?

    var current: CoachPump? { lock.withLock { pump } }

    func set(_ pump: CoachPump?) {
        lock.withLock { self.pump = pump }
    }

    func ingest(_ source: CoachSource, _ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        lock.withLock { pump }?.ingest(source, samples, count: count, rate: rate)
    }
}

final class CoachPump: @unchecked Sendable {
    static let ringFrames = 960_000
    static let tickInterval = DispatchTimeInterval.milliseconds(50)
    static let clipRingSeconds = 12.0
    static let clipsFolderName = "coach-clips"
    static let logName = "coach.jsonl"

    let folder: URL
    var onHUD: (@Sendable (CoachHUDState) -> Void)?

    private let queue = DispatchQueue(label: "recorder.coach", qos: .userInitiated)
    private let micRing = FloatRingBuffer(capacityFrames: CoachPump.ringFrames)
    private let desktopRing = FloatRingBuffer(capacityFrames: CoachPump.ringFrames)
    private let micRate = Atomic<UInt64>(0)
    private let desktopRate = Atomic<UInt64>(0)
    private let coach: VoiceCoach
    private let encoder: JSONEncoder
    private var timer: DispatchSourceTimer?
    private var log: FileHandle?
    private var lastHUD: CoachHUDState?
    private var stopped = false
    private var retainsAudio: Bool
    private var chunk = [Float](repeating: 0, count: 4096)
    private var clipRing: [Float] = []
    private var clipRingStart = 0
    private var clipRate = 0.0

    init(folder: URL, config: CoachConfig, retainsAudio: Bool, random: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.folder = folder
        self.retainsAudio = retainsAudio
        coach = VoiceCoach(config: config, random: random)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let logURL = folder.appendingPathComponent(Self.logName)
        if FileManager.default.createFile(atPath: logURL.path, contents: nil) {
            log = try? FileHandle(forWritingTo: logURL)
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.pumpOnce() }
        self.timer = timer
        timer.resume()
    }

    func ingest(_ source: CoachSource, _ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        switch source {
        case .mic:
            micRate.store(rate.bitPattern, ordering: .relaxed)
            micRing.write(samples, count: count)
        case .desktop:
            desktopRate.store(rate.bitPattern, ordering: .relaxed)
            desktopRing.write(samples, count: count)
        }
    }

    func ingest(lines: [CoachLine]) {
        guard !lines.isEmpty else { return }
        queue.async { [self] in
            guard !stopped else { return }
            for line in lines { coach.ingest(line) }
        }
    }

    func setPreset(_ preset: CoachPreset) {
        queue.async { [self] in
            guard !stopped else { return }
            coach.setPreset(preset)
        }
    }

    func audioRetentionChanged(retains: Bool) {
        queue.async { [self] in
            retainsAudio = retains
            guard !retains else { return }
            clipRing.removeAll()
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.clipsFolderName))
        }
    }

    func drainNow() {
        queue.sync { pumpOnce() }
    }

    func stop() -> CoachSessionSummary {
        queue.sync {
            timer?.cancel()
            timer = nil
            if !stopped { pumpOnce() }
            stopped = true
            try? log?.close()
            log = nil
            clipRing.removeAll()
            return coach.finish()
        }
    }

    private func pumpOnce() {
        guard !stopped else { return }
        drain(desktopRing, source: .desktop, rate: Double(bitPattern: desktopRate.load(ordering: .relaxed)))
        drain(micRing, source: .mic, rate: Double(bitPattern: micRate.load(ordering: .relaxed)))
        let output = coach.advance()
        for event in output.events { write(event) }
        for request in output.clips { writeClip(request) }
        if output.hud != lastHUD {
            lastHUD = output.hud
            onHUD?(output.hud)
        }
    }

    private func drain(_ ring: FloatRingBuffer, source: CoachSource, rate: Double) {
        chunk.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while true {
                let count = ring.read(into: base, maxCount: buffer.count)
                guard count > 0 else { break }
                guard rate > 0 else { continue }
                let samples = UnsafeBufferPointer(start: base, count: count)
                coach.ingest(source, samples, sampleRate: rate)
                if source == .mic { remember(samples, rate: rate) }
            }
        }
    }

    private func remember(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        guard retainsAudio else {
            clipRingStart += samples.count
            return
        }
        clipRate = rate
        clipRing.append(contentsOf: samples)
        let keep = Int(Self.clipRingSeconds * rate)
        if clipRing.count > keep + keep / 4 {
            let drop = clipRing.count - keep
            clipRing.removeFirst(drop)
            clipRingStart += drop
        }
    }

    private func write(_ event: CoachEvent) {
        guard let log, var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        try? log.write(contentsOf: data)
    }

    private func writeClip(_ request: ClipRequest) {
        guard retainsAudio, clipRate > 0 else {
            write(CoachEvent(t: request.end, kind: .clip, detector: request.detector, note: "transcript only", id: request.id))
            return
        }
        let first = Int(request.start * clipRate) - clipRingStart
        let last = Int(request.end * clipRate) - clipRingStart
        guard first >= 0, last <= clipRing.count, last > first else {
            write(CoachEvent(t: request.end, kind: .clip, detector: request.detector, note: "audio no longer held", id: request.id))
            return
        }
        let directory = folder.appendingPathComponent(Self.clipsFolderName, isDirectory: true)
        let url = directory.appendingPathComponent("\(request.id).m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writeAAC(Array(clipRing[first..<last]), rate: clipRate, to: url)
        } catch {
            write(CoachEvent(t: request.end, kind: .clip, detector: request.detector, note: "write failed: \(error.localizedDescription)", id: request.id))
        }
    }

    static func writeAAC(_ samples: [Float], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

@MainActor
@Observable
final class CoachController {
    private(set) var hud: CoachHUDState?
    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var preset: CoachPreset = .presentation
    private(set) var hiddenForSession = false

    @ObservationIgnored nonisolated let relay = CoachRelay()
    @ObservationIgnored private var pump: CoachPump?
    @ObservationIgnored private var lineTimer: Timer?
    @ObservationIgnored private var seenLines = Set<UUID>()
    @ObservationIgnored private var lines: (@MainActor () -> [TranscriptLine])?
    @ObservationIgnored private var micName = "default"
    @ObservationIgnored private let store: CoachStore
    @ObservationIgnored var showsPanel = true

    init(store: CoachStore? = nil) {
        self.store = store ?? CoachStore.shared
    }

    func start(folder: URL, language: String, engine: LiveEngineKind, attendeeCount: Int?, retainsAudio: Bool, lines: @escaping @MainActor () -> [TranscriptLine]) {
        if isActive { stop(discard: true) }
        micName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "default"
        var config = CoachConfig(language: language)
        config.preset = CoachPreset.pick(attendeeCount: attendeeCount)
        config.promoted = Preferences.coachPromoted
        config.withholding = Preferences.coachWithholding
        config.cueOffSession = CuePolicy.isCueOffSession(index: store.nextSessionIndex())
        config.transcriptCues = engine == .apple
        config.baselineRate = store.baseline.rate(language: language)
        config.baselineLevelDB = store.baseline.level(mic: micName)
        let pump = CoachPump(folder: folder, config: config, retainsAudio: retainsAudio)
        pump.onHUD = { [weak self] state in
            Task { @MainActor in self?.hud = state }
        }
        self.pump = pump
        self.lines = lines
        seenLines = []
        preset = config.preset
        hud = .idle(config.preset)
        isPaused = false
        hiddenForSession = false
        isActive = true
        pump.start()
        relay.set(pump)
        lineTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.forwardLines() }
        }
        if showsPanel { CoachHUDPanel.shared.show(controller: self) }
    }

    func stop(discard: Bool = false) {
        guard isActive, let pump else { return }
        relay.set(nil)
        lineTimer?.invalidate()
        lineTimer = nil
        forwardLines()
        let summary = pump.stop()
        if !discard {
            store.baseline.record(summary, mic: micName)
            store.save()
        }
        self.pump = nil
        lines = nil
        isActive = false
        hud = nil
        CoachHUDPanel.shared.close()
    }

    func setPaused(_ paused: Bool) {
        guard isActive else { return }
        isPaused = paused
    }

    func overridePreset(_ preset: CoachPreset) {
        guard isActive else { return }
        self.preset = preset
        pump?.setPreset(preset)
    }

    func audioRetentionChanged(retains: Bool) {
        pump?.audioRetentionChanged(retains: retains)
    }

    func hideForSession() {
        hiddenForSession = true
        CoachHUDPanel.shared.close()
    }

    func showAgain() {
        guard isActive else { return }
        hiddenForSession = false
        CoachHUDPanel.shared.show(controller: self)
    }

    private func forwardLines() {
        guard let pump, let lines else { return }
        let fresh = lines().filter { seenLines.insert($0.id).inserted }
        pump.ingest(lines: fresh.map { CoachLine(time: $0.time, text: $0.text, isOwn: $0.speaker == "You") })
    }
}
