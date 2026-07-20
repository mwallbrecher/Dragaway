import Foundation

enum AIError: LocalizedError {
    case noAPIKey(provider: String)
    case invalidConfiguration(String)
    case modelUnavailable(provider: String, model: String)
    case imageInputUnsupported(provider: String, model: String)
    case apiError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            return "No API key for \(provider). Open Settings (⌘,) to add one."
        case .invalidConfiguration(let message):
            return message
        case .modelUnavailable(let provider, let model):
            return "\(model) is no longer available from \(provider). Open Provider Settings, refresh the model list, and choose another model."
        case .imageInputUnsupported(let provider, let model):
            return "\(model) does not support image input on \(provider). Choose a vision-capable model in Provider Settings."
        case .apiError(let msg):
            return msg
        case .httpError(let code):
            return "Request failed (HTTP \(code))."
        }
    }
}

// Shared helper used by all providers.
extension Data {
    /// Tries to extract a human-readable message from an API error body.
    func apiErrorMessage() -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: self) as? [String: Any] else { return nil }
        // OpenAI / Groq style: { "error": { "message": "..." } }
        if let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String { return msg }
        // Anthropic style: { "error": { "message": "..." } } — same shape, covered above.
        return nil
    }
}
