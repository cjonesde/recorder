import Foundation
import Observation
import AppKit
import os
import VoiceCoach

/// Owns every component and wires their callbacks. The model is @MainActor;
/// audio-thread callbacks hop to main via DispatchQueue.main.async before touching state.
@MainActor
@Observable
final class RecorderModel {

    // MARK: - Observable UI state

    var state: RecorderState = .idle {
        didSet {
            if state == .idle { transcriptions.release() } else { transcriptions.hold() }
        }
    }
    let transcriptions = TranscriptionQueue<PendingTranscription>()
    var desktopLevel: Float = 0      // 0..1 meter (LEFT / desktop)
    var micLevel: Float = 0          // 0..1 meter (RIGHT / mic)
    var meetings: [Meeting] = []
    var currentSession: RecordingSession? = nil
    var elapsed: TimeInterval = 0
    var statusMessage: String? = nil {
        didSet { appendDebugReportNotice() }
    }
    @ObservationIgnored private var debugReportNotice: String?

    /// On-device transcription engines. Exposed so the panel can
    /// render the live transcript and engine status directly.
    let live: LocalTranscriptionEngine

    @ObservationIgnored private let whisperLoader: (@MainActor (String) async -> Void)?
    @ObservationIgnored private let fileTranscriber: (@MainActor (URL) async throws -> OfflineTranscription)?
    @ObservationIgnored private let whisperUnloader: (@MainActor () -> Void)?
    @ObservationIgnored private var recordingUsesLive = false

    init(
        engineFactory: @escaping LocalTranscriptionEngine.EngineFactory = LocalTranscriptionEngine.defaultFactory,
        whisperLoader: (@MainActor (String) async -> Void)? = nil,
        fileTranscriber: (@MainActor (URL) async throws -> OfflineTranscription)? = nil,
        whisperUnloader: (@MainActor () -> Void)? = nil
    ) {
        live = LocalTranscriptionEngine(factory: engineFactory)
        self.whisperLoader = whisperLoader
        self.fileTranscriber = fileTranscriber
        self.whisperUnloader = whisperUnloader
        transcriptions.perform = { [weak self] pending in
            guard let self else { return .finished }
            return await self.runTranscription(pending)
        }
    }

    // MARK: - Persisted preferences (mirrored to UserDefaults via Preferences)

    /// Auto-stop after this many seconds of two-channel silence.
    var silenceTimeout: TimeInterval = 300 {
        didSet { Preferences.silenceTimeout = silenceTimeout }
    }
    /// dBFS below which a channel is considered silent.
    var silenceThresholdDB: Float = -50 {
        didSet { Preferences.silenceThresholdDB = silenceThresholdDB }
    }
    /// Whether silence auto-stop runs at all.
    var silenceAutoStopEnabled: Bool = true {
        didSet { Preferences.silenceAutoStop = silenceAutoStopEnabled }
    }
    /// What this recording may leave on disk.
    var audioHandlingMode: AudioHandlingMode = .default {
        didSet { Preferences.audioHandlingMode = audioHandlingMode }
    }
    /// Used only when transcribing saved audio.
    var whisperModel: String = WhisperModelOption.defaultModelID {
        didSet { Preferences.whisperModel = whisperModel }
    }
    private var selectedLanguage = TranscriptionLanguage.selection(for: "")
    var transcriptionLanguage: String {
        get { selectedLanguage }
        set {
            guard state == .idle else { return }
            selectedLanguage = newValue
            Preferences.language = newValue
            live.language = String(newValue.prefix(2))
        }
    }
    private var streamsLive = true
    var liveTranscriptionEnabled: Bool {
        get { streamsLive }
        set {
            guard state == .idle else { return }
            streamsLive = newValue
            Preferences.liveTranscription = newValue
        }
    }
    /// Whether transcripts carry speaker labels (live: You/Them by channel;
    /// offline: Speaker N via on-device diarization).
    var speakerLabelsEnabled: Bool = true {
        didSet {
            Preferences.speakerLabels = speakerLabelsEnabled
            live.labelSpeakers = speakerLabelsEnabled
        }
    }
    /// Whether voice profiles are matched and enrolled. Off by default.
    var voiceProfilesEnabled: Bool = false {
        didSet { Preferences.voiceProfiles = voiceProfilesEnabled }
    }

    var liveEngine: LiveEngineKind = .default {
        didSet { Preferences.liveEngine = liveEngine }
    }
    var coachEnabled: Bool = false {
        didSet { Preferences.coachEnabled = coachEnabled }
    }
    var coachWithholding: Bool = true {
        didSet { Preferences.coachWithholding = coachWithholding }
    }
    var coachPromoted: Set<DetectorID> = [.pace] {
        didSet { Preferences.coachPromoted = coachPromoted }
    }
    let coach = CoachController()

    var showDebugInfo: Bool = false {
        didSet {
            Preferences.showDebugInfo = showDebugInfo
            if !showDebugInfo {
                stopDiagnosticsSampling()
                diagnostics = nil
            }
        }
    }

    private(set) var diagnostics: DiagnosticsRecorder?
    var isSamplingDiagnostics: Bool { diagnosticsTimer != nil }
    @ObservationIgnored private var diagnosticsTimer: Timer?
    @ObservationIgnored private var heartbeat: MainThreadHeartbeat?
    @ObservationIgnored private var diagnosticsFolder: URL?

    /// Saved voiceprints. Observed, so the Speakers pane updates as profiles change.
    let speakerStore = SpeakerProfileStore()

