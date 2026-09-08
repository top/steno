import CoreAudio
import Foundation

/// Observation of one audio client process as seen by the Core Audio HAL.
///
/// Mirrors `AudioHardwareProcess` but is a value type that the monitor
/// computes and hands to the coordinator, so arbitration logic never has to
/// touch the Core Audio object graph (which can throw) on the hot path.
public struct AudioProcessObservation: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(pid: Int32, bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Snapshot of the state of all audio client processes on the system.
public struct AudioProcessSnapshot: Sendable {
    public let capturedAtMs: Int64
    public let processes: [AudioProcessObservation]

    public init(capturedAtMs: Int64, processes: [AudioProcessObservation]) {
        self.capturedAtMs = capturedAtMs
        self.processes = processes
    }
}

/// Polls the Core Audio HAL for the set of processes that have live input or
/// output streams, and reduces it to two booleans that drive the arbitration
/// state machine.
///
/// - `externalInputActive` — some *other* process is currently using a
///   microphone (or the configured subset of them).
/// - `externalOutputActive` — some *other* process is currently playing audio.
///
/// The monitor runs on a low-priority serial queue; the real-time audio
/// callback never touches it.
public final class AudioProcessMonitor: @unchecked Sendable {
    public struct Config: Sendable {
        public var pollInterval: TimeInterval
        /// Bundle IDs that should never count as "external", even if they
        /// have a live input stream.
        public var ignoredBundleIDs: Set<String>
        /// PIDs that should never count as "external". Own PID is always
        /// added to this set automatically.
        public var ignoredPIDs: Set<Int32>
        /// When non-nil, only processes whose bundleID is in this set count
        /// as "external input" (for `yieldToConfiguredApps`).
        public var watchedBundleIDs: Set<String>?
        /// When non-nil, only processes whose bundleID is in this set count
        /// as "external output" (for output policies with app rules).
        public var watchedOutputBundleIDs: Set<String>?

        public init(
            pollInterval: TimeInterval = 0.2,
            ignoredBundleIDs: Set<String> = Self.systemDaemonBundleIDs,
            ignoredPIDs: Set<Int32> = [],
            watchedBundleIDs: Set<String>? = nil,
            watchedOutputBundleIDs: Set<String>? = nil
        ) {
            self.pollInterval = pollInterval
            self.ignoredBundleIDs = ignoredBundleIDs
            self.ignoredPIDs = ignoredPIDs
            self.watchedBundleIDs = watchedBundleIDs
            self.watchedOutputBundleIDs = watchedOutputBundleIDs
        }

        /// Core audio daemons and other system processes that keep a standing
        /// HAL handle and would otherwise look like "someone is using the
        /// microphone" all the time.
        public static let systemDaemonBundleIDs: Set<String> = [
            "com.apple.audiomxd",
            "com.apple.coreaudiod",
            "com.apple.audio.Agent",
            "com.apple.mediaremoted",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.WindowServer",
            // ponytail: CoreSpeech keeps a standing input reservation for
            // system dictation at all times, not just while dictating —
            // without this every launch immediately yields to it.
            "com.apple.CoreSpeech"
        ]
    }

    public struct State: Sendable {
        public var externalInputActive: Bool
        public var externalOutputActive: Bool
        public var externalInputPIDs: [Int32]
        public var externalInputBundleIDs: [String]
    }

    private let config: Config
    private let queue = DispatchQueue(label: "ambient.assistant.AudioProcessMonitor", qos: DispatchQoS.utility)
    private var timer: DispatchSourceTimer?
    private var _state: State = State(externalInputActive: false, externalOutputActive: false, externalInputPIDs: [], externalInputBundleIDs: [])
    private let ourPID: Int32

    public var state: State {
        get { queue.sync { _state } }
        set { queue.sync { _state = newValue } }
    }

    public var onStateUpdate: (@Sendable (AudioProcessMonitor.State) -> Void)?

    public init(
        config: Config = Config(),
        onStateUpdate: (@Sendable (AudioProcessMonitor.State) -> Void)? = nil,
        ourPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.config = config
        self.ourPID = ourPID
        self.onStateUpdate = onStateUpdate
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            _state = computeStateLocked()
            let newTimer = DispatchSource.makeTimerSource(queue: queue)
            newTimer.schedule(
                deadline: .now() + .milliseconds(Int(config.pollInterval * 1000)),
                repeating: .milliseconds(Int(config.pollInterval * 1000)),
                leeway: .milliseconds(Int(config.pollInterval * 50))
            )
            newTimer.setEventHandler { [weak self] in
                self?.pollAndEmit()
            }
            newTimer.resume()
            timer = newTimer
        }
    }

    public func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        stop()
    }

    public func getState() -> State {
        queue.sync { _state }
    }

    private func computeStateLocked() -> State {
        var result = State(externalInputActive: false, externalOutputActive: false, externalInputPIDs: [], externalInputBundleIDs: [])
        do {
            let procs = try AudioHardwareSystem.shared.processes
            for proc in procs {
                do {
                    let pid = try proc.pid
                    let bundleID = try proc.bundleID
                    let input = try proc.isRunningInput
                    let output = try proc.isRunningOutput
                    if config.ignoredPIDs.contains(pid) { continue }
                    if pid == ourPID { continue }
                    if let bid = bundleID, config.ignoredBundleIDs.contains(bid) { continue }
                    // ponytail: processes with no bundle ID (unlabeled system
                    // daemons) can't be allow/deny-listed and shouldn't be
                    // able to force a yield; without this they were counted
                    // as "external input" on every poll, repeatedly cutting
                    // real recordings before a segment could finish.
                    guard let bundleID else { continue }
                    let inputMatches = config.watchedBundleIDs?.contains(bundleID) ?? true
                    if input, inputMatches {
                        result.externalInputActive = true
                        result.externalInputPIDs.append(pid)
                        result.externalInputBundleIDs.append(bundleID)
                    }
                    let outputMatches = config.watchedOutputBundleIDs?.contains(bundleID) ?? true
                    if output, outputMatches { result.externalOutputActive = true }
                } catch { continue }
            }
        } catch {}
        return result
    }

    private func pollAndEmit() {
        let newState = computeStateLocked()
        self._state = newState
        self.onStateUpdate?(newState)
    }


}
