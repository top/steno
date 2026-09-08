import AVFoundation
import CoreAudio
import Foundation
import os.log

// ponytail: one-shot signposts, not a full logging framework — just enough
// to see in Console.app/`log stream` whether the tap ever actually fires
// and whether the engine reports itself running. Remove once the pipeline
// is confirmed reliable end-to-end.
private let captureLog = Logger(subsystem: "local.steno", category: "capture")

/// Automatic gain control for microphone level: keeps the level handed to
/// VAD/STT in a predictable range regardless of mic distance/gain, instead
/// of relying on a fixed RMS threshold tuned for one specific input level.
/// Pure/stateless-per-call math so it's testable without a real audio tap.
public struct AutomaticGainControl: Sendable {
    public var gain: Float = 1.0
    public static let targetRMS: Float = 0.08
    public static let minGain: Float = 1.0
    public static let maxGain: Float = 12.0
    // ponytail: single-pole smoothing (slow enough that a word's natural
    // volume dips don't yank the gain around) rather than separate
    // attack/release constants — revisit if speech still pumps/clips.
    public static let adaptRate: Float = 0.05
    // Below this raw RMS, treat it as silence and freeze gain adaptation so
    // AGC doesn't amplify background hiss up into false "speech".
    public static let noiseFloor: Float = 0.002

    public init() {}

    /// Updates `gain` toward whatever multiplier would bring `rawRMS` to
    /// `targetRMS`, then applies the (clamped) result to `samples` in place.
    /// Returns the post-gain RMS.
    @discardableResult
    public mutating func apply(to samples: inout [Float], rawRMS: Float) -> Float {
        if rawRMS > Self.noiseFloor {
            let desiredGain = min(Self.maxGain, max(Self.minGain, Self.targetRMS / rawRMS))
            gain += (desiredGain - gain) * Self.adaptRate
        }
        gain = min(Self.maxGain, max(Self.minGain, gain))

        var energy: Float = 0
        for index in samples.indices {
            let gained = max(-1, min(1, samples[index] * gain))
            samples[index] = gained
            energy += gained * gained
        }
        return sqrt(energy / Float(samples.count))
    }
}

/// Microphone capture backed by `AVAudioEngine`.
///
/// Real-time path: the input tap only schedules the buffer onto a serial
/// audio pipeline queue. All actual work (downmix, resample to 16 kHz, RMS,
/// delivery to VAD) happens off the real-time thread.
///
/// Also watches the default input device, device availability, engine
/// configuration changes, and sleep/wake so the coordinator can rebuild.
public final class AVAudioEngineCaptureProvider: AudioCaptureProvider {
    public var onAudioFrame: (@Sendable (AudioFrame) -> Void)?
    public var onFault: (@Sendable (CaptureFault) -> Void)?

    /// Native mic format is passed straight through — no resampling. Both
    /// STT providers already build their audio format from
    /// `AudioFrame.sampleRate`/`sampleRateHz` dynamically, so there is no
    /// hardcoded 16 kHz requirement downstream.
    private let engine = AVAudioEngine()
    private let pipeline = DispatchQueue(label: "ambient.assistant.audio-pipeline")
    private let systemQueue = DispatchQueue(label: "ambient.assistant.audio-system", qos: .utility)
    private var isStarted = false
    private var tapInstalled = false
    private var hasLoggedFirstFrame = false
    private var agc = AutomaticGainControl()

    private var notificationObservers: [NSObjectProtocol] = []
    private var audioPropertySelectors: [AudioObjectPropertySelector] = []
    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    deinit {
        teardown()
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isStarted else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AVAudioEngineError.invalidInputFormat
        }

        // Prepare the engine graph BEFORE installing the tap so the bus
        // format is stable.
        engine.prepare()

        // Install the tap on the prepared format.
        let tapFormat = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.pipeline.async {
                self.process(buffer: buffer)
            }
        }
        tapInstalled = true

        installSystemObservers()

        do {
            try engine.start()
            isStarted = true
            hasLoggedFirstFrame = false
            captureLog.notice("engine.start() succeeded, format=\(tapFormat.sampleRate, privacy: .public)Hz ch=\(tapFormat.channelCount, privacy: .public), isRunning=\(self.engine.isRunning, privacy: .public)")
        } catch {
            // Clean up everything we just set up.
            teardown()
            throw AVAudioEngineError.engineStartFailed(underlying: error.localizedDescription)
        }
    }

    public func stop() {
        // Synchronous teardown — avoids race with the next start().
        teardown()
    }

    // MARK: - Pipeline

    private func process(buffer: AVAudioPCMBuffer) {
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            captureLog.notice("first tap buffer received, frameLength=\(buffer.frameLength, privacy: .public) hasCallback=\(self.onAudioFrame != nil, privacy: .public)")
        }
        guard let callback = onAudioFrame else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        // Downmix to mono by averaging channels (most Mac mic input is
        // already mono, but external multi-channel interfaces exist).
        var samples = [Float](repeating: 0, count: frameLength)
        var rawEnergy: Float = 0
        for frame in 0..<frameLength {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            let value = sum / Float(channelCount)
            samples[frame] = value
            rawEnergy += value * value
        }
        let rawRMS = sqrt(rawEnergy / Float(frameLength))
        let finalRMS = agc.apply(to: &samples, rawRMS: rawRMS)

        callback(AudioFrame(
            rms: finalRMS,
            timestampMs: Self.nowMilliseconds(),
            samples: samples,
            sampleRate: buffer.format.sampleRate
        ))
    }

    // MARK: - Teardown

    private func teardown() {
        isStarted = false
        agc = AutomaticGainControl()

        removeSystemObservers()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - System observers

    private func installSystemObservers() {
        removeSystemObservers()

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleTransportInvalidation(reason: .deviceUnavailable)
        }
        self.propertyListenerBlock = listenerBlock

        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let result = AudioObjectAddPropertyListenerBlock(
                systemObject,
                &address,
                systemQueue,
                listenerBlock
            )
            if result == noErr {
                audioPropertySelectors.append(selector)
            }
        }

        let wakeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSWorkspaceDidWakeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTransportInvalidation(reason: .deviceUnavailable)
        }
        notificationObservers.append(wakeObserver)

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.handleTransportInvalidation(reason: .formatChanged)
            }
        )
    }

    private func removeSystemObservers() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let block = propertyListenerBlock {
            for selector in audioPropertySelectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    systemObject,
                    &address,
                    systemQueue,
                    block
                )
            }
        }
        audioPropertySelectors = []
        propertyListenerBlock = nil

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
    }

    private func handleTransportInvalidation(reason: CaptureFault) {
        guard isStarted else { return }
        // Run teardown synchronously to avoid racing with the next start().
        teardown()
        onFault?(reason)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public enum AVAudioEngineError: LocalizedError, Sendable {
    case invalidInputFormat
    case engineStartFailed(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The input device reported an invalid audio format."
        case .engineStartFailed(let underlying):
            return "AVAudioEngine failed to start: \(underlying)"
        }
    }
}