import SwiftUI

/// The content of the dedicated **Preferences window**.
///
/// The window itself is an AppKit `NSWindow` hosting this view — see
/// `PreferencesWindowController` for why we don't use SwiftUI's `Settings` scene.
///   - **General**: silence auto-stop.
///   - **Transcription**: on-device model, language, live transcription, and
///     whether transcript.md is written automatically after saving.
///
/// Grouped `Form`s in a `TabView` give the standard macOS System-Settings look.
/// The `TabView` is given a single fixed size so the host window doesn't clip
/// the taller tab or leave the window resizing as you switch tabs.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }

            TranscriptionPreferences()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
        }
        .frame(width: 480, height: 560)
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

            Section {
                Toggle("Label speakers", isOn: $model.speakerLabelsEnabled)
                Text("Live lines are labeled You (microphone) or Them (desktop audio) from the channel layout. Transcribing a saved file runs on-device diarization instead and labels voices Speaker 1, 2, ... (~50 MB one-time model download).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speakers")
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
