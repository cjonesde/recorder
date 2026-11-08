import AppKit
import SwiftUI
import Observation

@MainActor
final class DebugWindowController: NSObject, NSWindowDelegate {
    static let shared = DebugWindowController()

    private var panel: NSPanel?
    private var isWatchingDebugSwitch = false

    private override init() { super.init() }

    func show(model: RecorderModel) {
        guard model.showDebugInfo else { return }
        NSApp.activate(ignoringOtherApps: true)

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recorder Debug"
        panel.contentViewController = NSHostingController(rootView: DebugWindowView().environment(model))
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        closeWhenDebugTurnsOff(model)
    }

    func close() {
        panel?.close()
    }

    private func closeWhenDebugTurnsOff(_ model: RecorderModel) {
        guard !isWatchingDebugSwitch else { return }
        isWatchingDebugSwitch = true
        withObservationTracking {
            _ = model.showDebugInfo
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self else { return }
                self.isWatchingDebugSwitch = false
                guard let model, self.panel != nil else { return }
                if model.showDebugInfo {
                    self.closeWhenDebugTurnsOff(model)
                } else {
                    self.close()
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
