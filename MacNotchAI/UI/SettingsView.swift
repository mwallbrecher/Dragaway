import SwiftUI
import UniformTypeIdentifiers

/// Which slice of the settings to show. The menu-bar dropdown opens the window
/// scoped to a single setting (`.windowSize` / `.customPrompt` / `.favoriteTools` /
/// `.aiProvider`); the system ⌘, Settings scene still shows everything (`.all`).
enum SettingsSection: String {
    case all, windowSize, customPrompt, favoriteTools, outputDirectory, scripts, aiProvider, clipboard, help

    /// Title for the settings window when opened scoped to this section.
    var windowTitle: String {
        switch self {
        case .all:             return "Dragaway Settings"
        case .windowSize:      return "Window Size"
        case .customPrompt:    return "Custom Prompts"
        case .favoriteTools:   return "Favorite Tools"
        case .outputDirectory: return "Output Directory"
        case .scripts:         return "Scripts"
        case .aiProvider:      return "AI Provider"
        case .clipboard:       return "Clipboard & Capture"
        case .help:            return "Help"
        }
    }
}

struct SettingsView: View {
    /// Slice to render. `.all` (default) shows every section — used by the system
    /// ⌘, scene. The menu items pass a single section to focus the window.
    var section: SettingsSection = .all

    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @AppStorage("uiScale")          private var uiScaleRaw       = UIScale.small.rawValue
    @AppStorage("screenshotsToSession")         private var screenshotsToSession  = false
    @AppStorage("clipboardSessionHotkeyEnabled") private var clipboardHotkeyEnabled = true
    /// Sub-mode of screenshots→session: "instant" (thumbnail off, immediate) or
    /// "thumbnail" (preview kept, session opens after the ~5 s save delay).
    @AppStorage("screenshotCaptureMode")        private var screenshotMode = "instant"

    /// The macOS floating thumbnail goes off only while the feature is on AND in
    /// instant mode; any other combination restores the system default.
    private func applyThumbnailPreference() {
        ScreenCapturePrefs.setThumbnailDisabled(screenshotsToSession && screenshotMode == "instant")
    }

