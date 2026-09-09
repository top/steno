import Foundation

public struct STTAvailability: Sendable {
    public var isAvailable: Bool
    public var message: String?

    public init(isAvailable: Bool, message: String? = nil) {
        self.isAvailable = isAvailable
        self.message = message
    }
}

public struct TranscriptionRequest: Sendable {
    public var segmentID: String
    /// Raw little-endian Float32 mono samples, at `sampleRateHz`. Not yet encoded
    /// into any audio container — providers that need a file (e.g. WAV) build it themselves.
    public var pcmData: Data?
    public var sampleRateHz: Double
    public var source: SegmentSource
    public var language: Locale
    public var providerSnapshot: String
    public var deadline: Date

    public init(
        segmentID: String,
        pcmData: Data?,
        sampleRateHz: Double,
        source: SegmentSource,
        language: Locale,
        providerSnapshot: String,
        deadline: Date
    ) {
        self.segmentID = segmentID
        self.pcmData = pcmData
        self.sampleRateHz = sampleRateHz
        self.source = source
        self.language = language
        self.providerSnapshot = providerSnapshot
        self.deadline = deadline
    }
}

public struct TranscriptionResult: Sendable {
    public var text: String
    public var isFinal: Bool
    public var language: String
    public var confidence: Double?
    public var providerKind: STTProviderKind
    public var engineVersionOrMode: String?

    public init(
        text: String,
        isFinal: Bool,
        language: String,
        confidence: Double?,
        providerKind: STTProviderKind,
        engineVersionOrMode: String?
    ) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.confidence = confidence
        self.providerKind = providerKind
        self.engineVersionOrMode = engineVersionOrMode
    }
}

public protocol STTProvider: Sendable {
    var kind: STTProviderKind { get }
    func availability(for language: Locale) async -> STTAvailability
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public enum STTProviderError: LocalizedError {
    case invalidConfiguration(String)
    case missingAPIKey
    case unsupported(String)
    /// The provider ran fine and heard nothing worth keeping. Unlike every other
    /// error here this will not change on a second attempt, so it is the one
    /// failure the pipeline is allowed to treat as final and discard.
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .missingAPIKey:
            return "API key not found. Save it in Settings."
        case .unsupported(let message):
            return message
        case .emptyTranscript:
            return "No speech was recognized in this segment."
        }
    }

    /// Whether retrying could plausibly succeed. A wrong key or a dropped network
    /// is worth another pass; silence never is.
    public var isPermanent: Bool {
        if case .emptyTranscript = self { return true }
        return false
    }
}
