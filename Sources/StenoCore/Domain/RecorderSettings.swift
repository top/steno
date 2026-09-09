import Foundation

public enum InputArbitrationMode: String, Codable, CaseIterable, Sendable {
    case alwaysRecord
    case yieldToAnyOtherInput
    case yieldToConfiguredApps
    case manualOnly

    public var displayName: String {
        switch self {
        case .alwaysRecord: return "Always record"
        case .yieldToAnyOtherInput: return "Yield to any input app"
        case .yieldToConfiguredApps: return "Yield to configured apps"
        case .manualOnly: return "Manual only"
        }
    }

    public var shouldYieldToExternalInput: Bool {
        switch self {
        case .yieldToAnyOtherInput, .yieldToConfiguredApps:
            return true
        case .alwaysRecord, .manualOnly:
            return false
        }
    }
}

public enum PlaybackPolicy: String, Codable, CaseIterable, Sendable {
    case ignorePlayback
    case pauseOnOutputIO
    case pauseOnAudibleOutput
    case transcribeSystemOutput

    public var displayName: String {
        switch self {
        case .ignorePlayback: return "Ignore playback"
        case .pauseOnOutputIO: return "Pause on output I/O (approximate)"
        case .pauseOnAudibleOutput: return "Pause on audible output (macOS 26+)"
        case .transcribeSystemOutput: return "Transcribe system output (macOS 26+)"
        }
    }

    public var suppressesMicCapture: Bool {
        switch self {
        case .pauseOnOutputIO, .pauseOnAudibleOutput:
            return true
        case .ignorePlayback, .transcribeSystemOutput:
            return false
        }
    }
}

public enum STTProviderKind: String, Codable, CaseIterable, Sendable {
    case customAPI
    case appleSystem

    public var displayName: String {
        switch self {
        case .customAPI: return "Custom OpenAI API"
        case .appleSystem: return "Apple System Speech"
        }
    }
}

public enum AppleProcessingPolicy: String, Codable, CaseIterable, Sendable {
    case onDeviceOnly
    case allowAppleService

    public var displayName: String {
        switch self {
        case .onDeviceOnly: return "On-device only (never sends audio to Apple)"
        case .allowAppleService: return "Allow Apple service (audio may go to Apple servers)"
        }
    }
}

public enum AppRuleKind: String, Codable, Sendable {
    case inputArbitration = "input"
    case outputDetection = "output"
    case systemOutputCapture = "system_output"
}

public enum AppRuleBehavior: String, Codable, Sendable {
    case include
    case exclude
    case forceYield
}

public struct AppRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bundleID: String
    public var displayName: String
    public var kind: AppRuleKind
    public var behavior: AppRuleBehavior

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        displayName: String = "",
        kind: AppRuleKind = .inputArbitration,
        behavior: AppRuleBehavior = .forceYield
    ) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.behavior = behavior
    }
}

public enum TextOptimizationBehavior: String, Codable, CaseIterable, Sendable {
    case punctuationAndCasing
    case readability
    case conciseNotes

    public var displayName: String {
        switch self {
        case .punctuationAndCasing: return "Punctuation and casing"
        case .readability: return "Readability rewrite"
        case .conciseNotes: return "Concise notes"
        }
    }
}

