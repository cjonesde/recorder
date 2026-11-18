import Foundation

public enum CoachLimits {
    public static let paceSeconds = PaceDetector.consecutiveTicks
    public static let soShare = SentenceStartCounter.threshold
    public static let soWindow = SentenceStartCounter.windowSentences
    public static let soMinimum = SentenceStartCounter.minimumSentences
    public static let endingsWindow = EndingsDetector.window
    public static let risingSemitones = IntonationConstants.riseSemitones
    public static let endingsRefractory = EndingsDetector.refractory
    public static let trailingCount = EndingsDetector.trailingCount
    public static let raisedPitchST = ProsodyProxies.pitchThresholdST
    public static let raisedLevelDB = ProsodyProxies.levelThresholdDB
    public static let raisedSeconds = ProsodyProxies.consecutiveTicks
    public static let talkShareMinimumSeconds = TurnTaking.minimumSeconds
}
