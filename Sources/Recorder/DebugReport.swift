import Foundation
import Darwin

struct DebugReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let fileName = "debug.json"

    let schemaVersion: Int
    let appCommit: String?
    let machineModel: String
    let physicalMemoryBytes: UInt64
    let osVersion: String
    let engine: LiveEngineKind
    let engineSettings: [String: String]
    let language: String?
    let preparation: PreparationInfo?
    let samples: [DiagnosticSample]
    let events: [DebugEvent]
    let stops: [LiveStopReason]
    let summary: [String: Double]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, appCommit, machineModel, physicalMemoryBytes, osVersion, engine
        case engineSettings, language, preparation, samples, events, stops, summary
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(appCommit, forKey: .appCommit)
        try container.encode(machineModel, forKey: .machineModel)
        try container.encode(physicalMemoryBytes, forKey: .physicalMemoryBytes)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(engine, forKey: .engine)
        try container.encode(engineSettings, forKey: .engineSettings)
        try container.encode(language, forKey: .language)
        try container.encode(preparation, forKey: .preparation)
        try container.encode(samples, forKey: .samples)
        try container.encode(events, forKey: .events)
        try container.encode(stops, forKey: .stops)
        try container.encode(summary, forKey: .summary)
    }

    static let commitInfoKey = "RecorderGitCommit"

    static func bundledCommit(from info: [String: Any]?) -> String? {
        guard let commit = info?[commitInfoKey] as? String, !commit.isEmpty else { return nil }
        return commit
    }

    static func currentMachineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    func summaryText() -> String {
        let loadTime = preparation.map { String(format: "%.2f s (%@)", $0.loadSeconds, $0.firstLoad ? "first load" : "cached") } ?? "unknown"
        let speechPeak = samples.compactMap(\.reading.speechServiceFootprintBytes).max()
        let heldPeak = samples.compactMap { sample in sample.heldAudioSeconds.map { (seconds: $0, quality: sample.heldAudioQuality) } }
            .max { $0.seconds < $1.seconds }
        let stopsText = stops.isEmpty ? "none" : stops.map(\.rawValue).joined(separator: ", ")
        let behindRough = summary["medianBehindRough"].map { String(format: "median %.2f s", $0) } ?? "unknown"
        let behindFinal = summary["medianBehindFinal"].map { median in
            summary["maxBehindFinal"].map { String(format: "median %.2f s, max %.2f s", median, $0) } ?? String(format: "median %.2f s", median)
        } ?? "unknown"
        return [
            "Engine: \(engine.label)",
            "Machine: \(machineModel), \(Self.megabytes(physicalMemoryBytes)) RAM, \(osVersion)",
            "Load time: \(loadTime)",
            "First word: \(Self.seconds(summary["firstWordSeconds"]))",
            "Text behind (rough): \(behindRough)",
            "Text behind (final): \(behindFinal)",
            "Peak Recorder memory: \(summary["peakFootprintBytes"].map { Self.megabytes(UInt64($0)) } ?? "unknown")",
            "Peak speech service memory: \(speechPeak.map(Self.megabytes) ?? "unknown")",
            "Swap growth: \(summary["swapGrowthBytes"].map { Self.signedMegabytes(Int64($0)) } ?? "unknown")",
            "Peak held audio: \(heldPeak.map { String(format: "%.2f s (%@)", $0.seconds, $0.quality.rawValue) } ?? "unknown")",
            "Longest stall: \(Self.seconds(summary["longestStallSeconds"]))",
            "Stops: \(stopsText)",
        ].joined(separator: "\n")
    }

    private static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "unknown"
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private static func signedMegabytes(_ bytes: Int64) -> String {
        String(format: "%+.0f MB", Double(bytes) / 1_048_576)
    }
}

extension DiagnosticsRecorder {
    func report(language: String?) -> DebugReport {
        DebugReport(
            schemaVersion: DebugReport.currentSchemaVersion,
            appCommit: DebugReport.bundledCommit(from: Bundle.main.infoDictionary),
            machineModel: DebugReport.currentMachineModel(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            engine: engine,
            engineSettings: settings,
            language: language,
            preparation: preparation,
            samples: samples,
            events: events,
            stops: stops,
            summary: summaryValues()
        )
    }

    func summaryText() -> String {
        report(language: settings["language"]).summaryText()
    }

    private func summaryValues() -> [String: Double] {
        var values: [String: Double] = [:]
        if let started = events.first(where: { $0.kind == "capture started" }),
           let firstText = events.first(where: { $0.kind == "first text" }) {
            values["firstWordSeconds"] = max(0, firstText.t - started.t)
        }
        let rough = samples.compactMap(\.textBehindRough)
        let final = samples.compactMap(\.textBehindFinal)
        if let median = Self.median(rough) { values["medianBehindRough"] = median }
        if let median = Self.median(final) { values["medianBehindFinal"] = median }
        if let peak = final.max() { values["maxBehindFinal"] = peak }
        if let peak = samples.compactMap(\.reading.footprintBytes).max() { values["peakFootprintBytes"] = Double(peak) }
        if let growth = samples.compactMap(\.swapGrowthBytes).max() { values["swapGrowthBytes"] = Double(growth) }
        if let peak = samples.compactMap(\.heldAudioSeconds).max() { values["peakHeldAudioSeconds"] = peak }
        if let stall = samples.map(\.longestMainThreadStall).max() { values["longestStallSeconds"] = stall }
        return values
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
