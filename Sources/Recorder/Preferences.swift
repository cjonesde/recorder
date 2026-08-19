import Foundation

/// Typed wrapper over `UserDefaults` for the app's persisted preferences.
///
/// Keys + sensible defaults live here in one place; `RecorderModel` mirrors these
/// into `@Observable` properties (loading them at launch, writing them back on
/// change) so the UI can bind to them while disk persistence stays out of band.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let silenceTimeout      = "silenceTimeoutSeconds"
        static let silenceThresholdDB  = "silenceThresholdDB"
        static let silenceAutoStop     = "silenceAutoStopEnabled"
        static let autoTranscribe      = "autoTranscribeAfterSave"
        static let whisperModel        = "whisperModelName"
        static let language            = "transcriptionLanguage"
        static let liveTranscription   = "liveTranscriptionEnabled"
    }

    /// Seconds of two-channel silence before a recording auto-stops. Default 300 (5 min).
    static var silenceTimeout: TimeInterval {
        get { defaults.object(forKey: Key.silenceTimeout) == nil ? 300 : defaults.double(forKey: Key.silenceTimeout) }
        set { defaults.set(newValue, forKey: Key.silenceTimeout) }
    }

    /// dBFS below which a channel counts as silent. Default -50.
    static var silenceThresholdDB: Float {
        get { defaults.object(forKey: Key.silenceThresholdDB) == nil ? -50 : defaults.float(forKey: Key.silenceThresholdDB) }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    /// Whether silence auto-stop is active at all. Default true.
    static var silenceAutoStop: Bool {
        get { defaults.object(forKey: Key.silenceAutoStop) == nil ? true : defaults.bool(forKey: Key.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Key.silenceAutoStop) }
    }

    /// Whether to write `transcript.md` automatically once a recording is saved.
    /// Uses the live transcript when one exists, otherwise transcribes the saved
    /// audio with the local model. Default true.
    static var autoTranscribe: Bool {
        get { defaults.object(forKey: Key.autoTranscribe) == nil ? true : defaults.bool(forKey: Key.autoTranscribe) }
        set { defaults.set(newValue, forKey: Key.autoTranscribe) }
    }

    /// Selected on-device Whisper model (a WhisperKit variant name from
    /// `WhisperModelOption.catalog`).
    static var whisperModel: String {
        get {
            let stored = defaults.string(forKey: Key.whisperModel) ?? ""
            return stored.isEmpty ? WhisperModelOption.defaultModelID : stored
        }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    /// Transcription language: an ISO code ("de", "en", ...) or "auto" to
    /// detect per window. Default "auto".
    static var language: String {
        get {
            let stored = defaults.string(forKey: Key.language) ?? ""
            return stored.isEmpty ? "auto" : stored
        }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// Whether the transcript streams live into the panel while recording.
    /// Default true.
    static var liveTranscription: Bool {
        get { defaults.object(forKey: Key.liveTranscription) == nil ? true : defaults.bool(forKey: Key.liveTranscription) }
        set { defaults.set(newValue, forKey: Key.liveTranscription) }
    }
}
