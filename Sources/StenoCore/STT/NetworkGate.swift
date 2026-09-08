import Foundation
import Network

/// Holds remote transcription work until the machine actually has a network
/// path.
///
/// Without this, going offline burns a job's entire retry budget in about three
/// seconds — every attempt fails instantly with no route — and the segment is
/// marked failed while the user is still talking. Parking the queue instead
/// keeps the backlog intact until connectivity returns.
public actor NetworkGate {
    private let monitor = NWPathMonitor()
    /// Assume usable until the monitor says otherwise, so the first segment
    /// after launch is not delayed waiting for an initial path callback.
    private var isSatisfied = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.update(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "local.steno.network-gate"))
    }

    private func update(satisfied: Bool) {
        isSatisfied = satisfied
    }

    public var isNetworkAvailable: Bool { isSatisfied }

    /// Suspends until a network path exists. Polls rather than parking a
    /// continuation so that cancelling the job (app quit, recorder stop) cannot
    /// strand a suspended task holding the serialized queue.
    // ponytail: 2s poll while offline costs nothing on a suspended task; switch
    // to continuations woken by pathUpdateHandler only if sub-second pickup
    // after reconnecting ever matters.
    public func waitUntilSatisfied() async throws {
        while !isSatisfied {
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// True when the endpoint resolves to this machine, where a missing network
    /// path is irrelevant — a local model server keeps working offline and must
    /// not be gated.
    public static func isLoopback(endpoint: String) -> Bool {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}
