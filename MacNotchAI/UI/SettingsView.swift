import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @AppStorage("uiScale")          private var uiScaleRaw       = UIScale.small.rawValue
    @ObservedObject private var promptStore = PromptStore.shared
    @State private var apiKey = ""
    @State private var ollamaAvailable = false
    @State private var saved = false
    @State private var newCustomPrompt = ""

    private var selectedType: AIProviderType {
        AIProviderType(rawValue: selectedProvider) ?? .groq
    }

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Window Size")
                        .font(.headline)

                    HStack(spacing: 10) {
                        ForEach(UIScale.allCases, id: \.rawValue) { scale in
                            let selected = uiScaleRaw == scale.rawValue
                            Button {
                                uiScaleRaw = scale.rawValue
                            } label: {
                                VStack(spacing: 4) {
                                    Text(scale.label)
                                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                    Text(scale.sizeHint)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected
                                              ? Color.accentColor.opacity(0.15)
                                              : Color.secondary.opacity(0.08))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(selected ? Color.accentColor : .clear,
                                                              lineWidth: 1.5)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Takes effect on the next drag.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Custom Prompts"),
                    footer: Text("These appear in the Custom tab when you drop a file. Tap one to run it against the file.")
                        .font(.caption2)
                        .foregroundColor(.secondary)) {
                if promptStore.customPrompts.isEmpty {
                    Text("No custom prompts yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(promptStore.customPrompts, id: \.self) { prompt in
                        HStack {
                            Text(prompt)
                                .font(.system(size: 13))
                                .lineLimit(2)
                            Spacer()
                            Button(role: .destructive) {
                                promptStore.removeCustom(prompt)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                            .help("Delete prompt")
                        }
                    }
                }

                HStack {
                    TextField("Add a custom prompt…", text: $newCustomPrompt)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustomPrompt)
                    Button("Add", action: addCustomPrompt)
                        .disabled(newCustomPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section(header: Text("AI Provider"),
                    footer: Text("* with average document sizes")
                        .font(.caption2)
                        .foregroundColor(.secondary)) {
                VStack(spacing: 6) {
                    ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                        ProviderRow(
                            type: type,
                            isSelected: selectedProvider == type.rawValue
                        ) {
                            selectedProvider = type.rawValue
                            apiKey = KeychainManager.shared.load(
                                service: keychainService(for: selectedType)
                            ) ?? ""
                            saved = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if selectedType != .ollama {
                Section("API Key (stored securely in Keychain)") {
                    SecureField(placeholder(for: selectedType), text: $apiKey)

                    HStack {
                        Button("Save Key") {
                            KeychainManager.shared.save(
                                key: apiKey.trimmingCharacters(in: .whitespaces),
                                service: keychainService(for: selectedType)
                            )
                            saved = true
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }

                        Spacer()

                        switch selectedType {
                        case .groq:
                            Link("Get a free Groq key →", destination: URL(string: "https://console.groq.com")!)
                                .font(.caption)
                        case .gemini:
                            Link("Get a Gemini key →", destination: URL(string: "https://aistudio.google.com/apikey")!)
                                .font(.caption)
                        case .anthropic:
                            Link("Get an Anthropic key →", destination: URL(string: "https://console.anthropic.com")!)
                                .font(.caption)
                        case .openai:
                            Link("Get an OpenAI key →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                                .font(.caption)
                        case .ollama:
                            EmptyView()
                        }
                    }
                }
            } else {
                Section("Ollama (Local)") {
                    HStack {
                        Circle()
                            .fill(ollamaAvailable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(ollamaAvailable ? "Ollama is running" : "Ollama not detected")
                            .font(.caption)
                    }
                    Link("Download Ollama →", destination: URL(string: "https://ollama.ai")!)
                        .font(.caption)
                    Text("After installing, run: ollama pull llama3.1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .task { ollamaAvailable = await isOllamaRunning() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
        }
    }

    private func addCustomPrompt() {
        let t = newCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        promptStore.addCustom(t)
        newCustomPrompt = ""
    }

    private func keychainService(for type: AIProviderType) -> String {
        switch type {
        case .groq:      return "com.aidrop.groq"
        case .gemini:    return "com.aidrop.gemini"
        case .anthropic: return "com.aidrop.anthropic"
        case .openai:    return "com.aidrop.openai"
        case .ollama:    return "com.aidrop.ollama"
        }
    }

    private func placeholder(for type: AIProviderType) -> String {
        switch type {
        case .groq:      return "gsk_..."
        case .gemini:    return "AIza..."
        case .anthropic: return "sk-ant-..."
        case .openai:    return "sk-..."
        case .ollama:    return ""
        }
    }
}

/// Checks whether Ollama is running by pinging its health endpoint.
/// Uses proper async/await instead of a blocking semaphore.
private func isOllamaRunning() async -> Bool {
    guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
    var request = URLRequest(url: url, timeoutInterval: 1.5)
    request.httpMethod = "GET"
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
        return false
    }
}
