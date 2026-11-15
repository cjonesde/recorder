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

enum CoachLabel: String, Codable, CaseIterable {
    case right
    case falseAlarm
}

struct LabelTally: Equatable {
    var labelled = 0
    var right = 0

    var precision: Double? { labelled > 0 ? Double(right) / Double(labelled) : nil }
}

struct CoachTriggerRecord: Identifiable, Equatable {
    let id: String
    let detector: DetectorID
    let t: Double
    let shown: Bool
    let note: String
    let folder: URL
    let clipURL: URL?
    var label: CoachLabel?
}

enum CoachLabels {
    static let fileName = "coach-labels.json"
    static let minimumLabelled = 20
    static let minimumPrecision = 0.9

    static func canPromote(_ tally: LabelTally) -> Bool {
        tally.labelled >= minimumLabelled && (tally.precision ?? 0) >= minimumPrecision
    }

    static func labels(in folder: URL) -> [String: CoachLabel] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let decoded = try? JSONDecoder().decode([String: CoachLabel].self, from: data) else { return [:] }
        return decoded
    }

    static func setLabel(_ label: CoachLabel?, for id: String, in folder: URL) {
        var all = labels(in: folder)
        all[id] = label
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static func triggers(in folder: URL) -> [CoachTriggerRecord] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(CoachPump.logName), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let labels = labels(in: folder)
        let clips = folder.appendingPathComponent(CoachPump.clipsFolderName, isDirectory: true)
        return text.split(separator: "\n").compactMap { line -> CoachTriggerRecord? in
            guard let event = try? decoder.decode(CoachEvent.self, from: Data(line.utf8)),
                  event.kind == .trigger, let id = event.id, let detector = event.detector else { return nil }
            let clip = clips.appendingPathComponent("\(id).m4a")
            return CoachTriggerRecord(
                id: id,
                detector: detector,
                t: event.t,
                shown: event.shown ?? false,
                note: event.note ?? "",
                folder: folder,
                clipURL: FileManager.default.fileExists(atPath: clip.path) ? clip : nil,
                label: labels[id]
            )
        }
    }

    static func sessionFolders(root: URL?) -> [URL] {
        guard let root, let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let withLogs = children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(CoachPump.logName).path) }
        func modified(_ url: URL) -> Date {
            (try? url.appendingPathComponent(CoachPump.logName).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return withLogs.sorted { modified($0) > modified($1) }
    }

    static func tallies(root: URL?) -> [DetectorID: LabelTally] {
        var tallies: [DetectorID: LabelTally] = [:]
        for folder in sessionFolders(root: root) {
            for record in triggers(in: folder) {
                guard let label = record.label else { continue }
                tallies[record.detector, default: LabelTally()].labelled += 1
                if label == .right { tallies[record.detector, default: LabelTally()].right += 1 }
            }
        }
        return tallies
    }
}