public struct RecorderSettings: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var autoStartRecordingOnLaunch: Bool

    public var inputArbitrationMode: InputArbitrationMode
    public var arbitrationRecoveryDelaySeconds: Double
    public var playbackPolicy: PlaybackPolicy

    public var speechOnsetMs: Int
    public var silenceEndMs: Int
    public var preRollMs: Int
    public var maxSegmentMs: Int
    public var minSegmentMs: Int
    public var vadSensitivity: Double

    public var sttProvider: STTProviderKind
    public var languageIdentifier: String
    public var customEndpoint: String
    public var customModelID: String
    public var customTimeoutSeconds: Double
    public var sttAPIKey: String
    /// Keep each segment's audio after its transcript is stored. Off by default:
    /// the spool exists to protect unfinished work, not to archive recordings.
    public var keepAudioAfterTranscription: Bool

    public var llmEnabled: Bool
    public var llmEndpoint: String
    public var llmModelID: String
    public var llmTimeoutSeconds: Double
    public var llmOptimizationBehavior: TextOptimizationBehavior
    public var llmAPIKey: String

    public var autoCopyFinalTranscript: Bool
    public var showClipboardWriteToast: Bool
    public var appRules: [AppRule]
    public var appleProcessingPolicy: AppleProcessingPolicy
    // Not persisted — drives a transient toast in the settings/menu UI only.
    public var clipboardToastMessage: String?

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case autoStartRecordingOnLaunch
        case inputArbitrationMode
        case arbitrationRecoveryDelaySeconds
        case playbackPolicy
        case speechOnsetMs
        case silenceEndMs
        case preRollMs
        case maxSegmentMs
        case minSegmentMs
        case vadSensitivity
        case sttProvider
        case languageIdentifier
        case customEndpoint
        case customModelID
        case customTimeoutSeconds
        case sttAPIKey
        case keepAudioAfterTranscription
        case llmEnabled
        case llmEndpoint
        case llmModelID
        case llmTimeoutSeconds
        case llmOptimizationBehavior
        case llmAPIKey
        case autoCopyFinalTranscript
        case showClipboardWriteToast
        case appRules
        case appleProcessingPolicy
    }

    public init(
        launchAtLogin: Bool = false,
        autoStartRecordingOnLaunch: Bool = false,
        inputArbitrationMode: InputArbitrationMode = .yieldToAnyOtherInput,
        arbitrationRecoveryDelaySeconds: Double = 2.0,
        playbackPolicy: PlaybackPolicy = .ignorePlayback,
        speechOnsetMs: Int = 250,
        silenceEndMs: Int = 1_200,
        preRollMs: Int = 400,
        maxSegmentMs: Int = 90_000,
        minSegmentMs: Int = 700,
        vadSensitivity: Double = 0.55,
        sttProvider: STTProviderKind = .customAPI,
        languageIdentifier: String = "auto",
        customEndpoint: String = "http://127.0.0.1:11434/v1/audio/transcriptions",
        customModelID: String = "Qwen3-ASR-1.7B",
        customTimeoutSeconds: Double = 30,
        sttAPIKey: String = "",
        keepAudioAfterTranscription: Bool = false,
        llmEnabled: Bool = false,
        llmEndpoint: String = "https://api.openai.com/v1/chat/completions",
        llmModelID: String = "gpt-4o-mini",
        llmTimeoutSeconds: Double = 20,
        llmOptimizationBehavior: TextOptimizationBehavior = .punctuationAndCasing,
        llmAPIKey: String = "",
        autoCopyFinalTranscript: Bool = false,
        showClipboardWriteToast: Bool = true,
        appRules: [AppRule] = [],
        appleProcessingPolicy: AppleProcessingPolicy = .onDeviceOnly
    ) {
        self.launchAtLogin = launchAtLogin
        self.autoStartRecordingOnLaunch = autoStartRecordingOnLaunch
        self.inputArbitrationMode = inputArbitrationMode
        self.arbitrationRecoveryDelaySeconds = arbitrationRecoveryDelaySeconds
        self.playbackPolicy = playbackPolicy
        self.speechOnsetMs = speechOnsetMs
        self.silenceEndMs = silenceEndMs
        self.preRollMs = preRollMs
        self.maxSegmentMs = maxSegmentMs
        self.minSegmentMs = minSegmentMs
        self.vadSensitivity = vadSensitivity
        self.sttProvider = sttProvider
        self.languageIdentifier = languageIdentifier
        self.customEndpoint = customEndpoint
        self.customModelID = customModelID
        self.customTimeoutSeconds = customTimeoutSeconds
        self.sttAPIKey = sttAPIKey
        self.keepAudioAfterTranscription = keepAudioAfterTranscription
        self.llmEnabled = llmEnabled
        self.llmEndpoint = llmEndpoint
        self.llmModelID = llmModelID
        self.llmTimeoutSeconds = llmTimeoutSeconds
        self.llmOptimizationBehavior = llmOptimizationBehavior
        self.llmAPIKey = llmAPIKey
        self.autoCopyFinalTranscript = autoCopyFinalTranscript
        self.showClipboardWriteToast = showClipboardWriteToast
        self.appRules = appRules
        self.appleProcessingPolicy = appleProcessingPolicy
        self.clipboardToastMessage = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecorderSettings()

        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        autoStartRecordingOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartRecordingOnLaunch) ?? defaults.autoStartRecordingOnLaunch
        inputArbitrationMode = try container.decodeIfPresent(InputArbitrationMode.self, forKey: .inputArbitrationMode) ?? defaults.inputArbitrationMode
        arbitrationRecoveryDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .arbitrationRecoveryDelaySeconds) ?? defaults.arbitrationRecoveryDelaySeconds
        playbackPolicy = try container.decodeIfPresent(PlaybackPolicy.self, forKey: .playbackPolicy) ?? defaults.playbackPolicy
        speechOnsetMs = try container.decodeIfPresent(Int.self, forKey: .speechOnsetMs) ?? defaults.speechOnsetMs
        silenceEndMs = try container.decodeIfPresent(Int.self, forKey: .silenceEndMs) ?? defaults.silenceEndMs
        preRollMs = try container.decodeIfPresent(Int.self, forKey: .preRollMs) ?? defaults.preRollMs
        maxSegmentMs = try container.decodeIfPresent(Int.self, forKey: .maxSegmentMs) ?? defaults.maxSegmentMs
        minSegmentMs = try container.decodeIfPresent(Int.self, forKey: .minSegmentMs) ?? defaults.minSegmentMs
        vadSensitivity = try container.decodeIfPresent(Double.self, forKey: .vadSensitivity) ?? defaults.vadSensitivity
        sttProvider = try container.decodeIfPresent(STTProviderKind.self, forKey: .sttProvider) ?? defaults.sttProvider
        languageIdentifier = try container.decodeIfPresent(String.self, forKey: .languageIdentifier) ?? defaults.languageIdentifier
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint) ?? defaults.customEndpoint
        customModelID = try container.decodeIfPresent(String.self, forKey: .customModelID) ?? defaults.customModelID
        customTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .customTimeoutSeconds) ?? defaults.customTimeoutSeconds
        sttAPIKey = try container.decodeIfPresent(String.self, forKey: .sttAPIKey) ?? defaults.sttAPIKey
        keepAudioAfterTranscription = try container.decodeIfPresent(Bool.self, forKey: .keepAudioAfterTranscription) ?? defaults.keepAudioAfterTranscription
        llmEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? defaults.llmEnabled
        llmEndpoint = try container.decodeIfPresent(String.self, forKey: .llmEndpoint) ?? defaults.llmEndpoint
        llmModelID = try container.decodeIfPresent(String.self, forKey: .llmModelID) ?? defaults.llmModelID
        llmTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .llmTimeoutSeconds) ?? defaults.llmTimeoutSeconds
        llmOptimizationBehavior = try container.decodeIfPresent(TextOptimizationBehavior.self, forKey: .llmOptimizationBehavior) ?? defaults.llmOptimizationBehavior
        llmAPIKey = try container.decodeIfPresent(String.self, forKey: .llmAPIKey) ?? defaults.llmAPIKey
        autoCopyFinalTranscript = try container.decodeIfPresent(Bool.self, forKey: .autoCopyFinalTranscript) ?? defaults.autoCopyFinalTranscript
        showClipboardWriteToast = try container.decodeIfPresent(Bool.self, forKey: .showClipboardWriteToast) ?? defaults.showClipboardWriteToast
        appRules = try container.decodeIfPresent([AppRule].self, forKey: .appRules) ?? defaults.appRules
        appleProcessingPolicy = try container.decodeIfPresent(AppleProcessingPolicy.self, forKey: .appleProcessingPolicy) ?? defaults.appleProcessingPolicy
        clipboardToastMessage = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(autoStartRecordingOnLaunch, forKey: .autoStartRecordingOnLaunch)
        try container.encode(inputArbitrationMode, forKey: .inputArbitrationMode)
        try container.encode(arbitrationRecoveryDelaySeconds, forKey: .arbitrationRecoveryDelaySeconds)
        try container.encode(playbackPolicy, forKey: .playbackPolicy)
        try container.encode(speechOnsetMs, forKey: .speechOnsetMs)
        try container.encode(silenceEndMs, forKey: .silenceEndMs)
        try container.encode(preRollMs, forKey: .preRollMs)
        try container.encode(maxSegmentMs, forKey: .maxSegmentMs)
        try container.encode(minSegmentMs, forKey: .minSegmentMs)
        try container.encode(vadSensitivity, forKey: .vadSensitivity)
        try container.encode(sttProvider, forKey: .sttProvider)
        try container.encode(languageIdentifier, forKey: .languageIdentifier)
        try container.encode(customEndpoint, forKey: .customEndpoint)
        try container.encode(customModelID, forKey: .customModelID)
        try container.encode(customTimeoutSeconds, forKey: .customTimeoutSeconds)
        try container.encode(sttAPIKey, forKey: .sttAPIKey)
        try container.encode(keepAudioAfterTranscription, forKey: .keepAudioAfterTranscription)
        try container.encode(llmEnabled, forKey: .llmEnabled)
        try container.encode(llmEndpoint, forKey: .llmEndpoint)
        try container.encode(llmModelID, forKey: .llmModelID)
        try container.encode(llmTimeoutSeconds, forKey: .llmTimeoutSeconds)
        try container.encode(llmOptimizationBehavior, forKey: .llmOptimizationBehavior)
        try container.encode(llmAPIKey, forKey: .llmAPIKey)
        try container.encode(autoCopyFinalTranscript, forKey: .autoCopyFinalTranscript)
        try container.encode(showClipboardWriteToast, forKey: .showClipboardWriteToast)
        try container.encode(appRules, forKey: .appRules)
        try container.encode(appleProcessingPolicy, forKey: .appleProcessingPolicy)
        // clipboardToastMessage is intentionally not persisted.
    }

    public func validated() -> RecorderSettings {
        var copy = self
        copy.arbitrationRecoveryDelaySeconds = min(max(arbitrationRecoveryDelaySeconds, 0.5), 10.0)
        copy.speechOnsetMs = min(max(speechOnsetMs, 100), 1_000)
        copy.silenceEndMs = min(max(silenceEndMs, 300), 5_000)
        copy.preRollMs = min(max(preRollMs, 0), 1_500)
        copy.maxSegmentMs = min(max(maxSegmentMs, 10_000), 300_000)
        copy.minSegmentMs = min(max(minSegmentMs, 200), 5_000)
        if copy.minSegmentMs > copy.maxSegmentMs {
            copy.minSegmentMs = copy.maxSegmentMs
        }
        copy.vadSensitivity = min(max(vadSensitivity, 0.0), 1.0)
        copy.appRules = copy.appRules.filter { rule in
            !rule.bundleID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        copy.customTimeoutSeconds = min(max(customTimeoutSeconds, 5), 120)
        copy.llmTimeoutSeconds = min(max(llmTimeoutSeconds, 5), 120)

        assert(copy.minSegmentMs <= copy.maxSegmentMs, "minSegmentMs must be <= maxSegmentMs after validation")
        assert((0...1).contains(copy.vadSensitivity), "vadSensitivity must be clamped to 0...1")
        assert((5...120).contains(copy.customTimeoutSeconds), "customTimeoutSeconds must be clamped")
        assert((5...120).contains(copy.llmTimeoutSeconds), "llmTimeoutSeconds must be clamped")
        return copy
    }
}
