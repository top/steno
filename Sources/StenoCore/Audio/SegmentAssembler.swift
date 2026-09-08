import Foundation

public actor SegmentAssembler {
    private var openSegmentStartMs: Int64?

    public init() {}

    public func handle(
        event: VADEvent,
        source: SegmentSource,
        settings: RecorderSettings,
        providerSnapshotJSON: String
    ) -> TranscriptSegment? {
        switch event {
        case .segmentStarted(let startedAtMs):
            openSegmentStartMs = startedAtMs
            return nil

        case .segmentEnded(let endedAtMs, let reason):
            guard let startedAtMs = openSegmentStartMs else {
                return nil
            }
            openSegmentStartMs = nil

            let duration = endedAtMs - startedAtMs
            guard duration >= Int64(settings.minSegmentMs) else {
                return nil
            }

            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return TranscriptSegment(
                source: source,
                startedAtMs: startedAtMs,
                endedAtMs: endedAtMs,
                language: settings.languageIdentifier,
                sttProvider: settings.sttProvider,
                providerSnapshotJSON: providerSnapshotJSON,
                sttModel: settings.sttProvider == .customAPI
                    ? settings.customModelID
                    : settings.appleProcessingPolicy.rawValue,
                status: "captured",
                terminationReason: reason,
                createdAtMs: now,
                updatedAtMs: now
            )
        }
    }
}
