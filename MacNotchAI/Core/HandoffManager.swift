import AppKit

/// Hands the current session off to the user's native AI app or its web interface.
///
/// What it does:
/// 1. Builds a clipboard payload: system prompt + file name/path + AI response
///    (for image files the NSImage is also placed on the clipboard so the user
///    can paste it straight into a chat input).
/// 2. Opens the provider's native app (if installed) via bundle ID / URL scheme,
///    falling back to the provider's web URL.
///
/// The caller gets back the display name of the provider ("Claude", "ChatGPT", …)
/// to show in UI feedback.
struct HandoffManager {

    // MARK: - Public API

    /// Copy context to clipboard, open the provider, return the provider's display name.
    @discardableResult
    static func handOff(fileURL: URL, action: AIAction, result: String) -> String {
        let type = currentProviderType()
        copyToClipboard(fileURL: fileURL, action: action, result: result)
        openProvider(type)
        return providerName(type)
    }

    static func providerName(_ type: AIProviderType? = nil) -> String {
        switch type ?? currentProviderType() {
        case .groq:      return "Groq"
        case .gemini:    return "Gemini"
        case .anthropic: return "Claude"
        case .openai:    return "ChatGPT"
        case .ollama:    return "Ollama"
        }
    }

    static func providerIcon(_ type: AIProviderType? = nil) -> String {
        switch type ?? currentProviderType() {
        case .groq:      return "bolt.fill"
        case .gemini:    return "sparkles"
        case .anthropic: return "sparkle"
        case .openai:    return "brain"
        case .ollama:    return "server.rack"
        }
    }

    // MARK: - Clipboard

    private static func copyToClipboard(fileURL: URL, action: AIAction, result: String) {
        let payload = """
        \(action.systemPrompt)

        ---
        File: \(fileURL.lastPathComponent)
        Path: \(fileURL.path)
        ---

        Previous AI response:
        \(result)

        ---
        Continue the conversation below:
        """

        let pb = NSPasteboard.general
        pb.clearContents()

        if FileInspector.isImageFile(fileURL), let image = NSImage(contentsOf: fileURL) {
            // Write both image and text so the user can paste the image directly.
            // NSPasteboard.writeObjects(_:) accepts any NSPasteboardWriting — NSImage conforms.
            pb.writeObjects([image])
            pb.addTypes([.string], owner: nil)
            pb.setString(payload, forType: .string)
        } else {
            pb.setString(payload, forType: .string)
        }
    }

    // MARK: - Open provider

    private static func openProvider(_ type: AIProviderType) {
        switch type {
        case .anthropic:
            // Anthropic desktop app (claude.ai/download) → fallback to web new chat
            if !tryOpenApp(bundleID: "com.anthropic.claudefordesktop") {
                open("https://claude.ai/new")
            }
        case .openai:
            // ChatGPT Mac app registers the chatgpt:// scheme → fallback to web
            if !tryOpenScheme("chatgpt://") {
                open("https://chatgpt.com")
            }
        case .groq:
            open("https://console.groq.com/playground")
        case .gemini:
            open("https://gemini.google.com/app")
        case .ollama:
            // Open WebUI (localhost:3000) is the most popular Ollama front-end.
            // Falls back to the Ollama API docs page if nothing is running locally.
            open("http://localhost:3000")
        }
    }

    // MARK: - Helpers

    private static func currentProviderType() -> AIProviderType {
        let raw = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
        return AIProviderType(rawValue: raw) ?? .groq
    }

    /// Open an app by its bundle identifier. Returns true if the app was found and launched.
    @discardableResult
    private static func tryOpenApp(bundleID: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        // open(_:) on a .app URL launches the application.
        NSWorkspace.shared.open(appURL)
        return true
    }

    /// Open a URL scheme. Returns true if an app is registered for the scheme.
    @discardableResult
    private static func tryOpenScheme(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
