import Foundation

public struct CoachTuning: Sendable, Equatable {
    public var analysisRate = 16_000.0
    public var hop = 160
    public var levelWindow = 480
    public var pitchFloor = 60.0
    public var pitchCeiling = 500.0
    public var yinThreshold = 0.15
    public var yinWindow = 480
    public var speechAboveFloorDB = 10.0
    public var speechMinimumDB = -60.0
    public var floorRiseDBPerSecond = 0.5
    public var tapQuietDB = -50.0
    public var gateLead = 0.3
    public var gateHangover = 0.5
    public var overlapMarginDB = 6.0
    public var desktopStallSeconds = 2.0
    public var cueSeconds = 4.0
    public var clipBefore = 6.0
    public var clipAfter = 2.0

    public static let `default` = CoachTuning()

    public init() {}

    var frameSeconds: Double { Double(hop) / analysisRate }
    var leadFrames: Int { Int((gateLead / frameSeconds).rounded()) }
    var hangoverFrames: Int { Int((gateHangover / frameSeconds).rounded()) }
    var stallFrames: Int { Int((desktopStallSeconds / frameSeconds).rounded()) }

    func frames(_ seconds: Double) -> Int { Int((seconds / frameSeconds).rounded()) }
}