    /// The document behind the transcript currently shown, kept so a rename can
    /// re-render `transcript.md` from its source rather than patching the markdown.
    private(set) var lastDocument: TranscriptDocument?

    // Transcription (post-save).
    var transcriptionState: TranscriptionState = .idle
    var lastTranscriptText: String? = nil
    var lastTranscriptURL: URL? = nil

    /// The most recent recordings on disk (loaded at launch + after changes).
    var recentRecordings: [RecordingEntry] = []

    // MARK: - Heavy / audio objects (not observation-tracked)

    @ObservationIgnored private static let log = Logger(subsystem: "com.tobi.Recorder", category: "RecorderModel")

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var didAppear = false

    var canStartRecording: Bool { state == .idle }
    var canChangeLiveEngine: Bool { state == .idle }
    var isCapturing: Bool { state == .recording || state == .paused }

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    /// The meeting (if any) the current recording is attached to — kept so its
    /// title + attendees are available as transcript context at save time.
    @ObservationIgnored private var activeMeeting: Meeting?

    /// The mode the recording in progress actually started with, which can differ from
    /// `audioHandlingMode` after a mid-recording downgrade.
    @ObservationIgnored private var activeMode: AudioHandlingMode = .default

    @ObservationIgnored private var liveRestartTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveRestartAt: TimeInterval?
    @ObservationIgnored private var liveFailureStreak = 0

    /// Everything needed to (re)run a transcription, captured at save time.
    struct PendingTranscription: Identifiable {
        let audioURL: URL?
        let folderURL: URL
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date
        var liveEngineName: String? = nil
        var diagnostics: DiagnosticsRecorder? = nil
        var reportLanguage: String? = nil

        var id: URL { folderURL }

        var displayTitle: String {
            meetingTitle ?? "Recording \(startedAt.formatted(date: .omitted, time: .shortened))"
        }
    }
    private(set) var lastTranscription: PendingTranscription?

    // MARK: - Lifecycle

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        // Load persisted preferences first so the UI reflects them immediately.
        loadPreferences()

        // Load prior recordings from disk so they survive restarts.
        refreshRecordings()

        // Biometric data should not outlive its purpose: drop voiceprints nobody named.
        speakerStore.prunePending()

        // Request permissions concurrently, then load meetings.
        Task { @MainActor in
            _ = await MicCapture.requestAccess()
        }
        Task { @MainActor in
            _ = await calendar.requestAccess()
            refreshMeetings()
        }
        Task { @MainActor in
            await notifications.requestAuthorization()
        }

        // Refetch meetings on calendar changes.
        calendar.onChange = { [weak self] in
            // onChange is delivered on main (CalendarAccess is @MainActor).
            self?.refreshMeetings()
        }

        // A user tapping "Stop Recording" in the meeting-end notification stops + saves.
        notifications.onStopRequested = { [weak self] in
            guard let self else { return }
            if self.state != .idle {
                self.saveAndStop(source: .meetingEndNotification)
            }
        }

