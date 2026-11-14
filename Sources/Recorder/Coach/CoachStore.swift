import Foundation
import VoiceCoach

@MainActor
final class CoachStore {
    static let shared = CoachStore()

    let directory: URL
    private(set) var loaded = false
    private var cached = CoachBaseline()

    init(directory: URL? = nil) {
        self.directory = directory ?? CoachStore.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Recorder", isDirectory: true)
    }

    var baselineURL: URL { directory.appendingPathComponent("coach-baseline.json") }

    var baseline: CoachBaseline {
        get {
            if !loaded {
                loaded = true
                if let data = try? Data(contentsOf: baselineURL),
                   let decoded = try? JSONDecoder().decode(CoachBaseline.self, from: data) {
                    cached = decoded
                }
            }
            return cached
        }
        set {
            loaded = true
            cached = newValue
        }
    }

    func nextSessionIndex() -> Int {
        let next = Preferences.coachSessionCount + 1
        Preferences.coachSessionCount = next
        return next
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(baseline) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: baselineURL, options: .atomic)
    }
}
