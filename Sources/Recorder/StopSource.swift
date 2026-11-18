enum StopSource: Equatable, Sendable {
    case panelSave
    case meetingEndNotification
    case silenceTimeout
    case liveEngineFailure(String)
    case captureFailure(String)

    var label: String {
        switch self {
        case .panelSave: "panel save button"
        case .meetingEndNotification: "meeting-end notification"
        case .silenceTimeout: "silence timeout"
        case .liveEngineFailure(let detail): "live engine failure: \(detail)"
        case .captureFailure(let detail): "capture failure: \(detail)"
        }
    }
}
