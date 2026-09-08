import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Database open failed: \(message)"
        case .executeFailed(let message):
            return "Database execution failed: \(message)"
        case .prepareFailed(let message):
            return "Database prepare failed: \(message)"
        case .bindFailed(let message):
            return "Database bind failed: \(message)"
        case .stepFailed(let message):
            return "Database write failed: \(message)"
        }
    }
}

public struct TranscriptRecord: Sendable, Identifiable {
    public let id: String
    public let source: SegmentSource
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let text: String
    public let language: String?
    public let status: String
}

public actor DatabaseWriter {
    public nonisolated let databaseURL: URL
    private var db: OpaquePointer?

    public init(appName: String = "Steno") throws {
        let fileManager = FileManager.default
        let appSupport = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(appName, isDirectory: true)

        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbURL = appSupport.appendingPathComponent("Steno.sqlite3")
        self.databaseURL = dbURL

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &pointer, flags, nil) != SQLITE_OK {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(pointer)
            throw DatabaseError.openFailed(message)
        }

        guard let openedDB = pointer else {
            throw DatabaseError.openFailed("db pointer unavailable")
        }

        self.db = openedDB
        try Self.execute(openedDB, sql: "PRAGMA foreign_keys=ON;")
        try Self.execute(openedDB, sql: "PRAGMA journal_mode=WAL;")
        try Self.runMigrations(on: openedDB)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func recordStateTransition(
        from previous: CaptureState?,
        to next: CaptureState,
        reasonCode: String,
        detailsJSON: String? = nil,
        relatedPID: Int32? = nil,
        relatedBundleID: String? = nil
    ) throws {
        let sql = """
        INSERT INTO capture_events(
            id, occurred_at_ms, previous_state, new_state, reason_code,
            related_pid, related_bundle_id, input_device_uid, output_device_uid, details_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?);
        """

        guard let db else { throw DatabaseError.openFailed("db unavailable") }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        let now = Self.nowMilliseconds()
        guard bindText(statement, index: 1, value: UUID().uuidString),
              sqlite3_bind_int64(statement, 2, sqlite3_int64(now)) == SQLITE_OK,
              bindOptionalText(statement, index: 3, value: previous?.rawValue),
              bindText(statement, index: 4, value: next.rawValue),
              bindText(statement, index: 5, value: reasonCode),
              bindOptionalInt(statement, index: 6, value: relatedPID.map(Int.init)),
              bindOptionalText(statement, index: 7, value: relatedBundleID),
              bindOptionalText(statement, index: 8, value: detailsJSON) else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func insertSegment(_ segment: TranscriptSegment) throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        try Self.execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            try insertSegmentIntoTable(segment, on: db)
            if let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                try insertTranscriptVersion(
                    TranscriptVersion(
                        segmentID: segment.id,
                        kind: .raw,
                        text: text,
                        language: segment.language,
                        provenanceStage: "segment_insert",
                        provenanceProvider: segment.sttProvider.rawValue,
                        provenanceModel: segment.sttModel,
                        provenanceSnapshotJSON: segment.providerSnapshotJSON,
                        createdAtMs: segment.updatedAtMs
                    ),
                    on: db
                )
            }
            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func insertSegmentIntoTable(_ segment: TranscriptSegment, on db: OpaquePointer) throws {
        let sql = """
        INSERT INTO transcript_segments(
            id, source, started_at_ms, ended_at_ms, text, language, stt_provider,
            provider_snapshot_json, stt_model, confidence, status, termination_reason,
            continuation_group_id, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, index: 1, value: segment.id),
              bindText(statement, index: 2, value: segment.source.rawValue),
              sqlite3_bind_int64(statement, 3, segment.startedAtMs) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, segment.endedAtMs) == SQLITE_OK,
              bindOptionalText(statement, index: 5, value: segment.text),
              bindText(statement, index: 6, value: segment.language),
              bindText(statement, index: 7, value: segment.sttProvider.rawValue),
              bindText(statement, index: 8, value: segment.providerSnapshotJSON),
              bindOptionalText(statement, index: 9, value: segment.sttModel),
              bindOptionalDouble(statement, index: 10, value: segment.confidence),
              bindText(statement, index: 11, value: segment.status),
              bindOptionalText(statement, index: 12, value: segment.terminationReason),
              bindOptionalText(statement, index: 13, value: segment.continuationGroupID),
              sqlite3_bind_int64(statement, 14, segment.createdAtMs) == SQLITE_OK,
              sqlite3_bind_int64(statement, 15, segment.updatedAtMs) == SQLITE_OK else {
            throw DatabaseError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func createSTTJob(id: String, segmentID: String, providerName: String, providerSnapshotJSON: String) throws {
        let sql = """
        INSERT INTO stt_jobs(
          id, segment_id, attempt_count, state, provider_name, provider_snapshot_json,
          error_code, error_message, next_retry_at_ms, created_at_ms, updated_at_ms
        ) VALUES (?, ?, 0, 'queued', ?, ?, NULL, NULL, NULL, ?, ?);
        """
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        let now = Self.nowMilliseconds()
        guard bindText(statement, index: 1, value: id),
              bindText(statement, index: 2, value: segmentID),
              bindText(statement, index: 3, value: providerName),
              bindText(statement, index: 4, value: providerSnapshotJSON),
              sqlite3_bind_int64(statement, 5, now) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, now) == SQLITE_OK else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func updateSTTJob(id: String, attemptCount: Int, state: String, error: Error? = nil, nextRetryAtMs: Int64? = nil) throws {
        let sql = """
        UPDATE stt_jobs
        SET attempt_count=?, state=?, error_code=?, error_message=?, next_retry_at_ms=?, updated_at_ms=?
        WHERE id=?;
        """
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(attemptCount)) == SQLITE_OK,
              bindText(statement, index: 2, value: state),
              bindOptionalText(statement, index: 3, value: error.map { String(describing: type(of: $0)) }),
              bindOptionalText(statement, index: 4, value: error.map { String($0.localizedDescription.prefix(1_000)) }),
              bindOptionalInt64(statement, index: 5, value: nextRetryAtMs),
              sqlite3_bind_int64(statement, 6, Self.nowMilliseconds()) == SQLITE_OK,
              bindText(statement, index: 7, value: id) else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func completeSTTJob(id: String) throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        var statement: OpaquePointer?
        let sql = "UPDATE stt_jobs SET state='completed', error_code=NULL, error_message=NULL, next_retry_at_ms=NULL, updated_at_ms=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Self.nowMilliseconds()) == SQLITE_OK,
              bindText(statement, index: 2, value: id) else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func markSegmentSTTFailed(segmentID: String, reason: String) throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        var statement: OpaquePointer?
        let sql = "UPDATE transcript_segments SET status='stt_failed', termination_reason=?, updated_at_ms=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, index: 1, value: String(reason.prefix(1_000))),
              sqlite3_bind_int64(statement, 2, Self.nowMilliseconds()) == SQLITE_OK,
              bindText(statement, index: 3, value: segmentID) else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func recordClipboardEvent(segmentID: String, result: String, textCharacterCount: Int, pasteboardChangeCount: Int?, errorCode: String?) throws {
        let sql = """
        INSERT INTO clipboard_events(
          id, segment_id, occurred_at_ms, operation, result,
          text_char_count, pasteboard_change_count, error_code
        ) VALUES (?, ?, ?, 'write', ?, ?, ?, ?);
        """
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, index: 1, value: UUID().uuidString),
              bindText(statement, index: 2, value: segmentID),
              sqlite3_bind_int64(statement, 3, Self.nowMilliseconds()) == SQLITE_OK,
              bindText(statement, index: 4, value: result),
              sqlite3_bind_int(statement, 5, Int32(textCharacterCount)) == SQLITE_OK,
              bindOptionalInt(statement, index: 6, value: pasteboardChangeCount),
              bindOptionalText(statement, index: 7, value: errorCode) else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    public func queryTranscripts(search: String? = nil, limit: Int = 500) throws -> [TranscriptRecord] {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        let normalized = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filtered = !normalized.isEmpty
        let sql = """
        SELECT id, source, started_at_ms, ended_at_ms, COALESCE(text, ''), language, status
        FROM transcript_segments
        \(filtered ? "WHERE text LIKE '%' || ? || '%'" : "")
        ORDER BY started_at_ms ASC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if filtered {
            guard bindText(statement, index: index, value: normalized) else {
                throw DatabaseError.bindFailed(lastErrorMessage())
            }
            index += 1
        }
        guard sqlite3_bind_int64(statement, index, Int64(max(1, limit))) == SQLITE_OK else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }
        var records: [TranscriptRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, index: 0),
                  let sourceText = columnText(statement, index: 1),
                  let source = SegmentSource(rawValue: sourceText),
                  let text = columnText(statement, index: 4),
                  let status = columnText(statement, index: 6) else { continue }
            records.append(
                TranscriptRecord(
                    id: id,
                    source: source,
                    startedAtMs: sqlite3_column_int64(statement, 2),
                    endedAtMs: sqlite3_column_int64(statement, 3),
                    text: text,
                    language: columnText(statement, index: 5),
                    status: status
                )
            )
        }
        return records
    }

    public struct ActivitySummary: Sendable {
        public let capturedSegments: Int
        public let completedSegments: Int
        public let failedSegments: Int
        public let pendingJobs: Int
        public let lastEventState: String?
        public let lastEventReason: String?
        public let lastEventAtMs: Int64?
    }

    /// One-shot snapshot of what the pipeline has actually done, for surfacing
    /// in Settings so "is it working?" doesn't require opening the sqlite file by hand.
    public func activitySummary() throws -> ActivitySummary {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }

        func scalarInt(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        let captured = try scalarInt("SELECT COUNT(*) FROM transcript_segments WHERE status='captured';")
        let completed = try scalarInt("SELECT COUNT(*) FROM transcript_segments WHERE status='completed';")
        let failed = try scalarInt("SELECT COUNT(*) FROM transcript_segments WHERE status='stt_failed';")
        let pendingJobs = try scalarInt("SELECT COUNT(*) FROM stt_jobs WHERE state IN ('queued','running','retry_wait');")

        var lastState: String?
        var lastReason: String?
        var lastAt: Int64?
        var lastBundleID: String?
        var statement: OpaquePointer?
        // Order by rowid, not occurred_at_ms: rapid arbitration flapping can produce
        // multiple events within the same millisecond, and rowid reflects true insertion order.
        let lastEventSQL = "SELECT new_state, reason_code, occurred_at_ms, related_bundle_id FROM capture_events ORDER BY rowid DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, lastEventSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        if sqlite3_step(statement) == SQLITE_ROW {
            lastState = columnText(statement, index: 0)
            lastReason = columnText(statement, index: 1)
            lastAt = sqlite3_column_int64(statement, 2)
            lastBundleID = columnText(statement, index: 3)
        }
        sqlite3_finalize(statement)

        return ActivitySummary(
            capturedSegments: captured,
            completedSegments: completed,
            failedSegments: failed,
            pendingJobs: pendingJobs,
            lastEventState: lastState,
            lastEventReason: lastBundleID.map { "\(lastReason ?? "-") (\($0))" } ?? lastReason,
            lastEventAtMs: lastAt
        )
    }

    public func exportTranscripts(to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        let text = try queryTranscripts(limit: Int.max).compactMap { record -> String? in
            let content = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let date = Date(timeIntervalSince1970: Double(record.startedAtMs) / 1_000)
            return "[\(formatter.string(from: date))] [\(record.source.rawValue)] \(content)"
        }.joined(separator: "\n")
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func deleteAllTranscripts() throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        try Self.execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            try Self.execute(db, sql: "DELETE FROM clipboard_events;")
            try Self.execute(db, sql: "DELETE FROM stt_jobs;")
            try Self.execute(db, sql: "DELETE FROM transcript_versions;")
            try Self.execute(db, sql: "DELETE FROM transcript_segments;")
            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func insertTranscriptVersion(_ version: TranscriptVersion) throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        try insertTranscriptVersion(version, on: db)
    }

    public func recordTranscriptionVersions(
        segmentID: String,
        rawText: String,
        language: String,
        sttProvider: STTProviderKind,
        sttModel: String?,
        confidence: Double?,
        sttSnapshotJSON: String,
        optimizedResult: TextOptimizationResult?
    ) throws {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }

        let normalizedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRawText.isEmpty else {
            throw DatabaseError.bindFailed("rawText cannot be empty")
        }

        try Self.execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            let timestampMs = Self.nowMilliseconds()
            let rawVersion = TranscriptVersion(
                segmentID: segmentID,
                kind: .raw,
                text: normalizedRawText,
                language: language,
                provenanceStage: "stt_raw_output",
                provenanceProvider: sttProvider.rawValue,
                provenanceModel: sttModel,
                provenanceSnapshotJSON: sttSnapshotJSON,
                createdAtMs: timestampMs
            )
            try insertTranscriptVersion(rawVersion, on: db)

            var activeText = normalizedRawText
            if let optimizedResult {
                let normalizedOptimizedText = optimizedResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedOptimizedText.isEmpty {
                    let optimizedVersion = TranscriptVersion(
                        segmentID: segmentID,
                        kind: .optimized,
                        text: normalizedOptimizedText,
                        language: language,
                        provenanceStage: "llm_optimization",
                        provenanceProvider: optimizedResult.providerName,
                        provenanceModel: optimizedResult.modelID,
                        provenanceSnapshotJSON: optimizedResult.providerSnapshotJSON,
                        sourceVersionID: rawVersion.id,
                        createdAtMs: timestampMs
                    )
                    try insertTranscriptVersion(optimizedVersion, on: db)
                    activeText = normalizedOptimizedText
                }
            }

            let updateSQL = """
        UPDATE transcript_segments
        SET text = ?, language = ?, stt_provider = ?, stt_model = ?, confidence = ?, status = ?, updated_at_ms = ?
        WHERE id = ?;
        """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }

            guard bindText(statement, index: 1, value: activeText),
                  bindText(statement, index: 2, value: language),
                  bindText(statement, index: 3, value: sttProvider.rawValue),
                  bindOptionalText(statement, index: 4, value: sttModel),
                  bindOptionalDouble(statement, index: 5, value: confidence),
                  bindText(statement, index: 6, value: "completed"),
                  sqlite3_bind_int64(statement, 7, sqlite3_int64(timestampMs)) == SQLITE_OK,
                  bindText(statement, index: 8, value: segmentID) else {
                throw DatabaseError.bindFailed(lastErrorMessage())
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(lastErrorMessage())
            }

            guard sqlite3_changes(db) > 0 else {
                throw DatabaseError.stepFailed("segment not found for transcript update")
            }
            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func validateTranscriptVersionSchema() throws -> Bool {
        guard let db else { throw DatabaseError.openFailed("db unavailable") }
        let columns = try tableColumns(tableName: "transcript_versions", on: db)
        let expected = [
            "id",
            "segment_id",
            "version_kind",
            "text",
            "language",
            "provenance_stage",
            "provenance_provider",
            "provenance_model",
            "provenance_snapshot_json",
            "source_version_id",
            "created_at_ms"
        ]
        for column in expected {
            if !columns.contains(column) {
                return false
            }
        }
        return true
    }

    private static func runMigrations(on db: OpaquePointer) throws {
        try execute(
            db,
            sql:
            """
            CREATE TABLE IF NOT EXISTS transcript_segments (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL CHECK(source IN ('microphone','system_output')),
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              text TEXT,
              language TEXT,
              stt_provider TEXT NOT NULL,
              provider_snapshot_json TEXT NOT NULL,
              stt_model TEXT,
              confidence REAL,
              status TEXT NOT NULL,
              termination_reason TEXT,
              continuation_group_id TEXT,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE TABLE IF NOT EXISTS transcript_versions (
              id TEXT PRIMARY KEY,
              segment_id TEXT NOT NULL,
              version_kind TEXT NOT NULL CHECK(version_kind IN ('raw','optimized')),
              text TEXT NOT NULL,
              language TEXT NOT NULL,
              provenance_stage TEXT NOT NULL,
              provenance_provider TEXT,
              provenance_model TEXT,
              provenance_snapshot_json TEXT,
              source_version_id TEXT,
              created_at_ms INTEGER NOT NULL,
              FOREIGN KEY(segment_id) REFERENCES transcript_segments(id) ON DELETE CASCADE,
              FOREIGN KEY(source_version_id) REFERENCES transcript_versions(id) ON DELETE SET NULL
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_versions_segment_created
            ON transcript_versions(segment_id, created_at_ms);
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_versions_source
            ON transcript_versions(source_version_id);
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE TABLE IF NOT EXISTS stt_jobs (
              id TEXT PRIMARY KEY,
              segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              provider_name TEXT NOT NULL,
              provider_snapshot_json TEXT NOT NULL,
              error_code TEXT,
              error_message TEXT,
              next_retry_at_ms INTEGER,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE TABLE IF NOT EXISTS capture_events (
              id TEXT PRIMARY KEY,
              occurred_at_ms INTEGER NOT NULL,
              previous_state TEXT,
              new_state TEXT NOT NULL,
              reason_code TEXT NOT NULL,
              related_pid INTEGER,
              related_bundle_id TEXT,
              input_device_uid TEXT,
              output_device_uid TEXT,
              details_json TEXT
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE TABLE IF NOT EXISTS clipboard_events (
              id TEXT PRIMARY KEY,
              segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
              occurred_at_ms INTEGER NOT NULL,
              operation TEXT NOT NULL CHECK(operation IN ('write')),
              result TEXT NOT NULL CHECK(result IN ('success','denied','failed')),
              text_char_count INTEGER NOT NULL,
              pasteboard_change_count INTEGER,
              error_code TEXT
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
              text,
              content='transcript_segments',
              content_rowid='rowid'
            );
            """
        )

        try execute(
            db,
            sql:
            """
            CREATE TRIGGER IF NOT EXISTS transcript_fts_ai AFTER INSERT ON transcript_segments BEGIN
              INSERT INTO transcript_fts(rowid, text) VALUES (new.rowid, COALESCE(new.text, ''));
            END;
            CREATE TRIGGER IF NOT EXISTS transcript_fts_ad AFTER DELETE ON transcript_segments BEGIN
              INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES('delete', old.rowid, COALESCE(old.text, ''));
            END;
            CREATE TRIGGER IF NOT EXISTS transcript_fts_au AFTER UPDATE ON transcript_segments BEGIN
              INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES('delete', old.rowid, COALESCE(old.text, ''));
              INSERT INTO transcript_fts(rowid, text) VALUES (new.rowid, COALESCE(new.text, ''));
            END;
            """
        )
    }

    private static func execute(_ db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw DatabaseError.executeFailed(message)
        }
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) -> Bool {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) -> Bool {
        if let value {
            return sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK
        }
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, index: Int32, value: Double?) -> Bool {
        if let value {
            return sqlite3_bind_double(statement, index, value) == SQLITE_OK
        }
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }

    private func bindOptionalInt64(_ statement: OpaquePointer?, index: Int32, value: Int64?) -> Bool {
        if let value {
            return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
        }
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, index: Int32, value: Int?) -> Bool {
        if let value {
            return sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK
        }
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func insertTranscriptVersion(_ version: TranscriptVersion, on db: OpaquePointer) throws {
        let sql = """
        INSERT INTO transcript_versions(
            id, segment_id, version_kind, text, language, provenance_stage,
            provenance_provider, provenance_model, provenance_snapshot_json,
            source_version_id, created_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, index: 1, value: version.id),
              bindText(statement, index: 2, value: version.segmentID),
              bindText(statement, index: 3, value: version.kind.rawValue),
              bindText(statement, index: 4, value: version.text),
              bindText(statement, index: 5, value: version.language),
              bindText(statement, index: 6, value: version.provenanceStage),
              bindOptionalText(statement, index: 7, value: version.provenanceProvider),
              bindOptionalText(statement, index: 8, value: version.provenanceModel),
              bindOptionalText(statement, index: 9, value: version.provenanceSnapshotJSON),
              bindOptionalText(statement, index: 10, value: version.sourceVersionID),
              sqlite3_bind_int64(statement, 11, sqlite3_int64(version.createdAtMs)) == SQLITE_OK else {
            throw DatabaseError.bindFailed(lastErrorMessage())
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    private func tableColumns(tableName: String, on db: OpaquePointer) throws -> Set<String> {
        let pragmaSQL = "PRAGMA table_info(\(tableName));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragmaSQL, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePointer = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: namePointer))
            }
        }
        return columns
    }

    private func lastErrorMessage() -> String {
        guard let db else { return "db unavailable" }
        return String(cString: sqlite3_errmsg(db))
    }

    public static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