    /// One hotkey line on the Help page: key chip + description.
    private func helpRow(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6)))
                .frame(minWidth: 84, alignment: .leading)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
    }
    @ObservedObject private var promptStore = PromptStore.shared
    @ObservedObject private var toolsStore  = FavoriteToolsStore.shared
    @ObservedObject private var outputStore = OutputDirectoryStore.shared
    @ObservedObject private var scriptsStore = ScriptsStore.shared
    @State private var apiKey = ""
    @State private var ollamaAvailable = false
    @State private var saved = false
    @State private var newCustomPrompt = ""
    /// Which favorite-tools tab is showing. `.general` = the shared list; a category
    /// case = that file type's own list (with its Use-General toggle).
    @State private var favTab: FavTab = .general
    /// Which Output Directory tab is showing (reuses `FavTab`: General + per-category).
    @State private var outTab: FavTab = .general

    /// Selection for the Favorite Tools tab picker.
    private enum FavTab: Hashable {
        case general
        case category(FileCategory)
    }

    private var selectedType: AIProviderType {
        AIProviderType(rawValue: selectedProvider) ?? .groq
    }

    /// Whether a given section should render under the current scope.
    private func shows(_ s: SettingsSection) -> Bool { section == .all || section == s }

    var body: some View {
        Form {
            if shows(.windowSize) {
            Section("Window Size") {
                VStack(alignment: .leading, spacing: 12) {
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
            }

            if shows(.clipboard) {
            Section("Clipboard & Capture") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Open new screenshots in a session", isOn: $screenshotsToSession)
                        Text("Take a screenshot with the native ⇧⌘4 / ⇧⌘5 — Dragaway opens the saved file in a session automatically. (macOS reserves those shortcuts, so they can't be overridden directly; the file still lands where your screenshots normally save.)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if screenshotsToSession {
                            Picker("", selection: $screenshotMode) {
                                Text("Instant — skip the floating thumbnail").tag("instant")
                                Text("Keep the floating thumbnail").tag("thumbnail")
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            .padding(.top, 4)
                            Text(screenshotMode == "instant"
                                 ? "Screenshots save immediately and the session opens right away. Trade-off: macOS's corner preview is turned off system-wide, so its quick actions (markup, drag) aren't available for any screenshot."
                                 : "The corner preview keeps working as usual — but macOS only writes the screenshot file once the preview is dismissed or times out (~5 s), so the session opens after that delay.")
                                .font(.caption)
                                .foregroundColor(.orange.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("⌃⌘N — New session from clipboard", isOn: $clipboardHotkeyEnabled)
                        Text("Press ⌃⌘N anywhere to open whatever is in your clipboard (text, image, link, or copied files) in a new session — including screenshots taken to the clipboard with ⌃⇧⌘4.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .onChange(of: screenshotsToSession) { _, _ in
                    applyThumbnailPreference()
                    NotificationCenter.default.post(name: .captureSettingsChanged, object: nil)
                }
                .onChange(of: screenshotMode) { _, _ in
                    applyThumbnailPreference()
                }
                .onChange(of: clipboardHotkeyEnabled) { _, _ in
                    NotificationCenter.default.post(name: .captureSettingsChanged, object: nil)
                }
            }
            }

            if shows(.help) {
            Section("Hotkeys") {
                VStack(alignment: .leading, spacing: 8) {
                    helpRow("⌃⌘V",       "Clipboard history picker (last 10)")
                    helpRow("⌃⌘N",       "New session from the current clipboard")
                    helpRow("⌥1 … ⌥9",   "Open the dropped file in a favorite app")
                    helpRow("Tab / ⇧Tab", "Cycle the session card's tabs")
                    helpRow("⇧ + drag",  "Radial launcher (change under Add Hotkey…)")
                    helpRow("Esc",       "Dismiss the pill / close the card")
                }
                .padding(.vertical, 4)
            }
            Section("Where things live") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Drag files, text, links, or images onto the notch to start a session.\n• Right-click files in Finder → Quick Actions → “Add to Dragaway”.\n• Utilities tab: local conversions (PDF ⇄ Word/Markdown, images, video) — no upload.\n• Scripts tab: run your own commands on the dropped file.\n• Screenshots → session: Settings → Clipboard & Capture.\n• Recent + Search Sessions: menu bar icon.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Restart Tutorial") {
                        NotificationCenter.default.post(name: .showTutorial, object: nil)
                    }
                    .padding(.top, 6)
                }
                .padding(.vertical, 4)
            }
            }

            if shows(.customPrompt) {
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
            }

            if shows(.favoriteTools) {
            Section(header: Text("Favorite Tools"),
                    footer: Text("Drop a file, then open it in one of these apps with a click — or press ⌥1…⌥9. Up to 9 apps per list. Each file type can keep its own apps or use your General list.")
                        .font(.caption2)
                        .foregroundColor(.secondary)) {
                Picker("", selection: $favTab) {
                    Text("General").tag(FavTab.general)
                    ForEach(FileCategory.allCases, id: \.self) { c in
                        Text(c.title).tag(FavTab.category(c))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 4)

                favoriteToolsBody
            }
            }

            if shows(.outputDirectory) {
            Section(header: Text("Output Directory"),
                    footer: Text("Where file-utility outputs are saved. Set a General folder, or give a file type its own. Empty = save next to the original file (the default).")
                        .font(.caption2)
                        .foregroundColor(.secondary)) {
                Picker("", selection: $outTab) {
                    Text("General").tag(FavTab.general)
                    ForEach(FileCategory.allCases, id: \.self) { c in
                        Text(c.title).tag(FavTab.category(c))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 4)

                outputDirectoryBody
            }
            }

            if shows(.scripts) {
            Section(header: Text("Scripts"),
                    footer: Text("Saved shell commands runnable from the Scripts tab against a dropped file's project. Placeholders: {dir} (file's folder), {file}, {name}, {root} (git root). Commands run in a login shell — you author them; they only run when you tap.")
                        .font(.caption2)
                        .foregroundColor(.secondary)) {
                scriptsBody
            }
            }

            if shows(.aiProvider) {
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
        }
    }

    /// Body of the Favorite Tools section for the selected tab. The General tab shows
    /// just its list; a category tab shows a Use-General toggle, then either a note
    /// (deferring) or that category's own editable list.
    @ViewBuilder private var favoriteToolsBody: some View {
        switch favTab {
        case .general:
            favoriteList(for: nil)
        case .category(let c):
            Toggle("Use General favorites", isOn: Binding(
                get: { toolsStore.useGeneral(for: c) },
                set: { toolsStore.setUseGeneral($0, for: c) }
            ))
            if toolsStore.useGeneral(for: c) {
                Text("\(c.title) files use your General favorites.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                favoriteList(for: c)
            }
        }
    }

    /// The editable favorites list for a scope (`nil` = General): icon + name + ⌥N +
    /// remove, drag-to-reorder, and an Add button capped at `maxTools`.
    @ViewBuilder private func favoriteList(for category: FileCategory?) -> some View {
        let tools = toolsStore.tools(for: category)
        if tools.isEmpty {
            Text("No favorite apps yet.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                HStack(spacing: 10) {
                    Image(nsImage: toolsStore.icon(for: tool))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(tool.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    Text("⌥\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        toolsStore.remove(tool, from: category)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .help("Remove \(tool.name)")
                }
            }
            .onMove { toolsStore.move(from: $0, to: $1, in: category) }
        }

        Button {
            addTool(to: category)
        } label: {
            Label("Add App…", systemImage: "plus")
        }
        .disabled(toolsStore.tools(for: category).count >= FavoriteToolsStore.maxTools)
    }

    /// Body of the Output Directory section for the selected tab — mirrors
    /// `favoriteToolsBody`: General shows just its folder; a category shows a
    /// "Use General File Directory" toggle, then a note or its own folder picker.
    @ViewBuilder private var outputDirectoryBody: some View {
        switch outTab {
        case .general:
            outputDirField(for: nil)
        case .category(let c):
            Toggle("Use General File Directory", isOn: Binding(
                get: { outputStore.useGeneral(for: c) },
                set: { outputStore.setUseGeneral($0, for: c) }
            ))
            if outputStore.useGeneral(for: c) {
                Text("\(c.title) files use your General output folder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                outputDirField(for: c)
            }
        }
    }

    /// The folder row + Choose/Change + Clear for a scope (`nil` = General).
    @ViewBuilder private func outputDirField(for category: FileCategory?) -> some View {
        let path = outputStore.path(for: category)
        HStack(spacing: 10) {
            Image(systemName: path != nil ? "folder.fill" : "folder")
                .foregroundColor(path != nil ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(OutputDirectoryStore.displayName(for: path) ?? "Save next to the original file")
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let path {
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if path != nil {
                Button(role: .destructive) {
                    if let c = category { outputStore.clearCategory(for: c) }
                    else { outputStore.clearGeneral() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("Clear")
            }
        }
        Button {
            pickOutputDir(for: category)
        } label: {
            Label(path == nil ? "Choose Folder…" : "Change Folder…", systemImage: "folder.badge.plus")
        }
    }

    /// Pick an output folder for a scope (`nil` = General).
    private func pickOutputDir(for category: FileCategory?) {
        let panel = NSOpenPanel()
        panel.title = "Choose output folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if let c = category { outputStore.setCategory(url, for: c) }
            else { outputStore.setGeneral(url) }
        }
    }

    private func addCustomPrompt() {
        let t = newCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        promptStore.addCustom(t)
        newCustomPrompt = ""
    }

    // MARK: - Scripts section

    @ViewBuilder private var scriptsBody: some View {
        ForEach(scriptsStore.scripts) { script in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField("Name", text: scriptBinding(script, \.name))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { scriptsStore.remove(script) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this script")
                }
                TextField("Command — e.g. npm run dev", text: scriptBinding(script, \.command))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                HStack(spacing: 12) {
                    Picker("", selection: scriptBinding(script, \.inTerminal)) {
                        Text("Terminal").tag(true)
                        Text("In-app").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Toggle("Run in git root", isOn: scriptBinding(script, \.useGitRoot))
                        .toggleStyle(.checkbox)
                    Spacer()
                }
            }
            .padding(.vertical, 3)
        }

        Button { scriptsStore.addBlank() } label: {
            Label("Add Script", systemImage: "plus")
        }
        .disabled(scriptsStore.scripts.count >= ScriptsStore.maxScripts)
    }

    /// Live binding to a field of `script` in the store (read current, write via `update`).
    private func scriptBinding<V>(_ script: Script,
                                  _ keyPath: WritableKeyPath<Script, V>) -> Binding<V> {
        Binding(
            get: { (scriptsStore.scripts.first { $0.id == script.id } ?? script)[keyPath: keyPath] },
            set: {
                var s = scriptsStore.scripts.first { $0.id == script.id } ?? script
                s[keyPath: keyPath] = $0
                scriptsStore.update(s)
            }
        )
    }

    /// Pick a .app bundle to add to a favorites list (`nil` = General).
    private func addTool(to category: FileCategory?) {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            toolsStore.add(appURL: url, to: category)
        }
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