        configureCaptures()
    }

    /// Wire the capture callbacks and load the selected model. Split out of `onAppear`
    /// so it can run without the permission and notification setup, which needs a real
    /// app bundle and therefore cannot run under the test runner.
    func configureCaptures() {
        // Surface fatal capture errors to the UI.
        tap.onCaptureError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleCaptureFailure(error)
            }
        }
        mic.onCaptureError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleCaptureFailure(error)
            }
        }

        // Feed both captures into the live-transcription inbox. The inbox is a
        // no-op outside an active session, so the hooks stay wired permanently.
        let router = live.router
        let coachRelay = coach.relay
        tap.onSamples = { samples, count, rate in
            router.ingest(.desktop, samples, count: count, rate: rate)
            coachRelay.ingest(.desktop, samples, count: count, rate: rate)
        }
        mic.onSamples = { samples, count, rate in
            router.ingest(.mic, samples, count: count, rate: rate)
            coachRelay.ingest(.mic, samples, count: count, rate: rate)
        }

        live.onFailure = { [weak self] in
            self?.handleLiveEngineFailure()
        }

        tap.onGap = { [weak self] gap, rate in
            DispatchQueue.main.async {
                self?.noteDesktopGap(gap, rate: rate)
            }
        }
    }

    private func noteDesktopGap(_ gap: CaptureRingDrain.Gap, rate: Double) {
        guard isCapturing, rate > 0 else { return }
        let heldBack = Double(gap.heldBackFromLiveFrames) / rate
        let lost = Double(gap.lostFrames) / rate
        let detail = String(format: "%.2f s kept out of live text, %.2f s lost", heldBack, lost)
        Self.log.notice("desktop audio stalled: \(detail, privacy: .public)")
        diagnostics?.record("desktop audio stalled", detail: detail)
        if lost > 0 {
            statusMessage = String(format: "Desktop audio stalled for %.1f s. Recording continues.", lost)
        }
    }

    private func handleLiveEngineFailure() {
        let engine = live.engine
        if let reason = engine.stopReason { diagnostics?.recordStop(reason) }
        guard isCapturing, live.inRecordingSession else { return }
        let detail = engine.failureMessage ?? engine.stopReason?.rawValue ?? "unknown"
        Self.log.error("live text interrupted, restarting: \(detail, privacy: .public)")
        diagnostics?.record("live text interrupted, restarting", detail: detail)
        statusMessage = "Live text interrupted. Restarting it; recording continues."
        let now = ProcessInfo.processInfo.systemUptime
        let failedSoonAfterRestart = lastLiveRestartAt.map { now - $0 < Self.stableLiveSessionSeconds } ?? false
        liveFailureStreak = failedSoonAfterRestart ? liveFailureStreak + 1 : 0
        restartLiveText(attempt: liveFailureStreak)
    }

    static let stableLiveSessionSeconds: TimeInterval = 60

    private func restartLiveText(attempt: Int, retrying: Bool = false) {
        guard liveRestartTask == nil || retrying else { return }
        let language = transcriptionLanguage
        liveRestartTask = Task { [weak self] in
            if attempt > 0 {
                try? await Task.sleep(for: self?.liveRestartDelay(attempt) ?? .zero)
            }
            guard let self, !Task.isCancelled, self.isCapturing, self.live.inRecordingSession else { return }
            do {
                try await self.live.restartSession(language: language)
                self.liveRestartTask = nil
                self.lastLiveRestartAt = ProcessInfo.processInfo.systemUptime
                guard self.isCapturing else { return }
                self.diagnostics?.record("live text restarted", detail: "attempt \(attempt + 1)")
                self.statusMessage = "Live text restarted. Recording continues."
            } catch {
                guard !Task.isCancelled, self.isCapturing, self.live.inRecordingSession else {
                    self.liveRestartTask = nil
                    return
                }
                Self.log.error("live text restart failed: \(error.localizedDescription, privacy: .public)")
                self.diagnostics?.record("live text restart failed", detail: error.localizedDescription)
                self.statusMessage = "Live text could not restart yet (\(error.localizedDescription)). Recording continues; retrying."
                self.restartLiveText(attempt: attempt + 1, retrying: true)
            }
        }
    }

    static func liveRestartDelay(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(attempt, 5)))
    }

    @ObservationIgnored var liveRestartDelay: (Int) -> Duration = { RecorderModel.liveRestartDelay(attempt: $0) }

    func reportCaptureErrorForTesting(_ error: Error) {
        handleCaptureFailure(error)
    }

    private func handleCaptureFailure(_ error: Error) {
        guard isCapturing else { return }
        Self.log.error("capture problem, recording continues: \(error.localizedDescription, privacy: .public)")
        diagnostics?.record("capture problem, recording continues", detail: error.localizedDescription)
        statusMessage = "\(error.localizedDescription) Recording continues."
    }

    /// Pull persisted preferences into the observable properties. The `didSet`
    /// write-backs are idempotent (same value in → same value out).
    private func loadPreferences() {
        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        audioHandlingMode = Preferences.audioHandlingMode
        whisperModel = Preferences.whisperModel
        transcriptionLanguage = Preferences.language
        liveTranscriptionEnabled = Preferences.liveTranscription
        speakerLabelsEnabled = Preferences.speakerLabels
        voiceProfilesEnabled = Preferences.voiceProfiles
        liveEngine = Preferences.liveEngine
        showDebugInfo = Preferences.showDebugInfo
        coachEnabled = Preferences.coachEnabled
        coachWithholding = Preferences.coachWithholding
        coachPromoted = Preferences.coachPromoted
    }

    // MARK: - Recording control

    func startRecording(meeting: Meeting?) {
        guard canStartRecording else { return }
        liveRestartTask?.cancel()
        liveRestartTask = nil
        lastLiveRestartAt = nil
        liveFailureStreak = 0

        let mode = audioHandlingMode
        guard !mode.producesNothing(liveTranscriptionEnabled: liveTranscriptionEnabled) else {
            statusMessage = "Transcript-only mode needs live transcription switched on, otherwise nothing would be saved."
            return
        }

        let language = transcriptionLanguage
        let wantsLive = liveTranscriptionEnabled
        let kind = liveEngine
        recordingUsesLive = wantsLive
        if wantsLive { unloadOfflineModels() }
        state = .preparing
        statusMessage = wantsLive ? Self.preparingMessage(kind, progress: nil) : "Starting capture…"
        let diagnostics = beginDiagnostics(engine: kind, liveTranscription: wantsLive, settings: [
            "language": language,
            "liveTranscription": String(wantsLive),
            "audioHandling": mode.rawValue,
            "speakerLabels": String(speakerLabelsEnabled),
        ])
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if wantsLive {
                    diagnostics?.record("preparation started", detail: nil)
                    await self.live.select(kind)
                    try Task.checkCancellation()
                    try await self.live.beginSession(language: language, progress: { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.state == .preparing else { return }
                            self.statusMessage = Self.preparingMessage(kind, progress: fraction)
                        }
                    })
                    if let info = self.live.lastPreparation {
                        diagnostics?.setPreparation(info)
                        diagnostics?.record("preparation finished", detail: String(format: "%.2f s, %@", info.loadSeconds, info.firstLoad ? "first load" : "cached"))
                    }
                }
                try Task.checkCancellation()
                guard self.state == .preparing else { return }
                self.startPreparedRecording(meeting: meeting, mode: mode)
            } catch {
                guard !Task.isCancelled else { return }
                diagnostics?.record("preparation failed", detail: error.localizedDescription)
                self.stopDiagnosticsSampling()
                self.live.cancelSession()
                self.state = .idle
                self.statusMessage = "Could not prepare \(kind.label): \(error.localizedDescription)"
            }
            self.startupTask = nil
        }
    }

    private static func preparingMessage(_ kind: LiveEngineKind, progress: Double?) -> String {
        guard let progress else { return "Preparing \(kind.label)…" }
        return "Preparing \(kind.label)… \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    private func startPreparedRecording(meeting: Meeting?, mode: AudioHandlingMode) {
        let now = Date()
        let session: RecordingSession
        do {
            session = try RecordingSession.create(now: now, meetingTitle: meeting?.title, mode: mode)
        } catch {
            statusMessage = "Could not create recording folder: \(error.localizedDescription)"
            diagnostics?.record("capture failed", detail: error.localizedDescription)
            stopDiagnosticsSampling()
            live.cancelSession()
            state = .idle
            return
        }
        currentSession = session
        activeMeeting = meeting
        activeMode = mode
        if diagnostics != nil { diagnosticsFolder = session.folderURL }

        // Clear any previous recording's transcription UI.
        clearTranscriptCard()

        // Silence monitor (auto-stop after prolonged silence on both channels).
        // Only armed when the user has auto-stop enabled.
        if silenceAutoStopEnabled {
            silenceMonitor = SilenceMonitor(
                thresholdDB: silenceThresholdDB,
                timeout: silenceTimeout,
                onTimeout: { [weak self] in
                    // onTimeout is invoked on MAIN per contract.
                    self?.saveAndStop(source: .silenceTimeout)
                }
            )
        } else {
            silenceMonitor = nil
        }

        // Wire level callbacks (called on audio threads -> hop to main).
        tap.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desktopLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }
        mic.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }

        // Start both captures.
        heartbeat?.resetLongest()
        do {
            try tap.start(writingTo: session.desktopURL)
            try mic.start(writingTo: session.micURL)
        } catch {
            statusMessage = "Could not start capture: \(error.localizedDescription)"
            diagnostics?.record("capture failed", detail: error.localizedDescription)
            stopDiagnosticsSampling()
            _ = tap.stop()
            _ = mic.stop()
            try? FileManager.default.removeItem(at: session.folderURL)
            currentSession = nil
            activeMeeting = nil
            silenceMonitor = nil
            live.cancelSession()
            state = .idle
            return
        }

        if let diagnostics {
            diagnostics.captureStarted(stall: heartbeat?.longestStall ?? 0)
            diagnostics.setPhase(.recording)
            watchFirstText(for: diagnostics)
        }

        silenceMonitor?.start()

        // Schedule a meeting-end alert when recording a known meeting.
        if let meeting {
            notifications.scheduleMeetingEndAlert(at: meeting.end, meetingTitle: meeting.title)
        }

        state = .recording
        statusMessage = nil
        startElapsedTimer(from: now)
        startCoach(session: session, meeting: meeting, mode: mode)
    }

    private func startCoach(session: RecordingSession, meeting: Meeting?, mode: AudioHandlingMode) {
        guard coachEnabled else { return }
        let live = self.live
        coach.start(
            folder: session.folderURL,
            language: String(transcriptionLanguage.prefix(2)),
            engine: recordingUsesLive ? liveEngine : nil,
            attendeeCount: meeting?.attendees.count,
            retainsAudio: mode.retainsAudio,
            lines: { live.confirmedLines }
        )
    }

    /// Change the audio-handling mode for the recording in progress. Downgrading to
    /// transcript-only closes and deletes the partial audio. Upgrading is refused,
    /// because the earlier audio was never written and a half-recording would
    /// misrepresent itself. Returns whether the change applied to this recording.
    @discardableResult
    func changeAudioHandling(to mode: AudioHandlingMode) -> Bool {
        guard state != .preparing && state != .finishing else { return false }
        guard state != .idle, let session = currentSession else {
            audioHandlingMode = mode
            return true
        }

        switch AudioHandlingChange.decide(
            from: activeMode,
            to: mode,
            liveTranscriptionEnabled: liveTranscriptionEnabled
        ) {
        case .refuseNothingProduced:
            statusMessage = "Transcript-only mode needs live transcription switched on."
            return false
        case .refuseUpgrade:
            statusMessage = "Cannot start keeping audio mid-recording: the earlier audio was never saved."
            return false
        case .apply:
            break
        }

        audioHandlingMode = mode

        if AudioHandlingChange.deletesPartialAudio(from: activeMode, to: mode) {
            coach.audioRetentionChanged(retains: false)
            tap.stopWriting()
            mic.stopWriting()
            for url in [session.desktopURL, session.micURL, session.outputURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            statusMessage = "Switched to transcript only, audio so far deleted"
        }

        activeMode = mode
        return true
    }

    func togglePause() {
        switch state {
        case .recording:
            tap.setPaused(true)
            mic.setPaused(true)
            coach.setPaused(true)
            silenceMonitor?.stop()
            state = .paused
        case .paused:
            tap.setPaused(false)
            mic.setPaused(false)
            coach.setPaused(false)
            silenceMonitor?.start()
            state = .recording
        case .idle, .preparing, .finishing:
            break
        }
    }

    func saveAndStop(source: StopSource = .panelSave) {
        guard isCapturing, let session = currentSession else { return }

        Self.log.notice("stop requested: \(source.label, privacy: .public)")
        diagnostics?.recordStopRequest(source)

        let coachSummary = coach.stop()
        let desktopResult = tap.stop()
        let micResult = mic.stop()

        cancelTimersAndAlerts()
        state = .finishing
        diagnostics?.setPhase(.finishing)
        sampleDiagnostics()

        let mode = activeMode
        let folderURL = session.folderURL
        let startedAt = session.startedAt
        let meetingTitle = activeMeeting?.title ?? session.meetingTitle
        let attendees = activeMeeting?.attendees ?? []

        // Finalize the live transcript (transcribes the remaining tail) in
        // parallel with the mix. Only awaited when a transcript will actually
        // be written, so an off toggle or a slow model never delays the save.
        let diagnostics = self.diagnostics
        let reportLanguage = transcriptionLanguage
        let pendingRestart = liveRestartTask
        pendingRestart?.cancel()
        liveRestartTask = nil
        let liveTask: Task<LiveSessionResult, Never>? = live.inRecordingSession
            ? Task { [live, weak self] in
                await pendingRestart?.value
                let finalizingSince = ProcessInfo.processInfo.systemUptime
                let result = await live.endSession()
                if let reason = result.stopReason { diagnostics?.recordStop(reason) }
                diagnostics?.record("finalized", detail: String(format: "%.2f s", ProcessInfo.processInfo.systemUptime - finalizingSince))
                self?.finishDiagnostics(diagnostics, folder: folderURL, language: reportLanguage)
                return result
            }
            : nil
        if liveTask == nil { finishDiagnostics(diagnostics, folder: folderURL, language: reportLanguage) }

        // No audio was ever written, so there is nothing to mix and nothing to polish.
        guard mode.retainsAudio,
              let outputURL = session.outputURL,
              let desktopURL = session.desktopURL,
              let micURL = session.micURL else {
            let pending = PendingTranscription(
                audioURL: nil,
                folderURL: folderURL,
                meetingTitle: meetingTitle,
                attendees: attendees,
                startedAt: startedAt,
                liveEngineName: recordingUsesLive ? live.engine.displayName : nil,
                diagnostics: diagnostics,
                reportLanguage: reportLanguage
            )
            claimTranscriptCard(pending, .running)
            statusMessage = "Finishing the transcript…"
            Task { [weak self] in
                guard let self else { return }
                defer { self.state = .idle }
                guard let liveResult = await liveTask?.value, !liveResult.isEmpty else {
                    self.transcriptionState = .failed("Nothing was transcribed, and no audio was kept.")
                    self.statusMessage = "Nothing to save"
                    if let coachSummary, coachSummary.ownSpeechSeconds < CoachController.keepLogOwnSeconds {
                        CoachController.removeArtifacts(in: folderURL)
                    }
                    if diagnostics == nil { Self.removeFolderIfEmpty(folderURL) }
                    self.refreshRecordings()
                    return
                }
                self.writeLiveTranscript(liveResult.lines, pending: pending, keepStatus: true)
                self.statusMessage = liveResult.complete
                    ? "Transcript saved, no audio kept"
                    : "Partial transcript saved; speech recognition stopped. No audio kept."
            }
            currentSession = nil
            activeMeeting = nil
            silenceMonitor = nil
            return
        }

        let pending = PendingTranscription(
            audioURL: outputURL,
            folderURL: folderURL,
            meetingTitle: meetingTitle,
            attendees: attendees,
            startedAt: startedAt,
            liveEngineName: recordingUsesLive ? live.engine.displayName : nil,
            diagnostics: diagnostics,
            reportLanguage: reportLanguage
        )
        let wantsTranscript = liveTranscriptionEnabled || mode.runsPolishPass
        let runsPolish = mode.runsPolishPass
        claimTranscriptCard(pending, wantsTranscript ? .running : .idle)
        statusMessage = liveTask == nil ? "Mixing…" : "Finishing the transcript…"

        // Mix off the main actor; keep raw CAFs regardless of outcome.
        let mix = Task.detached(priority: .utility) { () -> String? in
            do {
                try StereoMixer.mix(
                    desktopURL: desktopURL,
                    micURL: micURL,
                    desktopResult: desktopResult,
                    micResult: micResult,
                    outputURL: outputURL
                )
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        Task { [weak self] in
            let liveResult = await liveTask?.value
            guard let self else { return }
            if let liveResult, !liveResult.isEmpty {
                self.writeLiveTranscript(liveResult.lines, pending: pending, keepStatus: true)
                self.statusMessage = liveResult.complete
                    ? "Transcript saved, saving audio…"
                    : "Partial transcript saved; speech recognition stopped. Saving audio…"
            }
            self.state = .idle
            let mixError = await mix.value
            self.finishSavingAudio(
                pending,
                liveResult: liveResult,
                mixError: mixError,
                wantsTranscript: wantsTranscript,
                runsPolish: runsPolish
            )
        }

        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
    }

    private func finishSavingAudio(
        _ pending: PendingTranscription,
        liveResult: LiveSessionResult?,
        mixError: String?,
        wantsTranscript: Bool,
        runsPolish: Bool
    ) {
        refreshRecordings()
        let audioName = pending.audioURL?.lastPathComponent ?? "audio"
        let wroteLive = liveResult.map { !$0.isEmpty } ?? false
        if let mixError {
            Self.log.error("mix failed: \(mixError, privacy: .public)")
            let status = "Mix failed (raw files kept): \(mixError)"
            if wantsTranscript && !wroteLive {
                reportTranscriptionFailure(
                    "No live transcript, and the audio mix failed, so there is nothing to transcribe.",
                    status: status,
                    for: pending
                )
            } else {
                announce(status, about: pending)
            }
            return
        }
        if runsPolish {
            announce(wroteLive ? "Transcript saved; a local pass will refine it" : "Saved \(audioName); transcribing locally next", about: pending)
            transcriptions.enqueue(pending)
            return
        }
        guard wantsTranscript else {
            announce("Saved \(audioName) · transcription off", about: pending)
            return
        }
        guard wroteLive else {
            reportTranscriptionFailure(
                "Nothing was transcribed. The audio is saved, so you can transcribe it from Recent recordings.",
                status: "Saved \(audioName)",
                for: pending
            )
            return
        }
        announce(liveResult?.complete == false ? "Partial transcript and \(audioName) saved" : "Transcript and \(audioName) saved", about: pending)
    }

    func trashAndStop() {
        guard state != .finishing else { return }
        startupTask?.cancel()
        startupTask = nil
        if isSamplingDiagnostics {
            diagnostics?.record("discarded", detail: nil)
            stopDiagnosticsSampling()
        }
        guard state != .idle else {
            resetToIdle()
            return
        }

        coach.stop(discard: true)
        _ = tap.stop()
        _ = mic.stop()
        liveRestartTask?.cancel()
        liveRestartTask = nil
        live.cancelSession()

        cancelTimersAndAlerts()

        if let session = currentSession {
            try? FileManager.default.removeItem(at: session.folderURL)
        }

        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        statusMessage = "Discarded"
        clearTranscriptCard()
        refreshRecordings()
    }

    func refreshMeetings() {
        let now = Date()
        meetings = calendar.meetingsAroundNow(now)
    }

    /// The meeting currently in progress, if any. All-day events are already
    /// excluded from `meetings`, so this only matches timed meetings. Used as the
    /// default target for the main Record button so recording while you're in a
    /// meeting auto-tags it (folder name + end alert + transcript context).
    var currentMeeting: Meeting? {
        let now = Date()
        return meetings.first(where: { $0.isInProgress(now) })
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func startElapsedTimer(from start: Date) {
        recordingStartedAt = start
        elapsed = 0
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let started = self.recordingStartedAt else { return }
                if self.state == .recording {
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func beginDiagnostics(engine: LiveEngineKind, liveTranscription: Bool, settings: [String: String]) -> DiagnosticsRecorder? {
        stopDiagnosticsSampling()
        diagnosticsFolder = nil
        debugReportNotice = nil
        guard showDebugInfo else {
            diagnostics = nil
            return nil
        }
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        self.heartbeat = heartbeat
        let recorder = DiagnosticsRecorder(
            source: LiveSystemMetrics(),
            now: { ProcessInfo.processInfo.systemUptime },
            engine: engine,
            settings: settings,
            measuresSpeechService: liveTranscription && engine == .apple
        )
        recorder.record("record pressed", detail: nil)
        diagnostics = recorder
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sampleDiagnostics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
        return recorder
    }

    private func sampleDiagnostics() {
        guard isSamplingDiagnostics, let diagnostics, let heartbeat else { return }
        let stall = heartbeat.longestStall
        heartbeat.resetLongest()
        diagnostics.sample(engine: live.engine.diagnostics(), stall: stall, folder: diagnosticsFolder)
    }

    private func finishDiagnostics(_ recorder: DiagnosticsRecorder?, folder: URL, language: String?) {
        guard let recorder, diagnostics === recorder else { return }
        sampleDiagnostics()
        stopDiagnosticsSampling()
        persistDebugReport(recorder, folder: folder, language: language)
    }

    func persistDebugReport(_ recorder: DiagnosticsRecorder, folder: URL, language: String?) {
        do {
            try recorder.report(language: language).write(to: folder)
        } catch {
            debugReportNotice = "Could not write debug.json: \(error.localizedDescription)"
            appendDebugReportNotice()
        }
    }

    private func appendDebugReportNotice() {
        guard let notice = debugReportNotice, statusMessage?.hasSuffix(notice) != true else { return }
        statusMessage = [statusMessage, notice].compactMap { $0 }.joined(separator: " ")
    }

    private static func removeFolderIfEmpty(_ folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    private func stopDiagnosticsSampling() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        heartbeat?.stop()
        heartbeat = nil
    }

    private func watchFirstText(for recorder: DiagnosticsRecorder) {
        guard diagnostics === recorder, isSamplingDiagnostics else { return }
        recorder.noteText(hypothesis: live.hypothesis, finalLines: live.confirmedLines.count)
        guard !recorder.hasSeenFirstFinalText else { return }
        withObservationTracking {
            _ = live.hypothesis
            _ = live.confirmedLines
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchFirstText(for: recorder) }
        }
    }

    private func cancelTimersAndAlerts() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        silenceMonitor?.stop()
        notifications.cancelMeetingEndAlert()
    }

    private func resetToIdle() {
        cancelTimersAndAlerts()
        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        elapsed = 0
    }

    // MARK: - Transcription

    /// The speakers of the transcript currently shown, in order of first speech.
    var currentSpeakers: [(id: String, name: String)] {
        guard let document = lastDocument else { return [] }
        return document.speakerIDs.map { ($0, document.displayName(for: $0)) }
    }

    /// Rename one speaker: re-render the transcript from its source, and when voice
    /// profiles are on, teach the store what that person sounds like.
    ///
    /// The markdown is never patched. `transcript.json` is the source of truth, so a
    /// rename re-renders it and stays idempotent across repeated applications.
    func renameSpeaker(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let document = lastDocument,
              let pending = lastTranscription else { return }

        // The microphone speaker is identified structurally, so renaming it changes the
        // display label only and never creates or updates a profile.
        if voiceProfilesEnabled,
           id != SpeakerNaming.micSpeakerID,
           let centroidsID = document.speakerCentroidsID {
            do {
                try speakerStore.applyName(trimmed, toCluster: id, pendingID: centroidsID)
            } catch {
                Self.log.error("could not update voice profiles: \(error.localizedDescription)")
                statusMessage = "Renamed, but the voice profile could not be saved"
            }
        }

        writeTranscript(
            document: document.renamingSpeaker(id, to: trimmed),
            pending: pending,
            keepStatus: true
        )
    }

    /// Re-run the last transcription (offline, from the saved audio).
    func retryTranscription() {
        guard let pending = lastTranscription else { return }
        requestTranscription(pending)
    }

    private func requestTranscription(_ pending: PendingTranscription) {
        guard !transcriptions.contains(pending.id) else { return }
        if state == .idle { claimTranscriptCard(pending, .running) }
        transcriptions.enqueue(pending)
    }

    private func runTranscription(_ pending: PendingTranscription) async -> QueuedJobOutcome {
        defer { unloadOfflineModels() }
        guard let audioURL = pending.audioURL else {
            reportTranscriptionFailure(
                "This recording kept no audio, so it cannot be transcribed again.",
                status: nil,
                for: pending
            )
            return .finished
        }
        do {
            await unloadLiveEngineForPolish(pending)
            try Task.checkCancellation()
            if let whisperLoader {
                await whisperLoader(whisperModel)
            } else {
                await live.loadModel(whisperModel, downloadIfNeeded: true)
            }
            try Task.checkCancellation()
            let offline: OfflineTranscription
            if let fileTranscriber {
                offline = try await fileTranscriber(audioURL)
            } else {
                offline = try await live.transcribeFile(audioURL)
            }
            guard !offline.lines.isEmpty else {
                reportTranscriptionFailure(
                    "The model returned an empty transcript (silent audio?).",
                    status: "Transcription produced no text",
                    for: pending
                )
                return .finished
            }
            var names = offline.speakerNames
            var centroidsID: String?

            if voiceProfilesEnabled, !offline.clusters.isEmpty {
                let assignments = SpeakerNaming.resolve(
                    clusters: offline.clusters,
                    defaultNames: offline.speakerNames,
                    profiles: speakerStore.profiles
                )
                for (id, assignment) in assignments {
                    names[id] = assignment.name
                }

                // `appliedProfileID` stays nil even where a profile matched: an
                // automatic match names a speaker but never writes a voiceprint, so
                // the database only ever grows from a correction the user saw. It also
                // keeps confirming a correct guess an enrollment rather than a no-op.
                let voiceprints = PendingSpeakers(
                    id: UUID().uuidString,
                    createdAt: Date(),
                    clusters: offline.clusters.reduce(into: [:]) { result, entry in
                        result[entry.key] = PendingSpeakers.Cluster(
                            vector: entry.value.centroid,
                            speechSeconds: entry.value.speechSeconds,
                            appliedProfileID: nil
                        )
                    }
                )
                do {
                    try speakerStore.writePending(voiceprints)
                    centroidsID = voiceprints.id
                } catch {
                    Self.log.error("could not store voiceprints: \(error.localizedDescription)")
                }
            }

            var document = TranscriptDocument(
                meetingTitle: pending.meetingTitle,
                attendees: pending.attendees,
                startedAt: pending.startedAt,
                audioName: audioURL.lastPathComponent,
                model: live.loadedModelName ?? live.modelName,
                isPolished: true,
                lines: offline.lines.map {
                    TranscriptDocument.StoredLine(time: $0.time, text: $0.text, speakerID: $0.speaker)
                },
                speakerNames: names,
                speakerCentroidsID: centroidsID
            )
            document.liveEngine = pending.liveEngineName
            writeTranscript(document: document, pending: pending, keepStatus: false)
            return .finished
        } catch {
            if Task.isCancelled { return .interrupted }
            reportTranscriptionFailure(
                Self.describeTranscriptionError(error),
                status: "Transcription failed",
                for: pending
            )
            return .finished
        }
    }

    private func claimTranscriptCard(_ pending: PendingTranscription, _ cardState: TranscriptionState) {
        lastTranscription = pending
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastDocument = nil
        transcriptionState = cardState
    }

    private func clearTranscriptCard() {
        lastTranscription = nil
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastDocument = nil
        transcriptionState = .idle
    }

    private func cardShows(_ pending: PendingTranscription) -> Bool {
        if let shown = lastTranscription { return shown.id == pending.id }
        return state == .idle
    }

    private func announce(_ message: String, about pending: PendingTranscription) {
        guard state == .idle else { return }
        statusMessage = lastTranscription?.id == pending.id
            ? message
            : "\(pending.displayTitle): \(message)"
    }

    private func reportTranscriptionFailure(_ message: String, status: String?, for pending: PendingTranscription) {
        Self.log.error("transcription failed: \(message, privacy: .public)")
        guard cardShows(pending) else {
            announce("transcription failed. \(message)", about: pending)
            return
        }
        lastTranscription = pending
        transcriptionState = .failed(message)
        if let status { statusMessage = status }
    }

    var cardAwaitsLocalTranscription: Bool {
        guard let shown = lastTranscription else { return false }
        return transcriptions.contains(shown.id)
    }

    var cardProgressMessage: String {
        guard let shown = lastTranscription else { return "Finishing the transcript…" }
        if transcriptions.running?.id == shown.id { return "Transcribing locally…" }
        if transcriptions.contains(shown.id) { return "Waiting to transcribe locally…" }
        return "Finishing the transcript…"
    }

    var transcriptionQueueSummary: String? {
        let recording = state == .preparing || isCapturing
        if recording {
            return TranscriptionQueueSummary.text(running: nil, waiting: transcriptions.count, recording: true)
        }
        guard let running = transcriptions.running else { return nil }
        let othersWaiting = transcriptions.waiting.count
        if running.id == lastTranscription?.id, transcriptionState == .running, othersWaiting == 0 { return nil }
        return TranscriptionQueueSummary.text(running: running.displayTitle, waiting: othersWaiting, recording: false)
    }

    func unloadLiveEngineForPolish(_ pending: PendingTranscription) async {
        let wasLoaded = await live.releaseEngine()
        guard wasLoaded, showDebugInfo, let recorder = pending.diagnostics else { return }
        recorder.record("live engine unloaded for polish", detail: nil)
        persistDebugReport(recorder, folder: pending.folderURL, language: pending.reportLanguage)
    }

    private func unloadOfflineModels() {
        if let whisperUnloader {
            whisperUnloader()
        } else {
            live.unloadOfflineModels()
        }
    }

    func startPolishForTesting(
        audioURL: URL,
        folderURL: URL,
        meetingTitle: String? = nil,
        liveEngineName: String?,
        diagnostics: DiagnosticsRecorder?,
        reportLanguage: String?
    ) {
        requestTranscription(PendingTranscription(
            audioURL: audioURL,
            folderURL: folderURL,
            meetingTitle: meetingTitle,
            attendees: [],
            startedAt: Date(),
            liveEngineName: liveEngineName,
            diagnostics: diagnostics,
            reportLanguage: reportLanguage
        ))
    }

    /// Compose the transcript document, write it to transcript.md, and update
    /// the UI state. `keepStatus` leaves the status line untouched (used when a
    /// mix failure message must stay visible).
    /// Wrap live transcript lines in a document and write both files.
    private func writeLiveTranscript(
        _ lines: [TranscriptLine],
        pending: PendingTranscription,
        keepStatus: Bool
    ) {
        writeTranscript(
            document: TranscriptDocument(
                live: lines,
                meetingTitle: pending.meetingTitle,
                attendees: pending.attendees,
                startedAt: pending.startedAt,
                audioName: pending.audioURL?.lastPathComponent,
                model: live.engine.displayName
            ),
            pending: pending,
            keepStatus: keepStatus
        )
    }

    /// Write `transcript.json` and render `transcript.md` from it. The sidecar is written
    /// first so a crash between the two never leaves the markdown ahead of its source.
    private func writeTranscript(
        document: TranscriptDocument,
        pending: PendingTranscription,
        keepStatus: Bool
    ) {
        let markdownURL = pending.folderURL.appendingPathComponent("transcript.md")
        let jsonURL = pending.folderURL.appendingPathComponent("transcript.json")
        let markdown = document.renderMarkdown()
        do {
            try document.write(jsonTo: jsonURL)
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            reportTranscriptionFailure("Could not write the transcript: \(error.localizedDescription)", status: nil, for: pending)
            return
        }
        guard cardShows(pending) else {
            announce("transcript ready", about: pending)
            refreshRecordings()
            return
        }
        lastTranscription = pending
        lastTranscriptText = markdown
        lastTranscriptURL = markdownURL
        lastDocument = document
        transcriptionState = .done(markdownURL)
        if !keepStatus {
            statusMessage = "Transcript saved (transcript.md)"
        }
        refreshRecordings()
    }

    /// Copy the live transcript (confirmed lines + current hypothesis) while
    /// a recording is running.
    func copyLiveTranscript() {
        let text = live.transcript(includeHypothesis: true)
        guard !text.isEmpty else {
            statusMessage = "Nothing transcribed yet"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Live transcript copied"
    }

    /// Copy the transcript text to the clipboard.
    func copyTranscriptText() {
        guard let text = lastTranscriptText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Transcript text copied"
    }

    /// Copy the transcript *file* to the clipboard (paste into Finder / Mail / etc.).
    func copyTranscriptFile() {
        guard let url = lastTranscriptURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Transcript file copied"
    }

    /// Reveal the transcript in Finder.
    func revealTranscript() {
        guard let url = lastTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Recordings library

    /// Reload the recent-recordings list from disk.
    func refreshRecordings() {
        recentRecordings = RecordingsLibrary.recent(limit: 4)
    }

    /// Transcribe (or re-transcribe) an existing recording's audio.
    func transcribeExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = "No audio.m4a to transcribe in that folder."
            return
        }
        requestTranscription(PendingTranscription(
            audioURL: audio,
            folderURL: entry.folderURL,
            meetingTitle: entry.title,
            attendees: [],
            startedAt: entry.date
        ))
    }

    /// Put a file on the clipboard (paste into Finder / Mail / …).
    func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Copied \(url.lastPathComponent)"
    }

    /// Put a text file's contents on the clipboard.
    func copyTextOfFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Copied text of \(url.lastPathComponent)"
    }

    /// Reveal an arbitrary file/folder in Finder.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open ~/Documents/Recordings in Finder (creating it if needed).
    func openRecordingsFolder() {
        guard let root = RecordingsLibrary.recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func describeTranscriptionError(_ error: Error) -> String {
        if let e = error as? WhisperModelHost.HostError {
            return e.errorDescription ?? "Transcription failed."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Network error while fetching the model: \(ns.localizedDescription)"
        }
        return error.localizedDescription
    }
}
