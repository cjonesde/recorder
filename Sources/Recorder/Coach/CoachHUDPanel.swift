import AppKit
import SwiftUI
import VoiceCoach

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
        } else if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

private final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CoachHUDPanel: NSObject, NSWindowDelegate {
    static let shared = CoachHUDPanel()
    static let size = NSSize(width: 196, height: 30)
    static let gapBelowMenuBar: CGFloat = 6
    static let checksGap: CGFloat = 6
    static let checkRowHeight: CGFloat = 46
    static let checksPadding: CGFloat = 10
    static let expandedSize = NSSize(
        width: 360,
        height: size.height + checksGap + CGFloat(CoachCheckLine.order.count) * checkRowHeight + checksPadding * 2
    )

    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func show(controller: CoachController) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let collapsed = NSRect(origin: initialOrigin(), size: Self.size)
        let panel = HUDWindow(
            contentRect: Self.frame(keepingCapsuleOf: collapsed, expanded: controller.showsChecks),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = DraggableHostingView(rootView: CoachHUDView().environment(controller))
        content.onDoubleClick = { [weak controller] in controller?.toggleChecks() }
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        panel.setFrame(Self.frame(keepingCapsuleOf: panel.frame, expanded: expanded), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        Preferences.coachHUDOrigin = Self.collapsedOrigin(of: panel.frame)
    }

    static func frame(keepingCapsuleOf frame: NSRect, expanded: Bool) -> NSRect {
        let target = expanded ? expandedSize : size
        return NSRect(x: frame.midX - target.width / 2, y: frame.maxY - target.height, width: target.width, height: target.height)
    }

    static func collapsedOrigin(of frame: NSRect) -> NSPoint {
        self.frame(keepingCapsuleOf: frame, expanded: false).origin
    }

    private func initialOrigin() -> NSPoint {
        if let saved = Preferences.coachHUDOrigin,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: saved, size: Self.size)) }) {
            return saved
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return Self.defaultOrigin(in: screen.visibleFrame)
    }

    static func defaultOrigin(in visible: NSRect) -> NSPoint {
        let centre = visible.midX + visible.width / 3
        return NSPoint(x: centre - size.width / 2, y: visible.maxY - size.height - gapBelowMenuBar)
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
        VStack(spacing: CoachHUDPanel.checksGap) {
            CoachHUDContent(state: coach.hud ?? .idle(coach.preset), paused: coach.isPaused)
            if coach.showsChecks {
                CoachChecksList(lines: CoachCheckLine.lines(monitor: coach.monitor, preset: coach.preset, promoted: coach.promoted))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
            Button(coach.showsChecks ? "Hide all checks" : "Show all checks") { coach.toggleChecks() }
            Button("Hide until next recording") { coach.hideForSession() }
        }
    }
}

struct CoachChecksList: View {
    let lines: [CoachCheckLine]

    static let flagColor = Color(red: 1.0, green: 0.72, blue: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(line.flagging ? Self.flagColor : Color.white.opacity(0.2))
                            .frame(width: 7, height: 7)
                        Text(line.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(line.flagging ? Self.flagColor : Color.white)
                        Spacer(minLength: 4)
                        if let flags = line.flags {
                            Text(flags == 1 ? "1 flag" : "\(flags) flags")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(flags > 0 ? 0.85 : 0.45))
                        }
                        Text(line.status)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(line.status == "On the bar" ? 0.85 : 0.5))
                    }
                    Text(line.reading)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.leading, 13)
                    Text(line.limit)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.leading, 13)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: CoachHUDPanel.checkRowHeight, maxHeight: CoachHUDPanel.checkRowHeight, alignment: .leading)
                .animation(.easeOut(duration: 0.25), value: line.flagging)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, CoachHUDPanel.checksPadding)
        .frame(width: CoachHUDPanel.expandedSize.width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

struct CoachHUDContent: View {
    let state: CoachHUDState
    let paused: Bool

    var body: some View {
        HStack(spacing: 8) {
            GateDot(gate: state.gate, talkShare: state.talkShare, talkShareHigh: state.talkShareHigh)
            EnergyBar(value: state.energy)
            HStack(spacing: 3) {
                ForEach(CoachHUDView.cueOrder, id: \.self) { detector in
                    Image(systemName: CoachHUDView.symbol(detector))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.2))
                        .frame(width: 17, height: 12)
                        .opacity(state.litCues.contains(detector) ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: state.litCues)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(width: CoachHUDPanel.size.width, height: CoachHUDPanel.size.height)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .opacity(paused ? 0.4 : 1)
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
