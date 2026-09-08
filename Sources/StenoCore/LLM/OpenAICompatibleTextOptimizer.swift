import Foundation

public struct OpenAICompatibleTextOptimizerConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var modelID: String
    public var timeoutSeconds: Double
    public var behavior: TextOptimizationBehavior
    public var apiKey: String

    public init(
        endpoint: String,
        modelID: String,
        timeoutSeconds: Double,
        behavior: TextOptimizationBehavior,
        apiKey: String
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.timeoutSeconds = timeoutSeconds
        self.behavior = behavior
        self.apiKey = apiKey
    }
}

public struct TextOptimizationResult: Sendable {
    public var text: String
    public var providerName: String
    public var modelID: String
    public var providerSnapshotJSON: String

    public init(text: String, providerName: String, modelID: String, providerSnapshotJSON: String) {
        self.text = text
        self.providerName = providerName
        self.modelID = modelID
        self.providerSnapshotJSON = providerSnapshotJSON
    }
}

public struct OpenAICompatibleTextOptimizer: Sendable {
    private let configuration: OpenAICompatibleTextOptimizerConfiguration
    private let session: URLSession

    public init(
        configuration: OpenAICompatibleTextOptimizerConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func validateConfiguration() throws {
        _ = try validatedEndpoint()
        guard !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw STTProviderError.invalidConfiguration("LLM model ID cannot be empty.")
        }
        guard !configuration.apiKey.isEmpty else {
            throw STTProviderError.invalidConfiguration("LLM API key not found. Save it in Settings.")
        }
    }

    public func optimize(text: String, languageIdentifier: String) async throws -> TextOptimizationResult {
        try validateConfiguration()
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw STTProviderError.invalidConfiguration("Cannot optimize empty text.")
        }

        let requestPayload = ChatCompletionsRequest(
            model: configuration.modelID,
            messages: [
                .init(role: "system", content: systemInstruction(for: configuration.behavior)),
                .init(role: "user", content: "Language: \(languageIdentifier)\n\nTranscript:\n\(content)")
            ],
            temperature: 0.2
        )

        let endpointURL = try validatedEndpoint()
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        guard !configuration.apiKey.isEmpty else {
            throw STTProviderError.invalidConfiguration("LLM API key not found. Save it in Settings.")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw STTProviderError.invalidConfiguration("LLM endpoint returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw STTProviderError.unsupported("LLM optimization request failed with HTTP \(http.statusCode).")
        }

        let parsed = try JSONDecoder().decode(ChatCompletionsResponse.self, from: responseData)
        guard let candidate = parsed.choices.first?.message.content,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw STTProviderError.unsupported("LLM optimization response was empty.")
        }

        struct Snapshot: Codable {
            var endpoint: String
            var modelID: String
            var behavior: TextOptimizationBehavior
            var timeoutSeconds: Double
        }

        let snapshot = Snapshot(
            endpoint: configuration.endpoint,
            modelID: configuration.modelID,
            behavior: configuration.behavior,
            timeoutSeconds: configuration.timeoutSeconds
        )

        let snapshotJSON: String
        if let data = try? JSONEncoder().encode(snapshot),
           let text = String(data: data, encoding: .utf8) {
            snapshotJSON = text
        } else {
            snapshotJSON = "{}"
        }

        return TextOptimizationResult(
            text: candidate.trimmingCharacters(in: .whitespacesAndNewlines),
            providerName: "openai_compatible_llm",
            modelID: configuration.modelID,
            providerSnapshotJSON: snapshotJSON
        )
    }

    public func validatedEndpoint() throws -> URL {
        let raw = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            throw STTProviderError.invalidConfiguration("Invalid LLM endpoint.")
        }

        if scheme == "https" {
            return url
        }

        if scheme == "http" {
            let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
            if loopbackHosts.contains(host) {
                return url
            }
            throw STTProviderError.invalidConfiguration("HTTP is only allowed for localhost; remote endpoints must use HTTPS.")
        }

        throw STTProviderError.invalidConfiguration("Only HTTP and HTTPS endpoints are supported.")
    }

    private func systemInstruction(for behavior: TextOptimizationBehavior) -> String {
        switch behavior {
        case .punctuationAndCasing:
            return "You are a transcript cleaner. Preserve meaning exactly. Fix punctuation, spacing, and letter casing only."
        case .readability:
            return "You improve transcript readability while preserving facts. Do not invent details. Keep the same language."
        case .conciseNotes:
            return "You rewrite transcript text into concise factual notes. Preserve key facts and avoid speculation."
        }
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var temperature: Double
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message
    }

    var choices: [Choice]
}
