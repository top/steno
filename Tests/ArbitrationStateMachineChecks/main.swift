import StenoCore
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
    return true
}

let arbitrator = AudioArbitrator()

let pausedDecision = arbitrator.evaluate(
    inputs: ArbitrationInputs(
        demand: .pausedByUser,
        hasMicrophonePermission: true,
        hasInputDevice: true,
        externalInputActive: true,
        playbackActive: true
    ),
    settings: RecorderSettings()
)
check(pausedDecision.state == .pausedByUser, "pausedByUser should win all priorities")

let permissionDecision = arbitrator.evaluate(
    inputs: ArbitrationInputs(
        demand: .active,
        hasMicrophonePermission: false,
        hasInputDevice: true,
        externalInputActive: true,
        playbackActive: true
    ),
    settings: RecorderSettings()
)
check(permissionDecision.state == .permissionRequired, "permissionRequired should preempt yield/playback")

let yieldDecision = arbitrator.evaluate(
    inputs: ArbitrationInputs(
        demand: .active,
        hasMicrophonePermission: true,
        hasInputDevice: true,
        externalInputActive: true,
        playbackActive: false
    ),
    settings: RecorderSettings(inputArbitrationMode: .yieldToAnyOtherInput)
)
check(yieldDecision.state == .yieldedToOtherInput, "yield policy should yield on external input")

let playbackDecision = arbitrator.evaluate(
    inputs: ArbitrationInputs(
        demand: .active,
        hasMicrophonePermission: true,
        hasInputDevice: true,
        externalInputActive: false,
        playbackActive: true
    ),
    settings: RecorderSettings(playbackPolicy: .pauseOnOutputIO)
)
check(playbackDecision.state == .suppressedByPlayback, "playback policy should suppress when active")

let recordDecision = arbitrator.evaluate(
    inputs: ArbitrationInputs(
        demand: .active,
        hasMicrophonePermission: true,
        hasInputDevice: true,
        externalInputActive: false,
        playbackActive: false
    ),
    settings: RecorderSettings()
)
check(recordDecision.state == .recording, "active state should record when no blockers")

let validatedSettings = RecorderSettings(
    speechOnsetMs: 10,
    silenceEndMs: 8_000,
    preRollMs: -20,
    maxSegmentMs: 4_000,
    minSegmentMs: 50_000,
    vadSensitivity: 2.0,
    customTimeoutSeconds: 1,
    llmTimeoutSeconds: 400
).validated()
check(validatedSettings.speechOnsetMs == 100, "speech onset should clamp to lower bound")
check(validatedSettings.silenceEndMs == 5_000, "silence end should clamp to upper bound")
check(validatedSettings.preRollMs == 0, "pre-roll should clamp to lower bound")
check(validatedSettings.maxSegmentMs == 10_000, "max segment should clamp to lower bound")
check(validatedSettings.minSegmentMs == 5_000, "min segment should clamp and stay <= max segment")
check(validatedSettings.minSegmentMs <= validatedSettings.maxSegmentMs, "validated min segment must not exceed max segment")
check(validatedSettings.vadSensitivity == 1.0, "VAD sensitivity should clamp to upper bound")
check(validatedSettings.customTimeoutSeconds == 5, "STT timeout should clamp to lower bound")
check(validatedSettings.llmTimeoutSeconds == 120, "LLM timeout should clamp to upper bound")

do {
    let schemaWriter = try DatabaseWriter(appName: "StenoSchemaChecks")
    let schemaDatabasePath = schemaWriter.databaseURL.path
    check(transcriptVersionSchemaExists(at: schemaDatabasePath), "transcript_versions schema should include required columns")
    check(tableExists("stt_jobs", at: schemaDatabasePath), "stt_jobs schema should exist")
    check(tableExists("clipboard_events", at: schemaDatabasePath), "clipboard_events schema should exist")
} catch {
    check(false, "schema writer initialization should succeed: \(error)")
}

