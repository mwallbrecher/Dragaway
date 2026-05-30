# CLAUDE.md — AI Drop: macOS Drag-and-Drop AI Interface
> Feed this file to your AI coding agent (e.g. Claude Code) as the master brief.
> It contains every architectural decision, code pattern, and implementation detail needed to build the app from scratch.

## Workflow Orchestration
### 1. PLan Node Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately - don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity
### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One tack per subagent for focused execution
### 3. Self-Improvement Loop
- After ANY correction from the user: update tasks/lessons. md" with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project
### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check Logs, demonstrate correctness
### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause
and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes - don't over-engineer
- Challenge your own work before presenting it
### 6. Autonomous Bug Fizing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests - then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how
## Task Management
1. **Plan First**: Write plan to
tasks/todo.md" with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to 'tasks/todo.md"
6. **Capture Lessons**: Update
tasks/lessons.md" after corrections
## Core Principles
- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimat Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

---

## What You Are Building

A **native macOS menu-bar app** called **"AI Drop"** (working title).

When the user drags any file toward the top of their screen, a beautiful contextual overlay appears — no app switching, no typing, no prompts. The user drops the file, sees instant smart action labels based on the file type ("Summarise", "Extract Key Dates", "Translate"...), clicks one, and the AI result appears inline. The file never had to leave the desktop.

This interaction paradigm was validated in a peer-reviewed HCI study (Kingston University, 2025) showing **17–41 second reductions** in task completion time vs. standard ChatGPT workflows.

**The elevator pitch:** AI as an OS extension, not a chatbot.

---

## Principles — Never Violate These

- **UI layer only.** No background agents, no complex orchestration.
- **Zero friction.** The overlay must appear in under 100ms from drag detection.
- **Zero mandatory cost.** Users either use their own API key (BYOK) or local inference via Ollama. The developer pays nothing.
- **No context switching.** The result appears in the overlay, inline. No browser opens.
- **No prompt thinking required.** All actions are predefined labels. User never types.
- **Privacy-first.** Files are only sent to AI when the user explicitly clicks an action. Nothing is uploaded speculatively.

---

## Visual Design — The Exact Aesthetic From the Paper

This is not a generic macOS sheet or popover. The design is deliberate and must be followed precisely.

**The overlay is a solid pure-black panel** (`#000000` / `Color.black`) — not dark gray, not vibrancy, not `regularMaterial`. It looks like a floating black card that descends from the notch.

**Notch anchoring.** The panel is horizontally centered on the notch and its top edge sits flush with the bottom of the notch (~36px from the very top of the screen on MacBook Pro). The visual effect is that the UI "hangs" from the notch — as if it is part of the menu bar hardware extending downward. On Macs without a notch, it anchors to the top center of the screen with a small gap.

