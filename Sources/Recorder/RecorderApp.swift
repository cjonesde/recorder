import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderPanel()
                .environment(model)
                .task { model.onAppear() }
        } label: {
            MenuBarLabel(state: model.state, elapsed: model.elapsed)
        }
        .menuBarExtraStyle(.window)

        // The dedicated Preferences window is an AppKit-managed NSWindow rather than
        // a SwiftUI `Settings` scene — see PreferencesWindowController for why that's
        // more reliable from a menu-bar–only (.accessory) app. It's opened from the
        // panel's "Settings…" button / ⌘,.
    }
}

struct MenuBarLabel: View {
    let state: RecorderState
    let elapsed: TimeInterval

    var body: some View {
        if let pill = MenuBarPill(state: state, elapsed: elapsed) {
            Image(nsImage: pill.image(scale: NSScreen.main?.backingScaleFactor ?? 2))
                .accessibilityLabel(pill.accessibilityLabel)
        } else {
            Image(systemName: state == .idle ? "mic.fill" : "hourglass")
        }
    }
}
