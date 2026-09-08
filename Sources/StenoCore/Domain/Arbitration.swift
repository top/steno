import Foundation

public struct ArbitrationInputs: Sendable {
    public var demand: CaptureDemand
    public var hasMicrophonePermission: Bool
    public var hasInputDevice: Bool
    public var externalInputActive: Bool
    public var playbackActive: Bool

    public init(
        demand: CaptureDemand,
        hasMicrophonePermission: Bool,
        hasInputDevice: Bool,
        externalInputActive: Bool,
        playbackActive: Bool
    ) {
        self.demand = demand
        self.hasMicrophonePermission = hasMicrophonePermission
        self.hasInputDevice = hasInputDevice
        self.externalInputActive = externalInputActive
        self.playbackActive = playbackActive
    }
}

public struct ArbitrationDecision: Sendable {
    public let state: CaptureState
    public let reasonCode: String

    public init(state: CaptureState, reasonCode: String) {
        self.state = state
        self.reasonCode = reasonCode
    }
}

public struct AudioArbitrator: Sendable {
    public init() {}

    public func evaluate(inputs: ArbitrationInputs, settings: RecorderSettings) -> ArbitrationDecision {
        switch inputs.demand {
        case .disabled:
            return ArbitrationDecision(state: .disabled, reasonCode: "demand_disabled")
        case .pausedByUser:
            return ArbitrationDecision(state: .pausedByUser, reasonCode: "user_paused")
        case .active:
            break
        }

        guard inputs.hasMicrophonePermission else {
            return ArbitrationDecision(state: .permissionRequired, reasonCode: "mic_permission_required")
        }

        guard inputs.hasInputDevice else {
            return ArbitrationDecision(state: .noInputDevice, reasonCode: "no_input_device")
        }

        if settings.inputArbitrationMode.shouldYieldToExternalInput, inputs.externalInputActive {
            return ArbitrationDecision(state: .yieldedToOtherInput, reasonCode: "external_input_active")
        }

        if settings.playbackPolicy.suppressesMicCapture, inputs.playbackActive {
            return ArbitrationDecision(state: .suppressedByPlayback, reasonCode: "playback_policy_active")
        }

        return ArbitrationDecision(state: .recording, reasonCode: "ready_to_record")
    }
}
