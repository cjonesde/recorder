import Foundation
import Observation
import AppKit
import os

/// Owns every component and wires their callbacks. The model is @MainActor;
/// audio-thread callbacks hop to main via DispatchQueue.main.async before touching state.
@MainActor
@Observable
final class RecorderModel {

    // MARK: - Observable UI state

    var state: RecorderState = .idle
    var desktopLevel: Float = 0      // 0..1 meter (LEFT / desktop)
    var micLevel: Float = 0          // 0..1 meter (RIGHT / mic)
    var meetings: [Meeting] = []
    var currentSession: RecordingSession? = nil
    var elapsed: TimeInterval = 0
    var statusMessage: String? = nil

    /// On-device transcription engines. Exposed so the panel can
    /// render the live transcript and engine status directly.
    let live: LocalTranscriptionEngine

    init(engineFactory: @escaping LocalTranscriptionEngine.EngineFactory = LocalTranscriptionEngine.defaultFactory) {
        live = LocalTranscriptionEngine(factory: engineFactory)
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

    var canStartRecording: Bool { state == .idle && transcriptionState != .running }
    var canChangeLiveEngine: Bool { state == .idle && transcriptionState != .running }
    var isCapturing: Bool { state == .recording || state == .paused }

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    /// The meeting (if any) the current recording is attached to — kept so its
    /// title + attendees are available as transcript context at save time.
    @ObservationIgnored private var activeMeeting: Meeting?

    /// The mode the recording in progress actually started with, which can differ from
    /// `audioHandlingMode` after a mid-recording downgrade.
    @ObservationIgnored private var activeMode: AudioHandlingMode = .default

    /// Everything needed to (re)run a transcription, captured at save time.
    private struct PendingTranscription {
        let audioURL: URL?
        let folderURL: URL
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date
    }
    @ObservationIgnored private var lastTranscription: PendingTranscription?

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
                self.saveAndStop()
            }
        }

        configureCaptures()
    }

    /// Wire the capture callbacks and load the selected model. Split out of `onAppear`
    /// so it can run without the permission and notification setup, which needs a real
    /// app bundle and therefore cannot run under the test runner.
    func configureCaptures() {
        // Surface fatal capture errors to the UI.
        tap.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleCaptureFailure(error)
            }
        }
        mic.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleCaptureFailure(error)
            }
        }

        // Feed both captures into the live-transcription inbox. The inbox is a
        // no-op outside an active session, so the hooks stay wired permanently.
        let router = live.router
        tap.onSamples = { samples, count, rate in
            router.ingest(.desktop, samples, count: count, rate: rate)
        }
        mic.onSamples = { samples, count, rate in
            router.ingest(.mic, samples, count: count, rate: rate)
        }

        live.onFailure = { [weak self] in
            guard let self else { return }
            if let reason = self.live.engine.stopReason { self.diagnostics?.recordStop(reason) }
            guard self.isCapturing else { return }
            self.saveAndStop()
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        guard isCapturing else { return }
        diagnostics?.record("capture failed", detail: error.localizedDescription)
        if let stop = error as? LiveStopError { diagnostics?.recordStop(stop.reason) }
        if live.isSessionActive { live.engine.captureFailed(error) }
        else { saveAndStop() }
        statusMessage = "Capture stopped: \(error.localizedDescription)"
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
    }

    // MARK: - Recording control

    func startRecording(meeting: Meeting?) {
        guard canStartRecording else { return }

        let mode = audioHandlingMode
        guard !mode.producesNothing(liveTranscriptionEnabled: liveTranscriptionEnabled) else {
            statusMessage = "Transcript-only mode needs live transcription switched on, otherwise nothing would be saved."
            return
        }

        let language = transcriptionLanguage
        let wantsLive = liveTranscriptionEnabled
        let kind = liveEngine
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
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil

        // Silence monitor (auto-stop after prolonged silence on both channels).
        // Only armed when the user has auto-stop enabled.
        if silenceAutoStopEnabled {
            silenceMonitor = SilenceMonitor(
                thresholdDB: silenceThresholdDB,
                timeout: silenceTimeout,
                onTimeout: { [weak self] in
                    // onTimeout is invoked on MAIN per contract.
                    self?.saveAndStop()
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
            silenceMonitor?.stop()
            state = .paused
        case .paused:
            tap.setPaused(false)
            mic.setPaused(false)
            silenceMonitor?.start()
            state = .recording
        case .idle, .preparing, .finishing:
            break
        }
    }

    func saveAndStop() {
        guard isCapturing, let session = currentSession else { return }

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
        let liveTask: Task<LiveSessionResult, Never>? = live.isSessionActive
            ? Task { [live, weak self] in
                let finalizingSince = ProcessInfo.processInfo.systemUptime
                let result = await live.endSession()
                if let reason = result.stopReason { diagnostics?.recordStop(reason) }
                diagnostics?.record("finalized", detail: String(format: "%.2f s", ProcessInfo.processInfo.systemUptime - finalizingSince))
                self?.finishDiagnostics(diagnostics)
                return result
            }
            : nil
        if liveTask == nil { finishDiagnostics(diagnostics) }

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
                startedAt: startedAt
            )
            lastTranscription = pending
            transcriptionState = .running
            statusMessage = "Finishing the transcript…"
            Task { [weak self] in
                guard let self else { return }
                defer { self.state = .idle }
                guard let liveResult = await liveTask?.value, !liveResult.isEmpty else {
                    self.transcriptionState = .failed("Nothing was transcribed, and no audio was kept.")
                    self.statusMessage = "Nothing to save"
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

        statusMessage = "Mixing…"
        let pending = PendingTranscription(
            audioURL: outputURL,
            folderURL: folderURL,
            meetingTitle: meetingTitle,
            attendees: attendees,
            startedAt: startedAt
        )
        let wantsTranscript = liveTranscriptionEnabled || mode.runsPolishPass
        if wantsTranscript {
            transcriptionState = .running
        }

        // Mix off the main actor; keep raw CAFs regardless of outcome.
        Task.detached(priority: .utility) {
            var mixError: Error? = nil
            do {
                try StereoMixer.mix(
                    desktopURL: desktopURL,
                    micURL: micURL,
                    desktopResult: desktopResult,
                    micResult: micResult,
                    outputURL: outputURL
                )
            } catch {
                mixError = error
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastTranscription = pending
                self.statusMessage = mixError == nil
                    ? "Saved \(outputURL.lastPathComponent)"
                    : "Mix failed (raw files kept): \(mixError!.localizedDescription)"
                self.refreshRecordings()
                if !wantsTranscript {
                    self.state = .idle
                    self.transcriptionState = .idle
                    if mixError == nil {
                        self.statusMessage = "Saved \(outputURL.lastPathComponent) · transcription off"
                    }
                }
            }
            guard wantsTranscript else { return }

            let liveResult = await liveTask?.value

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.state = .idle
                if let liveResult, !liveResult.isEmpty, liveResult.complete {
                    self.writeLiveTranscript(liveResult.lines, pending: pending, keepStatus: mixError != nil)
                    if mode.runsPolishPass, mixError == nil { self.startTranscription(pending) }
                } else if mixError == nil, mode.runsPolishPass {
                    self.startTranscription(pending)
                } else if let liveResult, !liveResult.isEmpty {
                    self.writeLiveTranscript(liveResult.lines, pending: pending, keepStatus: true)
                } else {
                    self.transcriptionState = .failed(
                        "No live transcript, and the audio mix failed, so there is nothing to transcribe."
                    )
                }
            }
        }

        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
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

        _ = tap.stop()
        _ = mic.stop()
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
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil
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

    private func finishDiagnostics(_ recorder: DiagnosticsRecorder?) {
        guard let recorder, diagnostics === recorder else { return }
        sampleDiagnostics()
        stopDiagnosticsSampling()
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
        startTranscription(pending)
    }

    /// Transcribe a saved recording's audio with the local model.
    private func startTranscription(_ pending: PendingTranscription) {
        lastTranscription = pending
        lastTranscriptText = nil
        lastTranscriptURL = nil

        transcriptionState = .running
        statusMessage = "Transcribing locally…"

        Task { [weak self] in
            guard let self else { return }
            guard let audioURL = pending.audioURL else {
                self.transcriptionState = .failed("This recording kept no audio, so it cannot be transcribed again.")
                return
            }
            do {
                await self.live.loadModel(self.whisperModel, downloadIfNeeded: true)
                let offline = try await self.live.transcribeFile(audioURL)
                guard !offline.lines.isEmpty else {
                    self.transcriptionState = .failed("The model returned an empty transcript (silent audio?).")
                    self.statusMessage = "Transcription produced no text"
                    return
                }
                var names = offline.speakerNames
                var centroidsID: String?

                if self.voiceProfilesEnabled, !offline.clusters.isEmpty {
                    let assignments = SpeakerNaming.resolve(
                        clusters: offline.clusters,
                        defaultNames: offline.speakerNames,
                        profiles: self.speakerStore.profiles
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
                        try self.speakerStore.writePending(voiceprints)
                        centroidsID = voiceprints.id
                    } catch {
                        Self.log.error("could not store voiceprints: \(error.localizedDescription)")
                    }
                }

                let document = TranscriptDocument(
                    meetingTitle: pending.meetingTitle,
                    attendees: pending.attendees,
                    startedAt: pending.startedAt,
                    audioName: audioURL.lastPathComponent,
                    model: self.live.loadedModelName ?? self.live.modelName,
                    isPolished: true,
                    lines: offline.lines.map {
                        TranscriptDocument.StoredLine(time: $0.time, text: $0.text, speakerID: $0.speaker)
                    },
                    speakerNames: names,
                    speakerCentroidsID: centroidsID
                )
                self.writeTranscript(document: document, pending: pending, keepStatus: false)
            } catch {
                let message = RecorderModel.describeTranscriptionError(error)
                self.transcriptionState = .failed(message)
                self.statusMessage = "Transcription failed"
            }
        }
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
            transcriptionState = .failed("Could not write the transcript: \(error.localizedDescription)")
            return
        }
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
        startTranscription(PendingTranscription(
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
