import StenoCore
import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var captureState: CaptureState = .disabled
    @Published var reasonCode: String = "initialized"
    @Published var settings: RecorderSettings
    @Published var databasePath: String
    @Published var sttConfigurationMessage: String = ""
    @Published var llmConfigurationMessage: String = ""
    @Published var sttConfigurationIsValid: Bool = false
    @Published var llmConfigurationIsValid: Bool = false
    @Published var dataMessage: String = ""
    /// nil until the first successful read (or when the database is unreachable).
    /// Published as the raw snapshot so the view can lay the numbers out itself.
    @Published var activity: DatabaseWriter.ActivitySummary?
    /// Spooled audio still waiting to be transcribed, plus what it occupies.
    @Published var pendingAudio: PendingAudioStore.Stats?

    private let settingsRepository: SettingsRepository
    private let coordinator: RecorderCoordinator?

    var isListeningRequested: Bool {
        ![.disabled, .pausedByUser, .failed].contains(captureState)
    }

    init() {
        let repository = SettingsRepository()
        self.settingsRepository = repository
        self.settings = repository.load().validated()

        guard let databaseWriter = try? DatabaseWriter(appName: "Steno") else {
            self.databasePath = "Database initialization failed"
            self.coordinator = nil
            self.captureState = .failed
            self.reasonCode = "database_init_failed"
            return
        }
        self.databasePath = databaseWriter.databaseURL.path
        self.coordinator = RecorderCoordinator(
            settingsRepository: repository,
            databaseWriter: databaseWriter,
            captureProvider: AVAudioEngineCaptureProvider()
        )

        syncLoginItem()

        Task {
            guard let coordinator else { return }
            await coordinator.setObserver { [weak self] state, reason in
                Task { @MainActor in
                    self?.captureState = state
                    self?.reasonCode = reason
                }
            }
            await coordinator.setSettingsObserver { [weak self] settings in
                Task { @MainActor in self?.settings = settings }
            }

            await coordinator.updateSettings(settings)
            // Pick up any segments spooled before the last quit — including a
            // backlog recorded with no network — before anything new is queued.
            await coordinator.resumePendingTranscriptions()
            await refreshFromCoordinator()
            await refreshSTTConfigurationMessage()
            await refreshLLMConfigurationMessage()
            await refreshActivitySummary()

            if settings.autoStartRecordingOnLaunch {
                await coordinator.startListening()
                await refreshFromCoordinator()
            }
        }
    }

    /// Registers/unregisters the app as a login item to match the setting.
    /// Native `SMAppService` (macOS 13+) — no helper app or third-party dependency needed.
    private func syncLoginItem() {
        let shouldBeEnabled = settings.launchAtLogin
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard shouldBeEnabled != isEnabled else { return }

        do {
            if shouldBeEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Reflect the real system state back into settings rather than lying to the UI.
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func toggleListening() {
        Task {
            guard let coordinator else { return }
            if isListeningRequested {
                await coordinator.pauseListening()
            } else {
                await coordinator.startListening()
            }
            await refreshFromCoordinator()
        }
    }

    func persistSettings() {
        settings = settings.validated()
        settingsRepository.save(settings)
        syncLoginItem()

        Task {
            guard let coordinator else { return }
            await coordinator.updateSettings(settings)
            await refreshSTTConfigurationMessage()
            await refreshLLMConfigurationMessage()
            await refreshFromCoordinator()
        }
    }

    func refreshSTTConfigurationMessage() async {
        if settings.sttProvider == .appleSystem {
            guard let coordinator else {
                sttConfigurationMessage = "Database initialization failed; settings are unavailable."
                sttConfigurationIsValid = false
                return
            }
            let availability = await coordinator.appleProviderAvailability(requestAuthorization: true)
            sttConfigurationMessage = availability.message ?? "Apple System Speech is available."
            sttConfigurationIsValid = availability.isAvailable
            return
        }

        guard let coordinator else {
            sttConfigurationMessage = "Database initialization failed; settings are unavailable."
            sttConfigurationIsValid = false
            return
        }

        let message = await coordinator.validateCustomProviderConfiguration()
        sttConfigurationMessage = message ?? "Custom STT configuration passed security validation."
        sttConfigurationIsValid = message == nil
    }

    func refreshLLMConfigurationMessage() async {
        guard settings.llmEnabled else {
            llmConfigurationMessage = "LLM text optimization is disabled."
            llmConfigurationIsValid = false
            return
        }

        guard let coordinator else {
            llmConfigurationMessage = "Database initialization failed; settings are unavailable."
            llmConfigurationIsValid = false
            return
        }

        let message = await coordinator.validateLLMConfiguration()
        llmConfigurationMessage = message ?? "LLM configuration passed security validation."
        llmConfigurationIsValid = message == nil
    }

    private func refreshFromCoordinator() async {
        guard let coordinator else { return }
        let state = await coordinator.currentState()
        let reason = await coordinator.currentReasonCode()

        await MainActor.run {
            self.captureState = state
            self.reasonCode = reason
        }
    }

    /// Summarizes what the recorder pipeline has actually done (captured / transcribed /
    /// failed / still queued), so "is it working?" doesn't require inspecting sqlite by hand.
    func refreshActivitySummary() async {
        guard let coordinator else { return }
        let summary = try? await coordinator.activitySummary()
        let pending = await coordinator.pendingAudioStats()
        await MainActor.run {
            self.activity = summary
            self.pendingAudio = pending
        }
    }


    func exportTranscripts() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Steno-Transcripts.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let coordinator else { return }
                try await coordinator.exportTranscripts(to: url)
                dataMessage = "Transcripts exported."
            } catch {
                dataMessage = error.localizedDescription
            }
        }
    }

    func deleteAllTranscripts() {
        let alert = NSAlert()
        alert.messageText = "Delete all transcripts?"
        alert.informativeText = "This permanently deletes transcript segments and their STT and clipboard audit records."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                guard let coordinator else { return }
                try await coordinator.deleteAllTranscripts()
                dataMessage = "All transcripts deleted."
            } catch {
                dataMessage = error.localizedDescription
            }
        }
    }

    func confirmAppleServicePolicyIfNeeded() {
        guard settings.appleProcessingPolicy == .allowAppleService else { return }
        let alert = NSAlert()
        alert.messageText = "Allow Apple service processing?"
        alert.informativeText = "Speech audio may be sent to Apple servers. On-device-only mode never silently falls back to this option."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Keep on-device only")
        alert.alertStyle = .warning
        if alert.runModal() != .alertFirstButtonReturn {
            settings.appleProcessingPolicy = .onDeviceOnly
            persistSettings()
        }
    }
}
