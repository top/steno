import Foundation

public enum TranscriptVersionKind: String, Codable, Sendable {
    case raw
    case optimized
}

public struct TranscriptVersion: Codable, Sendable {
    public var id: String
    public var segmentID: String
    public var kind: TranscriptVersionKind
    public var text: String
    public var language: String
    public var provenanceStage: String
    public var provenanceProvider: String?
    public var provenanceModel: String?
    public var provenanceSnapshotJSON: String?
    public var sourceVersionID: String?
    public var createdAtMs: Int64

    public init(
        id: String = UUID().uuidString,
        segmentID: String,
        kind: TranscriptVersionKind,
        text: String,
        language: String,
        provenanceStage: String,
        provenanceProvider: String?,
        provenanceModel: String?,
        provenanceSnapshotJSON: String?,
        sourceVersionID: String? = nil,
        createdAtMs: Int64
    ) {
        self.id = id
        self.segmentID = segmentID
        self.kind = kind
        self.text = text
        self.language = language
        self.provenanceStage = provenanceStage
        self.provenanceProvider = provenanceProvider
        self.provenanceModel = provenanceModel
        self.provenanceSnapshotJSON = provenanceSnapshotJSON
        self.sourceVersionID = sourceVersionID
        self.createdAtMs = createdAtMs
    }
}
