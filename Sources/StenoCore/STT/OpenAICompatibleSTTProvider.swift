import Foundation

public struct OpenAICompatibleSTTConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var modelID: String
    public var languageIdentifier: String
    public var timeoutSeconds: Double
    public var apiKey: String

    public init(
        endpoint: String,
        modelID: String,
        languageIdentifier: String,
        timeoutSeconds: Double,
        apiKey: String
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.languageIdentifier = languageIdentifier
        self.timeoutSeconds = timeoutSeconds
        self.apiKey = apiKey
    }
}

public struct OpenAICompatibleSTTProvider: STTProvider {
    public let kind: STTProviderKind = .customAPI

    private let configuration: OpenAICompatibleSTTConfiguration
    private let session: URLSession

    public init(
        configuration: OpenAICompatibleSTTConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func availability(for language: Locale) async -> STTAvailability {
        do {
            try validateConfiguration()
            let message = language.identifier == configuration.languageIdentifier
                ? nil
                : "Request language is fixed to \(configuration.languageIdentifier) by Settings."
            return STTAvailability(isAvailable: true, message: message)
        } catch {
            return STTAvailability(isAvailable: false, message: error.localizedDescription)
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try validateConfiguration()
        guard let pcmData = request.pcmData, !pcmData.isEmpty else {
            throw STTProviderError.invalidConfiguration("No audio was captured for this segment.")
        }
        guard !configuration.apiKey.isEmpty else {
            throw STTProviderError.missingAPIKey
        }

        let wavData = Self.makeWAVData(pcmFloat32LittleEndian: pcmData, sampleRate: request.sampleRateHz)
        let boundary = "Boundary-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: try validatedEndpoint())
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeoutSeconds

        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.makeMultipartBody(
            boundary: boundary,
            wavData: wavData,
            modelID: configuration.modelID,
            languageIdentifier: configuration.languageIdentifier
        )

        let (responseData, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw STTProviderError.unsupported("STT endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw STTProviderError.unsupported("STT request failed with HTTP \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw STTProviderError.unsupported("STT response contained no text.")
        }

        return TranscriptionResult(
            text: text,
            isFinal: true,
            language: configuration.languageIdentifier,
            confidence: nil,
            providerKind: .customAPI,
            engineVersionOrMode: configuration.modelID
        )
    }

    public func validateConfiguration() throws {
        _ = try validatedEndpoint()
        guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw STTProviderError.invalidConfiguration("Model ID cannot be empty.")
        }
        guard !configuration.apiKey.isEmpty else {
            throw STTProviderError.missingAPIKey
        }
    }

    public func validatedEndpoint() throws -> URL {
        let raw = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            throw STTProviderError.invalidConfiguration("Invalid STT endpoint.")
        }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return url }
        if scheme == "http" {
            throw STTProviderError.invalidConfiguration("HTTP is only allowed for localhost; remote endpoints must use HTTPS.")
        }
        throw STTProviderError.invalidConfiguration("Only HTTP and HTTPS endpoints are supported.")
    }

    private static func makeMultipartBody(
        boundary: String,
        wavData: Data,
        modelID: String,
        languageIdentifier: String
    ) throws -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField("model", modelID)
        if !languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("language", languageIdentifier)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    public static func makeWAVData(pcmFloat32LittleEndian: Data, sampleRate: Double) -> Data {
        let floatCount = pcmFloat32LittleEndian.count / MemoryLayout<Float>.size
        let samples = pcmFloat32LittleEndian.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self).prefix(floatCount))
        }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func appendASCII(_ string: String) { data.append(Data(string.utf8)) }
        func appendLE(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendLE(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendLE(UInt32(36) + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(channels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        appendASCII("data")
        appendLE(dataSize)
        for sample in samples {
            let intSample = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            withUnsafeBytes(of: intSample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private struct TranscriptionResponse: Decodable {
    var text: String
}
