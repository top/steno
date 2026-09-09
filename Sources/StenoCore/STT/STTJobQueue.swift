import Foundation

public actor STTJobQueue {
    public typealias Operation = @Sendable () async throws -> TranscriptionResult
    public typealias AttemptObserver = @Sendable (_ attempt: Int, _ error: Error?) async -> Void
    public typealias Completion = @Sendable (Result<TranscriptionResult, Error>) async -> Void

    private struct Job: Sendable {
        let operation: Operation
        let onAttempt: AttemptObserver
        let completion: Completion
    }

    private var jobs: [Job] = []
    private var processor: Task<Void, Never>?
    private let maximumAttempts: Int

    public init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public func enqueue(
        operation: @escaping Operation,
        onAttempt: @escaping AttemptObserver,
        completion: @escaping Completion
    ) {
        jobs.append(Job(operation: operation, onAttempt: onAttempt, completion: completion))
        guard processor == nil else { return }
        processor = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await run(job)
        }
        processor = nil
    }

    private func run(_ job: Job) async {
        var lastError: Error = STTProviderError.unsupported("STT job did not run.")
        for attempt in 1...maximumAttempts {
            do {
                await job.onAttempt(attempt, nil)
                await job.completion(.success(try await job.operation()))
                return
            } catch {
                lastError = error
                await job.onAttempt(attempt, error)
                // A permanent error is the same error next second. Sleeping and
                // asking again only delays the discard.
                if (error as? STTProviderError)?.isPermanent == true { break }
                guard attempt < maximumAttempts else { break }
                try? await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000)
            }
        }
        await job.completion(.failure(lastError))
    }
}
