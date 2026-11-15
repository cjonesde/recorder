import Foundation
import VoiceCoach

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
        static let audioHandling       = "audioHandlingMode"
        static let whisperModel        = "whisperModelName"
        static let language            = "transcriptionLanguage"
        static let liveTranscription   = "liveTranscriptionEnabled"
        static let speakerLabels       = "speakerLabelsEnabled"
        static let voiceProfiles       = "voiceProfilesEnabled"
        static let liveEngine          = "liveEngine"
        static let showDebugInfo       = "showDebugInfo"
        static let coachEnabled        = "coachEnabled"
        static let coachWithholding    = "coachWithholding"
        static let coachPromoted       = "coachPromoted"
        static let coachSessionCount   = "coachSessionCount"
        static let coachHUDOrigin      = "coachHUDOrigin"
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

    /// What a recording may leave on disk. New installations save only text.
    static var audioHandlingMode: AudioHandlingMode {
        get {
            guard let raw = defaults.string(forKey: Key.audioHandling),
                  let mode = AudioHandlingMode(rawValue: raw) else { return .default }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.audioHandling) }
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

    /// A selected Apple locale. Legacy auto-detect resolves to the system language.
    static var language: String {
        get {
            let stored = defaults.string(forKey: Key.language) ?? ""
            return TranscriptionLanguage.selection(for: stored)
        }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// Whether the transcript streams live into the panel while recording.
    /// Default true.
    static var liveTranscription: Bool {
        get { defaults.object(forKey: Key.liveTranscription) == nil ? true : defaults.bool(forKey: Key.liveTranscription) }
        set { defaults.set(newValue, forKey: Key.liveTranscription) }
    }

    /// Whether transcripts carry speaker labels: You/Them by channel while
    /// live, Speaker N via on-device diarization for saved files. Default true.
    static var speakerLabels: Bool {
        get { defaults.object(forKey: Key.speakerLabels) == nil ? true : defaults.bool(forKey: Key.speakerLabels) }
        set { defaults.set(newValue, forKey: Key.speakerLabels) }
    }

    /// Whether saved voiceprints are matched against new recordings, and whether renaming
    /// a speaker stores that voice. Default false: an embedding is biometric data under
    /// GDPR Art. 9, so this stays opt-in.
    static var voiceProfiles: Bool {
        get { defaults.bool(forKey: Key.voiceProfiles) }
        set { defaults.set(newValue, forKey: Key.voiceProfiles) }
    }

    static var liveEngine: LiveEngineKind {
        get {
            guard let raw = defaults.string(forKey: Key.liveEngine),
                  let kind = LiveEngineKind(rawValue: raw) else { return .default }
            return kind
        }
        set { defaults.set(newValue.rawValue, forKey: Key.liveEngine) }
    }

    static var showDebugInfo: Bool {
        get { defaults.bool(forKey: Key.showDebugInfo) }
        set { defaults.set(newValue, forKey: Key.showDebugInfo) }
    }

    static var coachEnabled: Bool {
        get { defaults.bool(forKey: Key.coachEnabled) }
        set { defaults.set(newValue, forKey: Key.coachEnabled) }
    }

    static var coachWithholding: Bool {
        get { defaults.object(forKey: Key.coachWithholding) == nil ? true : defaults.bool(forKey: Key.coachWithholding) }
        set { defaults.set(newValue, forKey: Key.coachWithholding) }
    }

    static var coachPromoted: Set<DetectorID> {
        get {
            guard let raw = defaults.array(forKey: Key.coachPromoted) as? [String] else { return [.pace] }
            return Set(raw.compactMap(DetectorID.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.coachPromoted) }
    }

    static var coachSessionCount: Int {
        get { defaults.integer(forKey: Key.coachSessionCount) }
        set { defaults.set(newValue, forKey: Key.coachSessionCount) }
    }

    static var coachHUDOrigin: CGPoint? {
        get {
            guard let raw = defaults.array(forKey: Key.coachHUDOrigin) as? [Double], raw.count == 2 else { return nil }
            return CGPoint(x: raw[0], y: raw[1])
        }
        set {
            if let newValue {
                defaults.set([Double(newValue.x), Double(newValue.y)], forKey: Key.coachHUDOrigin)
            } else {
                defaults.removeObject(forKey: Key.coachHUDOrigin)
            }
        }
    }
}