do {
    let versionWriter = try DatabaseWriter(appName: "StenoVersionChecks")
    let now = DatabaseWriter.nowMilliseconds()
    let segmentID = UUID().uuidString
    let segment = TranscriptSegment(
        id: segmentID,
        source: .microphone,
        startedAtMs: now - 2_000,
        endedAtMs: now - 1_000,
        text: nil,
        language: "en-US",
        sttProvider: .customAPI,
        providerSnapshotJSON: "{}",
        status: "captured",
        createdAtMs: now,
        updatedAtMs: now
    )

    check(runDatabaseWrites(on: versionWriter, segment: segment), "database writes for transcript versions should succeed")

    let databasePath = versionWriter.databaseURL.path
    let rawCount = transcriptVersionCount(at: databasePath, segmentID: segmentID, kind: "raw")
    let optimizedCount = transcriptVersionCount(at: databasePath, segmentID: segmentID, kind: "optimized")
    check(rawCount == 2, "raw transcript versions should append without overwriting existing rows")
    check(optimizedCount == 0, "optimized transcript versions should be absent when optimizer is disabled")
} catch {
    check(false, "version writer initialization should succeed: \(error)")
}

let wavSamples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
let wavPCM = wavSamples.withUnsafeBufferPointer { Data(buffer: $0) }
let wavData = OpenAICompatibleSTTProvider.makeWAVData(pcmFloat32LittleEndian: wavPCM, sampleRate: 16_000)
check(wavData.count == 44 + wavSamples.count * 2, "WAV data should be a 44-byte header plus 16-bit samples")
check(wavData.prefix(4) == Data("RIFF".utf8), "WAV data should start with a RIFF header")
check(wavData[8..<12] == Data("WAVE".utf8), "WAV data should declare the WAVE format")

print("✅ Arbitration state machine assertions passed")
print("✅ Settings and schema assertions passed")
print("✅ WAV encoding assertions passed")

