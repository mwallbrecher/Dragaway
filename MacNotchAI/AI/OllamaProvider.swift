import Foundation

// Completely free, runs locally on Apple Silicon.
// Install from: https://ollama.ai
// Then run: ollama pull llama3.1

final class OllamaProvider: AIProvider {
    let name = "Ollama (Local)"
    private let baseURL = "http://localhost:11434/v1/chat/completions"
    private let model = "llama3.1"

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
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Local llama3.1 is text-only — attachImage: false. Local inference is free,
        // so the ceiling here is only a runaway guard (stops a looping model burning
        // CPU/battery), never a bill saving.
        let body: [String: Any] = [
            "model": model,
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: false),
            "max_tokens": plan.maxOutputTokens,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }

    func replyStream(messages: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": openAICompatMessages(messages, imageURL: imageURL, attachImage: false),
            "max_tokens": plan.maxOutputTokens,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await openAICompatSSE(request: request, onDelta: onDelta)
    }
}
