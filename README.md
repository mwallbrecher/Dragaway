# AI Drop

**Drag any file. Drop it. Get instant AI insights — without leaving your desktop.**

AI Drop is a native macOS menu-bar app that turns your physical notch into an AI interface. While dragging a file, a pill emerges from the notch. Drop the file on it, pick an action, and the result appears inline — no browser, no chat window, no context switching.

![AI Drop in action](https://github.com/mwallbrecher/MacNotchAI/releases/download/v0.7.0/AiDropPopUp.gif)

> 📄 Read the full research background on the [publication page](https://moritzwallbrecher.com/publication).

---

## What's New in v9.5

- **Prompt tabs** — the action card now has three tabs: **Suggested** (smart actions for the file), **History** (your recently typed prompts), and **Custom** (your own saved prompts). History and custom prompts are saved locally on your Mac.
- **Custom Prompts in Settings** — add, edit, and remove reusable prompts from the Settings window; they show up instantly in the Custom tab.
- **Hosted free tier** — start using AI Drop with **no API key**. A built-in Gemini-powered free tier (metered per device) lets you try every action before bringing your own key.
- **Google Gemini provider** — bring your own **Gemini 2.5 Flash** key alongside Groq, Claude, ChatGPT, and Ollama.
- **Multi-file sessions** — drop a second file onto an open card to analyse several files together, with a file gallery, per-file remove, and multi-file share.
- **Movable overlay** — drag the panel to reposition it anywhere on screen.
- **Snappier animations** — faster, tighter state transitions with reduced overbounce across the whole flow.

---

## How to Install

1. Download **AIDrop.dmg** from the [latest release](https://github.com/mwallbrecher/MacNotchAI/releases/latest)
2. Open the DMG and drag **MacNotchAI.app** into your **Applications** folder
3. Launch the app — it lives in your **menu bar** (look for the ✦ icon)
4. On first launch, pick your AI provider and paste your API key
5. Drag any file toward the top of your screen to get started

> **macOS Gatekeeper — run this before opening the DMG**
> macOS will block unsigned apps. The easiest fix is to strip the quarantine flag from the downloaded DMG *before* you open it:
> 1. Open **Terminal** (Spotlight → Terminal)
> 2. Type `xattr -cr ` (with a trailing space), then **drag the DMG file from Finder into the Terminal window** so the path fills in automatically
> 3. Press **Return**
> 4. Now open the DMG and drag the app to Applications as normal
>
> If you already moved the app to Applications and it's blocked there, repeat the same steps but drag the app instead of the DMG.

---

## The Problem It Solves

Opening a file → switching to a browser → uploading it to an AI chat → waiting → copying the result back — this workflow has been measured at **17–41 seconds of task completion overhead** per interaction (Moritz Wallbrecher at Kingston University, 2026). That overhead compounds every time you need a summary, a translation, or a key-date extraction.

AI Drop eliminates every step except the one that matters: **what do you want to do with this file?**

---

## How It Works

```
Drag any file toward the top of your screen
        ↓
A pill drops from the notch  ←  liquid spring animation
        ↓
Drop the file onto the pill
        ↓
Instant AI action chips appear (Summarise · Translate · Extract Dates · …)
        ↓
Tap a chip  →  AI response renders inline with full Markdown formatting
        ↓
Done. Or continue the conversation in Claude / ChatGPT with one tap.
```

The entire flow happens in a floating black panel — no app switching, no typing, no prompts.

---

## Features

### Core Interaction
- **Drag detection** — monitors the system drag pasteboard; pill appears the moment a file drag is detected anywhere on screen
- **Notch-origin animation** — pill emerges from the physical notch with a two-phase liquid spring (notch mouth opens → pill drops with low-damping bounce)
- **Jelly hover** — single squash-rebound wobble on cursor enter; pill stays still for precise dropping
- **Shelf behaviour** — overlay stays open after a file is placed; acts as a temporary workspace

### AI Actions
- Summarise (bullets / short)
- Extract key dates
- Translate to German
- Rephrase (formal / casual)
- Extract key points
- Analyse image *(for image files)*
- Custom free-text prompt

### Result Panel
- **Markdown rendering** — bold, italic, headings, bullet & numbered lists, fenced code blocks, dividers — no raw tokens
- **Scrollable result** with text selection
- **Follow-up action chips** based on what was just run
- **"Continue in [Provider]"** — copies full context + image to clipboard and opens the provider's native app or web UI

### File Support
- PDF, DOCX, TXT, Markdown — full text extraction
- PNG, JPEG, GIF, HEIC, WebP — image analysis via vision models
- **Drag-out** — drag the file icon back out of the overlay to drop it anywhere in Finder

### AI Providers
| Provider | Model | Cost | Notes |
|---|---|---|---|
| **Free tier** | Gemini 2.5 Flash (hosted) | Free, metered | No API key needed; try every action right away |
| **Groq** | Llama 3.1 8B | ~10,000 interactions / $5 | Cheapest; fastest |
| **Gemini** | Gemini 2.5 Flash | BYOK | Fast with strong reasoning; image support |
| **Claude** | Haiku 4.5 | ~385 interactions / $5 | Best quality, coding, long context |
| **ChatGPT** | GPT-4o mini | ~2,800 interactions / $5 | Best balance; image support |
| **Ollama** | Any local model | Unlimited, free | Runs 100% on your Mac; no API bill |

The built-in **free tier** runs through a hosted metering proxy — the host key never ships in the app. Your own API keys are stored in **macOS Keychain** — never in files, never in the app bundle.

---

## Requirements

- **macOS 13 Ventura** or later (macOS 14 Sonoma recommended)
- A Mac with a **notch** (MacBook Pro 14″ / 16″, MacBook Air M2+) — works on non-notch Macs too, pill appears at the top-center of the screen
- **Xcode 15** or later to build from source
- **Accessibility permission** — required for global drag detection (`NSEvent.addGlobalMonitorForEvents`)

---

## Installation

### Build from Source

```bash
git clone https://github.com/YOUR_USERNAME/MacNotchAI.git
cd MacNotchAI
open MacNotchAI.xcodeproj
```

1. Select the **MacNotchAI** scheme
2. Choose **My Mac** as the run destination
3. Press **⌘R** to build and run

> The app is **not sandboxed** — this is required for `NSEvent` global mouse monitoring. You will see a prompt to grant Accessibility permission on first launch; the drag detection will not work without it.

### First Launch

1. The app lives in your **menu bar** (look for the sparkle icon ✦)
2. On first launch the **provider setup sheet** opens automatically
3. Pick your provider, paste your API key, click **Get Started**
4. Drag any file toward the top of your screen

### Provider API Keys

| Provider | Where to get a key |
|---|---|
| Groq | [console.groq.com](https://console.groq.com) — free, takes ~60 seconds |
| Claude | [console.anthropic.com](https://console.anthropic.com) |
| ChatGPT | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| Ollama | [ollama.ai](https://ollama.ai) — no key needed, run `ollama pull llama3.1` |

---

## Architecture & Technical Approach

### The Stack

- **SwiftUI + AppKit hybrid** — `MenuBarExtra` for the menu bar icon, `NSPanel` (`OverlayWindow`) for the overlay, `NSHostingView` subclass (`DroppableHostingView`) for drag-and-drop reception
- **Swift Concurrency** — `async/await` for AI calls and animation sequencing; `@MainActor` throughout
- **Combine** — `@Published` stage changes flow through a Combine pipeline to resize the window
- **No third-party dependencies** — pure Apple frameworks only

### Key Engineering Decisions

**Global drag detection without Accessibility API abuse**
We monitor `NSPasteboard(name: .drag)` via `NSEvent.addGlobalMonitorForEvents(.leftMouseDragged)`. The drag pasteboard is written by the source app before the first drag event fires, so detecting a new drag is instant. A `changeCount` guard prevents stale pasteboard contents from triggering the pill on plain mouse moves.

**Drag-end detection during AppKit modal loop**
`NSEvent.addGlobalMonitorForEvents(.leftMouseUp)` is silenced during an active AppKit drag session because macOS enters `.eventTracking` runloop mode. We use a `Timer` added to `.common` mode (fires in every runloop mode) that polls the drag pasteboard — when it empties, the drag ended.

**Window frame animation crash avoidance**
`NSAnimationContext { animator().setFrame() }` drives the window through intermediate sizes at 60 fps. AppKit runs a full constraint-solving layout pass on each intermediate frame; when those sizes are inconsistent with SwiftUI's fixed-width subviews the solver cannot converge → recursive "Update Constraints in Window" → `abort()`. Solution: **instant `setFrame(_:display:)`** — the window resizes in one step, SwiftUI transitions and spring modifiers handle all visual animation.

**Jelly wobble without clipping**
`scaleEffect` inside a `clipShape` clips the overflow. The wobble `scaleEffect` is applied at the `OverlayView` root — outside all clipping — using a 288×96 transparent canvas around the 240×68 pill. `anchor: .top` ensures all vertical expansion goes downward, so the pill never overflows upward into the notch.

**Animation task ownership**
During the 0.14 s dismiss fade, both the old and new `WaitingPillView` are live simultaneously. If both own a `Task` for the jelly animation, two concurrent `withAnimation{}` blocks targeting the same `@Published` properties cause a SwiftUI invariant violation (`_crashOnException`). Solution: the jelly `Task` is stored on `OverlayViewModel` (singleton); `startJellyHover()` always cancels the previous task before creating a new one.

**File content extraction**
- PDF → `PDFKit.PDFDocument` (first 20 pages / 12k chars)
- DOCX / DOC / RTF → `NSAttributedString` via the Cocoa text system (plain-text string)
- Plain text / code → `String(contentsOf:)` with encoding auto-detection + lossy fallback
- Images → passed as `URL` directly to vision-capable models
- Oversized sources are truncated to ~12k chars and flagged in the result UI

**Privacy model**
Files are read only when the user explicitly taps an action chip. Nothing is uploaded speculatively. The only network calls are the AI API completions. API keys never leave the device except in those API calls.

---

## Project Structure

```
MacNotchAI/
├── AI/
│   ├── AIProvider.swift          # Protocol + AIProviderType enum + display metadata
│   ├── AnthropicProvider.swift   # Claude Haiku 4.5
│   ├── GroqProvider.swift        # Llama 3.1 8B
│   ├── OpenAIProvider.swift      # GPT-4o mini
│   └── OllamaProvider.swift      # Local inference
├── Core/
│   ├── DragMonitor.swift         # Global drag detection + polling timer
│   ├── FileContentExtractor.swift
│   ├── FileInspector.swift       # File type → suggested actions
│   ├── HandoffManager.swift      # "Continue in [Provider]" clipboard + URL open
│   └── KeychainManager.swift
├── Models/
│   └── OverlayViewModel.swift    # Shared state + jelly animation task
├── UI/
│   ├── OverlayView.swift         # All overlay stages (pill / chips / result)
│   ├── OverlayWindow.swift       # NSPanel subclass
│   ├── DroppableHostingView.swift # NSHostingView + NSDraggingDestination
│   ├── MarkdownText.swift        # Lightweight Markdown renderer
│   ├── MenuBarView.swift
│   ├── OnboardingView.swift
│   └── SettingsView.swift
└── AppDelegate.swift             # Lifecycle, window management, Combine wiring
```

---

## Inspired By

- Apple's **Dynamic Island** interaction philosophy — contextual, springy, alive
- My HCI research finding that **task-switching overhead** is the primary friction in AI-assisted workflows
- The idea that **the OS itself** is the best AI interface — not another app

---

## Built With

All product decisions, architecture direction, and design were made by [@mwallbrecher](https://github.com/mwallbrecher). [Claude Code](https://claude.ai/code) (Anthropic) was used as an AI pair programmer during development.

---

## License

Open Source. Feel free to clone, edit the code and contribute your ideas. Do not use my project idea & code for commecial or public purposes!
