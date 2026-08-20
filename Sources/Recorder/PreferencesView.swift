import SwiftUI

/// The content of the dedicated **Preferences window**.
///
/// The window itself is an AppKit `NSWindow` hosting this view — see
/// `PreferencesWindowController` for why we don't use SwiftUI's `Settings` scene.
///   - **General**: silence auto-stop.
///   - **Recording**: what a recording may leave on disk.
///   - **Transcription**: on-device model, language, live transcription.
///   - **Speakers**: labelling, voice profiles, and the saved voice list.
///
/// Grouped `Form`s in a `TabView` give the standard macOS System-Settings look.
/// The `TabView` is given a single fixed size so the host window doesn't clip
/// the taller tab or leave the window resizing as you switch tabs.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }

            RecordingPreferences()
                .tabItem { Label("Recording", systemImage: "waveform") }

            TranscriptionPreferences()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }

            SpeakerPreferences()
                .tabItem { Label("Speakers", systemImage: "person.wave.2") }
        }
        .frame(width: 480, height: 620)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Stop automatically after silence", isOn: $model.silenceAutoStopEnabled)

                if model.silenceAutoStopEnabled {
                    Stepper(
                        value: Binding(
                            get: { Int((model.silenceTimeout / 60).rounded()) },
                            set: { model.silenceTimeout = TimeInterval(max(1, $0) * 60) }
                        ),
                        in: 1...60
                    ) {
                        Text("After \(Int((model.silenceTimeout / 60).rounded())) min of silence on both channels")
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence threshold")
                            Spacer()
                            Text("\(Int(model.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.silenceThresholdDB, in: -80 ... -20, step: 1)
                        Text("A channel counts as silent below this level. Lower = more tolerant of quiet rooms.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auto-stop")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

private struct RecordingPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Audio handling", selection: $model.audioHandlingMode) {
                    ForEach(AudioHandlingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(model.audioHandlingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.audioHandlingMode.producesNothing(
                    liveTranscriptionEnabled: model.liveTranscriptionEnabled
                ) {
                    Label(
                        "Transcript-only mode needs live transcription switched on, or nothing would be saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Audio handling")
            } footer: {
                Text("Transcript-only never writes audio to disk, not even temporarily, so a crash cannot leave a recording behind. The high-quality pass needs the audio file, so it is only available when audio is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

private struct TranscriptionPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Model", selection: $model.whisperModel) {
                    ForEach(WhisperModelOption.catalog) { option in
                        Text("\(option.label) · \(option.detail)").tag(option.id)
                    }
                }
                engineStatus
            } header: {
                Text("On-device model")
            } footer: {
                Text("Runs fully on this Mac via WhisperKit (CoreML). Each model is downloaded once from Hugging Face into Application Support; switching later is instant. All listed models handle German and English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: $model.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.options, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Text("Auto-detect re-checks the language for every window, which handles meetings that mix languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            Section {
                Toggle("Stream the transcript live while recording", isOn: $model.liveTranscriptionEnabled)
                Text("Shows the transcript in the panel as it is spoken, with a copy button. Uses more CPU while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Live transcription")
            }

        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch model.live.engineState {
        case .downloading(let name, let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                Text("Downloading \(WhisperModelOption.label(for: name))… \(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading(let name):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading \(WhisperModelOption.label(for: name))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            if let message = model.live.loadFailureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Model loaded and ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded:
            Label("Downloads when you start recording or transcribing", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unloaded:
            EmptyView()
        }
    }
}

// MARK: - Speakers

private struct SpeakerPreferences: View {
    @Environment(RecorderModel.self) private var model
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Label speakers", isOn: $model.speakerLabelsEnabled)
                Text("Live lines are labeled You (microphone) or Them (desktop audio) from the channel layout. Transcribing a saved file transcribes each channel on its own, so your own voice is always You, and the other voices are separated on-device and labeled Speaker 1, 2, ... (~50 MB one-time model download).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Labels")
            }

            Section {
                Toggle("Match voices to saved profiles", isOn: $model.voiceProfilesEnabled)
                Text("Renaming a speaker stores what that voice sounds like, so the same person is recognised in later recordings. A voiceprint is biometric data under GDPR Art. 9. It is kept in Application Support, never in the recording folder, so a transcript you share carries none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Voice profiles")
            }

            Section {
                if model.speakerStore.profiles.isEmpty {
                    Text("No saved voices yet. Rename a speaker in a finished transcript to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.speakerStore.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Spacer()
                            Text("\(profile.centroids.count) sample\(profile.centroids.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                try? model.speakerStore.delete(profileID: profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete \(profile.name)'s voice profile")
                        }
                    }

                    Button("Delete all voice data", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .confirmationDialog(
                        "Delete every saved voiceprint?",
                        isPresented: $confirmingDeleteAll,
                        titleVisibility: .visible
                    ) {
                        Button("Delete all voice data", role: .destructive) {
                            try? model.speakerStore.deleteAllVoiceData()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes every profile and every stored voiceprint, including ones waiting to be named. Transcripts keep the names already written into them.")
                    }
                }
            } header: {
                Text("Saved voices")
            }
        }
        .formStyle(.grouped)
    }
}
