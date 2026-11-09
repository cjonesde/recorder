import SwiftUI
import Charts
import AppKit

struct DebugWindowView: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        Group {
            if let recorder = model.diagnostics {
                DebugWindowContent(recorder: recorder)
            } else {
                ContentUnavailableView(
                    "No debug data yet",
                    systemImage: "waveform",
                    description: Text("Start a recording while Show debug info is on.")
                )
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

private struct DebugWindowContent: View {
    @Environment(RecorderModel.self) private var model
    let recorder: DiagnosticsRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Session") { header }
                section("Engine") { engineBlock }
                section("Over time") { charts }
                section("\(recorder.engine.label) details") { engineRows }
                section("Events") { eventLog }
                Button("Copy summary", action: copySummary)
            }
            .padding(14)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private var language: String {
        guard recorder.engine.usesLanguagePicker else { return "auto" }
        return recorder.settings["language"].map(TranscriptionLanguage.label(for:)) ?? DebugFormat.unknown
    }

    private var captureStart: Double? {
        recorder.events.first { $0.kind == "capture started" }?.t
    }

    private var recordingTime: String {
        guard let captureStart, let last = recorder.samples.last(where: { $0.phase == .recording })?.t else {
            return "not started"
        }
        let total = Int(max(0, last - captureStart))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            DebugRow(label: "Engine", value: recorder.engine.label)
            DebugRow(label: "Language", value: language)
            DebugRow(label: "Compute units", value: recorder.preparation?.computeUnits ?? DebugFormat.unknown)
            DebugRow(label: "Recording time", value: recordingTime)
            DebugRow(label: "Phase", value: recorder.phase.rawValue)
        }
    }

    private var engineBlock: some View {
        let preparation = recorder.preparation
        return VStack(alignment: .leading, spacing: 3) {
            DebugRow(label: "Load time", value: preparation.map { String(format: "%.2f s", $0.loadSeconds) } ?? DebugFormat.unknown)
            DebugRow(label: "Load", value: preparation.map { $0.firstLoad ? "first load" : "cached" } ?? DebugFormat.unknown)
            DebugRow(label: "Model size on disk", value: DebugFormat.megabytes(preparation?.modelBytesOnDisk.map { UInt64(max(0, $0)) }))
        }
    }

    private var preparingEnd: Double? {
        captureStart ?? recorder.samples.last?.t
    }

    private var charts: some View {
        let samples = recorder.samples
        let megabytes = { (bytes: Double) in bytes / DebugFormat.bytesPerMB }
        var memorySeries: [(String, (DiagnosticSample) -> Double?)] = [
            ("Recorder", { $0.reading.footprintBytes.map { megabytes(Double($0)) } }),
        ]
        if recorder.engine == .apple && recorder.measuresSpeechService {
            memorySeries.append(("Speech service", { $0.reading.speechServiceFootprintBytes.map { megabytes(Double($0)) } }))
        }
        memorySeries.append(("Swap growth", { $0.swapGrowthBytes.map { megabytes(Double($0)) } }))
        return VStack(alignment: .leading, spacing: 10) {
            DebugChart(
                title: "Text behind",
                unit: "s",
                points: DebugChartPoint.points(samples, series: [("Rough", \.textBehindRough), ("Final", \.textBehindFinal)]),
                preparingEnd: preparingEnd
            )
            DebugChart(
                title: "Memory",
                unit: "MB",
                points: DebugChartPoint.points(samples, series: memorySeries),
                preparingEnd: preparingEnd
            )
            DebugChart(
                title: samples.last?.heldAudioQuality == .estimated ? "Oldest audio held (estimated)" : "Oldest audio held",
                unit: "s",
                points: DebugChartPoint.points(samples, series: [("Held", { $0.heldAudioQuality == .unknown ? nil : $0.heldAudioSeconds })]),
                preparingEnd: preparingEnd
            )
            Text("Shaded area: preparing")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var engineRows: some View {
        let _ = recorder.samples.count
        let latest = recorder.samples.last
        VStack(alignment: .leading, spacing: 3) {
            if recorder.engine == .apple {
                DebugRow(
                    label: "Speech service memory",
                    value: DebugFormat.megabytes(latest?.reading.speechServiceFootprintBytes)
                )
            }
            if model.live.engine.kind == recorder.engine {
                ForEach(Array(model.live.engine.diagnostics().rows.enumerated()), id: \.offset) { _, row in
                    DebugRow(label: row.label, value: DebugFormat.labelled(row.value, quality: row.quality))
                }
            } else {
                Text("The selected engine changed since this recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(recorder.events.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 6) {
                    Text(String(format: "%7.2f s", event.t))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(event.kind)
                    if let detail = event.detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
            }
        }
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recorder.summaryText(), forType: .string)
    }
}

private struct DebugChartPoint: Identifiable {
    let id: String
    let t: Double
    let value: Double
    let series: String

    static func points(_ samples: [DiagnosticSample], series: [(String, (DiagnosticSample) -> Double?)]) -> [DebugChartPoint] {
        series.flatMap { name, value in
            samples.enumerated().compactMap { index, sample in
                value(sample).map { DebugChartPoint(id: "\(name)-\(index)", t: sample.t, value: $0, series: name) }
            }
        }
    }
}

private struct DebugChart: View {
    let title: String
    let unit: String
    let points: [DebugChartPoint]
    let preparingEnd: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            if points.isEmpty {
                Text(DebugFormat.unknown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.t), y: .value(unit, point.value))
                        .foregroundStyle(by: .value("Series", point.series))
                }
                .chartXAxisLabel("seconds")
                .chartYAxisLabel(unit)
                .chartBackground { proxy in preparingShade(proxy) }
                .frame(height: 110)
            }
        }
    }

    private func preparingShade(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let preparingEnd, let plotFrame = proxy.plotFrame,
               let start = proxy.position(forX: 0.0), let end = proxy.position(forX: preparingEnd) {
                let frame = geometry[plotFrame]
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: max(0, min(end, frame.width) - max(0, start)), height: frame.height)
                    .offset(x: frame.minX + max(0, start), y: frame.minY)
            }
        }
    }
}
