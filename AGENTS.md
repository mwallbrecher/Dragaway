# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, Cursor, etc.) when working with
code in this repository. It is the single source of truth — there is no separate `CLAUDE.md`.

> The original "build-from-scratch" master brief was moved to `docs/ORIGINAL_BRIEF.md`.
> It is historical — the shipping app has diverged significantly from it. Trust the code, not the brief.

> ## ⛔ TWO-BRANCH Git workflow is MANDATORY
> Read `docs/GIT_WORKFLOW.md` **before any edit, branch operation, worktree operation, or commit**.
> This repository has exactly two canonical branches: `main` and `thesis`. `main` is the live
> product, including the app, website/product page, branding, releases, bug fixes, and ordinary
> product development. `thesis` contains only the master's-thesis contribution on top of regularly
> merged `main`. Do not create `codex/*`, `claude/*`, `feature/*`, `fix/*`, or `thesis/*` branches;
> do not create or copy worktrees; and do not move work between branches unless the user explicitly
> authorises it. Thesis sync is **`git merge main` from `thesis`, never rebase or cherry-pick**.

## Mandatory Git preflight — before touching files

Run all three commands before every task that may change the repository:

```bash
git branch --show-current
git status --short --branch
git worktree list
```

Then apply these stop rules:

- **Unexpected staged, unstaged, or untracked files belong to another person/agent until proven
  otherwise.** Do not restore, stash, stage, move, delete, or commit them.
- If the required branch is checked out in an existing worktree, use that worktree. Never create
  another branch/worktree just to relocate a change.
- Product work goes to `main`: shipped app code, product page/website, icons and branding, releases,
  bug fixes, and features users receive.
- Thesis-only research work goes to `thesis`: Computational Intent Pipeline, thesis experiments,
  study instrumentation, and thesis-specific affordances/evaluation.
- If a change benefits both streams, implement the general product part on `main`, merge `main` into
  `thesis`, then add only the research-specific delta on `thesis`.
- If branch ownership, worktree ownership, or change ownership is unclear, stop and ask the user.

The presence of a `main` file or feature in `thesis` after a merge does **not** make it thesis work.
Attribution follows the originating commit and the `Thesis-Component:` trailer, not the final file tree.

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
- The app is **non-sandboxed** (`ENABLE_APP_SANDBOX = NO`) so its global `NSEvent` *mouse*
  monitors work. As of v1.1.3 it requests **no permissions at all** — drag detection, hotkeys,
  and the radial launcher use ungated APIs, and Esc dismissal rides the window responder chain
  (`OverlayWindow.cancelOperation`). Do **not** reintroduce Accessibility-gated APIs (global
  keyboard monitors, AX tree access) without an explicit decision — see `tasks/lessons.md`.
- `MACOSX_DEPLOYMENT_TARGET = 14.0`, Swift 5, hardened runtime on. The mic entitlement
  (`com.apple.security.device.audio-input`) in `MacNotchAI.entitlements` is mandatory for dictation.
- Editing `project.pbxproj` programmatically: it is **tab-indented**. String edits with spaces will
  silently fail to match (see `tasks/lessons.md` [BUILD-01]).

## Architecture — the big picture

It is an **AppKit shell hosting SwiftUI**, coordinated through one shared view model. Reading these
four files in order explains 90% of the app: `AppDelegate.swift` → `Models/OverlayViewModel.swift` →
`UI/OverlayView.swift` → `UI/DroppableHostingView.swift`.

