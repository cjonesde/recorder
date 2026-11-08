import SwiftUI

enum DebugLevel: Int, Comparable {
    case good, caution, bad

    static func < (lhs: DebugLevel, rhs: DebugLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .good: return .green
        case .caution: return .yellow
        case .bad: return .red
        }
    }

    static func worst(_ levels: DebugLevel?...) -> DebugLevel? {
        levels.compactMap { $0 }.max()
    }

    static func banded(_ value: Double?, good: Double, caution: Double) -> DebugLevel? {
        guard let value else { return nil }
        if value < good { return .good }
        if value < caution { return .caution }
        return .bad
    }

    static func textBehindRough(_ seconds: Double?) -> DebugLevel? {
        banded(seconds, good: 2, caution: 5)
    }

    static func textBehindFinal(_ seconds: Double?) -> DebugLevel? {
        banded(seconds, good: 5, caution: 12)
    }

    static func recorderMemory(_ bytes: UInt64?) -> DebugLevel? {
        banded(bytes.map { Double($0) / DebugFormat.bytesPerMB }, good: 1024, caution: 2048)
    }

    static func pressure(_ pressure: MemoryPressure?) -> DebugLevel? {
        switch pressure {
        case .normal: return .good
        case .warning: return .caution
        case .critical: return .bad
        case nil: return nil
        }
    }

    static func swapGrowth(_ bytes: Int64?) -> DebugLevel? {
        banded(bytes.map { Double($0) / DebugFormat.bytesPerMB }, good: 64, caution: 512)
    }

    static func heldAudio(_ seconds: Double?, quality: MetricQuality) -> DebugLevel? {
        quality == .unknown ? nil : banded(seconds, good: 30, caution: 60)
    }

    static func stops(_ count: Int) -> DebugLevel {
        count == 0 ? .good : .bad
    }
}

enum DebugFormat {
    static let bytesPerMB = 1_048_576.0
    static let unknown = "unknown"

    static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f s", $0) } ?? unknown
    }

    static func megabytes(_ bytes: UInt64?) -> String {
        bytes.map { String(format: "%.0f MB", Double($0) / bytesPerMB) } ?? unknown
    }

    static func signedMegabytes(_ bytes: Int64?) -> String {
        bytes.map { String(format: "%+.0f MB", Double($0) / bytesPerMB) } ?? unknown
    }

    static func held(_ seconds: Double?, quality: MetricQuality) -> String {
        guard let seconds, quality != .unknown else { return unknown }
        return labelled(String(format: "%.1f s", seconds), quality: quality)
    }

    static func labelled(_ value: String, quality: MetricQuality) -> String {
        switch quality {
        case .measured: return value
        case .estimated: return "\(value) (estimated)"
        case .unknown: return value == unknown ? value : "\(value) (unknown)"
        }
    }

    static func pressure(_ pressure: MemoryPressure?) -> String {
        pressure?.rawValue ?? unknown
    }

    static func audioFiles(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    static func stops(_ stops: [LiveStopReason]) -> String {
        guard let last = stops.last else { return "0" }
        return "\(stops.count), last: \(last.message)"
    }
}

struct DebugRow: View {
    let label: String
    let value: String
    var level: DebugLevel? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(level?.color ?? Color.clear)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

struct DebugDrawerView: View {
    let recorder: DiagnosticsRecorder?
    let popOut: () -> Void
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if let recorder {
                    DebugDrawerRows(recorder: recorder)
                } else {
                    Text("Starts with the next recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Debug")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Pop out ↗", action: popOut)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Open the debug view in a floating window")
            }
        }
    }
}

private struct DebugDrawerRows: View {
    let recorder: DiagnosticsRecorder

    var body: some View {
        let sample = recorder.samples.last
        let heldQuality = sample?.heldAudioQuality ?? .unknown
        VStack(alignment: .leading, spacing: 3) {
            DebugRow(
                label: "Text behind (rough / final)",
                value: "\(DebugFormat.seconds(sample?.textBehindRough)) / \(DebugFormat.seconds(sample?.textBehindFinal))",
                level: .worst(.textBehindRough(sample?.textBehindRough), .textBehindFinal(sample?.textBehindFinal))
            )
            DebugRow(
                label: "Recorder memory",
                value: DebugFormat.megabytes(sample?.reading.footprintBytes),
                level: .recorderMemory(sample?.reading.footprintBytes)
            )
            DebugRow(
                label: "Memory pressure, swap growth",
                value: "\(DebugFormat.pressure(sample?.reading.pressure)), \(DebugFormat.signedMegabytes(sample?.swapGrowthBytes))",
                level: .worst(.pressure(sample?.reading.pressure), .swapGrowth(sample?.swapGrowthBytes))
            )
            DebugRow(
                label: "Oldest audio held",
                value: DebugFormat.held(sample?.heldAudioSeconds, quality: heldQuality),
                level: .heldAudio(sample?.heldAudioSeconds, quality: heldQuality)
            )
            DebugRow(
                label: "Audio files on disk",
                value: DebugFormat.audioFiles(sample?.audioFilesOnDisk ?? [])
            )
            DebugRow(
                label: "Safety stops",
                value: DebugFormat.stops(recorder.stops),
                level: .stops(recorder.stops.count)
            )
        }
    }
}
