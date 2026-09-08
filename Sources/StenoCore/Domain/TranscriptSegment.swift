import Foundation

public enum SegmentSource: String, Codable, Sendable {
    case microphone
    case systemOutput = "system_output"
}

public struct TranscriptSegment: Codable, Sendable {
    public var id: String
    public var source: SegmentSource
    public var startedAtMs: Int64
    public var endedAtMs: Int64
    public var text: String?
    public var language: String
    public var sttProvider: STTProviderKind
    public var providerSnapshotJSON: String
    public var sttModel: String?
    public var confidence: Double?
    public var status: String
    public var terminationReason: String?
    public var continuationGroupID: String?
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    public init(
        id: String = UUID().uuidString,
        source: SegmentSource,
        startedAtMs: Int64,
        endedAtMs: Int64,
        text: String? = nil,
        language: String,
        sttProvider: STTProviderKind,
        providerSnapshotJSON: String,
        sttModel: String? = nil,
        confidence: Double? = nil,
        status: String,
        terminationReason: String? = nil,
        continuationGroupID: String? = nil,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.source = source
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.text = text
        self.language = language
        self.sttProvider = sttProvider
        self.providerSnapshotJSON = providerSnapshotJSON
        self.sttModel = sttModel
        self.confidence = confidence
        self.status = status
        self.terminationReason = terminationReason
        self.continuationGroupID = continuationGroupID
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }
}