**Stage state machine.** `OverlayViewModel.shared` (singleton, `@MainActor`) holds `stage`:
`waitingForDrop → chips → loading → result` (plus `error`, and `fileResult` — the utility
"second result stage", see Pillar 2). AppDelegate writes drag state into it; `OverlayView` reads it
and renders the matching stage. This is the single source of truth — almost every behavior flows
through it. The root `OverlayView.body` splits on `.waitingForDrop` (bare pill) vs `default:` (glass
card); an **inner** switch then routes the card's content: `.chips`→ChipsColumnView,
`.loading/.result/.error`→TwoColumnView, `.fileResult`→FileResultView.

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
text/code; images are passed through as a URL to vision models. `FileInspector.baseActions(for:)` maps
extension → suggested `AIAction`s and flags unsupported types; `suggestedActions(for:)` then makes that
list **content-aware** via `reorder(_:using:)` driven by `Core/FileSignals.swift` — a **bounded,
synchronous, local** peek (first ~16 KB of text/code, or a PDF's first page) yielding `{language,
hasManyDates, isShort, isLong, hasCodeFences, isMonetary}`. Heuristics-only (no LLM/tokens/network):
non-English prose leads with "Translate to English" (drops the to-<source> target), date/money-heavy
docs bubble Extract Key Dates/Points, short text drops "Summarise into Bullets", long text leads with
summarise, a ``` fence in prose adds "Explain This Code". Result deduped, capped ≤ 6, never empty; any
peek failure falls back to `baseActions`. The peek is memoised by path+mtime (`peekCache`) because the
result-stage Suggested rail recomputes it inside a SwiftUI `ForEach`. Multi-file sessions concatenate
extracted text (see `buildMultiFileContent` in `OverlayView.swift`). Other notable pieces:
`SpeechRecognizer` (native
on-device dictation for the prompt field), `HotkeyManager` (optional modifier gate for the pill),
`MarkdownText` (lightweight Markdown renderer for results).

**Favorite-tools launch row (Pillar 1).** `FavoriteToolsStore.shared` (Codable array in UserDefaults,
capped 9) holds the user's favorite apps. `UI/ToolRow.swift` renders a numbered "Open in" row in **both**
the `.chips` stage and the `.result` stage (bottom-left of the result left column) — the **same**
`ToolRow` view, so styling is identical. Clicking a tile — or pressing `Option+1…9` — calls
`FavoriteToolsStore.launch(_:with:)` (`NSWorkspace.open(_:withApplicationAt:…)`) on **all** staged files
(`OverlayViewModel.sessionFileURLs`). The launched app is activated but the notch session is left
**open** (user dismisses manually). A trailing dashed **"+"** tile (`AddToolButton`) posts
`.showFavoriteTools` → `showSettings(section: .favoriteTools)` to add an app. The hotkeys are a local
`NSEvent` keyDown monitor (`AppDelegate.startToolHotkeys`/`handleToolHotkey`, run via
`MainActor.assumeIsolated`) — installed when `stage` becomes `.chips` **or** `.result`, removed
otherwise; it swallows only a matched bare-`Option+N` and passes every other key through to the prompt
field. Configured in the "Favorite Tools" section of `SettingsView` (`NSOpenPanel`, `.application`).
Chips-window height adds `ChipsLayout.toolRowHeight`/`.toolHintHeight` in `AppDelegate.sizeForStage`; in
the result stage the row sits below a `Spacer` and consumes existing slack (no height-math change).

