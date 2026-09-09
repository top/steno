import StenoCore
import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, arbitration, stt, llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .arbitration: return "Arbitration"
        case .stt: return "STT"
        case .llm: return "LLM"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "waveform"
        case .arbitration: return "arrow.triangle.branch"
        case .stt: return "mic"
        case .llm: return "sparkles"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: SettingsTab = .general
    @State private var newExcludedBundleID: String = ""

    /// Debounce task for persisting settings. Prevents rapid slider/text changes
    /// from triggering dozens of coordinator restarts and UserDefaults writes.
    @State private var persistDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    tabContent(for: tab)
                        // Every tab gets the exact same content box, derived from the
                        // shared column widths. Without this each pane sizes to its own
                        // intrinsic width — a tab holding a full-width Spacer or a long
                        // wrapping caption ends up wider than one built only of rows,
                        // and TabView centers each pane, so they visibly disagree.
                        .frame(width: settingsContentWidth, alignment: .leading)
                        .padding(settingsContentPadding)
                        // Lets the window's height track each tab's actual content, the
                        // same way System Settings resizes when you switch panes.
                        .fixedSize(horizontal: false, vertical: true)
                        .tabItem {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .tag(tab)
                }
            }
            if let status = footerStatus {
                Divider()
                StatusBar(message: status.message, isValid: status.isValid)
            }
        }
        .onAppear {
            // Accessory apps (no Dock icon) don't get foreground focus for free;
            // without this the Settings window can open behind other windows.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .onChange(of: appState.settings) { _, _ in
            debouncedPersistSettings()
        }
        .onDisappear {
            // Flush any pending save when the settings window is closed.
            persistDebounceTask?.cancel()
            Task { appState.persistSettings() }
        }
    }

    /// Message shown in the shared status bar for the current tab. Each tab that
    /// needs to report success/failure (validation, export, etc.) feeds this
    /// instead of drawing its own inline status text.
    private var footerStatus: (message: String, isValid: Bool)? {
        switch selectedTab {
        case .general:
            return appState.dataMessage.isEmpty ? nil : (appState.dataMessage, true)
        case .stt:
            return appState.sttConfigurationMessage.isEmpty ? nil : (appState.sttConfigurationMessage, appState.sttConfigurationIsValid)
        case .llm:
            return appState.llmConfigurationMessage.isEmpty ? nil : (appState.llmConfigurationMessage, appState.llmConfigurationIsValid)
        case .recording, .arbitration:
            return nil
        }
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: generalTab
        case .recording: recordingTab
        case .arbitration: arbitrationTab
        case .stt: sttTab
        case .llm: llmTab
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: "Application") {
                SettingsRow(
                    "Launch at login",
                    subtitle: "Start Steno automatically when you log in to this Mac."
                ) {
                    Toggle("", isOn: $appState.settings.launchAtLogin).labelsHidden()
                }
                SettingsRow(
                    "Start recording on launch",
                    subtitle: "Begin listening as soon as the app launches, without clicking Start."
                ) {
                    Toggle("", isOn: $appState.settings.autoStartRecordingOnLaunch).labelsHidden()
                }
                SettingsRow(
                    "Copy final transcripts to clipboard",
                    subtitle: "Copy each finished transcript to the clipboard as soon as it's ready."
                ) {
                    Toggle("", isOn: $appState.settings.autoCopyFinalTranscript).labelsHidden()
                }
            }

            SettingsSection(title: "Storage") {
                SettingsRow("Database path", alignment: .top) {
                    Text(appState.databasePath)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                SettingsRow(
                    "Keep audio after transcription",
                    subtitle: "Save each segment as a WAV file instead of discarding it once its transcript is stored. Audio waiting to be transcribed is always kept, regardless of this setting."
                ) {
                    Toggle("", isOn: $appState.settings.keepAudioAfterTranscription).labelsHidden()
                }
                SettingsRow("Audio on disk", alignment: .top) {
                    Text(audioStorageDescription)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Export transcripts…") { appState.exportTranscripts() }
                    Button("Delete all transcripts", role: .destructive) { appState.deleteAllTranscripts() }
                    Spacer()
                }
            }

            SettingsSection(title: "Recording activity") {
                if let activity = appState.activity {
                    HStack(spacing: 0) {
                        activityStat("Transcribed", activity.completedSegments.formatted())
                        activityStat("Failed", activity.failedSegments.formatted())
                        activityStat("Recorded time", Self.durationText(milliseconds: activity.recordedMs))
                    }
                }
                HStack(spacing: 8) {
                    Text(lastEventDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await appState.refreshActivitySummary() } }
                        .controlSize(.small)
                }
            }
        }
        .task { await appState.refreshActivitySummary() }
    }

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: "Segment timing") {
                SettingsRow(
                    "Speech onset",
                    subtitle: "How long speech must continue before a segment starts recording."
                ) {
                    numberField(value: $appState.settings.speechOnsetMs, suffix: "ms")
                }
                SettingsRow(
                    "Silence end",
                    subtitle: "How long silence must last before a segment is considered finished."
                ) {
                    numberField(value: $appState.settings.silenceEndMs, suffix: "ms")
                }
                SettingsRow(
                    "Pre-roll",
                    subtitle: "Audio kept from just before speech onset, so words don't get clipped."
                ) {
                    numberField(value: $appState.settings.preRollMs, suffix: "ms")
                }
                SettingsRow(
                    "Maximum segment",
                    subtitle: "A segment is force-closed if it runs longer than this."
                ) {
                    numberField(value: $appState.settings.maxSegmentMs, suffix: "ms")
                }
                SettingsRow(
                    "Minimum segment",
                    subtitle: "Segments shorter than this are discarded as noise."
                ) {
                    numberField(value: $appState.settings.minSegmentMs, suffix: "ms")
                }
            }

            SettingsSection(title: "Voice activity detection") {
                SettingsRow(
                    "Sensitivity",
                    subtitle: "Higher values catch quieter speech, but also trigger more false positives."
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.vadSensitivity, in: 0...1)
                            .frame(width: 160)
                        Text(appState.settings.vadSensitivity, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var arbitrationTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: "Input arbitration") {
                SettingsRow(
                    "Mode",
                    subtitle: "Whether recording keeps going while another app also wants the microphone."
                ) {
                    Picker("", selection: $appState.settings.inputArbitrationMode) {
                        ForEach(InputArbitrationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsRow(
                    "Recovery debounce",
                    subtitle: "How long to wait after an interruption ends before resuming."
                ) {
                    numberField(value: $appState.settings.arbitrationRecoveryDelaySeconds, suffix: "s", precision: 1)
                }
                SettingsRow(
                    "Excluded apps",
                    subtitle: "Apps that hold the microphone continuously (e.g. noise-cancellation tools) but should never pause recording. Add their bundle ID below.",
                    alignment: .top
                ) {
                    appRulesEditor
                }
            }

            SettingsSection(title: "Playback") {
                SettingsRow(
                    "Policy",
                    subtitle: "What happens to microphone capture while audio is playing on this Mac."
                ) {
                    Picker("", selection: $appState.settings.playbackPolicy) {
                        ForEach(availablePlaybackPolicies, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if #available(macOS 26.0, *) {
                    Text("Audible-output detection and system-output transcription require the process-tap implementation, which is not enabled in this package build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Actual audible-output detection and system-output transcription require macOS 26 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// List of excluded app bundle IDs plus a field to add one. Reuses the
    /// existing `AppRule`/`.exclude` model already read by the coordinator's
    /// monitor config — this just exposes it in the UI.
    private var appRulesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(appState.settings.appRules) { rule in
                HStack {
                    Text(rule.bundleID).font(.callout.monospaced())
                    Spacer()
                    Button {
                        appState.settings.appRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("com.example.app", text: $newExcludedBundleID)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let bundleID = newExcludedBundleID.trimmingCharacters(in: .whitespaces)
                    guard !bundleID.isEmpty else { return }
                    appState.settings.appRules.append(AppRule(bundleID: bundleID, behavior: .exclude))
                    newExcludedBundleID = ""
                }
                .disabled(newExcludedBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: settingsControlWidth)
    }

    private var sttTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: "Provider") {
                SettingsRow("STT provider", subtitle: "Which service transcribes your speech into text.") {
                    Picker("", selection: $appState.settings.sttProvider) {
                        ForEach(STTProviderKind.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsRow("Language", subtitle: "Expected spoken language, used as a hint for the model.") {
                    TextField("auto", text: $appState.settings.languageIdentifier)
                        .labelsHidden()
                }
            }

            if appState.settings.sttProvider == .customAPI {
                SettingsSection(title: "OpenAI-compatible API") {
                    SettingsRow("Endpoint") {
                        TextField("https://…", text: $appState.settings.customEndpoint)
                            .labelsHidden()
                    }
                    SettingsRow("Model ID") {
                        TextField("whisper-1", text: $appState.settings.customModelID)
                            .labelsHidden()
                    }
                    SettingsRow("Timeout") {
                        numberField(value: $appState.settings.customTimeoutSeconds, suffix: "s", precision: 0)
                    }
                    apiKeyRow(value: $appState.settings.sttAPIKey)
                }
            } else {
                SettingsSection(title: "Apple System Speech") {
                    SettingsRow("Processing policy") {
                        Picker("", selection: $appState.settings.appleProcessingPolicy) {
                            ForEach(AppleProcessingPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: appState.settings.appleProcessingPolicy) { _, _ in
                            appState.confirmAppleServicePolicyIfNeeded()
                        }
                    }
                    if appState.settings.appleProcessingPolicy == .allowAppleService {
                        Text("Audio may be sent to Apple servers. Choose on-device only to prevent network fallback.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var llmTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(title: "Text optimization") {
                SettingsRow(
                    "Enable LLM optimization",
                    subtitle: "Run transcripts through a language model to clean up punctuation, casing, or wording."
                ) {
                    Toggle("", isOn: $appState.settings.llmEnabled).labelsHidden()
                }
                SettingsRow("Optimization behavior", subtitle: "What kind of rewrite the model should perform.") {
                    Picker("", selection: $appState.settings.llmOptimizationBehavior) {
                        ForEach(TextOptimizationBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .disabled(!appState.settings.llmEnabled)
            }

            SettingsSection(title: "OpenAI-compatible API") {
                SettingsRow("Endpoint") {
                    TextField("https://…", text: $appState.settings.llmEndpoint)
                        .labelsHidden()
                }
                .disabled(!appState.settings.llmEnabled)
                SettingsRow("Model ID") {
                    TextField("gpt-4o-mini", text: $appState.settings.llmModelID)
                        .labelsHidden()
                }
                .disabled(!appState.settings.llmEnabled)
                SettingsRow("Timeout") {
                    numberField(value: $appState.settings.llmTimeoutSeconds, suffix: "s", precision: 0)
                }
                .disabled(!appState.settings.llmEnabled)
                apiKeyRow(value: $appState.settings.llmAPIKey)
                    .disabled(!appState.settings.llmEnabled)
            }
        }
    }

    /// What the audio spool currently occupies. Deliberately surfaced rather
    /// than capped: a large backlog means the user really has been offline for a
    /// while, and silently deleting the audio would defeat the point of keeping
    /// it. Retained audio is reported separately since it only grows by choice.
    private var audioStorageDescription: String {
        guard let pending = appState.pendingAudio else { return "—" }
        func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        var lines = ["\(pending.pendingCount) waiting · \(size(pending.pendingBytes))"]
        if pending.retainedBytes > 0 {
            lines.append("\(size(pending.retainedBytes)) saved")
        }
        return lines.joined(separator: "\n")
    }

    /// One count in the activity row: the number, with its label underneath.
    /// Coarse on purpose: this is "how much has it done for me", not a stopwatch.
    private static func durationText(milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private func activityStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Most recent pipeline event, as state + how long ago. The raw reason code
    /// is deliberately left out — it's debug detail, not status.
    private var lastEventDescription: String {
        guard let activity = appState.activity else { return "Activity unavailable." }
        guard let state = activity.lastEventState, let ms = activity.lastEventAtMs else {
            return "No events yet."
        }
        let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
        let elapsed = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "Last event: \(state) · \(elapsed)"
    }

    private func apiKeyRow(value: Binding<String>) -> some View {
        SettingsRow("API key") {
            SecureField("", text: value)
                .labelsHidden()
        }
    }

    /// Plain, validated numeric input — replaces the stepper controls. SwiftUI's
    /// `TextField(value:format:)` rejects non-numeric text on commit and reverts to
    /// the last valid value; `RecorderSettings.validated()` then clamps it to range.
    private func numberField(value: Binding<Int>, suffix: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private func numberField(value: Binding<Double>, suffix: String, precision: Int) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number.precision(.fractionLength(precision)))
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    /// Debounce setting persistence to avoid hammering the coordinator and
    /// UserDefaults during rapid slider / text-field edits.  The final value
    /// is always flushed when the window disappears (see ``onDisappear``).
    private func debouncedPersistSettings() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            appState.persistSettings()
            persistDebounceTask = nil
        }
    }

    private var availablePlaybackPolicies: [PlaybackPolicy] {
        return [.ignorePlayback, .pauseOnOutputIO]
    }
}

/// A titled group of rows, replacing `Form`/`Section` (whose macOS layout wastes
/// vertical space and shares one label column across unrelated sections).
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
        }
    }
}

/// Shared footer strip for reporting a tab's status (validation, save, export…).
/// One place to draw this instead of every tab building its own status text.
private struct StatusBar: View {
    let message: String
    let isValid: Bool

    var body: some View {
        Label(message, systemImage: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(isValid ? .green : .orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, settingsContentPadding)
            .padding(.vertical, 10)
    }
}

/// Fixed label/control column widths shared by every `SettingsRow` and by any
/// other control that needs to line up with them (e.g. `appRulesEditor`). A
/// single shared constant, rather than a per-row override, is what keeps every
/// tab's layout identical — there is no knob left for a tab to drift out of line.
// Labels carry the wordy part (title + explanatory subtitle) while most controls
// are toggles or short number fields, so the label column gets the larger share.
// The control column still has to fit the widest control — the VAD slider — so it
// cannot shrink to the width a checkbox alone would need.
private let settingsLabelWidth: CGFloat = 300
private let settingsControlWidth: CGFloat = 220
private let settingsColumnSpacing: CGFloat = 16
private let settingsContentPadding: CGFloat = 24

/// The one content-box width every tab is laid out in, so no tab can be wider or
/// narrower than another. Derived from the columns rather than hardcoded, so the
/// box and the rows inside it can never disagree.
private let settingsContentWidth: CGFloat = settingsLabelWidth + settingsColumnSpacing + settingsControlWidth

/// A label(+subtitle) / trailing-control row. All rows share the same label column
/// width and the same control column width, so every tab lines up the same way.
private struct SettingsRow<Content: View>: View {
    enum ContentAlignment { case center, top }

    let title: String
    let subtitle: String?
    let alignment: ContentAlignment
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        alignment: ContentAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment == .top ? .top : .center, spacing: settingsColumnSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: settingsLabelWidth, alignment: .leading)

            content
                .frame(width: settingsControlWidth, alignment: .trailing)
        }
    }
}