do {
    // Unique per run: these assertions are about whole-database counts, so a
    // reused database makes them pass once on a clean machine and fail on every
    // run after that.
    let activityWriter = try DatabaseWriter(appName: "StenoActivityChecks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: activityWriter.databaseURL.deletingLastPathComponent()) }
    let now = DatabaseWriter.nowMilliseconds()
    let segment = TranscriptSegment(
        source: .microphone,
        startedAtMs: now - 2_000,
        endedAtMs: now - 1_000,
        language: "en-US",
        sttProvider: .appleSystem,
        providerSnapshotJSON: "{}",
        sttModel: nil,
        status: "captured",
        terminationReason: "silence_timeout",
        createdAtMs: now,
        updatedAtMs: now
    )
    check(
        runActivitySummaryChecks(on: activityWriter, segment: segment),
        "activity summary should reflect captured/failed segments and the culprit process of a yield"
    )
} catch {
    check(false, "activity writer initialization should succeed: \(error)")
}

print("✅ Activity summary assertions passed")

do {
    // Speech with brief per-frame dips (unvoiced consonants) must still
    // cross the onset threshold instead of being reset to idle on every dip.
    var vad = VoiceActivityDetector()
    let settings = RecorderSettings(speechOnsetMs: 250, silenceEndMs: 1_200, vadSensitivity: 0.55)
    var timestamp: Int64 = 0
    var sawSegmentStarted = false
    // loud, quiet(dip), loud, quiet(dip), loud... spanning >250ms of onset.
    let levels: [Float] = [0.2, 0.2, 0.02, 0.2, 0.2, 0.02, 0.2, 0.2, 0.2]
    for level in levels {
        let event = vad.ingest(
            frame: AudioFrame(rms: level, timestampMs: timestamp, samples: [], sampleRate: 48_000),
            settings: settings
        )
        if case .segmentStarted = event { sawSegmentStarted = true }
        timestamp += 100
    }
    check(sawSegmentStarted, "VAD should tolerate brief sub-threshold dips during onset instead of resetting")
}

do {
    // A single loud frame right after idle should enter the candidate state,
    // not immediately record — hangover must not remove the onset debounce.
    var vad = VoiceActivityDetector()
    let settings = RecorderSettings(speechOnsetMs: 250, silenceEndMs: 1_200, vadSensitivity: 0.55)
    let event = vad.ingest(
        frame: AudioFrame(rms: 0.2, timestampMs: 0, samples: [], sampleRate: 48_000),
        settings: settings
    )
    check(event == nil && vad.state == .speechCandidate, "single loud frame should enter candidate state, not immediately record")
}

print("✅ VAD onset hangover assertions passed")

do {
    // AGC should pull a consistently quiet mic input up toward the target
    // RMS instead of leaving it under the VAD's speech threshold forever.
    var agc = AutomaticGainControl()
    var lastRMS: Float = 0
    for _ in 0..<40 {
        var samples = [Float](repeating: 0.01, count: 480)
        lastRMS = agc.apply(to: &samples, rawRMS: 0.01)
    }
    check(lastRMS > 0.03, "AGC should raise a consistently quiet signal well above its raw 0.01 RMS (got \(lastRMS))")
}

do {
    // Near-silence must not be amplified into audible hiss/false speech.
    var agc = AutomaticGainControl()
    var samples = [Float](repeating: 0.0005, count: 480)
    let rms = agc.apply(to: &samples, rawRMS: 0.0005)
    check(rms < 0.01, "AGC should not amplify below-noise-floor signal (got \(rms))")
}

print("✅ AGC assertions passed")

check(runPendingAudioStoreChecks(), "pending audio spool should survive a round trip and only release audio on finish")

print("✅ Pending audio spool assertions passed")

/// The spool is what stops an offline stretch from losing recordings, so the
/// round trip has to hold: audio written, listed oldest-first, read back at
/// 16-bit fidelity, and removed only when explicitly finished.
func runPendingAudioStoreChecks() -> Bool {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoPendingAudioChecks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false

    func segment(startedAtMs: Int64) -> TranscriptSegment {
        TranscriptSegment(
            source: .microphone,
            startedAtMs: startedAtMs,
            endedAtMs: startedAtMs + 1_000,
            language: "en-US",
            sttProvider: .customAPI,
            providerSnapshotJSON: "{}",
            status: "captured",
            createdAtMs: startedAtMs,
            updatedAtMs: startedAtMs
        )
    }

    Task {
        do {
            let store = try PendingAudioStore(directory: directory)
            let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]

            // Saved out of order to prove the listing sorts by capture time.
            let later = PendingAudioStore.Entry(jobID: "job-later", segment: segment(startedAtMs: 2_000), sampleRate: 16_000)
            let earlier = PendingAudioStore.Entry(jobID: "job-earlier", segment: segment(startedAtMs: 1_000), sampleRate: 16_000)
            try await store.save(entry: later, samples: samples)
            try await store.save(entry: earlier, samples: samples)

            let pending = await store.pendingEntries()
            check(pending.count == 2, "both spooled segments should be listed as pending")
            check(pending.map(\.jobID) == ["job-earlier", "job-later"], "pending segments should be ordered oldest first")

            let restored = try await store.samples(for: "job-earlier")
            check(restored.count == samples.count, "restored sample count should match what was spooled")
            let maxError = zip(restored, samples).map { abs($0 - $1) }.max() ?? 0
            check(maxError <= 1.0 / 32_767.0, "restored samples should match within 16-bit precision (off by \(maxError))")

            let beforeFinish = await store.stats()
            check(beforeFinish.pendingCount == 2, "stats should report spooled segments as pending")
            check(beforeFinish.pendingBytes > 0, "stats should report the spool's size on disk")

            // Discarding without retention must leave nothing behind...
            await store.finish(jobID: "job-earlier", sampleRate: 16_000, keepAudio: false)
            let afterDiscard = await store.stats()
            check(afterDiscard.pendingCount == 1, "finishing a job should remove it from the pending spool")
            check(afterDiscard.retainedBytes == 0, "finishing without retention should not keep audio")

            // ...while retention must convert to a playable file instead.
            await store.finish(jobID: "job-later", sampleRate: 16_000, keepAudio: true)
            let afterKeep = await store.stats()
            check(afterKeep.pendingCount == 0, "the spool should be empty once every job is finished")
            check(afterKeep.retainedBytes > 0, "retention should keep the transcribed audio on disk")

            succeeded = true
        } catch {
            check(false, "pending audio spool checks should not throw: \(error)")
        }
        semaphore.signal()
    }

    semaphore.wait()
    return succeeded
}