**File utilities + the utility result stage (Pillar 2).** `Core/FileTools.swift` (`FileTools` engine +
`FileTool` catalogue) runs pure-Apple-framework file ops; every producer writes a deduped sibling and
returns the new `URL`. **Output directory (configurable):** producers always write the sibling, then
`FileToolActions.runFile`/`performAsync` **relocate** it via `relocate(_:original:)` →
`try? FileTools.move(output, to: dir)` before presenting. `effectiveOutputDir(for:)` resolves
`OverlayViewModel.sessionOutputOverride` (`.inherit`/`.sibling`/`.folder`, tri-state, reset on
`reset()`) → else `OutputDirectoryStore.shared.resolved(for: category)` → else nil = sibling (default).
`Models/OutputDirectoryStore.swift` mirrors `FavoriteToolsStore` (General path + per-`FileCategory`
path + `useGeneral`, JSON in UserDefaults `outputDirectory.v1`). UI: the Utilities tab's `outputDirRow`
(folder name + × reset + Change… `NSOpenPanel` + two "Remember" checkboxes persisting to General /
category + a gear → `.showOutputDirectory`), and a Settings **Output Directory** section
(`SettingsSection.outputDirectory`, same shape as Favorite Tools). `UI/FileToolsMenu.swift`
(`FileToolActions`) dispatches them: file-PRODUCING ops
go through `runFile`/`presentFileResult` (reveal the output in Finder, then set
`stage = .fileResult(original:output:tool:)` — deferred one tick + `withAnimation`); async media ops do
the same after their export; **rename / move / Count / SHA-256 are unchanged** (in-place remap, or an
NSAlert with Copy). `Stage.fileResult` renders **`FileResultView`** (single column, 500×430 in
`sizeForStage`): a past-tense `FileTool.resultTitle` header, then the output and original each as an
`ExpandedFilePill` (icon + name + size, expanded downward into a kind/dimensions/pages/duration/items
detail grid), with a size-delta capsule on the output ("73% smaller") and Reveal-in-Finder / Quick Look /
← back (`vm.returnToChips()`) actions. `returnToChips()` stashes the `.fileResult` into `cachedResult`
(mirroring the AI path's `navigateBackToChips`), so the chips header's **→ button** (`vm.stage.tag == 1
&& cachedResult != nil`) restores the utility result without re-running the tool — same control the AI
reply uses. Facts come from **`Core/FileFacts.swift`** — a `nonisolated`, `Sendable`
`FileFacts.gather(_:) async` that probes off-main (CGImageSource dims, PDFKit pages,
`AVURLAsset.load(.duration)`, recursive folder size/count) and is awaited from a `.task`. Both
`remapSessionURL` switches (stage + `cachedResult`) carry the `.fileResult` case so a rename remaps both URLs.

**Clipboard history.** `Models/ClipboardHistoryStore.shared` (`@MainActor ObservableObject`) polls
`NSPasteboard.general.changeCount` on a 0.5 s `.common`-mode `Timer` and records each new copy
(text / image / file URLs), newest-first, capped at **20**. Sensitive/transient pasteboard types
(`org.nspasteboard.ConcealedType`, `com.apple.is-sensitive`, `org.nspasteboard.TransientType`,
`org.nspasteboard.AutoGeneratedType` — password managers set these) are **never** captured. Items dedupe
by a relaunch-stable `signature` (`T:`/`F:`/`I:…`); our own copy-backs are skipped via `ignoreChangeCount`.
Persists as `clipboard_history.json` + sibling PNGs in `clip_images/` under App Support. Surfaced **two**
ways: the menu-bar **"Clipboard History"** submenu (last 20, `AppDelegate.buildClipboardSubmenu`; row
copies back, ⌥-alt removes; plus a "Track Clipboard" checkbox) and the **⌃⌘V picker popup**
(`UI/ClipboardPickerView.swift`, last 10). Picking an item only **copies it back** to the pasteboard
(`copyToPasteboard` — the user then presses ⌘V; we never synthesise keystrokes). The picker is a
borderless `ClipboardPickerPanel` (`canBecomeKey`, `.floating`, liquid-glass) driven by the
`ClipboardPicker.shared` controller (mirrors `QuickLookController`): a local keyDown monitor claims the
digit keys (1–9, 0 → 10th) + Esc while it's key, a global click monitor + `windowDidResignKey` dismiss.
The system-wide **⌃⌘V** is a Carbon `RegisterEventHotKey` (`Core/GlobalHotkey.swift`) — it **consumes**
the keystroke (no leak to the frontmost app) and needs **no** Accessibility. Capture + hotkey are armed
together at launch and flipped together by the "Track Clipboard" toggle, gated on `clipboardHistoryEnabled`.

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
  `disabledUntil`, `pref.chipsExpanded`, `pref.followupsExpanded`, `clipboardHistoryEnabled`, plus the
  hotkey keys.
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
- Deployment target is **macOS 14.0** (lowered from 26.0, 2026-06-01). The code compiles clean at 14
  with no `@available` guards needed (the "Liquid Glass" look is custom `NSVisualEffectView`, not the
  26-only `glassEffect` API). The **mic permission path is OS-branched** (`SpeechRecognizer`,
  `if #available(macOS 26)`): 26 → `AVCaptureDevice`, 14/15 → `AVAudioApplication` (lessons MIC-04/05/11).
  ⚠️ The 14/15 mic branch is **runtime-UNVERIFIED** — built from the documented lessons, but no 14/15
  test machine was available. The macOS 26 path is unchanged and verified.
- **App Store note:** the Mac App Store requires the App Sandbox, which is incompatible with this app's
  global event monitoring + Accessibility model. App Store distribution is an open architectural
  question — see `tasks/todo.md`.
