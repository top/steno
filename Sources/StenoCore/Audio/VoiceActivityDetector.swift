import Foundation

public enum VADState: String, Sendable {
    case idle
    case speechCandidate
    case recording
    case finalizing
}

public enum VADEvent: Sendable {
    case segmentStarted(startedAtMs: Int64)
    case segmentEnded(endedAtMs: Int64, reason: String)
}

public struct VoiceActivityDetector: Sendable {
    public private(set) var state: VADState = .idle

    private var candidateStartedAtMs: Int64?
    private var candidateSilenceStartedAtMs: Int64?
    private var recordingStartedAtMs: Int64?
    private var silenceStartedAtMs: Int64?

    // ponytail: brief per-frame dips (unvoiced consonants, breaths) are
    // normal mid-word — only abandon the onset candidate after a real pause,
    // not the first quiet 100ms frame. Raise if speech still misses onset
    // with natural pacing; lower if segments start on background noise.
    private static let onsetHangoverMs: Int64 = 300

    public init() {}

    public mutating func ingest(frame: AudioFrame, settings: RecorderSettings) -> VADEvent? {
        let speech = isSpeech(rms: frame.rms, sensitivity: settings.vadSensitivity)

        switch state {
        case .idle:
            guard speech else { return nil }
            candidateStartedAtMs = frame.timestampMs
            state = .speechCandidate
            return nil

        case .speechCandidate:
            if speech {
                candidateSilenceStartedAtMs = nil
            } else {
                if candidateSilenceStartedAtMs == nil {
                    candidateSilenceStartedAtMs = frame.timestampMs
                }
                let silenceRun = frame.timestampMs - candidateSilenceStartedAtMs!
                if silenceRun >= Self.onsetHangoverMs {
                    candidateStartedAtMs = nil
                    candidateSilenceStartedAtMs = nil
                    state = .idle
                }
                return nil
            }

            let onset = frame.timestampMs - (candidateStartedAtMs ?? frame.timestampMs)
            if onset >= Int64(settings.speechOnsetMs) {
                recordingStartedAtMs = candidateStartedAtMs
                silenceStartedAtMs = nil
                state = .recording
                return .segmentStarted(startedAtMs: recordingStartedAtMs ?? frame.timestampMs)
            }
            return nil

        case .recording:
            let recordDuration = frame.timestampMs - (recordingStartedAtMs ?? frame.timestampMs)
            if recordDuration >= Int64(settings.maxSegmentMs) {
                reset()
                return .segmentEnded(endedAtMs: frame.timestampMs, reason: "forced_max_segment")
            }

            if speech {
                silenceStartedAtMs = nil
                return nil
            }

            if silenceStartedAtMs == nil {
                silenceStartedAtMs = frame.timestampMs
            }

            let silenceDuration = frame.timestampMs - (silenceStartedAtMs ?? frame.timestampMs)
            if silenceDuration >= Int64(settings.silenceEndMs) {
                state = .finalizing
                let event = VADEvent.segmentEnded(endedAtMs: frame.timestampMs, reason: "silence_timeout")
                reset()
                return event
            }
            return nil

        case .finalizing:
            reset()
            return nil
        }
    }

    public mutating func reset() {
        state = .idle
        candidateStartedAtMs = nil
        candidateSilenceStartedAtMs = nil
        recordingStartedAtMs = nil
        silenceStartedAtMs = nil
    }

    private func isSpeech(rms: Float, sensitivity: Double) -> Bool {
        let threshold = max(0.005, 0.2 - Float(sensitivity) * 0.18)
        return rms >= threshold
    }
}