func transcriptVersionSchemaExists(at databasePath: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return false
    }
    defer { sqlite3_close(db) }

    let expectedColumns: Set<String> = [
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

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(transcript_versions);", -1, &statement, nil) == SQLITE_OK else {
        sqlite3_finalize(statement)
        return false
    }
    defer { sqlite3_finalize(statement) }

    var seenColumns = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
        if let columnName = sqlite3_column_text(statement, 1) {
            seenColumns.insert(String(cString: columnName))
        }
    }

    return expectedColumns.isSubset(of: seenColumns)
}

func runDatabaseWrites(on writer: DatabaseWriter, segment: TranscriptSegment) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false

    Task {
        do {
            try await writer.insertSegment(segment)
            try await writer.recordTranscriptionVersions(
                segmentID: segment.id,
                rawText: "first raw output",
                language: "en-US",
                sttProvider: .customAPI,
                sttModel: "whisper-1",
                confidence: 0.7,
                sttSnapshotJSON: "{}",
                optimizedResult: nil
            )
            try await writer.recordTranscriptionVersions(
                segmentID: segment.id,
                rawText: "second raw output",
                language: "en-US",
                sttProvider: .customAPI,
                sttModel: "whisper-1",
                confidence: 0.8,
                sttSnapshotJSON: "{}",
                optimizedResult: nil
            )
            let records = try await writer.queryTranscripts(search: "second raw")
            let jobID = UUID().uuidString
            try await writer.createSTTJob(
                id: jobID,
                segmentID: segment.id,
                providerName: STTProviderKind.customAPI.rawValue,
                providerSnapshotJSON: "{}"
            )
            try await writer.updateSTTJob(id: jobID, attemptCount: 1, state: "running")
            try await writer.completeSTTJob(id: jobID)
            try await writer.recordClipboardEvent(
                segmentID: segment.id,
                result: "success",
                textCharacterCount: 17,
                pasteboardChangeCount: 1,
                errorCode: nil
            )
            succeeded = records.contains { $0.id == segment.id && $0.text == "second raw output" }
        } catch {
            succeeded = false
        }
        semaphore.signal()
    }

    semaphore.wait()
    return succeeded
}

func runActivitySummaryChecks(on writer: DatabaseWriter, segment: TranscriptSegment) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false

    Task {
        do {
            try await writer.recordStateTransition(from: .disabled, to: .recording, reasonCode: "start_requested")
            try await writer.recordStateTransition(
                from: .recording,
                to: .yieldedToOtherInput,
                reasonCode: "external_input_active",
                relatedPID: 4242,
                relatedBundleID: "com.example.thief"
            )
            try await writer.insertSegment(segment)
            try await writer.markSegmentSTTFailed(segmentID: segment.id, reason: "boom")

            let summary = try await writer.activitySummary()
            succeeded = summary.failedSegments == 1
                && summary.capturedSegments == 0
                && summary.lastEventState == CaptureState.yieldedToOtherInput.rawValue
                && summary.lastEventReason == "external_input_active (com.example.thief)"
        } catch {
            succeeded = false
        }
        semaphore.signal()
    }

    semaphore.wait()
    return succeeded
}

func tableExists(_ name: String, at databasePath: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return false
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE name=? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
        return false
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
    return sqlite3_step(statement) == SQLITE_ROW
}

func transcriptVersionCount(at databasePath: String, segmentID: String, kind: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return 0
    }
    defer { sqlite3_close(db) }

    let query = "SELECT COUNT(*) FROM transcript_versions WHERE segment_id = ? AND version_kind = ?;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        sqlite3_finalize(statement)
        return 0
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_text(statement, 1, segmentID, -1, sqliteTransient) == SQLITE_OK,
          sqlite3_bind_text(statement, 2, kind, -1, sqliteTransient) == SQLITE_OK else {
        return 0
    }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        return 0
    }
    return Int(sqlite3_column_int(statement, 0))
}