**Layout inside the panel (from the paper's Fig. 1 and Fig. 2):**

```
┌─────────────────────────────────────────┐  ← black panel, ~400px wide
│                                         │
│    [file icon]  The Emu War.pdf         │  ← file icon + name, white text
│                                         │
│    ✦ Suggested:                         │  ← small muted label
│   ╭──────────────────────────────╮      │
│   │ Summarise into Bulletpoints  │      │  ← outlined pill chip
│   ╰──────────────────────────────╯      │
│   ╭───────────────────────────╮         │
│   │ Rephrase to formal english │         │
│   ╰───────────────────────────╯         │
│   ╭───────────────────────────╮         │
│   │ Extract all key dates     │         │
│   ╰───────────────────────────╯         │
│                                         │
└─────────────────────────────────────────┘
```

After an action is clicked (Fig. 2), the panel widens into a two-column layout:
- **Left column**: file + action chips (same as above, persists for follow-up)
- **Right column**: AI result text, scrollable, white on black

**Action chips** are outlined capsules: transparent fill, `white.opacity(0.15)` border, white label text. On hover: border brightens to `white.opacity(0.4)`. No solid fill.

**Typography:** All text is white (`Color.white`). File name: 13pt medium. Chip labels: 12pt regular. Result text: 13pt regular, slightly off-white (`Color.white.opacity(0.9)`) for readability. The "✦ Suggested:" label: 11pt, `white.opacity(0.4)`.

**Corner radius:** 14pt on the panel.

**No border on the panel itself.** The black card floats against the wallpaper with only a subtle drop shadow (`black.opacity(0.5), radius: 24, y: 12`).

**Animation:** The panel scale-and-fades in from the notch — it starts at `scaleEffect(y: 0.6, anchor: .top)` and animates to full size over 0.18s with a spring curve. It feels like it *unfolds* downward from the notch.

---

## Tech Stack

| Layer | Choice | Reason |
|---|---|---|
| Language | **Swift 5.9+** | Required for system-level drag event monitoring |
| UI Framework | **SwiftUI** | Modern, declarative, handles animations well |
| Target | **macOS 13.0+ (Ventura)** | Broad compatibility, modern APIs available |
| Project type | **macOS App (non-sandboxed)** | Sandbox blocks global event monitoring |
| Distribution | **Direct download / GitHub Releases** | App Store sandbox is incompatible |
| AI providers | **Anthropic, OpenAI, Groq, Ollama** | Unified protocol, user chooses |
| PDF parsing | **PDFKit** (built-in) | No dependencies needed |
| Secret storage | **macOS Keychain** | Never store API keys in UserDefaults or plist |
| Package manager | **Swift Package Manager** | Built into Xcode |

---

## Project Structure

```
AIDrop/
├── AIDrop.xcodeproj
├── AIDrop/
│   ├── App/
│   │   ├── AIDrop App.swift          # @main entry point, sets up menu bar
│   │   └── AppDelegate.swift         # NSApplicationDelegate, global event hooks
│   ├── Core/
│   │   ├── DragMonitor.swift         # Global NSEvent drag detection
│   │   ├── FileInspector.swift       # File type → smart label mapping
│   │   ├── FileContentExtractor.swift# PDF/text/image → String for AI
│   │   └── KeychainManager.swift     # Secure API key storage
│   ├── AI/
│   │   ├── AIProvider.swift          # Protocol definition
│   │   ├── AnthropicProvider.swift   # Claude Haiku implementation
│   │   ├── OpenAIProvider.swift      # GPT-4o-mini implementation
│   │   ├── GroqProvider.swift        # Groq free tier implementation
│   │   └── OllamaProvider.swift      # Local inference implementation
│   ├── UI/
│   │   ├── OverlayWindow.swift       # NSPanel overlay, non-activating
│   │   ├── OverlayView.swift         # SwiftUI root of overlay
│   │   ├── ActionChipView.swift      # Individual smart label button
│   │   ├── ResultView.swift          # AI response display
│   │   ├── MenuBarView.swift         # Status bar icon + menu
│   │   └── SettingsView.swift        # API key config, provider selection
│   ├── Models/
│   │   ├── AIAction.swift            # Enum of all predefined actions
│   │   ├── FileContext.swift         # Dropped file metadata struct
│   │   └── AppSettings.swift        # @AppStorage settings model
│   └── Resources/
│       ├── Assets.xcassets
│       └── Info.plist
└── README.md
```

---

## Step 1 — Xcode Project Setup

1. Create a new Xcode project: **macOS → App**
2. Product Name: `AIDrop`
3. Interface: `SwiftUI`
4. Language: `Swift`
5. **Uncheck** "Include Tests" for now
6. In **Signing & Capabilities**: Remove the `App Sandbox` entitlement entirely (select it, press delete). This is mandatory.
7. Add entitlement `com.apple.security.automation.apple-events = YES` in the `.entitlements` file
8. In `Info.plist`, add:
   - `NSAccessibilityUsageDescription` → `"AI Drop needs Accessibility access to detect when you drag files."`
   - `LSUIElement` → `YES` (makes it a menu bar app, no Dock icon)
   - `LSBackgroundOnly` → `NO`

---

## Step 2 — Global Drag Monitor

This is the heart of the app. Create `Core/DragMonitor.swift`:

```swift
import AppKit
import Combine

class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingNearTop = false
    @Published var draggedFileURL: URL? = nil

    private var eventMonitor: Any?
    private var mouseUpMonitor: Any?

    // Threshold: top 12% of screen triggers overlay
    private let triggerZoneRatio: CGFloat = 0.12

    func startMonitoring() {
        // Monitor drag events globally (requires Accessibility permission)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] event in
            self?.handleDragEvent(event)
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            // Small delay so drop can register
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.handleMouseUp()
            }
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseUpMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func handleDragEvent(_ event: NSEvent) {
        guard let screen = NSScreen.main else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = screen.frame.height
        let triggerY = screenHeight * (1 - triggerZoneRatio)

        let isNearTop = mouseLocation.y > triggerY

        // Read dragged file from pasteboard
        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURL = extractFileURL(from: dragPasteboard)

        DispatchQueue.main.async {
            self.draggedFileURL = fileURL
            self.isDraggingNearTop = isNearTop && fileURL != nil
        }
    }

    private func handleMouseUp() {
        // If user dropped while near top, keep overlay open with the file
        // If not, dismiss
        if !isDraggingNearTop {
            DispatchQueue.main.async {
                self.draggedFileURL = nil
            }
        }
    }

    private func extractFileURL(from pasteboard: NSPasteboard) -> URL? {
        // Try modern URL type first
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let first = urls.first {
            return first
        }
        // Fallback for older path format
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], let first = paths.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }
}
```

---

## Step 3 — Accessibility Permission Check

In `AppDelegate.swift`, always check on launch:

```swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        DragMonitor.shared.startMonitoring()
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted {
            // Show onboarding sheet guiding user to
            // System Settings → Privacy & Security → Accessibility
            showAccessibilityOnboarding()
        }
    }

    func showAccessibilityOnboarding() {
        // Present a clear, friendly NSAlert explaining why this is needed
        let alert = NSAlert()
        alert.messageText = "One permission needed"
        alert.informativeText = "AI Drop needs Accessibility access to detect when you drag files. Open System Settings → Privacy & Security → Accessibility and enable AI Drop."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
```

---

## Step 4 — File Type → Smart Labels

Create `Core/FileInspector.swift`. This is pure logic, zero AI calls:

```swift
import Foundation
import UniformTypeIdentifiers

enum AIAction: String, CaseIterable, Identifiable {
    // Document actions
    case summariseBullets = "Summarise into Bullets"
    case summariseShort = "Summarise in 1 Sentence"
    case extractKeyDates = "Extract Key Dates"
    case extractKeyPoints = "Extract Key Points"
    case translateGerman = "Translate to German"
    case translateFrench = "Translate to French"
    case translateSpanish = "Translate to Spanish"
    case rephraseFormal = "Rephrase Formally"
    case rephraseCasual = "Rephrase Casually"

    // Code actions
    case explainCode = "Explain This Code"
    case findBugs = "Find Bugs"
    case addDocstring = "Add Documentation"
    case refactor = "Suggest Refactoring"

    // Image actions
    case describeImage = "Describe Image"
    case extractTextFromImage = "Extract Text (OCR)"
    case generateAltText = "Generate Alt Text"

    var id: String { rawValue }

    // The actual prompt sent to the AI — user never sees this
    var systemPrompt: String {
        switch self {
        case .summariseBullets:
            return "Summarise the following content into concise bullet points. Be brief and extract only the most important information."
        case .summariseShort:
            return "Summarise the following content in exactly one sentence."
        case .extractKeyDates:
            return "Extract all dates, deadlines, and time references from the following content. Present them as a clean list."
        case .extractKeyPoints:
            return "Extract the 5 most important key points from the following content as a numbered list."
        case .translateGerman:
            return "Translate the following text to German. Preserve formatting."
        case .translateFrench:
            return "Translate the following text to French. Preserve formatting."
        case .translateSpanish:
            return "Translate the following text to Spanish. Preserve formatting."
        case .rephraseFormal:
            return "Rephrase the following text in formal, professional English."
        case .rephraseCasual:
            return "Rephrase the following text in casual, friendly English."
        case .explainCode:
            return "Explain what this code does in plain English. Use bullet points for each major component."
        case .findBugs:
            return "Analyse this code and identify any bugs, errors, or potential issues. List each issue with a brief explanation."
        case .addDocstring:
            return "Add clear documentation comments/docstrings to this code. Return the full code with documentation added."
        case .refactor:
            return "Suggest concrete refactoring improvements for this code. Explain each suggestion briefly."
        case .describeImage:
            return "Describe this image in detail."
        case .extractTextFromImage:
            return "Extract and transcribe all text visible in this image."
        case .generateAltText:
            return "Write concise, descriptive alt text for this image suitable for accessibility."
        }
    }
}

struct FileInspector {
    static func suggestedActions(for url: URL) -> [AIAction] {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return [.summariseBullets, .extractKeyDates, .extractKeyPoints, .translateGerman, .rephraseFormal]
        case "txt", "md", "rtf":
            return [.summariseBullets, .summariseShort, .rephraseFormal, .rephraseCasual, .translateGerman]
        case "docx", "doc", "pages":
            return [.summariseBullets, .extractKeyPoints, .rephraseFormal, .translateGerman]
        case "swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "rb", "java", "kt", "cpp", "c", "cs":
            return [.explainCode, .findBugs, .addDocstring, .refactor]
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff":
            return [.describeImage, .extractTextFromImage, .generateAltText]
        case "csv":
            return [.summariseBullets, .extractKeyPoints]
        case "json", "xml", "yaml", "yml":
            return [.explainCode, .summariseBullets]
        default:
            return [.summariseBullets, .summariseShort, .extractKeyPoints]
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func requiresVision(_ url: URL) -> Bool {
        return isImageFile(url)
    }
}
```

---

## Step 5 — File Content Extraction

Create `Core/FileContentExtractor.swift`:

```swift
import Foundation
import PDFKit
import Vision
import AppKit

struct FileContentExtractor {

    static func extract(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractPDF(from: url)
        case "txt", "md", "rtf", "swift", "py", "js", "ts", "jsx", "tsx",
             "go", "rs", "rb", "java", "kt", "cpp", "c", "cs", "json",
             "xml", "yaml", "yml", "csv":
            return try String(contentsOf: url, encoding: .utf8)
        case "png", "jpg", "jpeg", "heic", "webp", "tiff":
            return "IMAGE_FILE" // Signal to use vision API or local OCR
        default:
            // Attempt UTF-8 read as fallback
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private static func extractPDF(from url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw ExtractionError.cannotOpenPDF
        }
        var text = ""
        let maxPages = min(pdf.pageCount, 20) // Limit to avoid huge token counts
        for i in 0..<maxPages {
            if let page = pdf.page(at: i) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.pdfHasNoText
        }
        // Truncate to ~12,000 chars to stay within typical context limits
        let truncated = String(text.prefix(12000))
        return truncated
    }

    enum ExtractionError: LocalizedError {
        case cannotOpenPDF
        case pdfHasNoText
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF: return "Could not open the PDF file."
            case .pdfHasNoText: return "This PDF appears to contain only images. Try an image action instead."
            case .unsupportedFileType: return "This file type is not yet supported."
            }
        }
    }
}
```

---

## Step 6 — AI Provider Protocol & Implementations

### `AI/AIProvider.swift` — The Protocol

```swift
import Foundation

protocol AIProvider {
    var name: String { get }
    var isAvailable: Bool { get } // Check keys are configured / Ollama is running
    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String
}

enum AIProviderType: String, CaseIterable {
    case groq = "Groq (Free)"
    case anthropic = "Anthropic (Claude)"
    case openai = "OpenAI (GPT-4o)"
    case ollama = "Ollama (Local, Free)"
}
```

### `AI/GroqProvider.swift` — Free Default

```swift
// Groq offers a free tier — ideal default for new users, no credit card needed
// Sign up at: https://console.groq.com
// Free model to use: llama-3.1-8b-instant or mixtral-8x7b-32768

import Foundation

class GroqProvider: AIProvider {
    let name = "Groq"
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1/chat/completions"
    private let model = "llama-3.1-8b-instant" // Fast, free tier

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user", "content": content]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }
}
```

### `AI/AnthropicProvider.swift`

```swift
// Claude Haiku is cheapest — ideal for BYOK users
// API key from: https://console.anthropic.com
// Pricing: ~$0.001 per typical task

import Foundation

class AnthropicProvider: AIProvider {
    let name = "Anthropic"
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-haiku-4-5-20251001"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []

        if let imageURL = imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            // Vision request with base64 image
            let base64 = imageData.base64EncodedString()
            let mimeType = mimeType(for: imageURL)
            messages.append([
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": base64]],
                    ["type": "text", "text": action.systemPrompt]
                ]
            ])
        } else {
            messages.append(["role": "user", "content": content])
        }

        let body: [String: Any] = [
            "model": model,
            "system": action.systemPrompt,
            "messages": messages,
            "max_tokens": 1024
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return response.content.first?.text ?? "No response"
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }
}

// Response models
struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    struct ContentBlock: Decodable {
        let text: String
    }
}
```

### `AI/OpenAIProvider.swift`

```swift
// GPT-4o-mini — BYOK
// API key from: https://platform.openai.com

class OpenAIProvider: AIProvider {
    let name = "OpenAI"
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent: Any = content

        // Handle image input for vision
        if let imageURL = imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            let base64 = imageData.base64EncodedString()
            let ext = imageURL.pathExtension.lowercased()
            let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
            userContent = [
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]],
                ["type": "text", "text": action.systemPrompt]
            ]
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }
}

// Shared response model (Groq uses same format as OpenAI)
struct OpenAICompatibleResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String
        }
    }
}
```

### `AI/OllamaProvider.swift`

```swift
// Completely free, runs locally on Apple Silicon
// User installs from: https://ollama.ai
// Then runs: ollama pull llama3.1 (or phi3 for faster/lighter)
// Endpoint: http://localhost:11434 (OpenAI-compatible)

class OllamaProvider: AIProvider {
    let name = "Ollama (Local)"
    private let baseURL = "http://localhost:11434/v1/chat/completions"
    private let model = "llama3.1" // or "phi3" for lighter/faster

    var isAvailable: Bool {
        // Check if Ollama is running by pinging its health endpoint
        // This check runs synchronously — acceptable for settings UI
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

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user", "content": content]
            ],
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }
}
```

---

## Step 7 — Keychain Manager

**Never store API keys in UserDefaults.** Always use Keychain:

```swift
import Security
import Foundation

class KeychainManager {
    static let shared = KeychainManager()

    func save(key: String, service: String = "com.aidrop.app") {
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary) // Remove existing first
        SecItemAdd(query as CFDictionary, nil)
    }

    func load(service: String = "com.aidrop.app") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    func delete(service: String = "com.aidrop.app") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

---

## Step 8 — The Overlay Window

The overlay must be **non-activating** — it appears but the user's current app keeps focus:

```swift
import AppKit

class OverlayWindow: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        // Window itself is transparent — the black color and corner radius
        // are handled entirely by the SwiftUI OverlayView.
        // This allows the shadow and rounded corners to render correctly.
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }  // CRITICAL: don't steal focus
    override var canBecomeMain: Bool { false }

    func showAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height

        // Center horizontally on the notch.
        // On MacBook Pro (notch models): notch bottom is ~37pt from screen top.
        // We position the panel so its top edge is flush with the notch bottom.
        // On non-notch Macs, this places it 37pt from top — still correct.
        let notchBottomY: CGFloat = 37
        let panelTopY = screenHeight - notchBottomY
        let x = (screenWidth - frame.width) / 2
        let y = panelTopY - frame.height  // panel hangs downward from notch

        setFrameOrigin(NSPoint(x: x, y: y))

        // Animate in: unfold downward from notch (scale Y from 0.6 → 1.0)
        // SwiftUI handles the spring animation — here we just fade the window in
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.animator().alphaValue = 0
        }) {
            self.orderOut(nil)
        }
    }
}
```

---

## Step 9 — SwiftUI Overlay View

`UI/OverlayView.swift` — The main UI that appears:

```swift
import SwiftUI

