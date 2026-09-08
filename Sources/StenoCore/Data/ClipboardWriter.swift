import AppKit
import Foundation

public enum ClipboardWriteOutcome: Sendable {
    case success
    case skipped
    case denied
}

public actor ClipboardWriter {
    private let databaseWriter: DatabaseWriter
    private var copiedSegmentIDs = Set<String>()
    private var latestCopiedEndMs: Int64 = .min

    public init(databaseWriter: DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func write(text: String, segmentID: String, endedAtMs: Int64) async -> ClipboardWriteOutcome {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !copiedSegmentIDs.contains(segmentID),
              endedAtMs >= latestCopiedEndMs else {
            return .skipped
        }

        let writeResult = await MainActor.run { () -> (succeeded: Bool, changeCount: Int) in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return (pasteboard.setString(normalized, forType: .string), pasteboard.changeCount)
        }
        let succeeded = writeResult.succeeded
        let outcome: ClipboardWriteOutcome = succeeded ? .success : .denied
        if succeeded {
            copiedSegmentIDs.insert(segmentID)
            latestCopiedEndMs = endedAtMs
        }
        try? await databaseWriter.recordClipboardEvent(
            segmentID: segmentID,
            result: succeeded ? "success" : "denied",
            textCharacterCount: normalized.count,
            pasteboardChangeCount: writeResult.changeCount,
            errorCode: succeeded ? nil : "pasteboard_write_rejected"
        )
        return outcome
    }
}
