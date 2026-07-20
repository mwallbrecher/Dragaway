import Foundation

// Completely free, runs locally on Apple Silicon.
// Install from: https://ollama.ai
// Then run: ollama pull llama3.1

final class OllamaProvider: AIProvider {
    let name = "Ollama (Local)"
    private let baseURL = "http://localhost:11434/v1/chat/completions"
    private let modelID: String
    private let supportsVision: Bool

    init(modelID: String, supportsVision: Bool) {
        self.modelID = modelID
        self.supportsVision = supportsVision
    }

    var isAvailable: Bool {
        // Synchronous check — acceptable for the settings UI only.
        // Do not call on the main thread during normal operation.
        let url = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: url, timeoutInterval: 1.0)
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        var available = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            available = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return available
    }

    func reply(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        try requireImageSupport(
            imageURL: imageURL,
            supportsVision: supportsVision,
            provider: name,
            modelID: modelID
        )
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Local inference is free, so the ceiling is only a runaway guard (stops a
        // looping model burning CPU/battery), never a bill-saving route decision.
        let body: [String: Any] = [
            "model": modelID,
            "messages": openAICompatMessages(
                messages,
                imageURL: imageURL,
                attachImage: supportsVision
            ),
            "max_tokens": plan.maxOutputTokens,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "No response"
    }

    func replyStream(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String {
        try requireImageSupport(
            imageURL: imageURL,
            supportsVision: supportsVision,
            provider: name,
            modelID: modelID
        )
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelID,
            "messages": openAICompatMessages(
                messages,
                imageURL: imageURL,
                attachImage: supportsVision
            ),
            "max_tokens": plan.maxOutputTokens,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await openAICompatSSE(request: request, onDelta: onDelta)
    }
}
