# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> The original "build-from-scratch" master brief was moved to `docs/ORIGINAL_BRIEF.md`.
> It is historical — the shipping app has diverged significantly from it. Trust the code, not the brief.

---

## What this is

**AI Drop** (target: `MacNotchAI`, bundle `com.wallbrecher.MacNotchAI`) is a non-sandboxed macOS
menu-bar app. While the user drags any file, a pill drops from the notch; dropping the file on it
reveals AI action chips; tapping one runs the action and renders the result inline. BYOK today
(Groq / Anthropic / OpenAI / Ollama). Pure Apple frameworks, no third-party packages.

## Build / run / test

```bash
# Build (CLI)
xcodebuild -project MacNotchAI.xcodeproj -scheme MacNotchAI -configuration Debug build

# Open in Xcode and run with ⌘R (destination: My Mac)
open MacNotchAI.xcodeproj
```

- **No test target exists.** There is nothing to run for unit/UI tests; "verification" means building
  and exercising the app manually (drag a file, drop, run an action).
- The app is **non-sandboxed** (`ENABLE_APP_SANDBOX = NO`) and requires **Accessibility permission**
  for its global `NSEvent` monitors (Escape key, outside-click). First launch prompts for it.
- `MACOSX_DEPLOYMENT_TARGET = 26.0`, Swift 5, hardened runtime on. The mic entitlement
  (`com.apple.security.device.audio-input`) in `MacNotchAI.entitlements` is mandatory for dictation.
- Editing `project.pbxproj` programmatically: it is **tab-indented**. String edits with spaces will
  silently fail to match (see `tasks/lessons.md` [BUILD-01]).

## Architecture — the big picture

It is an **AppKit shell hosting SwiftUI**, coordinated through one shared view model. Reading these
four files in order explains 90% of the app: `AppDelegate.swift` → `Models/OverlayViewModel.swift` →
`UI/OverlayView.swift` → `UI/DroppableHostingView.swift`.

**Stage state machine.** `OverlayViewModel.shared` (singleton, `@MainActor`) holds `stage`:
`waitingForDrop → chips → loading → result` (plus `error`). AppDelegate writes drag state into it;
`OverlayView` reads it and renders the matching stage. This is the single source of truth — almost
every behavior flows through it.

**Three event sources feed the model:**
1. `DragMonitor.shared` — global `.leftMouseDragged` / mouseDown / mouseUp monitors + a `.common`-mode
   poll timer detect when *any* file drag starts/ends anywhere on screen, publishing `isDraggingFile`.
   It does **not** transition stages; it only drives whether the Stage-1 pill is shown.
2. `DroppableHostingView` (an `NSHostingView` + `NSDraggingDestination`) receives the actual drop,
   caches the URL in `draggingEntered` (reading the pasteboard at drop time stalls), and advances the
   stage in `performDragOperation`.
3. SwiftUI buttons inside `OverlayView` (chips, prompt field, close) mutate the model directly.

**Window sizing is a Combine loop, not SwiftUI layout.** `AppDelegate.observe*` subscribes to
`$stage` / `$isChipsExpanded` / `$isFollowupsExpanded` and calls `resizeOverlay`, which computes a
fixed `CGSize` per stage and calls `OverlayWindow.animateTo`. The window resizes **instantly**
(`setFrame(display: false)`); all visible motion is SwiftUI springs/transitions inside the content.

**Providers.** `AIProvider` protocol with `complete(action:content:imageURL:)`. Groq/OpenAI share
`OpenAICompatibleResponse`; Anthropic has its own. `resolveProvider()` (bottom of `AppDelegate.swift`)
reads the `selectedProvider` UserDefault and pulls the key from Keychain. `HandoffManager` is a
separate path: it copies context to the clipboard and opens the provider's native app/web URL
("Continue in Claude/ChatGPT").

**Content extraction.** `FileContentExtractor` reads PDF (PDFKit, 20 pages / 12k chars) and UTF-8
text/code; images are passed through as a URL to vision models. `FileInspector` maps extension →
suggested `AIAction`s and flags unsupported types. Multi-file sessions concatenate extracted text
(see `buildMultiFileContent` in `OverlayView.swift`). Other notable pieces: `SpeechRecognizer` (native
on-device dictation for the prompt field), `HotkeyManager` (optional modifier gate for the pill),
`MarkdownText` (lightweight Markdown renderer for results).

## Critical invariants — do not break these

