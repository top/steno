import Foundation

public enum CaptureState: String, Codable, CaseIterable, Sendable {
    case disabled
    case permissionRequired
    case starting
    case recording
    case yieldedToOtherInput
    case suppressedByPlayback
    case pausedByUser
    case noInputDevice
    case recovering
    case failed

    public var menuDescription: String {
        switch self {
        case .disabled: return "Not listening"
        case .permissionRequired: return "Microphone permission required"
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .yieldedToOtherInput: return "Yielded: another input app is active"
        case .suppressedByPlayback: return "Paused: playback policy"
        case .pausedByUser: return "Paused by user"
        case .noInputDevice: return "No input device"
        case .recovering: return "Recovering audio connection"
        case .failed: return "Recording service needs attention"
        }
    }

}

public enum CaptureDemand: String, Codable, Sendable {
    case disabled
    case active
    case pausedByUser
}
