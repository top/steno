import AVFoundation
import Foundation
import Speech

@available(macOS 15.0, *)
public struct AppleSystemSpeechProvider: STTProvider {
    public let kind: STTProviderKind = .appleSystem
    private let languageIdentifier: String
    private let processingPolicy: AppleProcessingPolicy

    public init(languageIdentifier: String, processingPolicy: AppleProcessingPolicy) {
        self.languageIdentifier = languageIdentifier
        self.processingPolicy = processingPolicy
    }

    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return .denied
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func availability(for language: Locale) async -> STTAvailability {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return STTAvailability(isAvailable: false, message: "Run the bundled app to use Apple Speech; this executable has no Speech usage description.")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return STTAvailability(isAvailable: false, message: "Speech Recognition permission is required.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: language), recognizer.isAvailable else {
            return STTAvailability(isAvailable: false, message: "Apple System Speech is unavailable for \(language.identifier).")
        }
        if processingPolicy == .onDeviceOnly, !recognizer.supportsOnDeviceRecognition {
            return STTAvailability(isAvailable: false, message: "On-device recognition is unavailable for \(language.identifier); Apple service fallback remains disabled.")
        }
        return STTAvailability(
            isAvailable: true,
            message: processingPolicy == .onDeviceOnly
                ? "Apple System Speech is available in on-device-only mode."
                : "Apple System Speech is available; audio may be processed by Apple services."
        )
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard Date() < request.deadline else {
            throw STTProviderError.unsupported("Apple System Speech request deadline expired.")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw STTProviderError.unsupported("Speech Recognition permission is required.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: request.language), recognizer.isAvailable else {
            throw STTProviderError.unsupported("Apple System Speech is unavailable for \(request.language.identifier).")
        }
        if processingPolicy == .onDeviceOnly, !recognizer.supportsOnDeviceRecognition {
            throw STTProviderError.unsupported("On-device Apple recognition is unavailable; network fallback was not used.")
        }
        guard let pcmData = request.pcmData, !pcmData.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: request.sampleRateHz,
                channels: 1,
                interleaved: false
              ) else {
            throw STTProviderError.invalidConfiguration("No valid PCM audio was captured for Apple System Speech.")
        }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Float>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = buffer.floatChannelData?[0] else {
            throw STTProviderError.unsupported("Could not prepare audio for Apple System Speech.")
        }
        pcmData.withUnsafeBytes { bytes in
            guard let source = bytes.bindMemory(to: Float.self).baseAddress else { return }
            destination.update(from: source, count: Int(frameCount))
        }
        buffer.frameLength = frameCount

        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.shouldReportPartialResults = false
        speechRequest.requiresOnDeviceRecognition = processingPolicy == .onDeviceOnly
        speechRequest.append(buffer)
        speechRequest.endAudio()

        let remainingSeconds = max(1, request.deadline.timeIntervalSinceNow)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = SpeechContinuationGate(continuation, timeoutSeconds: remainingSeconds)
            _ = recognizer.recognitionTask(with: speechRequest) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        gate.fail(STTProviderError.unsupported("Apple System Speech returned no final text."))
                        return
                    }
                    gate.succeed(
                        TranscriptionResult(
                            text: text,
                            isFinal: true,
                            language: request.language.identifier,
                            confidence: nil,
                            providerKind: .appleSystem,
                            engineVersionOrMode: self.processingPolicy.rawValue
                        )
                    )
                } else if let error {
                    gate.fail(STTProviderError.unsupported("Apple System Speech failed: \(error.localizedDescription)"))
                }
            }
        }
    }
}

private final class SpeechContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private let timeoutQueue = DispatchQueue(label: "ambient.assistant.speech-timeout", qos: .utility)

    init(_ continuation: CheckedContinuation<TranscriptionResult, Error>, timeoutSeconds: TimeInterval) {
        self.continuation = continuation
        let item = DispatchWorkItem { [weak self] in
            self?.fail(STTProviderError.unsupported("Apple System Speech recognition timed out after \(timeoutSeconds)s."))
        }
        self.timeoutWorkItem = item
        timeoutQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
    }

    deinit {
        timeoutWorkItem?.cancel()
    }

    func succeed(_ result: TranscriptionResult) {
        take()?.resume(returning: result)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<TranscriptionResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let value = continuation
        continuation = nil
        return value
    }
}
