import StenoCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.captureState.menuDescription)
                .font(.headline)
            Text("Reason: \(appState.reasonCode)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Only shown when there is a backlog — the point of surfacing it
            // here is knowing, without opening Settings, that recordings made
            // offline are still safely waiting.
            if let pending = appState.pendingAudio, pending.pendingCount > 0 {
                Text("\(pending.pendingCount) waiting to transcribe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
        .task { await appState.refreshActivitySummary() }

        Button(appState.isListeningRequested ? "Pause listening" : "Start listening") {
            appState.toggleListening()
        }

        SettingsLink {
            Text("Open Settings…")
        }

        Divider()

        Button("Quit Steno") {
            NSApplication.shared.terminate(nil)
        }
    }
}

func menuBarSymbolName(for state: CaptureState) -> String {
    switch state {
    case .recording: return "mic.fill"
    case .yieldedToOtherInput: return "pause.circle.fill"
    case .suppressedByPlayback: return "speaker.slash.fill"
    case .pausedByUser, .disabled: return "mic.slash"
    case .permissionRequired: return "lock.fill"
    case .noInputDevice: return "questionmark.circle"
    case .recovering, .starting: return "arrow.triangle.2.circlepath"
    case .failed: return "exclamationmark.triangle.fill"
    }
}
