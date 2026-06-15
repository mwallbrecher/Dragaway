import SwiftUI
import Combine

/// A user-defined shell command runnable from the chips-stage **Scripts** tab. Runs against the
/// dropped file's project — its working directory defaults to the file's folder (or, with
/// `useGitRoot`, the enclosing git repo). Commands may use `{dir}` (file's folder), `{file}`
/// (full path), `{name}` (filename), and `{root}` (git root).
struct Script: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var command: String
    /// true → open in Terminal.app (live, interactive — dev servers); false → run in the
    /// background and show captured stdout/stderr in a panel (quick commands).
    var inTerminal: Bool
    /// true → working directory is the git root of the file's folder (falls back to the folder).
    var useGitRoot: Bool

    init(id: UUID = UUID(), name: String, command: String,
         inTerminal: Bool = true, useGitRoot: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.inTerminal = inTerminal
        self.useGitRoot = useGitRoot
    }
}

/// Single source of truth for the user's scripts. Same persistence pattern as `PromptStore` /
/// `FavoriteToolsStore`: a Codable value in UserDefaults. Seeded with a starter set on first run.
@MainActor
final class ScriptsStore: ObservableObject {
    static let shared = ScriptsStore()

    static let maxScripts = 16
    private static let key = "scripts.v1"

    @Published private(set) var scripts: [Script] = []

    private init() { load() }

    // MARK: - Mutations

    func add(_ script: Script) {
        guard scripts.count < Self.maxScripts else { return }
        scripts.append(script)
        persist()
    }

    /// Append a blank script (Settings "+"): the user fills it in inline.
    @discardableResult
    func addBlank() -> Script? {
        guard scripts.count < Self.maxScripts else { return nil }
        let s = Script(name: "New script", command: "", inTerminal: true)
        scripts.append(s)
        persist()
        return s
    }

    func update(_ script: Script) {
        guard let i = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[i] = script
        persist()
    }

    func remove(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        scripts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = saved
            return
        }
        // First run — seed a recommended starter set (commonly-typed dev commands). All run in
        // the file's folder; the user edits/deletes freely. Nothing destructive.
        scripts = [
            Script(name: "git status", command: "git status", inTerminal: false),
            Script(name: "git diff", command: "git diff", inTerminal: false),
            Script(name: "git pull", command: "git pull", inTerminal: false),
            Script(name: "npm run dev", command: "npm run dev", inTerminal: true),
            Script(name: "npm install", command: "npm install", inTerminal: true),
            Script(name: "Open in VS Code", command: "code {dir}", inTerminal: false),
            Script(name: "Reveal in Finder", command: "open {dir}", inTerminal: false),
        ]
        persist()
    }
}
