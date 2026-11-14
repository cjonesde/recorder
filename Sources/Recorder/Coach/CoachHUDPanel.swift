import AppKit
import SwiftUI
import VoiceCoach

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CoachHUDPanel: NSObject, NSWindowDelegate {
    static let shared = CoachHUDPanel()
    static let size = NSSize(width: 176, height: 30)
    static let gapBelowMenuBar: CGFloat = 6

    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func show(controller: CoachController) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = HUDWindow(
            contentRect: NSRect(origin: initialOrigin(), size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = DraggableHostingView(rootView: CoachHUDView().environment(controller))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        Preferences.coachHUDOrigin = panel.frame.origin
    }

    private func initialOrigin() -> NSPoint {
        if let saved = Preferences.coachHUDOrigin,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: saved, size: Self.size)) }) {
            return saved
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - Self.size.height - Self.gapBelowMenuBar)
    }
}

struct CoachHUDView: View {
    @Environment(CoachController.self) private var coach

    static let cueOrder: [DetectorID] = [.pace, .soStarts, .risingEndings, .trailingEndings]

    static func symbol(_ detector: DetectorID) -> String {
        switch detector {
        case .pace: return "tortoise.fill"
        case .soStarts: return "repeat"
        case .risingEndings: return "arrow.up.right"
        case .trailingEndings: return "arrow.down.right"
        default: return "circle"
        }
    }

    var body: some View {
        let state = coach.hud ?? .idle(coach.preset)
        HStack(spacing: 8) {
            GateDot(gate: state.gate, talkShare: state.talkShare, talkShareHigh: state.talkShareHigh)
            EnergyBar(value: state.energy)
            HStack(spacing: 2) {
                ForEach(Self.cueOrder, id: \.self) { detector in
                    Image(systemName: Self.symbol(detector))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.2))
                        .frame(width: 12, height: 12)
                        .opacity(state.litCues.contains(detector) ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: state.litCues)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(width: CoachHUDPanel.size.width, height: CoachHUDPanel.size.height)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .opacity(coach.isPaused ? 0.4 : 1)
        .contextMenu {
            ForEach(CoachPreset.allCases, id: \.self) { preset in
                Button {
                    coach.overridePreset(preset)
                } label: {
                    if preset == coach.preset {
                        Label(preset.menuLabel, systemImage: "checkmark")
                    } else {
                        Text(preset.menuLabel)
                    }
                }
            }
            Divider()
            Button("Hide until next recording") { coach.hideForSession() }
        }
    }
}

private struct GateDot: View {
    let gate: GateState
    let talkShare: Double?
    let talkShareHigh: Bool

    private var color: Color {
        switch gate {
        case .own: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .them: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .overlap: return Color(red: 0.7, green: 0.45, blue: 1.0)
        case .silence: return Color.white.opacity(0.35)
        case .unknown: return Color.clear
        }
    }

    var body: some View {
        ZStack {
            if let talkShare {
                Circle()
                    .trim(from: 0, to: min(1, max(0, talkShare)))
                    .stroke(talkShareHigh ? Color(red: 1.0, green: 0.72, blue: 0.2) : Color.white.opacity(0.5), lineWidth: 1.5)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.white.opacity(gate == .unknown ? 0.5 : 0), lineWidth: 1))
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.2), value: gate)
    }
}

private struct EnergyBar: View {
    let value: Double?

    static let cool = (red: 0.45, green: 0.55, blue: 0.68)
    static let warm = (red: 1.0, green: 0.55, blue: 0.15)

    private var fill: Color {
        let v = value ?? 0
        return Color(
            red: Self.cool.red + (Self.warm.red - Self.cool.red) * v,
            green: Self.cool.green + (Self.warm.green - Self.cool.green) * v,
            blue: Self.cool.blue + (Self.warm.blue - Self.cool.blue) * v
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let value {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(8, proxy.size.width * value))
                }
            }
        }
        .frame(width: 72, height: 8)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

extension CoachPreset {
    var menuLabel: String {
        switch self {
        case .presentation: return "Presentation"
        case .oneOnOne: return "1on1"
        case .group: return "Group"
        }
    }
}
