import Foundation
import SwiftUI

protocol AIProvider {
    var name: String { get }
    var isAvailable: Bool { get }
    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String
}

enum AIProviderType: String, CaseIterable {
    case groq       = "Groq (Free)"
    case gemini     = "Gemini (Google)"
    case openai     = "OpenAI (GPT-4o)"
    case anthropic  = "Anthropic (Claude)"
    case ollama     = "Ollama (Local, Free)"
}

// MARK: - Display metadata (used by provider picker in Onboarding + Settings)

extension AIProviderType {

    /// Short, friendly name shown as the row title.
    var displayName: String {
        switch self {
        case .groq:      return "Groq"
        case .gemini:    return "Gemini"
        case .anthropic: return "Claude"
        case .openai:    return "ChatGPT"
        case .ollama:    return "Ollama"
        }
    }

    /// Model badge shown next to the provider name in the picker row.
    var modelLabel: String {
        switch self {
        case .groq:      return "Llama 3.1 8B"
        case .gemini:    return "Gemini 2.5 Flash"
        case .anthropic: return "Haiku 4.5"
        case .openai:    return "GPT-4o mini"
        case .ollama:    return "local model"
        }
    }

    /// Prominent tier badge label shown on the provider card.
    var badgeLabel: String {
        switch self {
        case .groq:      return "Free"
        case .gemini:    return "Cheapest"
        case .openai:    return "Balance"
        case .anthropic: return "Highest Quality"
        case .ollama:    return "Local"
        }
    }

    /// Badge background colour.
    var badgeColor: Color {
        switch self {
        case .groq:      return .green
        case .gemini:    return .green
        case .openai:    return .blue
        case .anthropic: return .purple
        case .ollama:    return .secondary
        }
    }

    /// One-line tagline beneath the provider name.
    var tagline: String {
        switch self {
        case .groq:      return "Fast · Good for simple document analyses"
        case .gemini:    return "Fastest with fairly good reasoning"
        case .anthropic: return "Deepest reasoning · Best for power users"
        case .openai:    return "Better reasoning · Balance between quality, speed & price"
        case .ollama:    return "Runs on your Mac · Limited to your hardware"
        }
    }

    /// Model identifier + cost line shown as caption.
    ///
    /// Typical AI Drop task ≈ 1,500 tokens in + 400 tokens out:
    ///   Groq / Llama 3.1 8B   → free tier available, ~10,000 interactions per $5
    ///   Claude Haiku 4.5      → ~385 interactions per $5
    ///   GPT-4o mini           → ~2,800 interactions per $5
    ///   Ollama                → free local inference
    var pricingSubtitle: String {
        switch self {
        case .groq:
            return "Llama 3.1 8B · Free tier available · ~10,000 interactions* per $5"
        case .gemini:
            return "Gemini 2.5 Flash · Cheapest · Fastest with fairly good reasoning"
        case .anthropic:
            return "Claude Haiku 4.5 · ~400 interactions* per $5"
        case .openai:
            return "GPT-4o mini · ~2,800 interactions* per $5"
        case .ollama:
            return "Any local model · Free · No internet or API key required"
        }
    }

    /// Whether this provider requires a paid/registered API key.
    var requiresAPIKey: Bool {
        self != .ollama
    }

    /// Badge tint — green for free options, blue/default for paid.
    var isFree: Bool {
        self == .groq || self == .ollama
    }
}
