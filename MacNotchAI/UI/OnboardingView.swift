import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void

    /// The two ways to use Dragaway, chosen at the top of onboarding.
    /// `.free` (hosted, no key) is LOCKED until `BackendConfig.isBackendLive`.
    enum Version { case free, byok }

    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @State private var apiKey = ""
    @State private var saved  = false
    @State private var version: Version = .byok

    private var selectedType: AIProviderType {
        AIProviderType(rawValue: selectedProvider) ?? .groq
    }

    /// Hosted "Free" version is only selectable once the backend URL is filled in.
    private var hostedAvailable: Bool { EntitlementStore.shared.isHostedAvailable }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Welcome to Dragaway")
                    .font(.title2.bold())
                Text("Move any file towards the Notch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)

            Divider().padding(.vertical, 20)

            // ── Version chooser: Free (hosted) vs Bring your own key ─
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose how to use Dragaway")
                    .font(.headline)

                VersionCard(
                    icon: "sparkles",
                    title: "Dragaway Free",
                    subtitle: "Use AI instantly — no API key needed.",
                    badge: hostedAvailable ? "Free" : "Coming soon",
                    badgeColor: hostedAvailable ? .green : .secondary,
                    isSelected: version == .free,
                    isLocked: !hostedAvailable
                ) {
                    guard hostedAvailable else { return }
                    version = .free
                }

                VersionCard(
                    icon: "key.fill",
                    title: "Bring your own key",
                    subtitle: "Paste your own provider key — full speed, your own usage.",
                    badge: "Available",
                    badgeColor: .blue,
                    isSelected: version == .byok,
                    isLocked: false
                ) {
                    version = .byok
                }
            }
            .padding(.horizontal, 28)

            // ── BYOK setup (provider picker + key) ──────────────────
            if version == .byok {
                byokSetup
            } else {
                hostedInfo
            }

            Spacer(minLength: 12)

            // ── Footnote ─────────────────────────────────────────────
            if version == .byok {
                Text("* with average document sizes")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }

            // ── CTA ──────────────────────────────────────────────────
            Button(action: saveAndDismiss) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .disabled(ctaDisabled)
        }
        .frame(width: 400)
        .onAppear {
            // Reflect the persisted version, then pre-fill any existing key.
            version = EntitlementStore.shared.tier == .byok ? .byok : .free
            apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
        }
    }

    // ── BYOK setup section ──────────────────────────────────────────
    @ViewBuilder private var byokSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose your AI provider")
                .font(.headline)
                .padding(.top, 16)

            ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                ProviderRow(
                    type: type,
                    isSelected: selectedProvider == type.rawValue
                ) {
                    selectedProvider = type.rawValue
                    apiKey = KeychainManager.shared.load(service: keychainService(for: type)) ?? ""
                }
            }
        }
        .padding(.horizontal, 28)

        // API key field (hidden for Ollama)
        if selectedType != .ollama {
            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.headline)
                    .padding(.top, 16)

                SecureField(placeholder(for: selectedType), text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Stored securely in Keychain — never sent anywhere else.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if selectedType == .groq {
                    Link("Get a free Groq key (takes ~60 seconds) →",
                         destination: URL(string: "https://console.groq.com")!)
                        .font(.caption)
                } else if selectedType == .gemini {
                    Link("Get a Gemini key (Google AI Studio) →",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                } else if selectedType == .anthropic {
                    Link("Get an Anthropic API key →",
                         destination: URL(string: "https://console.anthropic.com")!)
                        .font(.caption)
                } else if selectedType == .openai {
                    Link("Get an OpenAI API key →",
                         destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 28)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make sure Ollama is running on your Mac.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Link("Download Ollama →", destination: URL(string: "https://ollama.ai")!)
                    .font(.caption)
                Text("Then run: ollama pull llama3.1")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
        }
    }

    // ── Hosted "Free" info (shown only when backend is live) ────────
    @ViewBuilder private var hostedInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dragaway Free")
                .font(.headline)
                .padding(.top, 16)
            Text("A free daily allowance, refreshed every day. No API key, no setup.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
    }

    // ── CTA enablement ──────────────────────────────────────────────
    private var ctaDisabled: Bool {
        switch version {
        case .free:
            return !hostedAvailable
        case .byok:
            return selectedType != .ollama && apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func saveAndDismiss() {
        switch version {
        case .byok:
            if selectedType != .ollama {
                KeychainManager.shared.save(key: apiKey.trimmingCharacters(in: .whitespaces),
                                            service: keychainService(for: selectedType))
            }
            EntitlementStore.shared.tier = .byok
        case .free:
            EntitlementStore.shared.tier = .freeHosted
        }
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        // Fresh install: follow up with the interactive tour (skippable; Settings → Help).
        if !UserDefaults.standard.bool(forKey: "tutorialShown") {
            NotificationCenter.default.post(name: .showTutorial, object: nil)
        }
        onDismiss()
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

// MARK: - Version card (Free vs BYOK)

struct VersionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String
    let badgeColor: Color
    let isSelected: Bool
    let isLocked: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {

                Image(systemName: isLocked ? "lock.fill" : icon)
                    .foregroundColor(isLocked ? .secondary : (isSelected ? .accentColor : .secondary))
                    .font(.system(size: 16))
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))

                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(badgeColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.12))
                            .overlay(
                                Capsule().strokeBorder(badgeColor.opacity(0.30), lineWidth: 0.75)
                            )
                            .clipShape(Capsule())

                        Spacer()
                    }

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundColor(isSelected ? .primary.opacity(0.75) : .secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .opacity(isLocked ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Provider row

struct ProviderRow: View {
    let type: AIProviderType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {

                    // Row 1: provider name + tier badge
                    HStack(spacing: 7) {
                        Text(type.displayName)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))

                        // Coloured tier badge (Free / Balance / Highest Quality / Local)
                        Text(type.badgeLabel)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(type.badgeColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(type.badgeColor.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(type.badgeColor.opacity(0.30), lineWidth: 0.75)
                            )
                            .clipShape(Capsule())

                        Spacer()
                    }

                    // Row 2: tagline
                    Text(type.tagline)
                        .font(.caption.weight(.medium))
                        .foregroundColor(isSelected ? .primary.opacity(0.75) : .secondary)

                    // Row 3: model + pricing caption
                    Text(type.pricingSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.80))
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
