import Foundation

// Gemini 2.5 Flash — BYOK
// API key from: https://aistudio.google.com/apikey
// Uses Google's OpenAI-compatible endpoint, so it reuses OpenAICompatibleResponse.

final class GeminiProvider: AIProvider {
    let name = "Gemini"
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    private let model = "gemini-2.5-flash"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent: Any = content

        if let imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            let base64 = imageData.base64EncodedString()
            let mime = Self.mimeType(for: imageURL)
            userContent = [
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]],
                ["type": "text", "text": action.systemPrompt]
            ]
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user",   "content": userContent]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "No response"
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        default:            return "image/png"
        }
    }
}
