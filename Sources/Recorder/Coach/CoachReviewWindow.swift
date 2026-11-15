import AppKit
import AVFoundation
import Observation
import SwiftUI
import VoiceCoach

@MainActor
final class CoachReviewWindow: NSObject, NSWindowDelegate {
    static let shared = CoachReviewWindow()

    private var window: NSWindow?

    func show(model: RecorderModel) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: CoachReviewView().environment(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Voice Coach Review"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

@MainActor
@Observable
final class CoachReviewModel {
    struct Session: Identifiable {
        let folder: URL
        var triggers: [CoachTriggerRecord]
        var id: String { folder.path }
        var title: String { folder.lastPathComponent }
    }

    private(set) var sessions: [Session] = []
    private(set) var tallies: [DetectorID: LabelTally] = [:]
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let root: URL?

    init(root: URL? = RecordingsLibrary.recordingsRoot()) {
        self.root = root
    }

    func reload() {
        sessions = CoachLabels.sessionFolders(root: root).map { Session(folder: $0, triggers: CoachLabels.triggers(in: $0)) }
            .filter { !$0.triggers.isEmpty }
        tallies = CoachLabels.tallies(root: root)
    }

    func setLabel(_ label: CoachLabel?, for record: CoachTriggerRecord) {
        CoachLabels.setLabel(label, for: record.id, in: record.folder)
        reload()
    }

    func isPlaying(_ record: CoachTriggerRecord) -> Bool { record.clipURL != nil && playing == record.clipURL }

    func toggle(_ record: CoachTriggerRecord) {
        if isPlaying(record) {
            player?.stop()
            playing = nil
            return
        }
        guard let url = record.clipURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        playing = url
    }
}

struct CoachReviewView: View {
    @Environment(RecorderModel.self) private var model
    @State private var review = CoachReviewModel()

    static let promotable: [DetectorID] = [.pace, .soStarts, .risingEndings, .trailingEndings, .talkShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promotionTable
                .padding(16)
            Divider()
            if review.sessions.isEmpty {
                ContentUnavailableView("No coach moments yet", systemImage: "waveform", description: Text("Record with the voice coach on. Moments it flags show up here, with a clip when audio is kept."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(review.sessions) { session in
                        Section(session.title) {
                            ForEach(session.triggers) { record in
                                row(record)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { review.reload() }
    }

    private var promotionTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Check").font(.caption.bold())
                Text("Labelled").font(.caption.bold())
                Text("Right").font(.caption.bold())
                Text("On the HUD").font(.caption.bold())
            }
            ForEach(Self.promotable, id: \.self) { detector in
                let tally = review.tallies[detector] ?? LabelTally()
                GridRow {
                    Label(detector.reviewName, systemImage: CoachHUDView.symbol(detector))
                    Text(detector == .talkShare ? "n/a" : "\(tally.labelled)")
                        .monospacedDigit()
                    Text(tally.precision.map { "\(Int(($0 * 100).rounded())) %" } ?? "n/a")
                        .monospacedDigit()
                    Toggle("", isOn: promotionBinding(detector))
                        .labelsHidden()
                        .disabled(!canToggle(detector, tally: tally))
                }
            }
            Text("A check can join the HUD once at least \(CoachLabels.minimumLabelled) labelled moments show it is right \(Int(CoachLabels.minimumPrecision * 100)) % of the time. Pace starts on the HUD; talk share is a measurement, not an alarm, so it has no labels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .gridCellColumns(4)
        }
    }

    private func canToggle(_ detector: DetectorID, tally: LabelTally) -> Bool {
        detector == .pace || detector == .talkShare || model.coachPromoted.contains(detector) || CoachLabels.canPromote(tally)
    }

    private func promotionBinding(_ detector: DetectorID) -> Binding<Bool> {
        Binding(
            get: { model.coachPromoted.contains(detector) },
            set: { on in
                if on { model.coachPromoted.insert(detector) } else { model.coachPromoted.remove(detector) }
            }
        )
    }

    private func row(_ record: CoachTriggerRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: CoachHUDView.symbol(record.detector))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.detector.reviewName)
                Text("\(Self.clock(record.t)) · \(record.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                review.toggle(record)
            } label: {
                Image(systemName: review.isPlaying(record) ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(record.clipURL == nil)
            .help(record.clipURL == nil ? "No clip: audio was not kept or the other side was audible" : "Play the clip")
            Picker("", selection: Binding(get: { record.label }, set: { review.setLabel($0, for: record) })) {
                Text("Unlabelled").tag(CoachLabel?.none)
                Text("Right").tag(CoachLabel?.some(.right))
                Text("False alarm").tag(CoachLabel?.some(.falseAlarm))
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    static func clock(_ t: Double) -> String {
        let total = Int(t)
        guard total >= 3600 else { return String(format: "%02d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}

extension DetectorID {
    var reviewName: String {
        switch self {
        case .pace: return "Pace"
        case .energy: return "Energy"
        case .soStarts: return "\"So\" at sentence starts"
        case .risingEndings: return "Rising statement endings"
        case .trailingEndings: return "Trailing endings"
        case .raisedVoice: return "Raised pitch and level"
        case .talkShare: return "Talk share"
        case .interruptions: return "Interruptions"
        }
    }
}
