import AVFoundation
import Foundation
import os.log
import Speech

// ponytail: same one-shot diagnostic as AVAudioEngineCaptureProvider — see
// that file's comment.
private let coordinatorLog = Logger(subsystem: "local.steno", category: "capture")

public actor RecorderCoordinator {
    public typealias StateObserver = @Sendable (_ state: CaptureState, _ reasonCode: String) -> Void
    public typealias SettingsObserver = @Sendable (_ settings: RecorderSettings) -> Void

    private let settingsRepository: SettingsRepository
    private let databaseWriter: DatabaseWriter
    private let captureProvider: AudioCaptureProvider
    private let segmentAssembler: SegmentAssembler
    private let sttJobQueue = STTJobQueue(maximumAttempts: 3)
    private let clipboardWriter: ClipboardWriter
    /// Durable spool for segment audio. `nil` only if its directory could not be
    /// created, in which case transcription falls back to in-memory audio.
    private let pendingAudioStore: PendingAudioStore?
    private let networkGate = NetworkGate()

    private let arbitrator = AudioArbitrator()

    private var vad = VoiceActivityDetector()
    private var demand: CaptureDemand = .disabled
    private var state: CaptureState = .disabled
    private var reasonCode: String = "initialized"

    private var hasInputDevice = true
    private var externalInputActive = false
    private var playbackActive = false
    // Last observed culprit process, so capture_events records *which* app
    // forced a yield instead of just "something else was using the mic".
    private var lastExternalInputPID: Int32?
    private var lastExternalInputBundleID: String?

    // Raw samples for the segment currently being captured, plus a rolling
    // pre-roll buffer so speech just before VAD's onset threshold isn't lost.
    private var isCapturingSegment = false
    private var segmentSamples: [Float] = []
    private var segmentSampleRate: Double = 0
    private var preRollBuffer: [(timestampMs: Int64, samples: [Float])] = []
    private var hasLoggedFirstHandledFrame = false
    private var frameLogCounter = 0
    private var peakRMSSinceLog: Float = 0

    /// Monitored state of all audio processes on the system (the core of the
    /// yield arbitration). If `nil`, cross-process arbitration is disabled.
    private var audioProcessMonitor: AudioProcessMonitor?
    private var inputRecoveryTask: Task<Void, Never>?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var captureRecoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0

    private var settings: RecorderSettings
    private var observer: StateObserver?
    private var settingsObserver: SettingsObserver?

    public init(
        settingsRepository: SettingsRepository,
        databaseWriter: DatabaseWriter,
        captureProvider: AudioCaptureProvider,
        segmentAssembler: SegmentAssembler = SegmentAssembler()
    ) {
        self.settingsRepository = settingsRepository
        self.databaseWriter = databaseWriter
        self.captureProvider = captureProvider
        self.segmentAssembler = segmentAssembler
        self.clipboardWriter = ClipboardWriter(databaseWriter: databaseWriter)
        self.settings = settingsRepository.load().validated()
        // Spool lives beside the database, so both are in the one directory the
        // user already knows about from Settings.
        self.pendingAudioStore = try? PendingAudioStore(
            directory: databaseWriter.databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("PendingAudio", isDirectory: true)
        )

        captureProvider.onAudioFrame = { [weak self] frame in
            Task {
                await self?.handleAudioFrame(frame)
            }
        }
        captureProvider.onFault = { [weak self] fault in
            Task {
                await self?.handleCaptureFault(fault)
            }
        }

        // ponytail: reuse capture_events as the startup log instead of a new
        // log file/table — it's already timestamped and exported alongside
        // everything else, so an "app_launched" row is enough to see launch
        // times when reviewing history.
        Task { [databaseWriter] in
            _ = try? await databaseWriter.recordStateTransition(
                from: .disabled,
                to: .disabled,
                reasonCode: "app_launched"
            )
        }
    }

    // MARK: - Public API

    public func setObserver(_ observer: @escaping StateObserver) {
        self.observer = observer
    }

    public func setSettingsObserver(_ observer: @escaping SettingsObserver) {
        self.settingsObserver = observer
    }

    public func currentState() -> CaptureState { state }
    public func currentReasonCode() -> String { reasonCode }
    public func currentSettings() -> RecorderSettings { settings }
    public func currentDatabasePath() -> String { databaseWriter.databaseURL.path }

    public func startListening() async {
        demand = .active
        recoveryAttempt = 0
        await restartArbitrationMonitoring()

        // Check permission BEFORE any state transition so we don't flash
        // a spurious ".starting" state when permission is already denied.
        let granted = await ensureMicrophonePermission()
        if !granted {
            await reevaluate(reason: "mic_permission_required")
            return
        }

        await reevaluate(reason: "start_requested")
    }

    public func pauseListening() async {
        demand = .pausedByUser
        stopArbitrationMonitoring()
        cancelRecoveryTasks()
        await reevaluate(reason: "user_paused")
    }

    public func disableListening() async {
        demand = .disabled
        stopArbitrationMonitoring()
        cancelRecoveryTasks()
        await reevaluate(reason: "user_disabled")
    }

    public func stopListening() async {
        await disableListening()
        stopArbitrationMonitoring()
    }

    public func updateSettings(_ newSettings: RecorderSettings) async {
        self.settings = newSettings.validated()
        settingsRepository.save(self.settings)
        if demand == .active {
            await restartArbitrationMonitoring()
        }
        await reevaluate(reason: "settings_updated")
    }

    // MARK: - Arbitration monitoring

    public func startArbitrationMonitoringIfNeeded() async {
        guard audioProcessMonitor == nil,
              monitorConfig() != nil else {
            return
        }
        await enableMonitor()
    }

    public func stopArbitrationMonitoring() {
        audioProcessMonitor?.stop()
        audioProcessMonitor = nil
        inputRecoveryTask?.cancel()
        playbackRecoveryTask?.cancel()
        inputRecoveryTask = nil
        playbackRecoveryTask = nil
        externalInputActive = false
        playbackActive = false
    }

    // MARK: - Validation

    public func validateCustomProviderConfiguration() -> String? {
        let provider = OpenAICompatibleSTTProvider(
            configuration: OpenAICompatibleSTTConfiguration(
                endpoint: settings.customEndpoint,
                modelID: settings.customModelID,
                languageIdentifier: settings.languageIdentifier,
                timeoutSeconds: settings.customTimeoutSeconds,
                apiKey: settings.sttAPIKey
            )
        )
        do {
            try provider.validateConfiguration()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func appleProviderAvailability(requestAuthorization: Bool) async -> STTAvailability {
            if requestAuthorization, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await AppleSystemSpeechProvider.requestAuthorization()
            }
            let provider = AppleSystemSpeechProvider(
                languageIdentifier: settings.languageIdentifier,
                processingPolicy: settings.appleProcessingPolicy
            )
            return await provider.availability(for: Locale(identifier: settings.languageIdentifier))
        }

    public func queryTranscripts(search: String? = nil, limit: Int = 500) async throws -> [TranscriptRecord] {
            try await databaseWriter.queryTranscripts(search: search, limit: limit)
        }

    public func exportTranscripts(to url: URL) async throws {
            try await databaseWriter.exportTranscripts(to: url)
        }

    public func deleteAllTranscripts() async throws {
        try await databaseWriter.deleteAllTranscripts()
        // Purging the text must take the audio it came from with it, otherwise
        // "delete all" quietly leaves recordings on disk.
        await pendingAudioStore?.removeAll()
    }

    public func activitySummary() async throws -> DatabaseWriter.ActivitySummary {
        try await databaseWriter.activitySummary()
    }

    public func validateLLMConfiguration() -> String? {
        guard settings.llmEnabled else { return nil }
        let optimizer = OpenAICompatibleTextOptimizer(
            configuration: OpenAICompatibleTextOptimizerConfiguration(
                endpoint: settings.llmEndpoint,
                modelID: settings.llmModelID,
                timeoutSeconds: settings.llmTimeoutSeconds,
                behavior: settings.llmOptimizationBehavior,
                apiKey: settings.llmAPIKey
            )
        )
        do {
            try optimizer.validateConfiguration()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - External state updates

    public func updateExternalInput(active: Bool) async {
        externalInputActive = active
        await reevaluate(reason: "external_input_changed")
    }

    public func updatePlayback(active: Bool) async {
        playbackActive = active
        await reevaluate(reason: "playback_changed")
    }

    public func updateInputDeviceAvailable(_ available: Bool) async {
        hasInputDevice = available
        if available {
            recoveryAttempt = 0
            captureRecoveryTask?.cancel()
            captureRecoveryTask = nil
        }
        await reevaluate(reason: "input_device_changed")
    }

    // MARK: - Transcription persistence

    private func persistTranscriptionResult(
        segment: TranscriptSegment,
        result: TranscriptionResult,
        settings jobSettings: RecorderSettings
    ) async throws {
        let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            throw STTProviderError.invalidConfiguration("STT transcription text was empty.")
        }

        let optimizedResult: TextOptimizationResult?
        if jobSettings.llmEnabled {
            let optimizer = OpenAICompatibleTextOptimizer(
                configuration: OpenAICompatibleTextOptimizerConfiguration(
                    endpoint: jobSettings.llmEndpoint,
                    modelID: jobSettings.llmModelID,
                    timeoutSeconds: jobSettings.llmTimeoutSeconds,
                    behavior: jobSettings.llmOptimizationBehavior,
                    apiKey: jobSettings.llmAPIKey
                )
            )
            optimizedResult = try? await optimizer.optimize(text: rawText, languageIdentifier: result.language)
        } else {
            optimizedResult = nil
        }

        try await databaseWriter.recordTranscriptionVersions(
            segmentID: segment.id,
            rawText: rawText,
            language: result.language,
            sttProvider: result.providerKind,
            sttModel: result.engineVersionOrMode,
            confidence: result.confidence,
            sttSnapshotJSON: segment.providerSnapshotJSON,
            optimizedResult: optimizedResult
        )

        if result.isFinal, jobSettings.autoCopyFinalTranscript {
            let outcome = await clipboardWriter.write(
                text: optimizedResult?.text ?? rawText,
                segmentID: segment.id,
                endedAtMs: segment.endedAtMs
            )
            if case .denied = outcome {
                settings.autoCopyFinalTranscript = false
                settings.clipboardToastMessage = "Clipboard access was denied; automatic copying was disabled."
                settingsRepository.save(settings)
                settingsObserver?(settings)
            }
        }
    }

    // MARK: - State machine

    private func reevaluate(reason: String) async {
        let hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let inputs = ArbitrationInputs(
            demand: demand,
            hasMicrophonePermission: hasPermission,
            hasInputDevice: hasInputDevice,
            externalInputActive: externalInputActive,
            playbackActive: playbackActive
        )

        let decision = arbitrator.evaluate(inputs: inputs, settings: settings)
        let nextReason = decision.reasonCode == "ready_to_record" ? reason : decision.reasonCode
        await transition(to: decision.state, reason: nextReason)
    }

    private func transition(to newState: CaptureState, reason: String) async {
        guard newState != state || reason != reasonCode else { return }

        let previous = state

        if newState == .recording {
            do {
                try captureProvider.start()
                recoveryAttempt = 0
                captureRecoveryTask?.cancel()
                captureRecoveryTask = nil
            } catch {
                await scheduleCaptureRecovery(
                    from: previous,
                    reason: "audio_start_failed",
                    details: ["error": error.localizedDescription]
                )
                return
            }
        } else {
            captureProvider.stop()
            vad.reset()
            segmentSamples = []
            preRollBuffer = []
            isCapturingSegment = false
        }

        state = newState
        reasonCode = reason

        do {
            try await databaseWriter.recordStateTransition(
                from: previous,
                to: newState,
                reasonCode: reason,
                relatedPID: reason == "external_input_active" ? lastExternalInputPID : nil,
                relatedBundleID: reason == "external_input_active" ? lastExternalInputBundleID : nil
            )
        } catch {
            // Database write failed — still keep the new state so the UI
            // reflects reality, but surface the failure.
            state = .failed
            reasonCode = "database_write_failed"
            observer?(state, reasonCode)
            return
        }

        observer?(state, reasonCode)
    }

    private func forceFailure(from previous: CaptureState, reason: String, details: [String: String]) async {
        captureProvider.stop()
        state = .failed
        reasonCode = reason

        let payloadData = try? JSONSerialization.data(withJSONObject: details)
        let payloadText = payloadData.flatMap { String(data: $0, encoding: .utf8) }

        _ = try? await databaseWriter.recordStateTransition(
            from: previous,
            to: .failed,
            reasonCode: reason,
            detailsJSON: payloadText
        )

        observer?(state, reasonCode)
    }

    // MARK: - Audio frame handling

    private func handleCaptureFault(_ fault: CaptureFault) async {
        await scheduleCaptureRecovery(
            from: state,
            reason: "capture_fault_\(fault.rawValue)",
            details: [:]
        )
    }

    private func scheduleCaptureRecovery(
        from previous: CaptureState,
        reason: String,
        details: [String: String]
    ) async {
        captureProvider.stop()
        vad.reset()
        segmentSamples = []
        preRollBuffer = []
        isCapturingSegment = false
        state = .recovering
        reasonCode = reason
        recoveryAttempt += 1

        let payloadData = try? JSONSerialization.data(withJSONObject: details)
        let payloadText = payloadData.flatMap { String(data: $0, encoding: .utf8) }
        _ = try? await databaseWriter.recordStateTransition(
            from: previous,
            to: .recovering,
            reasonCode: reason,
            detailsJSON: payloadText
        )
        observer?(state, reasonCode)

        let delays = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0]
        let delay = delays[min(recoveryAttempt - 1, delays.count - 1)]
        captureRecoveryTask?.cancel()
        captureRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reevaluate(reason: "capture_recovery_retry")
        }
    }

    private func cancelRecoveryTasks() {
        captureRecoveryTask?.cancel()
        inputRecoveryTask?.cancel()
        playbackRecoveryTask?.cancel()
        captureRecoveryTask = nil
        inputRecoveryTask = nil
        playbackRecoveryTask = nil
    }

    private func handleAudioFrame(_ frame: AudioFrame) async {
        if !hasLoggedFirstHandledFrame {
            hasLoggedFirstHandledFrame = true
            coordinatorLog.notice("handleAudioFrame first call, coordinatorState=\(String(describing: self.state), privacy: .public) rms=\(frame.rms, privacy: .public)")
        }
        // ponytail: throttled peak-RMS trace to see the real mic level
        // against the VAD threshold — remove once VAD sensitivity is
        // confirmed calibrated correctly.
        peakRMSSinceLog = max(peakRMSSinceLog, frame.rms)
        frameLogCounter += 1
        if frameLogCounter >= 20 {
            frameLogCounter = 0
            coordinatorLog.notice("peak rms over last ~20 frames: \(self.peakRMSSinceLog, privacy: .public), vadState=\(String(describing: self.vad.state), privacy: .public)")
            peakRMSSinceLog = 0
        }
        guard state == .recording else { return }

        if isCapturingSegment {
            segmentSamples.append(contentsOf: frame.samples)
        } else {
            preRollBuffer.append((frame.timestampMs, frame.samples))
            let cutoff = frame.timestampMs - Int64(settings.preRollMs)
            preRollBuffer.removeAll { $0.timestampMs < cutoff }
        }

        guard let event = vad.ingest(frame: frame, settings: settings) else { return }

        switch event {
        case .segmentStarted:
            isCapturingSegment = true
            segmentSampleRate = frame.sampleRate
            segmentSamples = preRollBuffer.flatMap(\.samples)
            preRollBuffer.removeAll()
        case .segmentEnded:
            isCapturingSegment = false
        }

        guard let segment = await segmentAssembler.handle(
            event: event,
            source: .microphone,
            settings: settings,
            providerSnapshotJSON: providerSnapshotJSON()
        ) else { return }

        let capturedSamples = segmentSamples
        let capturedSampleRate = segmentSampleRate
        segmentSamples = []

        do {
            try await databaseWriter.insertSegment(segment)
        } catch {
            await forceFailure(from: state, reason: "segment_insert_failed", details: ["error": error.localizedDescription])
            return
        }

        await enqueueTranscription(
            segment: segment,
            samples: capturedSamples,
            sampleRate: capturedSampleRate,
            settings: settings
        )
    }

    private func enqueueTranscription(
        segment: TranscriptSegment,
        samples: [Float],
        sampleRate: Double,
        settings jobSettings: RecorderSettings
    ) async {
        let jobID = UUID().uuidString
        let entry = PendingAudioStore.Entry(jobID: jobID, segment: segment, sampleRate: sampleRate)

        // Spool the audio before anything else: from here on the file on disk is
        // what guarantees the segment survives an offline stretch, a quit, or a
        // crash. Held in memory as a fallback if the spool is unavailable.
        var inMemorySamples: [Float]?
        if let pendingAudioStore {
            do {
                try await pendingAudioStore.save(entry: entry, samples: samples)
            } catch {
                inMemorySamples = samples
                _ = try? await databaseWriter.recordStateTransition(
                    from: state,
                    to: state,
                    reasonCode: "pending_audio_spool_failed",
                    detailsJSON: nil
                )
            }
        } else {
            inMemorySamples = samples
        }

        do {
            try await databaseWriter.createSTTJob(
                id: jobID,
                segmentID: segment.id,
                providerName: jobSettings.sttProvider.rawValue,
                providerSnapshotJSON: segment.providerSnapshotJSON
            )
        } catch {
            await forceFailure(from: state, reason: "stt_job_insert_failed", details: ["error": error.localizedDescription])
            return
        }

        await enqueueJob(entry: entry, settings: jobSettings, fallbackSamples: inMemorySamples)
    }

    /// Requeues every spooled segment that never completed, oldest first, so a
    /// backlog built up offline is transcribed in the order it was spoken.
    /// Anything still spooled at launch is by definition unfinished work.
    public func resumePendingTranscriptions() async {
        guard let pendingAudioStore else { return }
        let entries = await pendingAudioStore.pendingEntries()
        guard !entries.isEmpty else { return }
        _ = try? await databaseWriter.recordStateTransition(
            from: state,
            to: state,
            reasonCode: "pending_audio_resumed",
            detailsJSON: "{\"segments\":\(entries.count)}"
        )
        for entry in entries {
            await enqueueJob(entry: entry, settings: settings, fallbackSamples: nil)
        }
    }

    public func pendingAudioStats() async -> PendingAudioStore.Stats? {
        await pendingAudioStore?.stats()
    }

    private func enqueueJob(
        entry: PendingAudioStore.Entry,
        settings jobSettings: RecorderSettings,
        fallbackSamples: [Float]?
    ) async {
        let jobID = entry.jobID
        await sttJobQueue.enqueue(
            operation: { [weak self] in
                guard let self else { throw STTProviderError.unsupported("Recorder stopped before STT began.") }
                return try await self.transcribeSpooledSegment(
                    entry: entry,
                    settings: jobSettings,
                    fallbackSamples: fallbackSamples
                )
            },
            onAttempt: { [databaseWriter] attempt, error in
                let retryAt = error.map { _ in
                    DatabaseWriter.nowMilliseconds() + Int64((1 << max(0, attempt - 1)) * 1_000)
                }
                try? await databaseWriter.updateSTTJob(
                    id: jobID,
                    attemptCount: attempt,
                    state: error == nil ? "running" : (attempt < 3 ? "retry_wait" : "failed"),
                    error: error,
                    nextRetryAtMs: attempt < 3 ? retryAt : nil
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                await self.finishTranscriptionJob(
                    id: jobID,
                    segment: entry.segment,
                    sampleRate: entry.sampleRate,
                    settings: jobSettings,
                    result: result
                )
            }
        )
    }

    /// Loads the segment's audio back off the spool and transcribes it, waiting
    /// out any lack of connectivity first so an offline stretch costs no retries.
    private func transcribeSpooledSegment(
        entry: PendingAudioStore.Entry,
        settings jobSettings: RecorderSettings,
        fallbackSamples: [Float]?
    ) async throws -> TranscriptionResult {
        // Apple's recognizer runs locally, and a self-hosted endpoint keeps
        // working with no route off the machine — neither should be gated.
        let needsNetwork = jobSettings.sttProvider == .customAPI
            && !NetworkGate.isLoopback(endpoint: jobSettings.customEndpoint)
        if needsNetwork {
            try await networkGate.waitUntilSatisfied()
        }

        let samples: [Float]
        if let pendingAudioStore, let spooled = try? await pendingAudioStore.samples(for: entry.jobID) {
            samples = spooled
        } else if let fallbackSamples {
            samples = fallbackSamples
        } else {
            throw STTProviderError.invalidConfiguration("Spooled audio for this segment is missing.")
        }

        return try await performTranscription(
            segment: entry.segment,
            pcmData: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleRate: entry.sampleRate,
            settings: jobSettings
        )
    }

    private func performTranscription(
        segment: TranscriptSegment,
        pcmData: Data,
        sampleRate: Double,
        settings jobSettings: RecorderSettings
    ) async throws -> TranscriptionResult {
        let timeout = jobSettings.sttProvider == .customAPI ? jobSettings.customTimeoutSeconds : 120
        let request = TranscriptionRequest(
            segmentID: segment.id,
            pcmData: pcmData,
            sampleRateHz: sampleRate,
            source: segment.source,
            language: Locale(identifier: jobSettings.languageIdentifier),
            providerSnapshot: segment.providerSnapshotJSON,
            deadline: Date().addingTimeInterval(timeout)
        )
        switch jobSettings.sttProvider {
        case .customAPI:
            return try await OpenAICompatibleSTTProvider(
                configuration: OpenAICompatibleSTTConfiguration(
                    endpoint: jobSettings.customEndpoint,
                    modelID: jobSettings.customModelID,
                    languageIdentifier: jobSettings.languageIdentifier,
                    timeoutSeconds: jobSettings.customTimeoutSeconds,
                    apiKey: jobSettings.sttAPIKey
                )
            ).transcribe(request)
        case .appleSystem:
            return try await AppleSystemSpeechProvider(
                languageIdentifier: jobSettings.languageIdentifier,
                processingPolicy: jobSettings.appleProcessingPolicy
            ).transcribe(request)
        }
    }

    private func finishTranscriptionJob(
        id: String,
        segment: TranscriptSegment,
        sampleRate: Double,
        settings jobSettings: RecorderSettings,
        result: Result<TranscriptionResult, Error>
    ) async {
        switch result {
        case .success(let transcription):
            do {
                try await persistTranscriptionResult(segment: segment, result: transcription, settings: jobSettings)
                try await databaseWriter.completeSTTJob(id: id)
                // Only now is the audio expendable: the transcript it came from
                // is committed.
                await pendingAudioStore?.finish(
                    jobID: id,
                    sampleRate: sampleRate,
                    keepAudio: jobSettings.keepAudioAfterTranscription
                )
            } catch {
                try? await databaseWriter.updateSTTJob(id: id, attemptCount: 3, state: "failed", error: error)
                try? await databaseWriter.markSegmentTerminated(segmentID: segment.id, reason: error.localizedDescription)
            }
        case .failure(let error) where (error as? STTProviderError)?.isPermanent == true:
            // Nothing was said. Keeping the audio would mean retrying this
            // silence at every launch forever, and counting it as a failure would
            // pin it in the activity stats with no way to clear it.
            try? await databaseWriter.markSegmentTerminated(
                segmentID: segment.id,
                status: "discarded",
                reason: error.localizedDescription
            )
            try? await databaseWriter.completeSTTJob(id: id)
            await pendingAudioStore?.discard(jobID: id)
        case .failure(let error):
            // The spooled audio is deliberately left in place. Giving up on this
            // pass is not the same as giving up on the recording — it is retried
            // at next launch, so a bad key or a wrong endpoint can be corrected
            // without losing what was said.
            try? await databaseWriter.markSegmentTerminated(segmentID: segment.id, reason: error.localizedDescription)
            _ = try? await databaseWriter.recordStateTransition(
                from: state,
                to: state,
                reasonCode: "stt_failed_audio_retained_for_retry",
                detailsJSON: nil
            )
        }
    }

    // MARK: - Monitor config

    private func monitorConfig() -> AudioProcessMonitor.Config? {
        let watchesInput = settings.inputArbitrationMode.shouldYieldToExternalInput
        let watchesOutput = settings.playbackPolicy == .pauseOnOutputIO
        guard watchesInput || watchesOutput else { return nil }
        let appRules = settings.appRules
        let includedBundleIDs = Set(appRules.filter { $0.behavior == .include }.map { $0.bundleID })
        let forceYieldBundleIDs = Set(appRules.filter { $0.behavior == .forceYield }.map { $0.bundleID })
        let excludedBundleIDs = Set(appRules.filter { $0.behavior == .exclude }.map { $0.bundleID })

        let ignored = AudioProcessMonitor.Config.systemDaemonBundleIDs.union(excludedBundleIDs)
        let watchedInput = settings.inputArbitrationMode == .yieldToConfiguredApps
            ? includedBundleIDs.union(forceYieldBundleIDs)
            : nil
        let watchedOutput = includedBundleIDs.isEmpty ? nil : includedBundleIDs

        return AudioProcessMonitor.Config(
            pollInterval: 0.2,
            ignoredBundleIDs: ignored,
            ignoredPIDs: [],
            watchedBundleIDs: watchesInput ? watchedInput : [],
            watchedOutputBundleIDs: watchesOutput ? watchedOutput : []
        )
    }

    private func restartArbitrationMonitoring() async {
        stopArbitrationMonitoring()
        await startArbitrationMonitoringIfNeeded()
    }

    private func enableMonitor() async {
        guard let config = monitorConfig() else { return }
        let monitor = AudioProcessMonitor(config: config) { [weak self] monitorState in
            Task { [weak self] in
                await self?.monitorStateUpdated(monitorState)
            }
        }
        monitor.start()
        audioProcessMonitor = monitor
    }

    private func monitorStateUpdated(_ state: AudioProcessMonitor.State) async {
        if state.externalInputActive {
            lastExternalInputPID = state.externalInputPIDs.first
            lastExternalInputBundleID = state.externalInputBundleIDs.first
        }
        await updateMonitoredInput(state.externalInputActive)
        await updateMonitoredPlayback(state.externalOutputActive)
    }

    private func updateMonitoredInput(_ active: Bool) async {
        if active {
            inputRecoveryTask?.cancel()
            inputRecoveryTask = nil
            externalInputActive = true
            await reevaluate(reason: "arbitration_monitor_update")
            return
        }
        guard externalInputActive, inputRecoveryTask == nil else { return }
        let delay = settings.arbitrationRecoveryDelaySeconds
        inputRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.completeInputRecovery()
        }
    }

    private func completeInputRecovery() async {
        inputRecoveryTask = nil
        externalInputActive = false
        await reevaluate(reason: "external_input_recovery_debounce_elapsed")
    }

    private func updateMonitoredPlayback(_ active: Bool) async {
        if active {
            playbackRecoveryTask?.cancel()
            playbackRecoveryTask = nil
            playbackActive = true
            await reevaluate(reason: "arbitration_monitor_update")
            return
        }
        guard playbackActive, playbackRecoveryTask == nil else { return }
        let delay = settings.arbitrationRecoveryDelaySeconds
        playbackRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.completePlaybackRecovery()
        }
    }

    private func completePlaybackRecovery() async {
        playbackRecoveryTask = nil
        playbackActive = false
        await reevaluate(reason: "playback_recovery_debounce_elapsed")
    }

    // MARK: - Helpers

    private func providerSnapshotJSON() -> String {
        struct Snapshot: Codable {
            let provider: STTProviderKind
            let endpoint: String?
            let model: String?
            let timeoutSeconds: Double
            let appleProcessingPolicy: AppleProcessingPolicy?
        }
        let snapshot = Snapshot(
            provider: settings.sttProvider,
            endpoint: settings.sttProvider == .customAPI ? settings.customEndpoint : nil,
            model: settings.sttProvider == .customAPI ? settings.customModelID : nil,
            timeoutSeconds: settings.sttProvider == .customAPI ? settings.customTimeoutSeconds : 120,
            appleProcessingPolicy: settings.sttProvider == .appleSystem ? settings.appleProcessingPolicy : nil
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}