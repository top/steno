import Foundation

public struct AudioFrame: Sendable {
    public let rms: Float
    public let timestampMs: Int64
    public let samples: [Float]
    public let sampleRate: Double

    public init(rms: Float, timestampMs: Int64, samples: [Float], sampleRate: Double) {
        self.rms = rms
        self.timestampMs = timestampMs
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Reports transport-level problems that are not "another app took the input" —
/// device unplug, engine failure, format loss. The coordinator funnels these
/// into the shared recovery path.
public enum CaptureFault: String, Sendable {
    case deviceUnavailable
    case engineFailure
    case formatChanged
}

public protocol AudioCaptureProvider: AnyObject {
    var onAudioFrame: (@Sendable (AudioFrame) -> Void)? { get set }
    /// Fired on a background queue when the hardware transport breaks or the
    /// default input device disappears. Must never be called from a real-time
    /// audio callback.
    var onFault: (@Sendable (CaptureFault) -> Void)? { get set }
    func start() throws
    func stop()
}
