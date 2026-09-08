import SwiftUI
import StenoCore

@main
struct StenoApp: App {
    @StateObject private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Label("Ambient", systemImage: menuBarSymbolName(for: appState.captureState))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor(for: appState.captureState))
        }

        Settings {
            SettingsView(appState: appState)
        }
    }

    private func menuBarColor(for state: CaptureState) -> Color {
        switch state {
        case .recording: return .red
        case .yieldedToOtherInput: return .orange
        case .suppressedByPlayback: return .purple
        case .pausedByUser, .disabled, .noInputDevice: return .gray
        case .permissionRequired: return .yellow
        case .recovering, .starting: return .blue
        case .failed: return .orange
        }
    }
}