struct OverlayView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: AIProvider

    @State private var isProcessing = false
    @State private var result: String? = nil
    @State private var errorMessage: String? = nil
    @State private var selectedAction: AIAction? = nil
    @State private var hasAppeared = false  // drives unfold-from-notch animation

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // LEFT COLUMN — always visible: file + action chips
            VStack(alignment: .leading, spacing: 12) {
                // File indicator
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                }

                Text("✦ Suggested:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result == nil ? actions : followUpActions) { action in
                        ActionChip(title: action.rawValue, isLoading: isProcessing && selectedAction == action) {
                            runAction(action)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 220, alignment: .topLeading)

            // RIGHT COLUMN — only visible after an action is run
            if result != nil || isProcessing || errorMessage != nil {
                Divider()
                    .background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 8) {
                    if let result = result {
                        ScrollView {
                            Text(result)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    } else if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .tint(.white)
                            Text("Thinking...")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.top, 4)
                    } else if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                    }

                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(width: 260, alignment: .topLeading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // ─── CORE VISUAL: solid black panel, no blur, no material ───
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        // Animate panel width expansion when result column appears
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: result != nil || isProcessing)
        // Unfold-from-notch entrance animation
        .scaleEffect(hasAppeared ? 1.0 : 0.65, anchor: .top)
        .opacity(hasAppeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                hasAppeared = true
            }
        }
    }

    private var followUpActions: [AIAction] {
        // After a result, suggest related follow-up actions
        guard let selected = selectedAction else { return [] }
        switch selected {
        case .summariseBullets: return [.summariseShort, .translateGerman, .extractKeyPoints]
        case .extractKeyDates: return [.summariseBullets, .translateGerman]
        default: return [.summariseBullets, .rephraseFormal]
        }
    }

    private func runAction(_ action: AIAction) {
        selectedAction = action
        isProcessing = true
        result = nil
        errorMessage = nil

        Task {
            do {
                let content: String
                if FileInspector.isImageFile(fileURL) {
                    content = "Analyse the attached image."
                } else {
                    content = try await FileContentExtractor.extract(from: fileURL)
                }

                let imageURL = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let response = try await provider.complete(
                    action: action,
                    content: content,
                    imageURL: imageURL
                )
                await MainActor.run {
                    self.result = response
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
}

struct ActionChip: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(.white)
                        .frame(width: 10, height: 10)
                }
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Transparent fill — only the border defines the chip
            .background(Color.white.opacity(isHovered ? 0.08 : 0.0))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.45 : 0.22),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .disabled(isLoading)
    }
}
```

---

## Step 10 — Settings & Provider Selection

`UI/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @State private var groqKey = ""
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var ollamaAvailable = false

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("API Keys (stored securely in Keychain)") {
                if selectedProvider == AIProviderType.groq.rawValue {
                    LabeledContent("Groq API Key") {
                        SecureField("gsk_...", text: $groqKey)
                            .onSubmit { KeychainManager.shared.save(key: groqKey, service: "com.aidrop.groq") }
                    }
                    Link("Get free Groq key →", destination: URL(string: "https://console.groq.com")!)
                        .font(.caption)
                }
                // Similar for Anthropic, OpenAI...
            }

            if selectedProvider == AIProviderType.ollama.rawValue {
                Section("Ollama (Local)") {
                    HStack {
                        Circle()
                            .fill(ollamaAvailable ? .green : .red)
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
                .onAppear {
                    // Check Ollama availability
                    Task {
                        ollamaAvailable = OllamaProvider().isAvailable
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .padding()
    }
}
```

---

## Step 11 — App Entry Point

```swift
import SwiftUI

@main
struct AIDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dragMonitor = DragMonitor.shared

    var body: some Scene {
        // Menu bar icon
        MenuBarExtra("AI Drop", systemImage: "sparkles") {
            MenuBarView()
        }

        // Settings window (Cmd+,)
        Settings {
            SettingsView()
        }
    }
}
```

---

## Provider Selection Logic (On Launch)

```swift
func resolveProvider() -> AIProvider {
    let type = AIProviderType(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .groq

    switch type {
    case .groq:
        let key = KeychainManager.shared.load(service: "com.aidrop.groq") ?? ""
        return GroqProvider(apiKey: key)
    case .anthropic:
        let key = KeychainManager.shared.load(service: "com.aidrop.anthropic") ?? ""
        return AnthropicProvider(apiKey: key)
    case .openai:
        let key = KeychainManager.shared.load(service: "com.aidrop.openai") ?? ""
        return OpenAIProvider(apiKey: key)
    case .ollama:
        return OllamaProvider()
    }
}
```

---

## Distribution Checklist

When you're ready to share:

1. **Code signing** — Enroll in Apple Developer Program ($99/year). Sign with "Developer ID Application" certificate (not "Mac Development"). This allows distribution outside App Store.
2. **Notarization** — After archiving:
   ```bash
   xcrun notarytool submit AIDrop.dmg \
     --apple-id your@email.com \
     --team-id YOURTEAMID \
     --password YOUR_APP_SPECIFIC_PASSWORD \
     --wait
   xcrun stapler staple AIDrop.dmg
   ```
3. **Create DMG** — Use `create-dmg` (brew install create-dmg) for a professional installer
4. **GitHub Release** — Upload the notarized `.dmg` as a release asset
5. **Auto-update** — Later, add `Sparkle` framework for in-app update checks

---

## First-Run Onboarding Flow

1. Launch → Check Accessibility permission → If missing, show instructions
2. Check for Ollama at `localhost:11434` → If found, set as default provider silently
3. If no Ollama, show welcome screen: "Set up Groq (free) or enter your API key"
4. Groq link → `https://console.groq.com` → user gets free key in 60 seconds
5. User pastes key → saved to Keychain → done

---

## Key UX Rules for the Agent to Follow

- The overlay must **never steal keyboard focus** from the user's current app (`canBecomeKey = false`)
- The overlay dismisses when the user presses `Escape` or clicks anywhere outside it
- Show the file icon (using `NSWorkspace.shared.icon(forFile:)`) so users instantly know what they dropped
- Action chips are **pill-shaped capsules**, not rectangular buttons — matches the macOS design language
- The result text must be **selectable** (`textSelection(.enabled)`) so users can copy it
- **Never show the raw prompt** sent to the AI — only the friendly action label
- Limit file content sent to AI to ~12,000 characters to avoid unexpected costs for BYOK users
- Show a subtle loading state during API call, not a spinning wheel — a small animated dot or "Thinking..." text

---

## Approximate Build Order for the Agent

1. Xcode project setup + Info.plist config
2. `DragMonitor.swift` — get drag detection working with a simple NSLog test
3. `OverlayWindow.swift` — get a static overlay appearing at top of screen
4. `FileInspector.swift` — wire up file type detection
5. `OverlayView.swift` — render file name + action chips (no AI yet)
6. `KeychainManager.swift` + `SettingsView.swift` — API key storage
7. `GroqProvider.swift` — first working AI call
8. Wire everything together in `AppDelegate.swift`
9. Add remaining providers (Anthropic, OpenAI, Ollama)
10. `FileContentExtractor.swift` — PDF + image support
11. Onboarding flow
12. Polish animations + visual design
13. Notarization + distribution

---

*Built on research published at HCI Conference, Kingston University London, 2025.*
*Interaction paradigm: drag-and-drop AI invocation without context switching.*