These encode hard-won crash fixes. Violating them reintroduces `EXC_BREAKPOINT` / `abort()`.

- **Never animate the window frame.** Use instant `setFrame(_:display: false)`. Animating through
  intermediate sizes re-enters AppKit's constraint solver against SwiftUI's fixed-width subviews →
  recursive "Update Constraints in Window" → `abort()`.
- **Defer every `stage` write one runloop tick** (`DispatchQueue.main.async { withAnimation { … } }`).
  Writing stage synchronously inside a layout pass triggers the same recursive-constraint abort.
- **One `withAnimation` per gesture, on the main thread.** No Tasks/sleeps for choreography. The jelly
  wobble (`startJellyHover`/`stopJellyHover`) relies on spring damping alone. Two concurrent
  `withAnimation` blocks on the same `@Published` binding = SwiftUI invariant violation → crash.
- **Don't nil `overlayWindow` in `hideOverlay()`.** The dismiss is token-guarded (`dismissToken`) so a
  new drag can recycle the fading window instead of creating a second live window (the "two windows"
  race). `isWindowDismissing` gates `resizeOverlay` during the fade.
- **`scaleEffect` is visual only.** The drag hitbox is always the full 288×96 canvas regardless of
  jelly/collapse scale. The wobble lives *outside* the `clipShape` so it can overflow the canvas.
- **Drag detection guards are load-bearing.** `handleDrag` must gate on both `lastDragChangeCount`
  *and* `pressTimeChangeCount`; never read the pasteboard in the "count unchanged" early-return branch
  (causes phantom pills on plain click-hold). See `tasks/lessons.md` DRAG-01..03.

## Conventions

- **UI scale:** every literal dimension is multiplied by `@Environment(\.uiScale)` (`UIScale` enum,
  persisted in `uiScale` UserDefault). New views must respect it.
- **Glass surfaces:** use the `.liquidGlass` / `.liquidGlassCapsule` / `.liquidGlassCircle` modifiers
  from `LiquidGlass.swift` rather than ad-hoc backgrounds. Text is white on a dark glass tint.
- **Cross-component signals** use `NotificationCenter` names defined at the bottom of `AppDelegate.swift`
  (`.hideOverlay`, `.showOnboarding`, `.showHotkeyPicker`, `.showCustomDisable`).
- **Keychain services** are `com.aidrop.{groq,anthropic,openai,ollama}` (note: *aidrop*, not the bundle
  id). API keys never go in UserDefaults.
- **UserDefaults keys in use:** `selectedProvider`, `uiScale`, `hasCompletedOnboarding`,
  `disabledUntil`, `pref.chipsExpanded`, `pref.followupsExpanded`, plus the hotkey keys.
- **Concurrency:** classes are `@MainActor`; do not bridge state *binding* writes through
  `DispatchQueue.main.async` under strict isolation — use `Task { @MainActor }` or call directly
  (lessons CONC-01). Audio-tap callbacks must capture the request locally, never `self`.

## Workflow expectations (from the project owner)

- **Plan first** for any non-trivial change (3+ steps or an architectural decision). Write the plan to
  `tasks/todo.md` with checkable items and confirm before implementing. If something goes sideways,
  stop and re-plan rather than pushing through.
- **Verify before "done."** Build it; exercise the actual interaction. UI/feature correctness is not
  proven by a successful compile.
- **Capture lessons.** After any correction, append the pattern (What was wrong → Why → Fix → Rule) to
  `tasks/lessons.md`. **Read `tasks/lessons.md` at the start of a session** — it holds the macOS
  permission, drag-detection, concurrency, and build gotchas already paid for once.
- **Simplicity / minimal blast radius.** Touch only what the task needs; prefer the elegant fix over the
  hacky one, but don't over-engineer obvious changes.

## Known gaps / sharp edges

- README advertises **DOCX** support; `FileContentExtractor` does **not** implement it (no zip/XML
  parse) — `.docx` currently falls through to a UTF-8 read and will fail. Treat that README row as
  aspirational.
- Deployment target is **macOS 26.0** — the app won't launch on anything older despite the README
  saying "macOS 13+". Lowering it requires `@available` guards (some paths are macOS-26-specific, see
  lessons MIC-05).
- **App Store note:** the Mac App Store requires the App Sandbox, which is incompatible with this app's
  global event monitoring + Accessibility model. App Store distribution is an open architectural
  question — see `tasks/todo.md`.
