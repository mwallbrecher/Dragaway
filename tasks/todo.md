# AI Drop — App Store Roadmap & Review

## Website — Pricing page (DONE 2026-07-08)

- [x] Inspect existing static subpage structure and shared styles.
- [x] Add a Pricing page comparing Free and Pro.
- [x] Link Pricing from the existing website navigation/footer.
- [x] Verify syntax and browser rendering.

---

## Website — active page background gradient (DONE 2026-07-08)

- [x] Commit the current website state before touching the background work.
- [x] Add a page-wide black alpha gradient layer with multiple organic shapes over the Monterey wallpaper.
- [x] Tie the background layer to scroll with subtle parallax while keeping content and app UI fixed.
- [x] Replace the too-focused center swirl with full-page uneven black-alpha darkening patches.
- [x] Make the page-wide darkening more visible and add a very light wallpaper blur.
- [x] Split the background effect into separate patch layers so alpha and blur differences are visibly uneven.
- [x] Increase the base darkening and make patch movement/opacity respond more noticeably to scroll.
- [x] Darken the shared background further and make the scroll-driven ambient movement more obvious.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Website — Helvetica copy font test (DONE 2026-07-06)

- [x] Add a Helvetica/Helvetica Neue website copy font stack for the temporary test.
- [x] Keep app demo text and UI controls on the existing SF/System stack.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Website — hero brand cleanup (DONE 2026-07-06)

- [x] Add the dragaway logo above the Dragaway eyebrow in the hero copy stack.
- [x] Match the hero logo size/style to the footer brand mark.
- [x] Remove the "Speeding up..." claim row below the headline.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Website — replay tab push timing (DONE 2026-07-06)

- [x] Delay the automatic file-type tab change until after the open demo window has faded out.
- [x] Keep the replay fade, empty-screen hold, file pop, and tool-pop choreography timings unchanged.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Website — initial tool/text pop choreography (DONE 2026-07-06)

- [x] Disable the file-type toggle progress lighting again while keeping the auto replay tab push.
- [x] Create a website Git checkpoint after the progress-lighting removal.
- [x] Add the existing tool shell pop-in language to the initial boot animation without retiming the
      existing pill/drop/fill beats.
- [x] Replace the first-run `Your daily tools` write-in with quick per-letter pops coupled to the tool
      pop order/timing.
- [x] Make the initial pop visibly readable by adding a short pre-pop hold and slightly longer first-boot
      pop timing.
- [x] Refactor the first boot to use the same prelude handoff as the loop so radius and acceleration
      timelines stay unchanged.
- [x] Keep the outer tool rotation alive for the whole pop duration so there is no hitch when the last
      tool finishes appearing.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Feature — Smarter suggestions v2 (IMPLEMENTED 2026-07-03 — build green; owner test pending)

- Catalog grown +18 actions (36 total): CSV (Summarise Table, Describe the Data, Show
  Trends, Find Outliers, Suggest Charts, Make a Report), Image (Analyse UI, Design
  Reference, Rebuild as HTML/CSS), Text (Draft Email Reply, Extract To-Dos, Extract
  Names & Contacts, Explain Simply, Proofread & Fix), Notes (5-Slide Outline, LinkedIn
  Post, Turn into a Brief), Code (Write Tests).
- Selection stays capped at 6; per-type pools are candidate lists, `reorder` promotes.
- `ActionFrecency` (Core): local per-category learned frecency (decayed counts in
  UserDefaults, no telemetry) — user's top-2 lead. Recorded in sendTurn.
- `FileSignals` extended: CSV header/numeric-column detection, email/todo/notes flavour;
  `reorder` gains filename-keyword rules (invoice/design/resume/notes) + primary URL.
- Honest scope: "Suggest Charts" recommends (no rendering — no code exec); Describe-Data
  row counts reflect the bounded peek on huge files; vision actions need a vision model.

## v1.2 slice — drag anything + streaming + history search (IMPLEMENTED 2026-07-03 — build green; owner test pending)

Approved scope, build order:
1. **Sparkle build-gate** — wrap UpdaterController in `#if canImport(Sparkle)` (+ no-op stub)
   so the project builds before the package is added in Xcode.
2. **Drag anything** — pill wakes for TEXT / WEB-URL / IMAGE drags, not just files.
   `DropMaterializer` (new, Core) captures the payload at draggingEntered and writes it to
   Application Support/Drops on drop (.txt / .png, pruned to newest 50) → the whole
   existing file pipeline (chips, AI, utilities, history) just works. Radial stays
   file-only (apps open files, not selections). Known trade-off: in-app text drags also
   show the pill — the drag hotkey gate is the opt-out.
   Backlog: fetch+strip web pages (URL drop currently analyses the URL string), file
   promises (Photos/Mail).
3. **Streaming responses** — `AIProvider.replyStream(…, onDelta:)` with a non-streaming
   default; real SSE for Groq+OpenAI (shared helper), Anthropic, Gemini, Ollama
   (hosted Worker stays non-streaming for now). First delta flips loading→result and
   appends a placeholder assistant bubble whose text grows in place (stable ChatMessage
   id so SwiftUI doesn't recreate the row). Window resizes once at completion.
4. **Session-history search** — search window (clipboard-picker pattern) filtering by
   filename + prompts + result text; row click reopens via the existing restore path.
   `maxSessions` 10 → 25. Menu: "Search Sessions…" atop Recent Sessions.

---

> Plan written 2026-05-29. Status of the codebase: feature-complete BYOK app, distributed via
> Developer-ID DMG. Goal: ship on the App Store with a metered free → paid model.
> **Nothing below is implemented yet — this is the plan to confirm before building.**

---

## Website — stat banner boot choreography (DONE 2026-07-05)

- [x] Create a dedicated Git repo in `website/` and commit the current website baseline before animation changes.
- [x] Add the speed stat banner to the hero boot choreography after the pill expands.
- [x] Animate the banner background in first, then reveal each metric sequentially.
- [x] Reuse the hero 8.8x count-up visual language for the banner numbers without coupling it to the hero copy.
- [x] Cache-bust touched website assets and verify syntax/browser state.

---

## Website — speed stat banner rewrite (DONE 2026-07-04)

- [x] Replace the visible study disclaimer paragraph with a compact three-column metric banner.
- [x] Keep the final speedup factor unchanged and add placeholder time/cost metrics.
- [x] Add hover information to each number and a bottom "Hover the numbers for information. Learn more" link row.
- [x] Update saved-time metric to 37.5s and calculate daily savings as $10.42 at 20 interactions/day and $50/hour.
- [x] Cache-bust touched assets and verify syntax/browser load.

---

## Website — cleaner hero loop transition (DONE 2026-07-03)

- [x] Replace abrupt idle replay restart with a short replay prelude.
- [x] Fade the expanded window out before resetting the demo.
- [x] Show cursor/file briefly, fade tools in, then start the existing choreography unchanged.
- [x] Add a 600 ms empty pause after fadeout, then pop cursor/file before the tools fade in.
- [x] Delay the tool reveal slightly more and pop tools in one-by-one in a fast random order.
- [x] Keep the tools rotating while the replay pop-in sequence reveals them.
- [x] Smooth the handoff from replay pop-in to the normal orbit loop by separating outer rotation from inner icon pop.
- [x] Keep the replay pop-in radius pinned to the normal choreography's starting radius so the loop handoff does not jump.
- [x] Move the glass tile styling into an inner shell so the full tool tile pops in, not just the logo.
- [x] Cache-bust touched assets and verify syntax/browser load.

---

## Website — orbit radius peak timing (DONE 2026-07-03)

- [x] Move the orbit radius peak 80 ms earlier without changing the shared drop/morph/fill timeline.
- [x] Cache-bust the touched website assets.
- [x] Verify syntax and browser load.

---

## Website — Learn more + Contribute pages (DONE 2026-07-03)

- [x] Add a `learn-more.html` subpage covering pricing, data processing, AI/provider behavior, permissions, clipboard privacy, and beta/distribution details.
- [x] Add a `contribute.html` subpage with a simple name + message form that opens an addressed email draft.
- [x] Extend shared website styling for static subpages, FAQ rows, and the contribution form without disturbing the hero animation.
- [x] Link both pages from the main nav/footer and keep cache-busting current.
- [x] Verify HTML structure, browser load, form `mailto:` output, and console errors.

---

## Website — dragaway rebrand (DONE 2026-07-02)

- [x] Replace visible "AI Drop" branding with "dragaway".
- [x] Rename the first feature tab to "Drop" while keeping the demo behavior intact.
- [x] Use `assets/Dragaway.png` for the website icon/brand mark.
- [x] Switch visible brand logos to `assets/Dragaway-white.png` with no corner radius.
- [x] Verify the page in the browser.

---

## Website — hero text choreo polish (DONE 2026-07-03)

- [x] Rework `Your daily tools` replay activation to use the same single shimmer behavior as `one drag away`.
- [x] Add a very subtle body-text shimmer when the supporting copy activates.
- [x] Verify in browser.

---

## Website — headline lead evenness fix (DONE 2026-07-03)

- [x] Remove the horizontal white gradient hotspot from `Your daily tools`.
- [x] Remove the persistent lead-line glow/cutout after animation settles.
- [x] Verify in browser.

---

## Website — remove hero background cutout (DONE 2026-07-03)

- [x] Disable the demo backdrop/scrim layers that create the vertical cutout under hero copy.
- [x] Verify in browser that no backdrop/scrim layer is rendered over the copy.

---

## Website — disable text loop choreo (DONE 2026-07-03)

- [x] Keep the first hero text intro intact.
- [x] Disable the replay dim/re-light choreography without removing the code path.
- [x] Verify in browser.

---

## Website — lead create fade and body flicker removal (DONE 2026-07-03)

- [x] Remove the body text flicker/glimmer.
- [x] Replace `Your daily tools` create animation with a simple immediate fade-in.
- [x] Tune the lead fade to start at 50 ms with a longer duration.
- [x] Replace the lead fade with a typewriter-style write-in reveal.
- [x] Verify in browser.

---

## Website — pre-ramp orbit radius polish (DONE 2026-07-03)

- [x] Make the tool orbit radius slightly larger before the spin ramp-up.
- [x] Ease it back into the existing radius during the ramp so the fly-in choreography stays intact.
- [x] Change the radius change into a visible animation: 0.9 → 1.2 → 1.0.
- [x] Revert the mistaken expand beat delay so the pill/card choreography keeps its previous timing.
- [x] Hold the radius at 0.9 for the first 80 ms, then grow to 1.2 before returning to 1.0.
- [x] Verify in browser.

---

## Feature — Scripts tab (5th chips tab) (IMPLEMENTED 2026-06-06 — build green; owner test pending)

> Owner: a 5th "Scripts" tab where users save shell commands (npm run dev, git diff, …) and run
> them against the dropped file's project — skip Terminal + cd + typing. Forks (answered):
> run mode = per-script **Terminal vs in-app captured**; cwd = **dropped file's folder**, with a
> per-script **"Run in git root"** toggle. Non-sandboxed → `Process`/AppleScript allowed.
> SECURITY: user-authored only, explicit run, no destructive seeds.

- [ ] `Models/ScriptsStore.swift` — `Script {id,name,command,inTerminal,useGitRoot}` + store.
- [ ] `Core/ScriptRunner.swift` — cwd resolve + `{file}/{dir}/{name}/{root}` expand; Terminal (osascript)
      or captured (`/bin/zsh -lc` + Pipe → NSAlert). git-root = walk up for `.git`.
- [ ] `ChipsTab.scripts` + `ChipsLayout.rows`; OverlayView tab + content; Settings section; AppDelegate notif.

---

## Feature — Output Directory (IMPLEMENTED 2026-06-05 — build green; owner test pending)

> Resolved fork: **session + persist tiers** + an **×** in the utilities row that resets to "same
> folder" FOR THE SESSION (modeled as `SessionOutput.sibling`, which beats even a persisted default).
> Session override is a tri-state on `OverlayViewModel`: `.inherit` (follow store) / `.sibling` (× →
> same folder) / `.folder(URL)` (picked this session). Cleared to `.inherit` in `reset()`.


> 2026-06-05. Owner: "In the utility tab, add the option to change the output folder with two
> checkboxes (Remember my choice / Remember my choice for this filetype) + a button to Settings. In
> Settings add an 'Output Directory' section, same logic as Favorite Tools: General + per-filetype,
> each filetype with a 'Use General File Directory' checkbox."

**Today:** every file-PRODUCING utility writes the new file NEXT TO the original
(`url.deletingLastPathComponent()` in each `FileTools`/`MediaTools` producer). No way to redirect.

**Checkbox semantics (my reading — confirm):** picking a folder always sets it as the **session**
output dir (used for the rest of this session). The checkboxes additionally PERSIST it:
- *Remember my choice* → save as the **General** output dir (`OutputDirectoryStore.general`).
- *Remember my choice for this filetype* → save as this file's **category** dir + set its
  `useGeneral = false`. Neither checked → session-only.

**Architecture — redirect by RELOCATING the output (minimal blast radius).** Producers stay
unchanged; the dispatch wrappers move the finished file into the chosen dir.

- [x] **`Models/OutputDirectoryStore.swift` (NEW)** — mirror `FavoriteToolsStore`. `@MainActor`
      `ObservableObject` singleton. `generalPath: String?` + `categories: [FileCategory: CategoryOutput]`
      where `CategoryOutput { useGeneral = true; path: String? }`. `resolved(for: FileCategory) -> URL?`
      (category path if set & !useGeneral, else general, else nil). Setters: `setGeneral/clearGeneral`,
      `setCategory/clearCategory`, `setUseGeneral`. Persist JSON in UserDefaults `outputDirectory.v1`.
      Skip dirs that no longer exist (best-effort).
- [x] **`OverlayViewModel`: `sessionOutputOverride: SessionOutput`** (tri-state — see header) —
      transient per-session override. Cleared to `.inherit` on `reset()`. Resolution (in
      `FileToolActions.effectiveOutputDir`): `.sibling`→nil · `.folder(u)`→u · `.inherit`→
      `OutputDirectoryStore.resolved(for: category(original))` → nil = original's folder (unchanged).
- [x] **`FileToolActions` (`UI/FileToolsMenu.swift`): relocate after production.** Add
      `relocate(_ output: URL, original: URL) -> URL`: resolve dir; if non-nil & different, `try?
      FileTools.move(output, to: dir)` (works for files AND the folder outputs of split/pdf→images);
      best-effort (return original output on failure). Call it in `runFile` and in `performAsync`
      before `presentFileResult`. **Producers + `FileTools`/`MediaTools` untouched.**
- [x] **Utilities tab UI (`OverlayView.swift` `.utilities` case)** — above the tool list: an
      "Output → <folder | Same as file>" row + **Change…** (`NSOpenPanel`, `canChooseDirectories`)
      → sets `sessionOutputDir` and persists per the two `@State` checkboxes; the two checkboxes; and a
      small **gear** button → posts `.showOutputDirectory`. Respect `@Environment(\.uiScale)` +
      `.liquidGlass`. Add its height to `ChipsLayout.rows(.utilities)` (≈ +2 rows) so the card sizes right.
- [x] **Settings (`UI/SettingsView.swift`)** — `SettingsSection.outputDirectory` (title "Output
      Directory"); an `outputDirectoryBody` mirroring `favoriteToolsBody`: a **General** folder picker +
      one row per `FileCategory` with a **Use General File Directory** toggle and (when off) its own
      folder picker. Add height in `settingsSize(for:)`.
- [x] **`AppDelegate`** — `Notification.Name.showOutputDirectory` + `handleShowOutputDirectory()` →
      `showSettings(section: .outputDirectory)` + register observer (mirror `.showFavoriteTools`).
      Optional: a menu item for parity.
- [x] **Build green** (`xcodebuild … Debug build`).
- [ ] **Manual test (OWNER):** run a producing tool with no dir set → writes next to original (as
      today). Set a session dir → output lands there. "Remember my choice" → persists as General,
      survives relaunch. "…for this filetype" → only that category redirects; others still General/sibling.
      Settings General + per-category + Use-General toggles behave like Favorite Tools.
- [ ] **Lessons:** capture if the post-production move has a gotcha (cross-volume, folder outputs).

---

## Feature — Smart suggested prompts, heuristics only (IMPLEMENTED 2026-06-04 — build green; owner test pending)

> 2026-06-04. Owner: "how can we make the AI suggested prompts smart?" Fork resolved
> (AskUserQuestion): **Heuristics only** — reorder/filter the existing fixed `AIAction` list from
> LOCAL text signals. Zero latency, zero tokens, no provider. No LLM call. Stay (mostly) within the
> existing action vocabulary.

**Today:** `FileInspector.suggestedActions(for:)` is a pure `switch` on file *extension* → fixed
`[AIAction]`, baked synchronously into `Stage.chips(url:actions:)` at ~9 call sites. Content is NOT
extracted at drop time (that's lazy, on action-run). So a PDF always shows the same 5 chips.

**Approach — bounded synchronous content peek inside `FileInspector` (minimal blast radius).** Keep
the signature and all 9 call sites unchanged; make the body content-aware via a cheap, capped peek.

- [x] **`Core/FileSignals.swift` (NEW).** `nonisolated` `FileSignals.peek(_ url:) -> FileSignals`.
      Reads a CAPPED prefix only: text/code → first ~16 KB via `FileHandle` (instant); PDF → PDFKit
      first-page `.string`; else nothing. Returns struct: `dominantLanguage` (NaturalLanguage
      `NLLanguageRecognizer`), `hasManyDates`, `isShort`, `isLong`, `hasCodeFences`, `isMonetary`.
      Frameworks: Foundation + NaturalLanguage + PDFKit. Every read `try?`-guarded → empty signals on
      failure.
- [x] **`AIAction`: add `.translateEnglish` = "Translate to English"** (icon `globe`, systemPrompt).
      The one genuinely-missing case — needed so a non-English doc can suggest translating *to* English.
- [x] **`FileInspector.reorder(_ base:using signals:) -> [AIAction]`.** Stable reorder + light filter
      of the extension-based list. Rules:
      - non-English dominant → prepend `.translateEnglish`; drop the to-X target equal to the source.
      - `hasManyDates` or `isMonetary` → move `.extractKeyDates` (+ `.extractKeyPoints`) to front.
      - `isShort` → drop `.summariseBullets`; prefer rephrase/translate.
      - `isLong` → ensure `.summariseShort` + `.summariseBullets` lead.
      - `hasCodeFences` in a prose file (.md/.txt) → append `.explainCode`.
      - Always dedupe, never empty, cap ≤ 6.
- [x] **Wire it in.** `suggestedActions(for:)` = base map → `peek` (bounded, single URL) → `reorder`.
      `suggestedActions(forAll:)` = union extensions as today → `reorder` using the FIRST url's peek
      only (bounds multi-file cost to one peek). All `try?`-guarded → fall back to the static list.
- [x] **No stage-machine / `@Published` / async changes.** Call sites stay synchronous.
- [x] **Build green** (`xcodebuild … Debug build`).
- [ ] **Manual test (OWNER):** German PDF → "Translate to English" leads; invoice PDF → dates/points lead;
      1-line `.txt` → no "Summarise into Bullets"; long PDF → summarise leads; `.md` with a ``` fence
      → "Explain This Code" appears. Confirm no perceptible hitch on drop (peek is byte-capped).
- [x] **Lessons:** capture only if NL/PDFKit on the main thread during the deferred stage write hitches.

---

## Feature — Clipboard History (IMPLEMENTED 2026-06-04 — build green; owner test pending)

> 2026-06-04. Owner: "add a clipboard history. Users should be able to paste the past 10 items with a
> hotkey of your suggestion and see a history of 20 in a submenu saying Clipboard History."
> Forks resolved (AskUserQuestion): **capture = text + images + files**; **pick = copy-to-clipboard
> only** (no ⌘V synthesis — user presses ⌘V themselves); **persist across restarts** (App Support),
> sensitive/concealed pasteboard items ALWAYS excluded.

**Suggested hotkey: `⌃⌘V` (Control+Command+V).** Not bound by macOS or common apps, mnemonic (V),
easy chord. Registered via Carbon `RegisterEventHotKey` so it's system-wide AND consumes the keystroke
(no leak into the frontmost app). Carbon hotkeys don't even need Accessibility.

**Store — `Models/ClipboardHistoryStore.swift` (NEW).** `@MainActor ObservableObject` singleton,
mirrors `SessionHistoryStore`. Polls `NSPasteboard.general.changeCount` on a 0.5 s `Timer` in `.common`
runloop mode (like DragMonitor, so it fires during drags/event-tracking). On change:
- **Skip sensitive types**: `org.nspasteboard.ConcealedType`, `com.apple.is-sensitive`,
  `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType` (password managers set these).
- **Kind priority**: file URLs → `.files`; else image (`public.png`/`tiff`/NSImage) → `.image`; else
  string → `.text`.
- **Dedupe / move-to-front**; cap **20**; ignore our OWN writes via an `ignoreChangeCount` token.
- `ClipItem: Codable, Identifiable { id; kind; text?; filePaths?; imageFile?; date; preview }`.
  Images persisted as PNG in `clip_images/<uuid>.png` under App Support; metadata in
  `clipboard_history.json`. Trim/clear delete orphan image files.
- `copyToPasteboard(_:)` writes the item back (string / `[NSURL]` / image data) and arms the ignore token.
- Gated by a `clipboardHistoryEnabled` UserDefault (default true) → menu checkbox "Track Clipboard".

**Global hotkey — `Core/GlobalHotkey.swift` (NEW).** Thin Carbon wrapper: `register(onFire:)` /
`unregister()`, static C trampoline → shared instance → main-thread closure (no `self` capture in the
callback). Registers `⌃⌘V`.

**Picker popup — `UI/ClipboardPickerView.swift` (NEW) + a borderless `ClipboardPickerPanel`.**
`ClipboardPicker.shared` controller (mirrors `QuickLookController`): show/hide + monitors. Panel is
`canBecomeKey`, `.floating`, liquid-glass styled, centered on the active screen. Lists the **10** newest
items, each row = number badge (1–9, 0 for the 10th) + kind icon/thumbnail + 1-line preview + relative
time. **Click or number key** → `copyToPasteboard(item)` + dismiss; **Esc** / outside-click / resignKey
dismiss (local keyDown monitor while key + global outside-click monitor — same pattern as the tool
hotkeys / dismiss monitors). Empty state: "No clipboard history yet." Copy-only, so NO focus restore /
keystroke synthesis needed — the prior app refocuses on dismiss and the user hits ⌘V.

**Menu — `AppDelegate.buildClipboardSubmenu()`.** New "Clipboard History" item (next to "Recent
Sessions") → submenu of the **20** newest: 2-line attributed rows (preview over relative time) + a
32-pt kind icon/thumbnail; click → `menuCopyClipItem(_:)` copies to clipboard; ⌥-alternate removes one;
separator → "Clear Clipboard History"; disabled info line "⌃⌘V to open the clipboard picker". Empty →
"No clipboard history". Add a "Track Clipboard" checkbox item to toggle capture.

**Wiring — `AppDelegate`.** `applicationDidFinishLaunching`: `ClipboardHistoryStore.shared.startMonitoring()`
(if enabled) + register the global hotkey → on fire `ClipboardPicker.shared.toggle()`. Honor the
enable/disable toggle (start/stop polling + register/unregister hotkey).

**Invariants to respect:** poll timer in `.common` mode; no `self` capture in the Carbon callback;
exclude sensitive types (passwords); dedupe self-writes via the ignore token; delete orphan image files
on trim/clear; picker panel must become key to read number keys (accessory app → `NSApp.activate` then
`makeKeyAndOrderFront`).

**Files:** `Models/ClipboardHistoryStore.swift` (NEW), `Core/GlobalHotkey.swift` (NEW),
`UI/ClipboardPickerView.swift` (NEW, incl. panel + controller), `AppDelegate.swift` (launch wiring +
submenu + actions + notification/hotkey), plus docs.

**Tasks**
- [x] `ClipboardHistoryStore`: poll changeCount, kind detection, sensitive-type skip, dedupe, cap 20,
      image PNG storage, persistence, `copyToPasteboard`, ignore-token, enable toggle, clear/remove.
- [x] `Core/GlobalHotkey.swift`: Carbon `RegisterEventHotKey` wrapper for `⌃⌘V`.
- [x] `UI/ClipboardPickerView.swift`: panel + controller + SwiftUI list (10 items, number keys, Esc,
      outside-click), thumbnails, empty state, liquid-glass styling, uiScale.
- [x] `AppDelegate`: `buildClipboardSubmenu()` (20 items) + "Clipboard History" menu item +
      `menuCopyClipItem`/`menuRemoveClipItem`/`menuClearClipboard` + "Track Clipboard" toggle.
- [x] `AppDelegate.applicationDidFinishLaunching`: start monitoring + register hotkey → picker.
- [x] Build green (no new warnings — only the pre-existing NSEvent-Sendable / maxChars warnings remain).
- [x] Docs: CLAUDE.md (clipboard architecture + conventions), todo.md boxes, aidrop-summary.md §14, lessons.
- [ ] Owner test: copy text/image/files → appears in menu (20) and picker (10); ⌃⌘V opens picker, number
      key + click copy to clipboard, ⌘V pastes; password-manager copy is NOT captured; survives relaunch;
      "Track Clipboard" off stops capture + hotkey.

**Build notes (impl):** `ClipboardPicker` keyDown monitor must return `handleKey`'s result directly —
`self?.handleKey(event) ?? event` resurrects a swallowed key (nil → event), so number/Esc keys would leak.
Guard `self` first, then return the (possibly nil) result. Hotkey + poll are armed together at launch and
flipped together by `menuToggleClipboard` so they never drift out of sync.

---

## STATUS — 2026-06-01

- **Hosted-tier code: all DONE + build green.** Token-budget quota, model routing, 3rd tier, content caps.
- **D1 migrations: APPLIED** (owner) — `usage.tokens` + `accounts.pro` columns added.
- **`wrangler deploy`: confirm it ran** — the migrations are inert until the new Worker code is live.
- **Manual tests: PASS** (owner) — multi-file, Finder Quick Action, conversation, minimize, file tools, history.
- **Paddle / payments: DEFERRED on purpose** — wire up only if the app gets real usage. `isPremiumUnlocked`
  stays `false`; Pro is reachable solely by a manual D1 `pro=1` flag for testing. Bill is bounded
  meanwhile by `GLOBAL_DAILY_CAP` (2000 interactions/day) regardless of device-id spoofing.

---

## Feature — Favorite apps by file type (per-category tabs + General) (DONE, build green)

> 2026-06-02. Owner: "add in the favorite apps setting tabs for each file type (video, image,
> text, audio) and a general tab where users can either select other ones or tick a box which
> says Use General."

**Design (defaults chosen to preserve today's behavior):**
- `FileCategory` enum: `image / video / audio / text`. `text` = the catch-all (PDF, code, json,
  docx, plain text — everything droppable that isn't image/video/audio). Resolver lives in
  `FileInspector.category(for:)` reusing existing `isImageFile/isVideoFile/isAudioFile`.
- Store gains a **General** list + a per-category `{ useGeneral: Bool, tools: [FavoriteTool] }`.
  Each list capped at 9 (the ⌥1…9 range). Resolution for a dropped file =
  `category.useGeneral ? general : category.tools`. Session category = primary (first) file.
- **Migration:** existing flat `favoriteTools.v1` → General list; every category defaults
  `useGeneral = true`. So current users see no behavior change. New key `favoriteTools.v2`.
- Settings: segmented Picker (General | Image | Video | Audio | Text). Category tabs show a
  "Use General favorites" toggle; ON → note + hide list, OFF → that category's own editable list.
  General tab has no toggle.

**Tasks**
- [x] `FileInspector`: add `FileCategory` enum (+title/systemImage) and `category(for:)`.
- [x] `FavoriteToolsStore`: replace flat `tools` with `general` + `categories` (@Published);
      scope-aware `add/remove/move`, `setUseGeneral/useGeneral`, `tools(for:)`,
      `resolvedTools(for: [URL])`, `tool(forNumber:for:)`; v1→v2 migration in `load()`.
- [x] `ToolRow`: resolve list via `store.resolvedTools(for: vm.sessionFileURLs)`.
- [x] `AppDelegate`: hotkey handler uses `tool(forNumber:for:)`; `$tools` observer → store
      `objectWillChange`; `sizeForStage` two `.isEmpty` checks use the resolved list.
- [x] `SettingsView`: tabbed favorite-tools section (Picker + Use-General toggle + per-scope list).
- [x] Bump favoriteTools settings-window height (420 → 520) for the added Picker/toggle.
- [x] Build green.
- [ ] Owner manual-test: General favorites still launch; set a category to its own apps, drop
      that file type, confirm the row + ⌥N reflect the category list; toggle Use General back.

---

## Feature — "+" add tile + favorites row in result stage (code DONE — build green, needs owner test)

> 2026-06-03. Owner: "add a + (add) rect next to the favorite tool. Add those tools to stage 2 in
> the bottom left corner — same styling as on stage 1." (stage 1 = chips, stage 2 = result.)
> Design fork resolved (AskUserQuestion): **enable ⌥1…9 in the result stage too** (full parity).

- [x] `UI/ToolRow.swift`: trailing `AddToolButton` — a dashed-border "+" tile (same 40×40 glass
      footprint as `ToolButton`, no number badge) appended after the app icons in the `populated` row;
      tap posts `.showFavoriteTools`. Empty-state hint left as the single muted line (keeps the
      `toolHintHeight` height-math; the "+" only shows once ≥1 favorite exists).
- [x] `AppDelegate`: new `.showFavoriteTools` notification + observer →
      `handleShowFavoriteTools()` → `showSettings(section: .favoriteTools)`.
- [x] `AppDelegate`: tool-hotkey monitor now installed for `.chips` **and** `.result`
      (`observeStageChanges` switch + `handleToolHotkey` `inToolStage` guard) so ⌥1…9 fire in both.
- [x] `UI/OverlayView.swift`: `ToolRow()` added to the result-stage `leftColumn` **after the Spacer**
      (bottom-left), so it reuses the identical view → identical styling incl. the "+" tile. Sits in
      existing slack (≈350 pt content vs 380 pt min window) — no `sizeForStage` change.
- [x] Build green (`xcodebuild … Debug` → `** BUILD SUCCEEDED **`).
- [ ] **Owner manual-test:** chips stage shows "+" after the app icons → opens Settings ▸ Favorite
      Tools; result stage shows the same row bottom-left; clicking a tile launches; ⌥1…9 launch in the
      result stage; the favorites row isn't clipped at the shortest result (multi-file header + 5
      suggested actions is the tightest case).

---

## Feature — Utility result stage (Pillar 2 "second result stage") (IMPLEMENTED, build green — owner test pending)

> 2026-06-03. Owner: "we need a second result stage. If a utility was used, place the result file
> next to it (UI expands same as the result stage). Give the option Reveal in Finder (we know the
> path/URL). Show the relevant details of it AND the original file below each — e.g. for compress how
> much smaller. Same styling; expand the file pill downwards where the details are displayed."
> Forks resolved (AskUserQuestion): **scope = all file-creating ops** (rename in-place + Count/SHA-256
> alert unchanged); **auto-reveal in Finder AND show the card**; **rich detail** (size+delta, kind,
> type-specific line).

**New stage.** `OverlayViewModel.Stage.fileResult(original: URL, output: URL, tool: FileTool)`
(`tag = 5`; `fileURL` → original; `showsRightColumn` stays false). The root `OverlayView` switch
routes it to a new `FileResultView` (lands in the existing glass-card `default:` branch → keeps
window-drag/grabber/second-file banner).

**Detail facts.** New `Core/FileFacts.swift`: `nonisolated static func gather(_ url:) async -> Facts`
→ { name, sizeBytes (folder = recursive sum), kind (localized UTType desc), dimensions? (CGImageSource),
pageCount? (PDFDocument), duration? (AVAsset.load(.duration)), itemCount? (dir), isDirectory }. Heavy
probes run off-main in the view's `.task`; assigned to `@State` on return. Output pill also shows the
**size delta vs original** (e.g. "1.2 MB · 73% smaller" / "↑ 18% larger").

**View.** `FileResultView` (in `OverlayView.swift`), 500-wide to match the result stage:
header (tool result-title + matched `CloseButton`) · "RESULT" caption · `ExpandedFilePill(output)`
(icon+name on top, detail rows beneath — the "pill expanded downwards") · Reveal-in-Finder + Quick Look
+ ← back-to-chips buttons · "ORIGINAL" caption · `ExpandedFilePill(original)` · `Spacer`. Reuses the
glass styling of `SingleFilePill`.

**Dispatch.** `FileToolActions`: new `runFile(tool, original:) { op }` — reveal output in Finder (user
chose "both") THEN set `vm.stage = .fileResult(...)` via `DispatchQueue.main.async { withAnimation {…} }`
(stage-write deferral invariant). Switch every file-producing `perform` case from `run{}` to `runFile`;
`performAsync` (media) does the same after its output. Rename/Move/Count/SHA-256 untouched. Add
`FileTool.resultTitle` (past-tense labels: Compressed / Converted to JPEG / Merged PDFs / …; fallback `.title`).

**Wiring/sizing.** `sizeForStage` `.fileResult` → `CGSize(500, 410) * s`. Add the new case to the two
exhaustive `Stage` switches in `remapSessionURL` (remap `original`, leave `output`). Add a VM helper to
return to chips for the back button (rebuild `.chips` from `sessionFileURLs`). `observeStageChanges`
default branch already stops tool-hotkeys for non-chips/result.

**Files:** `Models/OverlayViewModel.swift`, `Core/FileFacts.swift` (NEW), `Core/FileTools.swift`
(resultTitle), `UI/FileToolsMenu.swift`, `UI/OverlayView.swift`, `AppDelegate.swift` (sizeForStage),
docs (CLAUDE.md stage machine + Pillar 2, this file, lessons if anything bites).

**Tasks**
- [x] VM: `.fileResult` case + `tag`/`fileURL`; `remapSessionURL` (both switches); `returnToChips()` helper.
- [x] `Core/FileFacts.swift`: async `gather`, folder recursion, delta formatting.
- [x] `FileTool.resultTitle`.
- [x] `FileToolActions`: `runFile` + `presentFileResult`; switch producers; `performAsync` sets stage.
- [x] `FileResultView` + `ExpandedFilePill` + `FileResultActionButton` in `OverlayView` + inner switch case + transition.
- [x] `AppDelegate.sizeForStage` `.fileResult` → `CGSize(500, 430) * s` (430, not 410 — headroom for 2 detail grids).
- [x] Build green (no new warnings).
- [ ] Owner test: compress a file → card shows output+delta+original, Reveal works, ← returns to chips,
      ✕ dismisses; image convert/resize shows dimensions; pdf→images shows folder item count; media op.

---

## Feature — Video/audio support (droppable, AI-free) (DONE, build green)

> 2026-06-02. Owner: "add video and audio file types as supported. Right now i cant drop a mp4."
> Media (video/audio) was listed as UNSUPPORTED → routed to the error stage. Made it **droppable**
> for Pillar 1/2 (Open-in + file Utilities) while keeping the **hosted AI OFF** for it. Critical cost
> reason: `FileContentExtractor` falls through to its text reader for unknown types and decodes binary
> as Latin-1 → would send ~24k chars of garbage to the model and burn operator tokens. Confirmed via
> AskUserQuestion: media stage = **Utilities + Open-in only** (no prompt field, no AI tabs).

- [x] `FileInspector`: `videoExtensions`/`audioExtensions` + `isVideoFile`/`isAudioFile`/`isMediaFile`;
      `suggestedActions` returns `[]` for media; `isUnsupportedFileType` **exempts media** (droppable);
      archives/installers stay unsupported (→ error stage).
- [x] `OverlayViewModel.setChips(url:)`/`setChips(urls:)`: default `chipsTab = .utilities` when primary is media.
- [x] `ChipsColumnView` (`OverlayView`): `isMediaSession`; content always shown for media
      (`isChipsExpanded || isMediaSession`); **prompt field hidden** for media; tab bar shows only the
      Utilities group; empty-Suggested hint added (defensive).
- [x] `FileHeaderView`: collapse chevron hidden for media (nothing to collapse to).
- [x] `buildMultiFileContent`: single-media → throws `unsupportedFileType`; multi-file loop skips media
      with a `[Media: … not analysed]` placeholder (defends mixed sessions from token waste).
- [x] `AppDelegate.sizeForStage`: media `.chips` branch (header+tabBar+content+toolRow+padding, **no prompt**).
- [x] Build green.
- [ ] Owner manual-test: drop `.mp4` / `.mov` / `.mp3` / `.m4a` → lands on Utilities (Show in Finder /
      Rename / Move / Compress), Open-in row works, NO prompt field, NO AI tabs; height fits with no gap;
      archive (`.zip`) / installer (`.dmg`) still shows the error card.

### Backlog — media-specific utilities (noted, not built)

Natural next step now that media is droppable (all AVFoundation/Speech, local + free):
video→audio extract, mov↔mp4, compress, trim, extract frame, video→GIF, mute; audio convert/trim/
normalize; **transcribe (Speech, on-device)** — the closest thing to an "AI" action for media, still zero API cost.

---

## Feature — File-utility expansion (Pillar 2): first batch + backlog (IN PROGRESS)

> 2026-06-02. Owner: "start with first batch, note down the rest." File utilities are LOCAL, FREE,
> offline native-framework ops (zero API cost) surfaced in the chips-stage **Utilities** tab. They live
> in `Core/FileTools.swift` (`FileTool` enum + `FileTools` engine), dispatched by
> `UI/FileToolsMenu.swift` (`FileToolActions.perform`), type-gated by `FileTool.tools(for:sessionFiles:)`.
> Window height auto-scrolls past 5 rows (`ChipsLayout.maxVisibleRows`), so longer tool lists are safe.

### First batch (BUILD NOW)

- [x] `convertToJPEG` — image → JPEG (covers HEIC/webp/png→jpg). ImageIO, orientation baked. Gated: images, not already jpg.
- [x] `stripEXIF` — image → metadata-stripped copy (EXIF/GPS/TIFF/IPTC nulled, NO re-encode via `CGImageDestinationAddImageFromSource`). Gated: images.
- [x] `pdfSplit` — PDF → one `.pdf` per page into a `<name>-pages/` folder. PDFKit. Gated: PDFs (throws if <2 pages).
- [x] `pdfToImages` — PDF → one PNG per page (`page.thumbnail(of:for:)`, 2×) into `<name>-images/`. Gated: PDFs.
- [x] `imagesToPDF` — session images → single PDF (`PDFPage(image:)`). Gated: images.
- [x] `prettyJSON` — JSON → pretty-printed, sorted-keys sibling. `JSONSerialization`. Gated: `.json`.
- [x] `compress` — any file/folder → sibling `.zip` (`NSFileCoordinator .forUploading`). Gated: always.
- [x] Wire `FileToolActions.perform` cases + `FileTool.tools` gating; **build green**.
- [ ] Owner manual-test: drop image (Convert to JPEG / Remove Metadata / Convert to PDF), PDF
      (Split into Pages / Pages to Images), `.json` (Pretty-Print), any file (Compress .zip);
      confirm Finder reveal + sibling outputs, no name clobber, Utilities row scrolls past 5.

### Backlog (NOTED, not built)

- **PDF (PDFKit):** extract page range, compress, rotate/reverse, delete pages, unlock/encrypt, watermark,
  extract embedded images, strip/read metadata, flatten annotations.
- **Images (ImageIO/Core Image/Vision/AppKit):** convert to PNG, read EXIF, remove background
  (Vision `VNGenerateForegroundInstanceMask`, 14+), rotate/flip/crop, @1x/@2x/@3x exports / app-icon set,
  grayscale, contact sheet, extract palette.
- **Text/Code/Data (Foundation/CryptoKit):** minify JSON + validate, CSV↔JSON, fix encoding / line endings,
  word/char/line count, sort/dedupe lines, tabs↔spaces, Base64 encode/decode, hash (SHA-256/MD5),
  Markdown→HTML/PDF/RTF.
- **Office (NSAttributedString):** DOCX→PDF, DOCX/RTF→Markdown/plain text, extract images from DOCX.
- **Audio/Video (AVFoundation) — expands supported types:** video→audio, mov↔mp4, compress, trim,
  extract frame, video→GIF, mute; audio convert/trim/normalize; transcribe (Speech, on-device).
- **Any file:** unzip, duplicate, copy to Desktop/Downloads, AirDrop (NSSharingService), Quick Look,
  copy path, .ics→Calendar, .vcf→Contacts.
- **Free local versions of AI actions (zero API cost, offline):** OCR (Vision), background removal (Vision),
  transcription (Speech).

---

## Feature — Text/Code/Data utilities (Pillar 2, BATCH 3) (code DONE — build green, needs owner test)

> 2026-06-03. Owner: "yes go" to the proposed Text/Code/Data cluster (the emptiest format — plain
> text/code today only get the universal reveal/rename/move/compress). All ops are LOCAL, FREE,
> synchronous Foundation/CryptoKit — zero API cost, no async (unlike batch 2 media), no parameter
> dialogs (unlike Trim/Resize). They surface in the chips-stage **Utilities** tab and the list just
> scrolls past 5 rows (`ChipsLayout.maxVisibleRows`) — no AppDelegate sizing change.

### Architecture decision — the one real change: an INFO presentation path
Batch-1/2 ops all produce a SIBLING FILE (revealed in Finder). Two ops in this batch (**Count**,
**SHA-256**) produce a VALUE, not a file. So `FileToolActions` gains a `runInfo`/`presentInfo` path:
an NSAlert showing the value with **Copy** + **Done** buttons (Copy → `NSPasteboard`). Everything else
reuses the existing sync `run { try … }` → reveal-sibling path. No new stage, no async, no enum flag.

### Gating (new `FileInspector.isTextFile` + `textExtensions`)
- **Text/code/data files** (txt/md/csv/json/xml/yaml/code/…): Sort Lines, Remove Duplicate Lines,
  Count (lines/words/chars), Base64 Encode.
- **`.b64` / `.base64`**: Base64 Decode (instead of Encode).
- **`.json`**: Minify JSON (alongside existing Pretty-Print), JSON → CSV.
- **`.csv`**: CSV → JSON.
- **Any file (universal, near Compress):** SHA-256 checksum.

### Build now — core set
- [x] `FileInspector`: `textExtensions` + `isTextFile(_:)` (plain-text/code/data exts; NOT pdf/docx).
- [x] `FileTools` (`import CryptoKit`): `sortLines` / `dedupeLines` (preserve trailing-newline),
      `countStats` (→ String), `sha256` (chunked FileHandle stream, hex), `base64Encode` (raw bytes →
      `.b64`, MIME 76-col), `base64Decode` (whitespace-stripped → `-decoded.txt`/`.bin` by UTF-8 sniff),
      `minifyJSON` (compact `JSONSerialization`), `csvToJSON` (RFC-4180 parser, column-order-preserving
      hand-built JSON, all values as strings), `jsonToCSV` (array-of-objects → CSV, union keys sorted,
      RFC-4180 quoting). New `FileToolError` cases: notTextReadable / invalidBase64 / invalidCSV /
      jsonNotTabular. Private helpers: readText / splitLines / writeSibling / jsonStringLiteral /
      stringifyJSONValue / csvField / parseCSV.
- [x] `FileTool`: 9 new cases (+ titles + macOS-14-safe SF Symbols); `isAsync` stays false (all sync).
- [x] `FileTool.tools(for:sessionFiles:)`: json block (+minify, +jsonToCSV), csv block (csvToJSON),
      text block (sort/dedupe/count/base64), universal SHA-256 before Compress.
- [x] `FileToolActions.perform`: 7 file-producing cases via `run {}`; Count + SHA-256 via `runInfo`.
      Added `presentInfo(title:value:)` (Copy → pasteboard / Done).
- [x] Build green (`xcodebuild … Debug` → `** BUILD SUCCEEDED **`).
- [x] Captured lesson (TEXT-01 INFO-path + CSV round-trip) in `tasks/lessons.md`.
- [ ] **Owner manual-test:** drop `.txt`/`.log` → Sort, Dedupe, Count (alert+Copy), Base64 Encode (.b64);
      drop that `.b64` → Decode round-trips; `.csv` → CSV→JSON; `.json` → Minify + JSON→CSV; any file →
      SHA-256 (verify hex matches `shasum -a 256`). Each sibling reveals, no clobber, no beachball.

### Deferred (need dialogs or are heavier — note, not built)
CSV/JSON type inference (numbers/bools — currently all-string, lossless), Base64 of arbitrary binary
from the menu (encode is text-gated for now), word/char count on huge files staying off-main, fix
encoding / line-endings / tabs↔spaces, Markdown→HTML/PDF/RTF.

---

## Feature — Quick Look preview on pill click (code DONE — build green, needs owner test)

> 2026-06-03. Owner: "can we add a preview compatibility when the file which is dropped is clicked?"
> Trigger chosen (AskUserQuestion): **single-click the pill**. Uses the system Quick Look panel
> (`QLPreviewPanel`, the Finder-spacebar preview) — NOT Finder-only; any app can present it. We're
> non-sandboxed and already hold the URLs, so images / PDF / video / audio / text / code preview
> full-size for free, with ◀ ▶ between multi-file sessions.

### Wiring
- `QLPreviewPanel` walks the **key window's responder chain** for a `QLPreviewPanelController`.
  `OverlayWindow` (NSPanel, `canBecomeKey == true`) implements the 3 informal-protocol hooks and
  points the panel's `dataSource`/`delegate` at the `QuickLookController` singleton.
- **Dismiss-monitor safety (verified):** the outside-click monitor only dismisses in Stage-1
  `.waitingForDrop`; preview is reached in chips/result, where outside-clicks never dismiss. Esc is a
  GLOBAL `NSEvent` monitor (fires only for OTHER apps' events) → Esc inside the in-app QL panel closes
  the panel, leaving the session open.

### Build now
- [x] `UI/QuickLookPreview.swift` (NEW): `QuickLookController` singleton + `QLPreviewPanelDataSource`
      (NSURL conforms to QLPreviewItem natively) + empty `QLPreviewPanelDelegate`. `present(urls:current:)`
      filters to existing files, makes the overlay key, opens/re-points `QLPreviewPanel.shared()`.
- [x] `UI/OverlayWindow.swift`: `import Quartz` + 3 overrides — `acceptsPreviewPanelControl(_:) -> Bool`,
      `beginPreviewPanelControl(_:)` (sets dataSource/delegate/index), `endPreviewPanelControl(_:)`.
- [x] `UI/OverlayView.swift`: `.onTapGesture` on `SingleFilePill` (whole icon+name row,
      `.contentShape(Rectangle())`, opens index 0) and `FilePill` (icon-only, opens that file's index).
      Subtitle copy → "Click to preview · drag to move". ShareButton stays outside the tap target.
- [x] Build green (`xcodebuild … Debug` → `** BUILD SUCCEEDED **`).
- [x] Captured lesson (QL-01: informal-protocol method name) in `tasks/lessons.md`.
- [ ] **Owner manual-test:** single-click single-file pill → QL opens that file; multi-file → click a
      chip opens that file, ◀ ▶ navigates; Esc closes the panel (session stays); drag-to-move still works
      (tap vs drag don't conflict); Share button still shares, doesn't preview.

---

## Feature — Media utilities (Pillar 2, BATCH 2) (code DONE — build green, needs owner test)

> 2026-06-03. Owner: "second batch, start with media utility. Eg: Extract Audio, Transcribe, convert
> to GIF and so + everything you just proposed." Scope confirmed via AskUserQuestion: **core set first**
> (no parameter dialogs); Trim/Normalize/GIF-options deferred. Video/audio are already droppable
> (batch-1 media work) but today only offer Compress(.zip) + Open-in. This batch gives them real value.
>
> **Cost posture (operator-bill-first):** EVERY op is 100% local / on-device — AVFoundation + the
> Speech framework. ZERO Gemini calls, zero proxy hits. Transcription runs on-device where supported
> (`supportsOnDeviceRecognition`); even the Apple-server fallback is Apple's free Speech service, NOT
> the operator's Gemini bill. This stays perfectly inside the cost priority.

### Architecture decision — async dispatch (the one real change)
Batch-1 utilities run **synchronously on the main thread** (`FileToolActions.run` → `try op()`),
which is fine for instant ImageIO/PDFKit ops. Media ops (export, GIF encode, transcription) are slow
+ inherently async → running them sync would **beachball**. So:
- New **`Core/MediaTools.swift`**: `enum MediaTools` with `async throws` static funcs (AVFoundation /
  Speech / ImageIO). Inherently-async exports use `withCheckedThrowingContinuation` over
  `exportAsynchronously` (macOS-14-safe; NOT the 15+ `export(to:as:)`). CPU-bound work (GIF frame loop,
  poster frame) runs **off the main actor** (continuation on a background queue) so the overlay stays live.
- New **`FileToolActions.performAsync(_:fileURL:sessionFiles:) async`** for the media cases (reveal on
  success, NSAlert on error — reuses `presentError`). Sync `perform` stays unchanged for batch-1 tools.
- **Loading UX:** reuse `MenuActionRow.isLoading` (already a per-row spinner + `.disabled`). `ChipsColumnView`
  gets `@State runningTool: FileTool?`; tap sets it, `Task { await performAsync(); runningTool = nil }`,
  taps ignored while one runs. NO new stage, NO AppDelegate change.
- **Window sizing:** unchanged — `utilityTools.count` grows, the list just scrolls past 5 rows with the
  existing bottom fade.
- **Permissions:** `NSSpeechRecognitionUsageDescription` is ALREADY in the pbxproj (both configs) → no
  Info.plist edit. First Transcribe triggers the system prompt; denial → NSAlert. App is non-sandboxed,
  sibling writes are fine. No new entitlement.

### Build now — core media set (no parameter dialogs)
- [x] `MediaTools.extractAudio(video) → <name>.m4a` (AVAssetExportPresetAppleM4A).
- [x] `MediaTools.transcribe(audio|video) → <name>.txt` (SFSpeechRecognizer + SFSpeechURLRecognitionRequest;
      `requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition`; for VIDEO, extract audio to a
      temp m4a first then recognise; authorize via `SFSpeechRecognizer.requestAuthorization`).
- [x] `MediaTools.videoToGIF(video) → <name>.gif` (AVAssetImageGenerator @ fps 10, maxWidth 480, first ≤10 s;
      ImageIO `CGImageDestination` kUTTypeGIF, loop 0, per-frame delay 1/fps). Sensible defaults, no dialog.
- [x] `MediaTools.extractFrame(video) → <name>-frame.png` (AVAssetImageGenerator, midpoint, preferred transform).
- [x] `MediaTools.compressVideo(video) → <name>-compressed.mp4` (AVAssetExportPreset1280x720, .mp4).
- [x] `MediaTools.muteVideo(video) → <name>-muted.mp4` (AVMutableComposition, video track only, export .mp4).
- [x] `MediaTools.convertVideo(video, to:) → .mp4 / .mov` (Passthrough preset; retry HighestQuality on codec
      incompat). Offer Convert-to-MP4 unless already mp4; Convert-to-MOV unless already mov.
- [x] `MediaTools.convertAudio(audio) → <name>.m4a` (AppleM4A). Offer unless already m4a/aac.
- [x] `FileTool` new cases + titles + macOS-14-safe SF Symbols + `var isAsync` (true for the 9 media cases).
- [x] `FileTool.tools(for:sessionFiles:)`: video branch (transcribe, extractAudio, videoToGIF, extractFrame,
      compressVideo, muteVideo, convertToMP4/MOV) + audio branch (transcribe, convertToM4A). Compress(.zip) stays universal.
- [x] `FileToolActions.performAsync` dispatch for the new cases + `ChipsColumnView` runningTool wiring.
- [x] Build green (`xcodebuild … Debug` → `** BUILD SUCCEEDED **`, no errors/warnings in new code).
- [ ] **Owner manual-test:** drop `.mp4`/`.mov` → Extract Audio (.m4a), Transcribe (.txt, permission prompt
      once), Convert to GIF, Extract Frame, Compress, Remove Audio, Convert to MP4/MOV — each reveals a sibling,
      row spinner shows while running, no beachball, no clobber. Drop `.mp3`/`.m4a` → Transcribe + Convert to M4A.
- [x] Captured lessons (MEDIA-01 AVFoundation async + Speech file-transcription) in `tasks/lessons.md`.

### DECISION NEEDED — dialog-requiring ops (defer or include?)
These need a parameter UI (start/end, fps, gain), so they're a bigger lift than the no-dialog core:
- **Trim** (video/audio) — needs a start/end range picker (NSAlert with two time fields or a slider).
- **Normalize audio** — peak/RMS analysis + gain (AVAudioEngine), heavier DSP.
- **GIF options** — fps / max-size / duration picker instead of fixed defaults.
Recommend: ship the core set first (covers Extract Audio, Transcribe, GIF, Convert, Compress, Mute, Frame),
add Trim/Normalize/GIF-options as a follow-up sub-batch.

### Still backlog after this (other clusters, unchanged)
PDF (page-range, rotate, delete pages, watermark…), Images (PNG, remove-bg Vision, rotate/crop, app-icon set…),
Text/Data (CSV↔JSON, hash, Base64, Markdown→…), Office (DOCX→PDF/MD), Any-file (unzip, AirDrop, Quick Look…),
local OCR / background-removal (Vision).

---

## Feature — Pre-release UI polish: menu-style action rows + OPEN IN hint (IN PROGRESS)

> 2026-06-02. Pre-release polish. Owner: "the pills should only be for PROMPTS." Actions (AI insights +
> file utilities) go back to **Apple-menu styling** (icon-left list rows, like the old ••• menu) — the
> `FileTool` utilities used to live in a native menu (commit d70a9db) before becoming chips. Confirmed
> via AskUserQuestion: **(1) scope = everywhere actions appear** (chips Suggested + Utilities tabs AND the
> result view's Suggested rail + follow-ups); **(2) look = neutral white hover highlight** (matches the
> dark card glass); **(3) ToolRow caption = "OPEN IN ⌥+"** two-tone (OPEN IN lighter grey, ⌥+ slightly darker).
> Typed prompts (History + Custom tabs) STAY pills.

- [x] **`AIAction.icon`** (`Models/AIAction.swift`): added an SF-Symbol per action (macOS-14-safe symbols).
- [x] **`MenuActionRow`** (new view in `OverlayView.swift`): leading SF Symbol + label, full-width, soft
      `white.opacity(0.10)` rounded hover fill; `isLoading` swaps the icon for a small spinner. Kept ≤
      `ChipsLayout.rowStride` so the chips-stage window-height math is UNCHANGED (no AppDelegate resize edit).
- [x] Swapped 4 render sites from `ActionChip` → `MenuActionRow`: chips `.suggested` (icon `action.icon`),
      chips `.utilities` (icon `tool.systemImage`), result `leftColumn` Suggested rail (+isLoading), result
      `followUpActions`. Left `.history` + `.custom` (and the customAddRow) as `ActionChip` pills.
- [x] **ToolRow caption** (`UI/ToolRow.swift`): replaced plain `Text("OPEN IN")` with `OPEN IN` (opacity
      0.40, lighter grey) + `⌥+` (opacity 0.28, slightly darker grey). Per-app number badges on the icons stay.
- [x] **Prewarm parity:** `OverlayPrewarmView` now warms `MenuActionRow` (the new leaf the real card uses)
      alongside one `ActionChip` (prompt pill), per its "same leaf views" invariant.
- [x] **Build green** (`xcodebuild … Debug` → `** BUILD SUCCEEDED **`).
- [ ] Owner manual-test: chips Suggested/Utilities render as menu rows with icons + hover; History/Custom
      still pills; result-stage rail + follow-ups are menu rows; loading spinner shows on a running action;
      "OPEN IN ⌥+" two-tone reads right; window heights unchanged (no clipping/extra gap).

---

## Feature — Model-weighted budget debit (budget = COST guard, not token count) (code DONE — NEEDS deploy)

> 2026-06-02. Owner caught the gap: the daily TOKEN budget was raw count, so a `gemini-2.5-pro`
> token (the Pro `extra` model) drained it the same as a flash-lite token despite costing ~18×. A Pro
> user spamming "Go deeper"/findBugs could stay "within budget" while the bill hit ~$15–23/mo. Owner:
> "weight the tokens by model. Be generous." Worker-only; closes the deferred §8 cost-credit item.

**Weights (relative to flash = 1.0; deliberately generous — compressed below true cost ratio):**
- flash-lite → **0.5** (cheap path rewarded; thrifty mode ≈ 2× effective headroom)
- flash → **1.0** (anchor; today's 30k/200k budgets keep their exact feel)
- gemini-2.5-pro → **4.0** (≈ its $/token vs flash; true ratio is ~4× flash / ~18× flash-lite)
- unknown/renamed model → 1.0 (never 0 — must not be a free pass)

- [x] `BUDGET_WEIGHTS` map + `modelWeight()` added next to `PRICES` (`worker/src/index.js`).
- [x] `handleComplete`: debit `billedTokens = round(tokensUsed × modelWeight(usedModel))` against the
      daily budget (and in the returned `usage`). Weighted by the model ACTUALLY billed (incl. fallback).
- [x] **`spend` roll-up stays RAW** (real prompt/completion tokens) so `/v1/stats` $ math is unchanged.
- [x] `wrangler.toml` budgets re-documented as "flash-equivalent" tokens; `node --check` clean.
- [x] Verified worst-case: Pro maxed 30 days now **$1.74–$3.84/mo** for ANY model mix (was $15.40 all-pro).
      Free maxed **$0.26–$0.58/mo**. Budget is now a real ~$4/mo cost ceiling at the pro budget.
- [ ] **USER ACTION:** `cd worker && wrangler deploy` (same deploy as thrifty mode below). (Agent can't deploy.)
- [ ] NOTE: the stored `usage.tokens` unit becomes weighted from deploy; existing rows reset at the next
      UTC day rollover anyway (budget is per-day), so no migration needed.

---

## Feature — Thrifty routing mode (FREE-tier cost squeeze) (code DONE — NEEDS deploy)

> 2026-06-02. Owner: current routing is "generous" for launch/first users (fine), but at scale the
> Gemini bill could hurt ("5¢ from ~10 debug runs as the only user"). Add a SECOND routing mode that can
> be swapped instantly. Confirmed decisions (AskUserQuestion): **switch lives in the Worker only**
> (`env.ROUTING_MODE`, no app/client change) and it **applies to FREE only** — Pro keeps the full
> generous ladder. Priority unchanged: minimise the operator's bill first; every failure mode biases cheap.

**Mapping (free tier):**
- generous (default, today): fast→flash-lite, strong→flash, extra→flash (free degrade)
- thrifty: fast→flash-lite, strong→**flash-lite** (the squeeze; `reasoning_effort:"low"` is already
  always-on, so "more complex" strong tasks still get a little thinking), extra→flash (real reasoning).
- Pro (every mode): fast→flash-lite, strong→flash, extra→gemini-2.5-pro — UNCHANGED.

- [x] `pickModel(env, tier, isPro)` (`worker/src/index.js`): added a `thrifty && !isPro` branch — extra→
      strong(flash), everything else→fast(flash-lite). Pro + generous fall through to the unchanged ladder.
      Unknown/missing tier still degrades cost (thrifty→flash-lite, generous→flash). Fail-safe preserved.
- [x] `ROUTING_MODE` added to `wrangler.toml` [vars], default `"generous"` (preserves launch behaviour).
- [x] Tier-fallback stays consistent: in thrifty, `strongModel` = flash-lite, so a failed extra(flash)
      call retries on flash-lite (cheaper) — biases cheap, never errors out.
- [ ] **USER ACTION (swap, no logic redeploy):** flip in Cloudflare dashboard ▸ Workers ▸ aidrop ▸
      Settings ▸ Variables ▸ `ROUTING_MODE` = `thrifty` (or `generous`). OR edit `wrangler.toml` +
      `cd worker && wrangler deploy`. (Agent cannot deploy.)
- [ ] **Owner cost-check after flip:** confirm free strong tasks (summarise/extract) now bill flash-lite
      via `/v1/stats`; Pro unaffected.

---

## Feature — Pillar 1 MVP: Favorite Tools + drop-to-launch hotkeys (DONE 2026-06-01 — build green; owner manual-test owed)

> 2026-06-01. First slice of the product reframe (`docs/VISION.md`): the notch becomes a router, not
> just an AI surface. Drop a file → a numbered row of YOUR apps appears → click or `Option+1…9` opens
> the file there. **Tool list = manual favorites** (owner decided). Smallest build that proves the
> "your tools, one drag away" story. AI chips stay — tools are an added lane, not a replacement.

**Design decisions (flag if you disagree):**
- Tools shown as a **numbered row inside the `.chips` stage**, below/beside the AI action chips
  (respects `uiScale` + `.liquidGlass`). Number badge = the `Option+N` it maps to.
- Hotkeys via a **local `NSEvent` keyDown monitor** installed only while the chips stage is live
  (no Accessibility needed — local monitors catch our own app's events; auto-removed on stage exit).
- Launch opens **all staged files** (multi-file aware) in the chosen app, then **dismisses** the overlay.
- Empty state: no favorites → row hidden + a one-line "Add tools in Settings" hint (no dead UI).
- Number assignment: auto `1…9` by order; reorder/remove in Settings.

**Plan:**
- [x] **`Models/FavoriteToolsStore.swift`** — `@MainActor ObservableObject`, PromptStore-style:
      `FavoriteTool { id, name, path }`; persisted as a Codable array in UserDefaults (`favoriteTools.v1`).
      `add(appURL:)` (dedupe by path, cap 9), `remove`, `remove(at:)`, `move`, `tool(forNumber:)`,
      `launch(_:with:)`. Icons via `NSWorkspace.shared.icon(forFile:)` (not persisted).
- [x] **Launch path** — `FavoriteToolsStore.launch(_:with:)` uses
      `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)`. Opens ALL staged URLs
      (`OverlayViewModel.sessionFileURLs`); activates the app but leaves the notch session OPEN
      (owner chose keep-open over dismiss, 2026-06-01).
- [x] **Settings UI** — "Favorite Tools" section in `SettingsView`: add via `NSOpenPanel`
      (`.application`, default `/Applications`), list with icon + name + `⌥N` badge, remove, `.onMove`
      reorder. "Add App…" disabled at the 9 cap.
- [x] **Tool row view** — `UI/ToolRow.swift` in the chips stage (expanded): horizontal "OPEN IN" icon
      row, number badge per app, click → launch. Empty → one muted hint line. Height fed through
      `AppDelegate.sizeForStage` via `ChipsLayout.toolRowHeight`/`.toolHintHeight` (Combine loop, not
      SwiftUI layout) + a `FavoriteToolsStore.$tools` resize observer.
- [x] **Hotkeys** — chips-stage-scoped local `NSEvent` keyDown monitor (`startToolHotkeys`/
      `stopToolHotkeys`/`handleToolHotkey`, via `MainActor.assumeIsolated`): bare `Option+1…9` → launch
      favorite N; swallows only matched chords, passes everything else to the prompt field. Torn down in
      `stopDismissMonitors` and on any non-chips stage.
- [x] **Build green** — `xcodebuild … Debug` → BUILD SUCCEEDED.
- [x] Updated `docs/VISION.md` Pillar 1 status + `CLAUDE.md` (new store/view + local-monitor pattern).
- [ ] **Owner manual-test owed:** drop file → row shows favorites → click opens in app; `⌥2` opens the
      2nd; multi-file drop opens all; empty-favorites shows the hint; verify `⌥N` doesn't eat prompt keys.
- [ ] Capture a lesson if the hotkey monitor / focus interaction bites during manual test.

**Explicitly NOT in this MVP** (later pillars): file utilities (convert/compress), AI→tool bridges,
destinations (Slack/Notion), saved workflows, auto-detecting installed apps. Keep it thin.

---

## Feature — Lower deployment target macOS 26 → 14 (PLANNED — awaiting go-ahead)

> 2026-06-01. Owner wants older-OS reach. Chose **macOS 14 (Sonoma)** target (not 13 — 13 would force
> rewriting the 4 animated SF Symbols; 14 keeps them). **No older-OS test machine** → the 14/15 branch
> ships runtime-UNVERIFIED; the macOS-26 path stays byte-identical and IS verified on the dev machine.
> Good news: the glass look is custom (`NSVisualEffectView` + gradients), NOT the 26-only `glassEffect`
> API → the whole aesthetic survives untouched.

**The one real blocker — mic permission (per lessons MIC-01/04/05):**
- macOS **14/15**: audio TCC is owned by `AVAudioApplication`; `AVCaptureDevice.authorizationStatus`
  returns a false `.denied` (MIC-04). → must use `AVAudioApplication.shared.recordPermission` +
  `AVAudioApplication.requestRecordPermission`.
- macOS **26**: reversed — `AVAudioApplication` defaults `.denied` for accessory apps; `AVCaptureDevice`
  maps to `kTCCServiceMicrophone` correctly (MIC-05). → keep the current `AVCaptureDevice` path.
- Current code = AVCaptureDevice ONLY → dictation would break on 14/15. Fix = `if #available(macOS 26, *)`
  split, restoring the documented MIC-04 path behind the guard.

**Plan:** (code DONE 2026-06-01 — build green; owner runtime-test owed)
- [x] Set `MACOSX_DEPLOYMENT_TARGET = 14.0` — done at the **project level** (pbxproj lines 300/358);
      neither target overrides it, so app + AddToAIDrop both inherit 14. No `LSMinimumSystemVersion` present.
- [x] Built target 14 against the 26 SDK → **ZERO availability errors**. No 26-only APIs in the code
      (Liquid Glass is custom; `.symbolEffect`×4 are 14+). So **no `#available` guards needed anywhere**.
- [x] **`SpeechRecognizer` Step 2 OS-split** added: `micAuthStatus()` / `requestMicAccess()` branch on
      `if #available(macOS 26, *)` — 26 → AVCaptureDevice (unchanged); 14/15 → AVAudioApplication (MIC-04).
      MIC-06 overlay-level drop kept in the shared path. 26 behavior byte-identical.
- [x] Info.plist mic/speech usage strings already present (`INFOPLIST_KEY_NS*UsageDescription`, pbxproj
      both configs) — no change needed.
- [x] **Clean build green** at target 14 (`** BUILD SUCCEEDED **`).
- [x] README `macOS 13+` → `macOS 14+`; CLAUDE.md deployment-target + known-gaps updated; lesson MIC-11 added.
- [ ] **OWNER — verify the 26 runtime path unchanged on THIS machine:** drag→drop→action + dictation
      (mic prompt + transcription). Should be identical to before (26 branch untouched).
- [ ] **OWNER, when you get a 14/15 box/VM:** verify dictation actually prompts + records there. Until
      then the 14/15 mic branch is code-reviewed but NOT runtime-proven (the #1 residual risk).

---

## Feature — Spend instrumentation (§8) (code DONE — NEEDS deploy + secret + table)

> 2026-06-01. Owner priority is the API bill; this gives eyes on it. We already capture real
> tokens per call — this rolls them up so you can see spend and tune routing on data, not vibes.
> Server-side only, no app release. Per-action breakdown deferred (needs the client to send the
> action name; today only `tier` is sent).

- [x] **`spend` table** (`schema.sql`): per day × model-billed × requested-tier, splitting
      `prompt_tokens` / `completion_tokens` so cost is estimable. `PRIMARY KEY(day, model, tier)`.
- [x] **Worker writes it best-effort** after each successful call (`index.js`, `.catch(()=>{})` so a
      logging failure never breaks a user response). Tracks `usedModel` (incl. the fallback model),
      normalizes the tier hint to `fast|strong|extra|other`. `callGemini` now returns split in/out tokens.
- [x] **Spend write is OFF the response path** — wrapped in `ctx.waitUntil()` so it runs *after* the
      response is sent (zero user-facing latency). `handleComplete(request, env, ctx)`. Falls back to a
      plain `await` if `ctx` is missing. The consume/global-usage writes stay awaited (they gate the next
      request's limits → must be race-free).
- [x] **`GET /v1/stats`** — admin-guarded by the `ADMIN_TOKEN` secret (unset ⇒ endpoint closed).
      `?days=N` (default 7, max 90). Returns per-row + totals with `est_usd` from a list-price map
      (flash-lite/flash/pro; unknown model ⇒ $0). Cost math verified offline.
- [x] `node --check` clean. Cost/reduce logic sanity-checked (164-call sample ≈ $0.41).
- [ ] **USER ACTION 1:** `wrangler secret put ADMIN_TOKEN` (any long random string).
- [ ] **USER ACTION 2:** create the table — `wrangler d1 execute aidrop --remote --file=./schema.sql`
      (re-runs all `CREATE TABLE IF NOT EXISTS` — harmless to repeat).
- [ ] **USER ACTION 3:** `cd worker && wrangler deploy`.
- [ ] **Read it:** `curl -H "X-Admin-Token: <token>" https://aidrop.aidrop.workers.dev/v1/stats?days=7`
- [ ] FUTURE: send the action name from the client → per-action spend; optional simple HTML dashboard.

---

## Feature — 2× char caps + token-budget daily quota (code DONE — NEEDS deploy + D1 migration)

> Goal (owner): "double the max chars for free and paid users on every model; change the daily
> limit from flat interactions to 3× the maxchar for free and 10× for pro." Then, asked "is chars
> the right unit? we also have images" — owner chose to **meter actual upstream tokens** (chars
> miss image bytes). Priority unchanged: the operator's bill comes first; per-user cap is a relief valve.

- [x] **Doubled all char caps.** Client `FileContentExtractor.maxChars` 12k→**24k**, `maxCharsPro`
      24k→**48k**. Worker `MAX_CONTENT_CHARS` 20k→**40k**, `MAX_CONTENT_CHARS_PRO` 40k→**80k**
      (`wrangler.toml` + `readLimits` defaults). These now serve as the **pre-flight input guard**
      (char-based, checked before the call — token cost isn't known until after). Client cap stays
      below the Worker cap on purpose — headroom for the document riding every multi-turn request.
- [x] **Daily quota: flat interactions → TOKEN budget.** Was `FREE_DAILY_CAP = 10`/day. Now metered on
      the **actual tokens Gemini bills** (input + output), read from each response's `usage` block — so
      images, PDFs and text all debit fairly (a char count misses image bytes). `FREE_DAILY_TOKENS = 30000`
      (~3 full free requests), `PRO_DAILY_TOKENS = 200000` (~10 full pro requests). Tunable server-side,
      no app update. Fallback: if upstream `usage` is missing, estimate `chars/4` so nothing meters free.
- [x] **Trial unchanged (interaction-based, 30 lifetime); Pro bypasses the trial** → straight to its
      big daily token budget. Gate is "already-consumed ≥ budget" (last request may slightly overshoot —
      a relief valve, per-request char cap bounds the spill). Global circuit-breaker left interaction-based
      (coarse abuse valve).
- [x] **Schema:** `usage` gains a `tokens` column (kept `count` for instrumentation + the global breaker).
      Upsert bumps both; `callGemini` now returns `tokens` from the upstream `usage`. `worker/schema.sql` updated.
- [x] **Usage payload reshaped** (`/v1/complete` + `/v1/usage`): drops `dailyRemaining`/`remaining`, adds
      `dailyTokenBudget` + `dailyTokensRemaining` + `tier:"pro"`. Client `HostedUsage`/`UsageStore` mirror it;
      menu shows trial interactions ("8 free left") then a daily **percentage** ("73% free today") since
      raw token counts mean nothing to the user.
- [x] Build green (`** BUILD SUCCEEDED **`) + `node --check` OK.
- [ ] **USER ACTION 1:** `cd worker && wrangler deploy` (pushes the metering redesign + doubled caps).
- [x] **USER ACTION 2 (one-time, existing DB):**
      `ALTER TABLE usage ADD COLUMN tokens INTEGER NOT NULL DEFAULT 0` — APPLIED.
- [x] Manual test — PASS.
- [ ] FUTURE (spec §8): model-weighted cost-credits — a gemini-2.5-pro token costs ~4× a flash token;
      raw-token metering treats them equally. Fine for now (pro budget is large, `extra` fires rarely).

---

## Fix — Worker realigned to the multi-turn client + honors output ceilings (code DONE — NEEDS `wrangler deploy`)

> 2026-05-31. Found the live Worker (`worker/src/index.js`) still spoke the OLD single-shot contract
> (`content` string) while the app now sends multi-turn `messages` → every hosted call would 400. See
> lessons [WORK-01]. User chose "fix it + honor ceilings" (server-only; model routing deferred).

- [x] `/v1/complete` now reads `messages: [{role,content}]` (legacy `content` string still accepted),
      forwards the FULL conversation to Gemini (multi-turn), and bounds cost by total chars across turns.
- [x] Honors `body.max_tokens` (the per-action ceiling the app already sends) with Gemini thinking-headroom
      `max(requested + 1024, 2048)` + `reasoning_effort: low` — kills the server-side 2.5-Flash cut-off
      (a truncated answer = a wasted paid call + a retry = paying twice).
- [x] Image inlined into the first user turn (same shape as BYOK providers). `node --check` clean.
- [ ] **USER ACTION:** `cd worker && wrangler deploy` to push this live, then test the free tier end-to-end
      (set tier to non-BYOK, drop a file, run an action + a follow-up).
- [x] Model routing by tier — DONE in the block below (no longer deferred).

---

## Feature — Worker model routing by tier (#1 bill lever) (code DONE — NEEDS `wrangler deploy`)

> 2026-05-31. The labeled "#1 lever" from `docs/HOW_LLM_IS_CHOSEN.md` §4/§9. Route mechanical, bounded
> work to the cheap model and keep the capable model only where judgement matters — the single biggest
> cut to the operator's bill. Owner constraint: "I hate hardcoding keywords" → keywords must be
> NON-LOAD-BEARING; flash is the floor; we never *rely* on a keyword to decide quality.

- [x] App already ships `tier` (`plan.tier.rawValue`) on every `/v1/complete` call (HostedProvider).
- [x] `AIAction.routing`: deterministic `switch` (no keywords) maps each built-in chip's task class →
      `.fast` (extraction/short-summary/translate/rephrase/docstring/altText/OCR) or `.strong`
      (explain/findBugs/refactor/describeImage/freeform).
- [x] `RoutingPlan.forCustomPrompt`: floor = `.strong` (flash); keyword list may ONLY downgrade a short,
      obviously-trivial prompt to `.fast`. Delete the list → reverts to always-flash. Never escalates.
- [x] Worker `pickModel(env, tier)`: honours only an explicit `"fast"` → `GEMINI_MODEL_FAST`
      (gemini-2.5-flash-lite); missing/unknown/malformed → `GEMINI_MODEL` (gemini-2.5-flash). Tier is an
      UNTRUSTED hint — a bad tier degrades cost, never quality.
- [x] Worker retry: if the routed (cheap) model call fails, retry once on the strong default before
      erroring (`result.ok` check, `model !== strongModel`). User gets an answer, not a 502.
- [x] `wrangler.toml`: added `GEMINI_MODEL_FAST = "gemini-2.5-flash-lite"`. `node --check` clean; app
      build green.
- [ ] **USER ACTION:** `cd worker && wrangler deploy` to push the model map live, then test: a mechanical
      action (e.g. translate, summariseShort) should run on flash-lite; a reasoning action (explainCode,
      findBugs) on flash. Both should still answer (retry + untrusted-hint fallback cover the failure modes).

---

## Feature — Third tier "extra strong" (Pro-only top model, used sparingly) (code DONE — NEEDS deploy)

> 2026-05-31. SUPERSEDES the earlier "better model per tier" idea (too loose — auto-paid every call).
> Owner: pro everyday experience = SAME fast/strong models as free (the win is the bigger char cap);
> `extra` (gemini-2.5-pro) is a reserve used "only when really necessary", two ways: a tiny keyword-free
> whitelist + a manual "Go deeper" button. Server-verified (`accounts.pro`, reuses `isPro`) — free can't
> reach it. Owner constraint honoured: no keyword hardcoding; floor stays flash.

- [x] Client `AITier` gains `.extraStrong` (rawValue `"extra"` — wire contract). `AIAction.routing`:
      `findBugs`/`refactor` → `.extraStrong` (deep code reasoning); `explainCode` stays `.strong`.
- [x] Manual escalation: `sendTurn(forceTier:regenerate:)` re-answers the last turn forced to
      `.extraStrong` (drops stale assistant reply, no new user bubble). `RoutingPlan.with(tier:)` helper.
- [x] UI: "sparkles" icon button in the result icon bar, gated `provider is HostedProvider &&
      EntitlementStore.isPremiumUnlocked` (Pro + hosted only — BYOK has a fixed model, can't escalate).
- [x] Worker `pickModel(env, tier, isPro)`: `fast→flash-lite`, `strong→flash`, `extra→GEMINI_MODEL_EXTRA`
      (Pro) / `strong` (free degrade). Unknown tier → strong. `GEMINI_MODEL_EXTRA` optional → flash.
- [x] `wrangler.toml`: replaced `GEMINI_MODEL_PRO`/`_FAST_PRO` with `GEMINI_MODEL_EXTRA = "gemini-2.5-pro"`.
      App build green; `node --check` clean.
- [ ] **USER ACTION:** `cd worker && wrangler deploy` (same deploy as the content-cap change).
- [ ] **COST CHECK:** gemini-2.5-pro ≈ 4× flash / 12–25× flash-lite per token. It fires only on the
      whitelist + manual button, but confirm the sub covers it; comment out `GEMINI_MODEL_EXTRA` to disable.
- [x] **Manual test (Pro):** mark device pro + make `isPremiumUnlocked` true → sparkles button appears in
      result; tapping it re-answers on pro. findBugs/refactor auto-use pro; everything else stays flash.
- [ ] NOT changed: output-token ceilings shared across tiers; PDF 20-page cap shared.

---

## Feature — Pro tier content cap (2× chars for subscribers) (code DONE — NEEDS deploy + D1 migration)

> 2026-05-31. Pro/subscribers read twice as much of a file before the "analysed the first part only"
> truncation. Client free `maxChars = 12_000` → pro `maxCharsPro = 24_000`; Worker free
> `MAX_CONTENT_CHARS = 20000` → pro `MAX_CONTENT_CHARS_PRO = 40000`. Trust model: **server-verified**
> (`accounts.pro`), chosen over trusting a client hint — a modified client must not be able to double
> its own input spend.

- [x] Client `FileContentExtractor`: added `maxCharsPro`; `extract(from:limit:)` + `capped(_:limit:)`
      now take a cap. `buildMultiFileContent(…, charLimit:)` resolves it from
      `EntitlementStore.isPremiumUnlocked` (false today → free cap; flips to 24k when Pro unlocks).
- [x] Worker `wrangler.toml`: `MAX_CONTENT_CHARS` / `MAX_CONTENT_CHARS_PRO` vars (tunable, no deploy to change).
- [x] Worker `index.js`: `readLimits` reads both; `isProDevice(env, deviceId)` reads `accounts.pro`
      (server-trusted, try/catch-safe before migration, defaults free); content-size 413 uses the per-tier cap.
- [x] `schema.sql`: `accounts.pro` column for fresh DBs + ALTER migration comment for the live DB.
      App build green; `node --check` clean.
- [ ] **USER ACTION 1:** `cd worker && wrangler deploy`.
- [x] **USER ACTION 2 (one-time, existing DB):**
      `ALTER TABLE accounts ADD COLUMN pro INTEGER NOT NULL DEFAULT 0` — APPLIED.
- [ ] **To test the 40k path:** mark your device pro —
      `wrangler d1 execute aidrop --remote --command "UPDATE accounts SET pro=1 WHERE device_id='<id>'"` —
      and (client side) the 24k cap only activates once `EntitlementStore.isPremiumUnlocked` returns true.
- [ ] NOT changed: PDF 20-page cap is shared across tiers (only char caps differ, per request).

---

## Feature — Prompt caching of the document prefix (DONE — build green)

> Plan + impl 2026-05-31. `docs/HOW_LLM_IS_CHOSEN.md` §6 item 1 — "biggest real bill win after routing"
> for the multi-turn chat subset. We re-send the document every turn; cache it so follow-ups read it ~90%
> cheaper instead of paying full input price each time.

- [x] `ChatTurn` gains `cacheableDocument: String?` (defaulted) + `flattenedContent` (folds doc back into
      text byte-identically). `buildChatTurns` now puts the document on the FIRST user turn as that separate
      stable block instead of gluing it into the instruction string.
- [x] Anthropic: emits the doc as its own `{type:text, cache_control:{type:ephemeral}}` block, guarded by
      `cacheMinChars = 8000` (~Haiku's 2048-token cache minimum; below it the mark is a no-op).
- [x] OpenAI/Gemini: unchanged code — they auto-cache a stable leading prefix; `flattenedContent` keeps the
      first turn byte-identical across follow-ups so the prefix hits. Groq/Ollama: flatten only (no caching).
- [x] Hosted: folds doc via `flattenedContent` so the Worker still gets a stable cacheable prefix.
- Note: single-shot drops don't benefit (first turn pays ~25% cache-write premium, recovered on 1st follow-up).

---

## Feature — Per-action output ceilings / routing policy (DONE — build green)

> Plan + impl 2026-05-31. From `docs/HOW_LLM_IS_CHOSEN.md` (rewritten as an engineering spec).
> Owner priority: **minimise the operator's API bill first**; per-user caps are a relief valve.
> `max_tokens` is a CEILING not a target (you pay for tokens emitted), so this is a RUNAWAY
> GUARD, not the primary saving — the big levers (Worker model routing, prompt caching) come later.

- [x] New `AI/ModelRouting.swift`: `AITier{fast,strong}`, `AITaskClass`, `RoutingPlan{tier,
      taskClass,maxOutputTokens}`, `AIAction.routing` (static per-action plan), and
      `RoutingPlan.forCustomPrompt(_:)` (deterministic keyword/length heuristic, prompt text only,
      escalates typed prompts to `.strong` on evaluation/judgement signals).
- [x] Ceilings: tight for bounded output (summariseShort/altText 120; extract*/bullets 512),
      generous ~4096 where output ≈ input (translate*/rephrase*/addDocstring, OCR), mid for
      explain/findBugs/refactor 1024, freeform 1536, evaluation 2048.
- [x] `AIProvider.reply` → `reply(messages:imageURL:maxOutputTokens:)`; all 6 providers replace the
      hardcoded `4096`. Gemini keeps thinking headroom: `max(maxOutputTokens + 1024, 2048)` +
      `reasoning_effort: low`. Hosted forwards `max_tokens` so the Worker can cap the host model.
- [x] `sendTurn` computes the plan (`forCustomPrompt` for typed prompts, else `action.routing`) and
      passes `plan.maxOutputTokens`.
- [x] Fixed extension/app version mismatch warning (AddToAIDrop MARKETING_VERSION 1.0 → 0.9.8).
- [ ] NOT done (future, by ROI): Worker model routing (biggest lever, needs Worker live), prompt
      caching of the document prefix, image-only input trimming, validated escalation for extraction,
      usage instrumentation in normalised cost-credits.

---

## Feature — Conversation redesign + Gemini cutoff fix (v0.9.9, DONE — build green, manual test pending)

> Plan 2026-05-31. Make the result window a real multi-turn chat instead of a single result
> that restarts on every follow-up. Plus fix Gemini 2.5 Flash replies being cut off.
> Design confirmed: Restart (↻) = clear chat, keep file (→ suggested actions). User prompts =
> right-aligned bubbles; AI = full-width Markdown.

**Root causes**
- No conversation state: every chip/prompt calls `provider.complete(action:content:imageURL:)`,
  which rebuilds `[system, user(file)]` and REPLACES the single `.result(text)`. Hence "restart"
  + file re-sent + no transcript.
- Gemini cutoff: `GeminiProvider` `max_tokens: 1024`. 2.5-Flash thinking tokens eat that budget via
  the OpenAI-compat endpoint → `finish_reason: length` (the trailing bare `*`). Not parsing, not
  input context (1M).

**Plan**
- [x] Model: added `ChatRole`, `ChatMessage { role, display, modelText }`, `BaseContext`. VM gets
      `@Published conversation`, `@Published isAwaitingReply`, `var baseContext` (extracted once;
      invalidated by `additionalFileURLs.didSet`). `restartConversation(url:)` clears it → chips.
- [x] Clear `conversation` + `baseContext` + `isAwaitingReply` in `setChips`, `restartConversation`,
      `reset()`. `MinimizedSnapshot` carries `conversation` + `baseContext`; minimize gated on
      `!isAwaitingReply`; `applySnapshot` restores baseContext AFTER additionalFileURLs (didSet order).
- [x] Provider protocol: replaced `complete(...)` with `reply(messages: [ChatTurn], imageURL:)`.
      All 6 providers updated. Shared `openAICompatMessages(_:imageURL:attachImage:)` inlines the image
      into the first user turn (Groq/Ollama text-only → attachImage:false; OpenAI/Gemini true).
      Anthropic/Hosted split system turns into their own field.
- [x] Token fix: `max_tokens` 4096 across providers; Gemini also `reasoning_effort: "low"`.
- [x] Orchestrator: file-scope `sendTurn(provider:fileURL:action:typedPrompt:)` + `buildChatTurns` +
      `applyStage` in OverlayView. Optimistic user bubble; first/back-nav turn → `.loading`→`.result`,
      in-result follow-ups stay `.result` + inline `isAwaitingReply` thinking row. Error keeps the
      transcript (assistant ⚠️ note) unless it's the first turn (→ `.error`).
- [x] Rewired all 4 run sites (ChipsColumnView + TwoColumnView, action + custom) to `sendTurn`;
      removed both per-view `setStage` helpers.
- [x] UI: transcript ScrollViewReader (ForEach conversation → `ChatBubble`: right capsule for `.user`,
      full-width `MarkdownText` for `.assistant`) + `ThinkingRow` + auto-scroll to bottom.
- [x] Buttons: ↻ → `restartConversation` ("New conversation"). ← back unchanged (no convo clear).
- [x] History reopen rebuilds the full transcript from `SessionRecord.turns` (user+assistant per turn).
- [x] Resize: `.result` height from whole-transcript length, clamped 380–600.
- [ ] Manual test: multi-turn append (no restart), Gemini full replies, ↻ clears + keeps file,
      reopen-from-history shows transcript, minimize/restore mid-conversation.

---

## Feature — Multi-file drop + Finder "Add to AI Drop" Quick Action (v0.9.10, IN PROGRESS)

> Plan 2026-05-31. Two asks: (1) dragging MULTIPLE files drops them ALL into one session;
> (2) a Finder right-click "Add to AI Drop" that pops Stage 2 with the selected file(s).
> Decisions: right-click = a real Finder **Quick Action** (separate Action Extension target,
> top-level menu item). Files dropped/added onto an ALREADY-OPEN session keep the existing
> add/replace prompt, made batch-aware ("Add N files").

### Part 1 — Multi-file drop (self-contained, no new target) — ✅ DONE (build green, manual test pending)
- [x] `DroppableHostingView`: `extractURLs(from:)` (plural) + `cachedDropURLs: [URL]`; register reads all.
- [x] VM: migrate `pendingSecondFileURL: URL?` → `@Published pendingDroppedURLs: [URL]`; update all
      read sites (`isEmpty`) + write sites (`[]`). Add `setChips(urls: [URL])` — first supported = primary,
      rest supported = additionals; route unsupported-only to `.error`.
- [x] `performDragOperation`: fresh drop of N files → `setChips(urls:)`; active session → set
      `pendingDroppedURLs` (filtered to supported) for the banner.
- [x] `SecondFilePromptBanner`: batch-aware (header "N files", "Add N files to session"); `addToSession`
      appends all; `startNewSession` → `setChips(urls:)` with all.
- [ ] Manual test: drag 3 files → one session w/ 3 pills; drop 2 onto open session → "Add 2 files".

### Part 2 — Finder Quick Action extension (NEW TARGET — created in Xcode ✅)
> A macOS Action Extension (No-UI) that is a Finder Quick Action. SEPARATE, sandboxed process,
> so it hands the selected file URLs to the (non-sandboxed, always-on) main app.
> **IPC pivot (2026-05-31):** dropped the App Group plan — App Groups need dev-portal registration that
> a free/personal team can't do, which would dead-end the feature. Instead use a **named NSPasteboard**
> (`com.wallbrecher.MacNotchAI.share`) for the payload + a **Darwin notification** ping
> (`com.wallbrecher.MacNotchAI.addFiles`). Needs ZERO capabilities — works on any signing tier.
- [x] Extension target **AddToAIDrop** created in Xcode (No-UI Action Extension, embedded in MacNotchAI).
      Files in `AddToAIDrop/`: `ActionRequestHandler.swift` (reads `inputItems` → file URLs → writes the
      named pasteboard → posts Darwin ping → `completeRequest`; `ShareHandoff` writer inlined so the
      target needs only this ONE source file), `Info.plist` (NSExtension `com.apple.services`, principal
      class `$(PRODUCT_MODULE_NAME).ActionRequestHandler`, role Editor, Finder preview keys, activation
      rule `NSExtensionActivationSupportsFileWithMaxCount=100`). Sandbox + user-selected read-only come
      from build settings `ENABLE_APP_SANDBOX=YES` / `ENABLE_USER_SELECTED_FILES=readonly` (no physical
      entitlements file needed — the prepared `.entitlements` was deleted as redundant). Menu title set
      via `INFOPLIST_KEY_CFBundleDisplayName = "Add to AI Drop"`.
- [x] Main app side: `MacNotchAI/IPC/ShareInbox.swift` (`drain()` reads the named pasteboard);
      `AppDelegate.registerShareInboxObserver` (Darwin observer → posts `.addFilesFromShare`);
      `handleAddFilesFromShare` (drains + opens); `AppDelegate.openSessionWithFiles(_:)` (cancel dismiss →
      build/reuse window → `vm.setChips(urls:)` → size/place/order-front → `NSApp.activate`). Reuses the
      `restoreMinimizedSession` window bring-up pattern.
- [x] Full build green (main app + AddToAIDrop.appex compile, embed, codesign).
- [x] **Manual test:** run the app once (registers the extension with LaunchServices/pluginkit), then
      right-click file(s) in Finder ▸ **Quick Actions** (or the menu directly) ▸ **Add to AI Drop** → Stage 2
      pops with the selected file(s). If it doesn't appear: System Settings ▸ Login Items & Extensions ▸
      enable it under Finder/Quick Actions; `pkill Finder` (or re-login) refreshes the menu.

---

## ✅ Decision 0 — SETTLED: Path A (Developer ID + notarization)

**Chosen 2026-05-29: Path A.** Distribute as a notarized, signed direct download (NOT the Mac App
Store). Keep the entire architecture as-is — global `NSEvent` drag/keyboard monitoring + Accessibility
permission stay. This is what Raycast, CleanShot, Bartender, Rectangle Pro do.

What this decision means for the rest of the plan:
- **No App Sandbox** — the sandbox/MAS rejection risk is off the table. The core drag UX is preserved.
- **Payments = Paddle / Stripe / RevenueCat (NOT StoreKit).** External payment is allowed for
  direct-download apps, so the metering proxy + subscription can use any processor.
- **"App Store goal" → polished signed DMG + auto-update** (Sparkle later).
- **Deployment target** can be lowered freely (no MAS constraint) — still worth doing for audience
  reach (see review item: 26.0 → 14/15 with `@available` guards).

~~Path B — sandboxed MAS build~~ (rejected: would require re-architecting invocation away from global
drag detection; loses the "pill appears while you drag" UX).
~~Path C — both~~ (rejected: two codepaths to maintain).

---

## Phase 1 — UI polish (no backend, safe to start now)

### 1a. Calmer animations
- [ ] Reduce jelly wobble: `OverlayViewModel.stopJellyHover` dampingFraction 0.44 → ~0.8 (less
      oscillation), shrink hover scale 1.12 → ~1.05. Keep a subtle "alive" cue, drop the bounce.
- [ ] Soften entry spring in `OverlayView` (`scaleEffect`…`value: appeared`): dampingFraction
      0.58 → ~0.8; review the `handoffProviderName` fade-out spring (0.52) similarly.
- [ ] Audit the spring set across `OverlayView` for consistency; consider one shared "calm" spring
      constant instead of ~10 bespoke ones.
- [ ] Optional: respect **Reduce Motion** (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`)
      — Apple reviewers and users expect this; swap springs for quick fades when on.

### 1b. Movable window (origin stays at the notch)
- [ ] Add a thin centered "grabber" line at the top of the card (collapsed → expands on hover/drag).
- [ ] Make the panel draggable from that handle only (`NSWindow.performDrag` or a drag gesture →
      `setFrameOrigin`). Do **not** enable `isMovableByWindowBackground` (would hijack file drags).
- [ ] Persist the manual offset for the session; **reset to the notch anchor** on each new drop so the
      default origin is unchanged. Note: `resizeOverlay`/`handleScreenParametersChanged` currently
      recompute origin from the notch every stage change — moving must coexist with that (store a
      user-offset and apply it after `notchFrame`).

---

## Phase 2 — Monetization backend (the real work)

The "cost is on me, first 30 free" model **cannot ship an embedded API key** — it would be extracted
from the bundle in minutes. This requires a metering proxy that holds the key server-side and enforces
quota there (the client counter is display-only and trivially reset by reinstall).

> **Plan written 2026-05-29. Core decisions settled (below). Paddle + the live proxy are deferred —
> the near-term work is client-side: lock premium in the UI behind placeholders we paste in later.**

### Decisions — settled 2026-05-29

- [x] **DECIDED: Proxy host → Cloudflare Worker + D1.** Serverless, global edge, ~free at our
      scale (100k req/day free), provider key as an encrypted Worker secret, no server to patch. State
      in **D1** (SQLite) for accounts + usage rows; **Durable Object** only if we need strictly atomic
      per-device counters. Alternative — a small VPS — means we own patching, TLS, uptime for no benefit
      at this scale. *Reason to confirm: picks the whole 2a toolchain (wrangler/D1 vs Docker/Postgres).*
- [x] **DECIDED: Identity → App Attest + DeviceCheck (anonymous free tier).**
      App Attest proves each request comes from a genuine, unmodified build of our app (blocks scripted
      key-draining). DeviceCheck's 2 persistent bits survive reinstall, so "free trial consumed" can't be
      reset by deleting the app. **Sign in with Apple is deferred to subscription time only** (paid users
      need a durable cross-device account; free users stay anonymous). *Reason to confirm: App Attest
      needs the `com.apple.developer.devicecheck.appattest-environment` entitlement + key registration;
      adding SIWA up front would add a login wall to the free flow we may not want.*
- [x] **DECIDED: Payments → Paddle Billing — but SETUP DEFERRED.** Build the UI lock + API/config
      placeholders now; wire the real Paddle checkout later in a focused session. Paddle is a
      **Merchant of Record** — it handles global VAT/sales-tax registration and remittance, which a solo
      dev otherwise cannot do compliantly worldwide. Subscriptions + webhooks built in. RevenueCat is
      StoreKit-first; its non-IAP/Stripe path adds a vendor without removing the tax-compliance burden.
      *Reason to confirm: picks the webhook contract + checkout flow in 2c, and the MoR choice is hard to
      reverse once customers exist.*
- [x] **DECIDED: "30 free" = one-time trial of 30 hosted calls, then the free tier (10/day).** Server
      config holds `{ trialTotal: 30, freeDailyCap: 10, paidDailyCap: 20 }` so the numbers are tunable
      without a client release.

### 2.0 — DO NOW: lock premium in the UI + paste-later placeholders (no backend, no Paddle)

Goal: ship the Pro/premium surface *visibly locked* today, with all the wiring points stubbed so that
later we only paste in a proxy URL + Paddle URL and flip on the real checks. Nothing here makes a
network call — it's pure client scaffolding.

- [ ] **`BackendConfig` (Core/)** — one file holding the paste-later values, all `nil`/empty for now
      with clear `// TODO: paste after backend setup` markers:
      `proxyBaseURL: URL?`, `paddleCheckoutURL: URL?`, `appAttestKeyId: String?`.
      `var isBackendLive: Bool { proxyBaseURL != nil }` (false today → everything stays in BYOK mode).
- [ ] **`EntitlementStore` (Models/, `@MainActor ObservableObject`)** — the single source of truth for
      what's unlocked. `enum Tier { case byok, freeHosted, pro }`; `@Published var tier: Tier = .byok`;
      `var isPremiumUnlocked: Bool` (hard-coded `false` until backend is live). Stub methods that are
      safe no-ops today: `refreshEntitlement()` and `startUpgrade()` (the latter opens
      `paddleCheckoutURL` if set, else shows the "coming soon" state).
- [ ] **Two-version split in `OnboardingView`** — a top-level choice between the two ways to use the app:
      **AI Drop Free** (hosted, no key, metered — shown LOCKED / "Coming soon" until `isBackendLive`) and
      **Bring your own key** (the existing provider picker + key field — works today, default selection).
      Free is non-selectable while locked, so BYOK stays the only functional path = zero regression.
- [ ] **Locked "Pro" section in `MenuBarView`** — show the upgrade card with a lock badge, the planned
      perks ("hosted · no API key · more per day"), and a **disabled "Upgrade — coming soon"** button
      (enabled automatically once `isBackendLive`). Respects `uiScale` + `.liquidGlass`.
- [ ] **Build + verify** — app still launches in pure BYOK mode, Free/Pro show as locked/coming-soon,
      nothing attempts a network call. (No behaviour regression for existing BYOK users.)

> **Overlay limit-reached / upsell state is DEFERRED with the live backend** — it can't be reached until
> hosted metering exists, and the overlay stage machine is crash-sensitive (see Critical invariants).
> Build it alongside `HostedProvider` in 2b, not in this client-only slice.

### 2a. Proxy service (Cloudflare Worker)

- [ ] **Endpoints.**
      `POST /v1/complete` → `{ action, content, image?, requestedTier }` → forwards to the real model,
      returns `{ text, truncated, usage: { remaining, resetAt, tier } }`.
      `GET  /v1/usage` → `{ remaining, resetAt, tier, trialRemaining }` for launch sync.
      `POST /v1/attest/register` → one-time App Attest key registration (returns server account id).
      `POST /webhooks/paddle` → entitlement updates (signature-verified).
- [ ] **Auth.** App Attest: register the device key once (`/attest/register`), then send a per-request
      **assertion** the Worker verifies against Apple's root + the stored public key (replay-guarded by a
      monotonic counter). Issue a short-lived bearer (signed JWT, ~15 min) after a valid assertion so not
      every call re-verifies attestation. Bearer carries the opaque `accountId`.
- [ ] **Metering (server = source of truth).** D1 schema sketch:
      `accounts(id PK, deviceHash, createdAt, tier, trialUsed, subStatus, subExpiry, paddleCustomerId)`
      and `usage(accountId, day, count)`. On `/complete`: look up tier → cap, check `trialUsed`/today's
      `count`, **reject with 429 before forwarding** if over, else forward, then increment in the same
      transaction. Daily counter keyed by **UTC day**; client shows local-midnight reset (note skew).
- [ ] **Model routing by tier.** `free`/trial → **Gemini 2.5 Flash** (chosen by owner: cheapest + fast
      with fair reasoning; host key = `GEMINI_API_KEY` Worker secret). `paid` → a stronger model
      (Claude Haiku 4.5 / GPT-4o-mini — decide at build time). Keys held only as Worker secrets, never
      in the app bundle. Map our `AIAction` → server-side prompt templates so they're tunable without a
      client release.
- [ ] **Images (vision).** Accept base64 inline in `image` for files under ~4 MB (Worker body limits);
      reject larger with a clear error → client falls back to "too large for hosted, use BYOK/local".
      Forward as the provider's image part. **Never write image bytes to storage.**
- [ ] **Abuse + cost protection.** Per-account rate limit (e.g. burst 5/min) **and** a global daily spend
      circuit-breaker (hard stop if total calls exceed a budgeted ceiling, so a bug/abuse can't drain the
      account). Reject oversized `content` early (client already caps extraction at 12k chars — enforce
      server-side too). Log **only** counters + hashed device id + status codes — **no file content, no
      prompts, no completions** (this is the privacy commitment reviewers will ask about; see Security).
- [ ] **Secrets/ops.** Provider keys + Paddle webhook secret via `wrangler secret`. Staging vs prod
      Workers. App Attest in **development** env until release, then **production**.

### 2b. Client integration

- [ ] **`HostedProvider: AIProvider`** — new impl of `complete(action:content:imageURL:)` that POSTs to
      `/v1/complete` with the bearer token instead of calling a vendor. Lives in `AI/`. On HTTP 429 it
      throws a typed `HostedError.limitReached(tier:resetAt:)` so the UI can branch (vs a generic error).
- [ ] **`resolveProvider()` wiring** (`AppDelegate.swift`) — when `selectedProvider == .hosted` (new
      `AIProviderType` case) return `HostedProvider`; BYOK cases unchanged. BYOK path **never** touches
      the proxy (Phase 3: BYOK = Pro for free).
- [ ] **Attestation client** — small `AppAttestManager` (Core/): generate/persist the App Attest key in
      Keychain, register once, mint assertions, refresh the bearer. Gracefully degrade if App Attest is
      unavailable (older HW/VM) → fall back to "BYOK required" rather than crashing.
- [ ] **Usage model** — `UsageStore` (ObservableObject): mirror `{ remaining, resetAt, tier }` in
      UserDefaults for instant display; refresh from `/v1/usage` on launch and after every `/complete`
      response (the response already carries fresh `usage`). Server is source of truth; local mirror is
      only to avoid a blank bar on launch.

### 2c. Usage UI

- [ ] **Usage bar in `MenuBarView`** — top row: "X of 30 free left" (trial) / "X of 10 today" (free) /
      "Pro — 20/day" (paid), driven by `UsageStore`. Respects `uiScale` + `.liquidGlass` conventions.
- [ ] **Limit-reached overlay state** — new branch when `HostedError.limitReached` is thrown: a calm
      stage offering **Subscribe** (opens Paddle checkout in browser) and **Use my own key** (jumps to
      onboarding/settings BYOK). No dead end. Shows `resetAt` ("resets in 6h").

### 2d. Payments (Paddle — Path A, no StoreKit)

- [ ] **Checkout** — "Subscribe" opens a Paddle-hosted checkout URL in the default browser
      (external payment is permitted for direct-download apps; StoreKit not used).
- [ ] **Linking device → subscription** — free tier is anonymous, but a subscription needs a durable
      account. At checkout, collect email (Paddle does this); webhook stores `paddleCustomerId` +
      `subStatus` on a server account. The app links its device to that account via a one-time
      **license code** (issued post-purchase, pasted into Settings) **or** Sign in with Apple at
      subscribe time — pick during the **[CONFIRM]** identity decision above.
- [ ] **Entitlement** — `POST /webhooks/paddle` (signature-verified) updates `subStatus`/`subExpiry`;
      `/v1/usage` returns the resolved tier. Client caches entitlement locally for offline launch but
      **re-validates on every launch** (source of truth = proxy, fed by Paddle webhooks).

### 2e. Privacy / compliance follow-through (gates submission)

- [ ] Document exactly what the proxy logs/retains (counters + hashed id only; **no content**) — needed
      for the privacy nutrition label and user trust (we become the data processor for hosted calls).
- [ ] Update the in-app privacy disclosure + README: hosted calls route file content through our proxy
      to the model vendor; BYOK calls go direct to the user's chosen vendor.

---

## Phase 3 — Tier model (after Phase 2 lands)

Target tiers from the owner:
- [ ] **BYOK** → unlocks all Pro features for free (user pays their own vendor; we pay nothing).
- [ ] **Free (hosted)** → "weak models" only, **10/day** cap.
- [ ] **Subscription (~$1/mo)** → **20/day** cap, better models.
- [ ] Central entitlement resolver: `tier → {allowedModels, dailyCap}`; gate `complete()` on it.
- [ ] Daily counters reset at local midnight; enforced server-side for hosted tiers.

---

## Review — findings from a full read of the codebase

### Architecture (overall: strong)
- Clean single-source-of-truth (`OverlayViewModel`) + Combine resize loop. The crash-avoidance
  invariants are documented in `CLAUDE.md` and real — keep honoring them.
- **Refactor candidates:** `OverlayView.swift` is 1,557 lines — split per stage (Pill / Chips /
  TwoColumn / shared subviews) into separate files. `AppDelegate` (657 lines) mixes lifecycle, drag
  observation, window sizing, and dialogs — extract an `OverlayController`.
- `runAction`/`runCustomPrompt`/`setStage` are duplicated between `ChipsColumnView` and `TwoColumnView`
  — hoist into the view model.

### Battery efficiency (overall: fine, one always-on cost)
- The only persistent cost is the global `.leftMouseDragged` monitor. It does minimal work per event
  (changeCount compare + early return), so it's acceptable — but it fires on *every* mouse-drag
  system-wide. Verify in Instruments it's not waking the app excessively during long drags.
- ✅ Poll timers (`0.10s` drag poll, `0.05s` drag-out poll) only run *during* a drag — good, no idle drain.
- [ ] `prewarmSwiftUI` holds a hidden window 2s at launch — negligible, leave it.
- [ ] `VisualEffectBlur` uses `.active` + `isEmphasized` continuously while the overlay is visible
      (GPU compositing). Fine while open; confirm it's torn down on hide (it is — window orderOut).
- [ ] Consider pausing the global monitor while the pill is disabled ("Disable for…") to save the
      per-event cost entirely during pauses.

### Bugs / edge cases
- [x] **DOCX broken but advertised** — FIXED. `FileContentExtractor` now decodes DOCX/DOC/RTF via
      `NSAttributedString` (Cocoa text system reads Office Open XML natively, on the main actor). No
      third-party zip lib needed.
- [x] **Non-UTF-8 text/RTF** — FIXED. RTF now goes through the rich-text path; plain text/code uses an
      encoding-detecting read (`String(contentsOf:usedEncoding:)`) with Latin-1 + lossy UTF-8 fallback.
- [x] **Silent truncation** — FIXED. `extract` returns `(text, truncated)`; oversized sources (12k chars
      / 20 PDF pages) set `vm.contentTruncated`, which renders a "Large file — analysed the first part
      only" hint under the result.
- [x] **Hotkey gate unwired** — FIXED. `DragMonitor.handleDrag` now gates pill appearance on
      `HotkeyManager.shared.isHotkeyHeld()` (no-op when nothing is configured).
- [x] **Mic permission** — confirmed resolved on the current build (SpeechRecognizer uses
      `AVCaptureDevice` for status + request per lessons MIC-05; all MIC lessons are closed).
- [ ] **Deployment target 26.0 → 14/15 — DEFERRED (own task, needs multi-OS testing).** No
      macOS-26-only APIs are used in the UI, BUT the mic TCC logic is version-sensitive: the code uses
      `AVCaptureDevice` (correct on 26 per MIC-05) while MIC-04 says macOS 14/15 need `AVAudioApplication`.
      Lowering the target without `if #available(macOS 26, *)` branching risks breaking dictation on
      older OSes — and that can't be verified on this machine (macOS 26). Do this as a focused change
      with access to a 14/15 test machine or VM.

### Security / privacy (matters for App Store review)
- ✅ API keys in Keychain, not UserDefaults. ✅ Files read only on explicit action (no speculative upload).
- [ ] **Privacy nutrition label** required: the app reads user files and sends contents to third-party
      AI APIs. Must be disclosed accurately (data types, third parties) or Apple rejects.
- [ ] When the hosted proxy ships, document what the proxy logs/retains — reviewers will ask, and it's
      a genuine user-trust issue (you'd be the data processor).
- [ ] `HandoffManager` writes file contents + AI output to the general clipboard — fine, but worth a
      one-line disclosure.
- [ ] No `App Transport Security` exception needed (all vendor endpoints are HTTPS); the Ollama
      `http://localhost` path will need an ATS localhost exception if ever sandboxed.

### What an Apple reviewer will flag
1. **Sandbox** — see Decision 0. The #1 rejection risk for MAS.
2. **Accessibility permission usage** — must have a precise, honest purpose string; reviewers test that
   the app degrades gracefully if denied (right now drag detection just silently won't work).
3. **Purpose strings** — `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` must be
   present and specific (dictation in the prompt field).
4. **`LSUIElement` menu-bar app** — fine, but must have a visible way to quit + access settings (it does).
5. **Functional completeness** — broken DOCX / silent truncation could read as "doesn't work as
   advertised." Fix before submission.
6. **Deployment target macOS 26.0** — drastically limits the audience and looks like a misconfig.
   Lower to macOS 14/15 with `@available` guards for the broadest store reach.
7. **Payments** — if any paid feature exists in a MAS build, it must use StoreKit IAP (external payment
   links are restricted). This is another reason Decision 0 comes first.

---

## Suggested sequence
1. **Decide Path A / B / C** (Decision 0).
2. Phase 1 UI polish — independent, ships value immediately, no backend.
3. Fix the review bugs (DOCX, RTF/encoding, truncation hint, hotkey wiring, deployment target).
4. Phase 2 proxy + usage UI.
5. Phase 3 tiers + payments per chosen path.
6. Privacy labels, purpose strings, notarization/submission.

---

## Feature — Tabbed prompt section (Suggested / History / Custom)

> Confirmed scope (2026-05-30): **Stage 2 only** (the freshly-dropped-file chips card,
> `ChipsColumnView`). The stage-3 result view's "Suggested" rail is left untouched.
> **History records typed prompts only** (the free-text questions you run); tapping one re-runs it
> against the current file as a freeform query.

**Goal:** replace the single "Suggested" label + chip list in `ChipsColumnView` with a 3-tab switcher:
- **Suggested** — icon `sparkles.2` — current `FileInspector.suggestedActions(for:)` chips (default tab).
- **History** — icon `list.bullet` — auto-saved typed prompts, most-recent first, tap to re-run.
- **Custom** — icon `slider.vertical.3` — user-curated saved prompts + a `+` row to add inline.

Both History and Custom entries are plain strings; tapping either runs `runCustomPrompt`-style freeform.
History + Custom lists persist locally (UserDefaults string arrays). Custom prompts are also
managed in **Settings → Custom Prompts** (add / delete).

### Window-sizing approach (critical — fixed CGSize per stage)
The chips window height is computed in `AppDelegate.resizeOverlay` from the suggested-action count.
With tabs the visible row count changes per tab → the height must follow.
- Add `@Published var chipsTab` to the VM; `AppDelegate.observe…` subscribes to it (alongside
  `$isChipsExpanded`) and re-runs `resizeOverlay`.
- The tab content lives in a **capped** region: `min(rowCount, 5) × rowHeight`, internal `ScrollView`
  beyond that → window never grows unbounded, mirrors the result-card pattern.
- Empty tabs (e.g. Custom with 0 entries) render a fixed ~1-row placeholder so height is well-defined.
- Resize stays instant (`setFrame display:false`); tab-content swap animates with `easeInOut`/opacity
  (no spring → no Y-bounce, per ANIM-02).

### Steps
- [x] **`Models/PromptStore.swift` (new)** — `@MainActor final class PromptStore: ObservableObject`,
      `static let shared`. `@Published private(set) history: [String]` (cap 20, dedup, most-recent-first),
      `@Published private(set) customPrompts: [String]`. Persist via `UserDefaults` keys `prompt.history`,
      `prompt.custom` (native `[String]`). Methods: `recordHistory(_:)`, `addCustom(_:)`,
      `removeCustom(_:)`, `removeCustom(at:)`, `clearHistory()`. Auto-included via file-system-synced group.
- [x] **`OverlayViewModel`** — added `enum ChipsTab { suggested, history, custom }` +
      `@Published var chipsTab`. Reset to `.suggested` in `setChips()` and `reset()`. Added shared
      `ChipsLayout` geometry helper (rowStride/spacing/tabBarHeight + `contentHeight(rows:)` +
      `rows(for:suggested:history:custom:)`) so view + AppDelegate agree on height.
- [x] **`OverlayView` `ChipsColumnView`** — replaced `Text("Suggested") + chips` with `chipsTabBar`
      (3 icon buttons: sparkles.2 / list.bullet / slider.vertical.3, selected highlight) + `chipsTabContent`
      (fixed-height capped `ScrollView`). Suggested = `ActionChip` ForEach → `runAction`. History/Custom =
      ForEach over store strings → `runCustomPromptText`. Custom has inline `+` add row (auto-focused
      `TextField`). Tab swap on `.easeInOut(0.28)`.
- [x] **Factored `runCustomPromptText(_:)`** out of `runCustomPrompt()`; `recordHistory` called on every
      freeform run (typed or re-run, both stage-2 and stage-3 prompt fields).
- [x] **`AppDelegate`** — `observeChipsTab()` subscribes to `$chipsTab` + `PromptStore.$customPrompts` +
      `$history`; `.chips` case sizes height from the active tab's `ChipsLayout.rows(...)`, capped at 5.
- [x] **`SettingsView`** — "Custom Prompts" `Section`: lists `customPrompts` with per-row trash delete +
      add `TextField`/button. `@ObservedObject` the store.
- [x] **Build** — `BUILD SUCCEEDED`, no errors/unused warnings.
- [x] **`sparkles.2` SF Symbol verified present** (along with list.bullet / slider.vertical.3) via
      `NSImage(systemSymbolName:)` — renders fine, no blank-icon fallback needed.
- [x] **Manual test (user)**: drop a file → switch tabs (clean resize, no Y-jump) → run a typed prompt
      → it shows in History → add a Custom prompt via `+` and via Settings → both persist across relaunch
      → tap a History/Custom entry → re-runs.
- [ ] **Capture lesson** if any correction needed (esp. window-resize-on-tab-switch behaviour).

### Open/again-later
- Stage-3 result-view "Suggested" rail intentionally NOT tabbed (scope-limited). Revisit if wanted.
- Per-entry delete in the History tab (swipe/×) — out of scope unless requested; `clearHistory()` only.

---

## Feature — Minimize / restore overlay (v9.6)

**Goal:** A `−` button next to `×` minimizes the overlay (squish into notch, hide). Clicking the
menu-bar icon restores the minimized session. If nothing is minimized, the icon opens the menu as
normal (no empty overlay pops open).

**Design decision (confirm):** the menu-bar icon currently uses SwiftUI `MenuBarExtra`, which always
opens its menu on click — cannot intercept. To make a left-click *restore*, replace `MenuBarExtra`
with a custom `NSStatusItem` in `AppDelegate` whose button action is conditional:
- **left-click**: minimized session exists → restore; else → toggle the menu popover.
- **right-click**: always toggle the menu popover (so Settings/Quit stay reachable while minimized).
The menu content (`MenuBarView`) is hosted in an `NSPopover` (`.transient`). App stays a menu-bar
agent (`LSUIElement = YES`), `Settings` scene unchanged.

### Steps
- [x] **`OverlayViewModel`** — added `@Published var hasMinimizedSession`, `MinimizedSnapshot` struct +
      private `minimizedSnapshot`. `minimizeCurrentSession() -> Bool` (no-op at waitingForDrop),
      `consumeMinimizedSnapshot()`, `applySnapshot(_:)` (sets `stage` last). Snapshot cleared in
      `setChips()`; **preserved through `reset()`** so minimize→hideOverlay→reset keeps it.
- [x] **`MinimizeButton`** (OverlayView) — mirrors `CloseButton`, SF `minus`, neutral
      `.liquidGlassCircle`. Posts `.minimizeOverlay`. Placed before `CloseButton` in the stage-3 icon
      bar (always) and the chips/error header. **Gated to tag 1 (chips) + 4 (error)** — excluded from
      loading (2) so an in-flight request can't complete into a hidden, reset stage.
- [x] **`AppDelegate`** — `.minimizeOverlay` Notification + handler. `minimizeOverlay()` snapshots then
      reuses `hideOverlay()`. `restoreMinimizedSession()` builds/reuses window, `applySnapshot`, sizes
      via new `sizeForStage(_:)` (factored out of `resizeOverlay`), `place` + orderFront + monitors.
- [x] **Replaced `MenuBarExtra`** with `NSStatusItem` (sparkles template) + transient `NSPopover`
      hosting `MenuBarView`. `sendAction(on: [.leftMouseUp, .rightMouseUp])`; left→restore-or-menu,
      right/ctrl→menu. Popover rebuilt per open (fresh dynamic labels). `MacNotchAIApp` keeps only
      `Settings`.
- [x] **`MenuBarView`** — `openSettings()` → `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`.
- [x] **Build** — `BUILD SUCCEEDED`, no errors/unused warnings.
- [x] **Manual test (user)**: minimize from chips/result → squish to notch, hides → drag a new file
      still pops the pill → click icon restores exact session (stage, tab, expand state, position) →
      with nothing minimized, icon opens the menu (no empty overlay) → right-click opens menu while
      minimized → Settings… opens from the popover.
- [x] **Lesson** captured (MENU-01): MenuBarExtra → NSStatusItem for conditional click; openSettings
      from an NSPopover.

---

## Feature — File tools (modify session documents) (v9.7)

**Goal:** Beyond AI actions, let the user *modify the actual files* held in the session. First cut
(chosen by owner): **Show in Finder · Rename · Move to… · PDF → .txt · Stitch PDFs · Image resize /
compress**. Media (video/audio) compression is a **later phase** (AVFoundation + optional
user-installed ffmpeg; FileInspector's unsupported gate must relax then).

**Constraints / decisions already settled:**
- **Pure Apple frameworks only.** FileManager (rename/move), `NSWorkspace.activateFileViewerSelecting`
  (reveal), `NSOpenPanel` (folder pick), PDFKit (text export + merge pages), ImageIO/CoreImage (resize
  + recompress). **No ffmpeg bundled** (size + GPL/LGPL + hardened-runtime signing). ffmpeg, when the
  media phase arrives, is *detected* if the user installed it (`/opt/homebrew/bin`, `/usr/local/bin`),
  never shipped.
- **Output policy: write next to the source** with a suffix + dedupe (`name-stitched.pdf`,
  `name.txt`, `name-1024.jpg`). Minimizes TCC prompts (non-sandboxed, but first writes to
  Desktop/Documents/Downloads can still prompt). Rename/Move are in-place moves of the original.
- **Session URL remap.** Rename/Move change the file's URL — the live session must follow it. Add
  `OverlayViewModel.remapSessionURL(from:to:)` to patch `stage`'s primary URL + `additionalFileURLs`
  (and the minimized snapshot if present).

### Open question for owner — UI surface (confirm before building)
Where do the file tools live? Proposed **A**; B/C are alternatives.
- **A (recommended): `•••` button on the file pill.** A small ellipsis-circle in `SingleFilePill` /
  `FilePill` opens a SwiftUI `Menu` of type-gated `FileTool` items. Per-file, discoverable, no new
  tab. Stitch PDFs appears only when ≥2 PDFs are in the session.
- **B: a 4th "Tools" tab** beside Suggested/History/Custom. More room for options but mixes
  file-mutation with AI-prompt UI and isn't per-file.
- **C: right-click `.contextMenu` on the pill.** Zero chrome, but undiscoverable on macOS.

### Steps (first cut)
- [x] **`Core/FileTools.swift`** (engine; static, throwing). Funcs: `revealInFinder(_ urls:)`,
      `rename(_ url:to:) -> URL` (extension preserved), `move(_ url:to folder:) -> URL`,
      `exportPDFText(_ url:) -> URL` (PDFKit page `.string` join), `stitchPDFs(_ urls:) -> URL`
      (new `PDFDocument` + `insert(page.copy(),at:)`), `resizeAndRecompressImage(_ url:,maxDimension:,
      quality:) -> URL` (`CGImageSource` thumbnail downscale → `CGImageDestination` JPEG), private
      `uniqueDestination(_:allowSame:)` (dedupe `-1`,`-2`). `FileToolError: LocalizedError`.
- [x] **`FileTool` enum + type-gating.** `static func tools(for:sessionFiles:) -> [FileTool]`:
      Reveal/Rename/Move always; +Export.txt and (Stitch when ≥2 session PDFs) for `.pdf`;
      +Resize/Compress for images. Each case → SF symbol + title.
- [x] **`UI/FileToolsMenu.swift`** — `FileToolsButton` (••• `Menu`, glass-circle default + `compact`
      dark-badge variant). Dialogs via **AppKit** (proven from the floating panel; SwiftUI `.alert`
      can fail to find a key window here): rename = `NSAlert` + `NSTextField`; move = `NSOpenPanel`
      (`canChooseDirectories`); image = `NSAlert` w/ `NSPopUpButton` size presets + `NSSlider`
      quality. **Errors = `NSAlert`.**
- [x] **Confirmation = native, not an in-app banner** (deviation from the draft — avoids overflowing
      `sizeForStage`'s fixed window height / fighting the resize loop): new outputs (pdf→txt, stitch,
      image) are **revealed in Finder**; rename updates the pill live via `remapSessionURL`; move
      remaps **and** reveals.
- [x] **`OverlayViewModel.remapSessionURL(from:to:)`** — patches the live stage (recomputing chip
      actions), `additionalFileURLs`, `cachedResult`, and the parked minimized snapshot.
- [x] **Wired into pills** — `SingleFilePill` (••• next to Share, always visible) and multi-file
      `FilePill` (compact ••• top-leading hover badge, mirroring the × badge).
- [x] **Errors** — guarded (missing file, unreadable/empty PDF, unreadable image, <2 PDFs, write
      failure); surfaced via `NSAlert`, no silent catch.
- [x] **Build** — `BUILD SUCCEEDED`.
- [x] **Manual test (user)** — reveal opens Finder w/ file selected; rename updates pill + session
      (AI action still targets the renamed file); move relocates + remaps; PDF→txt writes sibling
      `.txt` + Reveal works; stitch merges 2+ PDFs in pill order; image resize/compress writes smaller
      sibling; output dedupe doesn't clobber; banner + Reveal correct.
- [ ] **Lesson** — capture any TCC/PDFKit/ImageIO/remap gotchas in `tasks/lessons.md`.

### Deferred (not in first cut)
- [ ] **Erase Metadata** (EXIF/GPS strip for images via ImageIO; PDF `documentAttributes` scrub).
- [ ] **PDF → .md** (likely AI-assisted, not a pure extraction).
- [ ] **Media compress / change resolution** (`AVAssetExportSession`; optional installed-ffmpeg
      detection). Requires relaxing `FileInspector` unsupported-type gate for video/audio.

---

## Feature — Session history (last 10 sessions) (v9.8)

**Goal:** remember the last 10 sessions (file + full AI conversation) and list them in a
"Recent Sessions" submenu of the menu-bar dropdown, styled like the screenshot (file icon +
name + date rows, "Clear History" footer, ⌥ to remove one). Clicking a row **reopens the full
session** in the overlay (restore latest result, one-level back to the prior turn).

**Design decisions (confirmed):** reopen full session · store ALL turns / restore latest ·
menu-bar submenu (native NSMenu, matches screenshot).

- [x] **`Models/SessionHistoryStore.swift`** (new, `@MainActor` `ObservableObject` singleton)
  - `SessionTurn: Codable` = `{ actionRaw: String, promptTitle: String, resultText: String, date: Date }`
    (`promptTitle` = typed question for freeform, else the action's title).
  - `SessionRecord: Codable, Identifiable` = `{ id: UUID, primaryPath, additionalPaths: [String],
    turns: [SessionTurn], updatedAt: Date }` + derived `fileName` / `fileURL`.
  - `@Published private(set) var sessions: [SessionRecord]` (newest first, cap 10).
  - Persist to JSON at `Application Support/<bundleID>/session_history.json` (conversation text is
    too big for UserDefaults). Load on init; save after each mutation.
  - `beginSession(primary:)` — set a fresh `pendingSessionID` (no record persisted until 1st turn,
    so a dropped-but-unused file never clutters history).
  - `recordTurn(primary:additional:action:prompt:result:)` — locate/create the pending record,
    append the turn, refresh paths, bump `updatedAt`, move to front, trim to 10, save.
  - `remove(id:)` / `clear()`.
- [x] **Record turns** — hooked all four result sites (`ChipsColumnView` + `TwoColumnView`,
      `runAction` + `runCustomPrompt`): after the AI `text` is obtained, `recordTurn(...)`
      (prompt = typed text for freeform, nil otherwise). Errors are NOT recorded.
- [x] **Begin session** — `beginSession(primary:)` in `OverlayViewModel.setChips(url:)`; paths
      kept fresh on rename/move via `remapPath(from:to:)` in `remapSessionURL`. Reopen continues
      the same record via `resumeSession(id:)` so further actions append (no duplicate).
- [x] **Menu UI** (`AppDelegate.buildStatusMenu`) — "Recent Sessions" item with `.submenu`:
      each record = `NSWorkspace.shared.icon(forFile:)` (32px) + 2-line `attributedTitle`
      (name `labelColor` / `dd.MM.yy, HH:mm` `secondaryLabelColor` — adapts to light/dark).
      `representedObject` = record id; action `menuOpenHistorySession(_:)`. Per row an `isAlternate`
      ⌥ item (red "Remove …") → `menuRemoveHistorySession(_:)`. Footer: separator + "Clear History"
      (`menuClearHistory`) + disabled "Hold ⌥ to remove a single session". Empty → "No recent sessions".
- [x] **Reopen** (`AppDelegate.menuOpenHistorySession`) — builds a `MinimizedSnapshot`
      (`stage = .result(primary, lastAction, lastText)`, `cachedResult` = prior turn if any,
      `additionalFileURLs` = existing added files), injects via `vm.stageMinimized(_:)`, then
      calls `restoreMinimizedSession()`. Missing file → still shows the saved text (fallback).
- [x] **Build** — `BUILD SUCCEEDED`.
- [x] **Manual test (user)** — run actions on a file → session appears in submenu w/ icon + date;
      run a 2nd action → same session updates (not duplicated); new drop → new entry; >10 sessions
      trims oldest; click reopens overlay w/ latest result + back-arrow to prior; ⌥ shows per-row
      remove; Clear History empties; survives app relaunch.
- [ ] **Lesson** — capture any NSMenu attributedTitle/alternate-item or AppSupport-IO gotchas.

---

## Website — External file-type toggle for AI Drop hero (PLANNED)

**Goal:** move the mock Notch's internal file-type tabs out of the card and render them as a segmented
toggle above the AI Drop demo. The toggle labels use file extensions (`.pdf`, `.png`, `.md`, `.xlsx`);
selecting one changes the dropped file, caption/actions, and the mock Notch card height/content so the
window feels adapted to that file type.

- [x] **Data shape** — add a short `ext` label to each `pill.tabs[]` item in `website/data.js`.
- [x] **Markup** — add a `#fileTypeToggle` container above the `#sim` demo in `website/index.html`.
- [x] **Renderer/state** — in `website/app.js`, render the external toggle from `D.pill.tabs`, track the
      selected tab id, and make `renderCard()`, `renderTabRows()`, `setFile()`, and the intro fill
      sequence use that selected type instead of embedded card tabs.
- [x] **Remove internal tabs from the Notch mock** — keep the caption/actions inside the card, but no
      `.ph-tabs` row inside the pill.
- [x] **Responsive card sizing** — adjust CSS/JS so the expanded mock window height follows the active
      file type's action count while staying within sensible desktop/mobile bounds.
- [x] **Verify** — reload `http://localhost:4399/`, test all four toggles, desktop layout,
      mobile smoke, and console errors.

---

## Website — Logo orbit + idle autoplay for AI Drop hero (DONE)

**Goal:** replace the orbiting SF-symbol tool tiles with all app logos currently in
`website/assets/`, while keeping Scripts, scissors, and audio waveform as non-logo utility tiles with
distinct styling. Remove the Replay button. The AI Drop demo should automatically restart after a short
idle delay only when the pointer is not over the AI Drop demo/window area.

- [x] **Orbit data** — change `AIDROP.orbit` from plain icon names to typed items:
      `{type:"logo", logo, name}` for every suitable app logo in `assets/`, plus utility items for
      Scripts, scissors, and audio waveform.
- [x] **Orbit renderer** — update `buildChips()` in `website/app.js` to render logo tiles with `<img>`
      and utility tiles with `[data-icon]`, preserving the current orbit/fly-in choreography.
- [x] **Styling** — add visual variants for logo tiles and for the three utility tiles so Scripts,
      scissors, and waveform remain in the orbit but read differently from app logos.
- [x] **Remove Replay** — remove the Replay button from `website/index.html`, delete its click binding,
      and keep the caption aligned without it.
- [x] **Idle autoplay** — after the demo reaches `done`, schedule a replay after a delay; cancel while
      the pointer is over the AI Drop demo/window area and resume the idle timer after pointer leave.
- [x] **Verify** — hard reload the local site, check orbit assets render, idle replay pauses on hover,
      restarts after leave, no Replay button remains, mobile smoke, and console errors.

## Website — Logo orbit refinements (DONE)

**Goal:** keep the orbit feeling less sorted and less text-heavy: remove AI Drop / Pages / Preview from
the orbit, render the on-device utility tools as icon-only glass tiles, reshuffle the orbit order for
every replay, and keep hero text from replaying after the first boot-up.

- [x] **Orbit data** — remove AI Drop, Pages, and Preview from `website/data.js` orbit items.
- [x] **Utility tiles** — render Scripts, scissors, and audio waveform without visible text while keeping
      their tooltip labels.
- [x] **Glass styling** — make logo and utility orbit tiles share the same glass base; only tint differs.
- [x] **Replay shuffle** — randomize the orbit item order every `play()`/replay so the fly-in order is not
      visually sorted.
- [x] **Text replay** — keep the hero copy and boot captions from replaying after the initial boot-up.
- [x] **Verify** — syntax check, asset check, browser hard reload, confirm removed items, no visible utility
      labels, shuffled replay order, no text replay, and no console errors.

## Website — Demo actions + seeded rows (DONE)

**Goal:** make the AI Drop hero demo reflect the full action catalogue shown lower on the page, make
the Open-in row vary by selected file type, mark AI actions subtly with a sparkle at the right edge of
each row, and shuffle the demo rows with the same replay seed so the card does not feel sorted.

- [x] **Data mapping** — add fileType/category references for the four demo tabs and define per-tab Open-in
      app lists.
- [x] **Action source** — generate demo rows from `fileTypes[].does` plus the generic "Any file" actions.
- [x] **Seeded shuffle** — reuse the current replay seed to shuffle action rows and Open-in apps per replay.
- [x] **AI marker** — render AI rows with a subtle right-edge sparkle icon and style it unobtrusively.
- [x] **Sizing** — adjust mock card content height for the larger action catalogue without breaking mobile.
- [x] **Sizing correction** — keep the full action catalogue scrollable but cap the visible action area to
      about five rows so the AI Drop window returns to the prior compact height.
- [x] **Animation correction** — render the action catalogue as plain rows inside one animated
      `.ph-tabcontent` scrollbox, not as one `fill` animation per action.
- [x] **Bounded chip reveal** — animate only the first seven visible chips with a pop-in, then skip the
      remaining scrollbox rows and continue into the Open-in launcher animation.
- [x] **Prompt micro-animation** — type "Ask anything..." into the prompt after the launcher reveal, then
      pop in a blue mic button.
- [x] **ChatGPT icon + Pages launcher** — force the new `assets/chatgpt.png` to load in the website demo
      and add Apple Pages as an Open-in launch option.
- [x] **Legacy hero actions** — remove "Show in Finder" / "Open in a favorite app" from demo actions,
      restore the old backup hero options such as "Find trends" into the Notch demo.
- [x] **File groups section rewrite** — keep the hero demo unchanged, replace the file-type cards with
      Text / Media / Data technical groups, supported extensions, local actions, and a mixed AI prompt list.
- [x] **Remove Section 3 toggle** — show file groups directly and rename the demo file-type toggle labels
      from extensions to category names.
- [x] **Orbit acceleration timing** — delay the AI Drop hero tools' spin acceleration slightly while
      keeping the drop/fill choreography intact.
- [x] **Cursor file ghost styling** — make the dragged file proxy look more like a real macOS file while
      keeping it visually related to the dropped file badge inside the AI Drop window.
- [x] **Cursor file ghost frost + categories** — give the cursor-attached file the same frozen glass
      language as the orbit tools/window and tint/icon it by Text, Media, and Data category.
- [x] **Cursor file ghost flattening** — remove the colored tint/deep lighting from the cursor-attached
      file and keep only a flat frozen surface with a subtle liquid-glass stroke.
- [x] **Cursor file ghost icon clarity** — keep the flat neutral file ghost but restore clearly visible,
      distinct file-type icons for text, media, docs, and data.
- [x] **Cursor file ghost visible icons** — make the neutral file ghost icons visually obvious in the
      actual animation, not only technically present in the DOM.
- [x] **Cursor drag easing** — replace the linear cursor/file drag path with a smoother, more natural
      eased movement into the AI Drop pill.
- [x] **Revert cursor drag easing + soften icon** — restore the prior simple drag path and make the
      cursor-file icon stroke thinner with light alpha.
- [x] **Website demo video** — replace the Section 2 demo placeholder with the local
      `website/notch-demo.mp4` recording and verify it loads in the browser.
- [x] **Cursor/file vanish offset** — keep the AI Drop pill expansion timing unchanged, but make the
      cursor-attached file disappear 50ms later.
- [x] **Smoother pill morph** — make the waiting pill expand into the card with simultaneous width/height
      motion and a subtle liquid distortion, without changing the drag/fill choreography.
- [x] **Earlier morph/vanish timing** — start the smoother pill morph and cursor/file vanish 100ms earlier,
      while leaving the rest of the hero choreography in place.
- [x] **Higher pill drop + longer drag** — make the waiting pill visibly enter from slightly higher up and
      lengthen the cursor/file drag movement without moving the drop/morph/fill beats.
- [x] **Earlier/slower pill drop** — start the waiting-pill drop animation earlier, extend its duration by
      the same amount, and keep the settled endpoint unchanged.
- [x] **Hero copy choreography** — keep "Your daily tools" visible from the start, reveal "one drag away"
      when the pill expands, and reveal the body copy at the existing final copy-reveal beat.
- [x] **Hero headline pop** — remove the comma, enlarge the AI Drop hero headline, and make "one drag
      away" pop in while "Your daily tools" shifts and shrinks slightly.
- [x] **Revert hero headline pop** — restore the previous hero-copy choreography styling: comma back,
      normal headline size, and no lead-shrink/tail-pop treatment.
- [x] **Verify** — syntax check, browser hard reload, all four toggles, row counts, app variation, seeded
      shuffle changes, AI markers, mobile smoke, and console errors.

## Website — loop number shine refinement (DONE 2026-07-05)

- [x] Keep the first boot-up count-up/popup choreography for the faster/stat numbers.
- [x] On idle replay, keep number values final and replay only a subtle shine/glow.
- [x] Cache-bust the touched website assets and verify syntax/browser state.

## Website — replay file-type rotation (DONE 2026-07-06)

- [x] Rename the third hero demo toggle from the repeated Text label to Notes.
- [x] Advance the hero demo file type on every automatic replay: Text → Media → Notes → Data.
- [x] Cache-bust touched website assets and verify syntax/browser state.

## Website — file-type toggle liquid pill (DONE 2026-07-06)

- [x] Replace the active toggle button background with a persistent moving selection pill.
- [x] Add a clean/snappy ease-in-out slide plus subtle liquid squash on file-type changes.
- [x] Recalculate the pill position on resize and cache-bust touched website assets.
- [x] Verify syntax and browser state.

## Website — auto toggle progress push (DONE 2026-07-06)

- [x] Add a subtle left-to-right progress light to the file-type toggle during the idle replay delay.
- [x] Correct the progress effect so it fills inside the active blue selection pill instead of sweeping across
      the whole toggle.
- [x] Make the thumb progress fill from the beginning of the idle delay and preserve/resume the current
      progress state while hovering the demo.
- [x] Move the automatic tab advance before the replay window fade so the selection pill visibly slides.
- [x] Use the same thumb push/squash impulse for automatic tab changes as for manual clicks.
- [x] Cache-bust touched website assets and verify syntax/browser state.

## Safari/browser tab drop fallback (DONE 2026-07-10)

**Goal:** allow Safari and browser tabs to hover and open a Dragaway session even when the browser's
drag session never discovers the notch window that appears after the drag has already started. Keep
the normal `NSDraggingDestination` path authoritative for Finder and every source that already works.

- [x] **Fallback capture** — cache a browser drag's HTTP(S) URL from the global drag pasteboard when
      `DragMonitor` first recognizes the session; do not write a Drops file until a confirmed release.
- [x] **Fallback hover** — while AppKit has not entered `DroppableHostingView`, derive hover from the
      global mouse position and the visible pill's real screen-space target rectangle.
- [x] **Fallback commit** — on physical mouse release over the pill, materialize the cached URL and
      open/add it through the existing session flow; disarm when AppKit takes ownership so one gesture
      can never produce two drops.
- [x] **Lifecycle safety** — clear fallback state on exit/cancel/space changes and preserve the existing
      pasteboard stale guards, deferred stage transitions, window reuse, and Finder behavior.
- [x] **Verify** — build Debug; retain Finder's proven `draggingEntered` path; exercise repeated real
      Safari-tab drags through fallback hover/drop; confirm the materialized page file, enriched content,
      and live chips-stage window; inspect cancel/duplicate-drop guards and pass `git diff --check`.

## Browser image vs URL drag routing (PLANNED 2026-07-12)

**Goal:** materialize the thing the user visibly dragged. Browser image-result drags that expose both
bitmap data and a source/page URL must become image files, while Safari/browser tab and link drags must
keep the proven URL fallback unchanged.

- [x] **Central payload priority** — make bitmap bytes authoritative over URL/text and support PNG,
      TIFF, and JPEG pasteboard flavours through one shared classifier.
- [x] **AppKit destination path** — remove the URL-first short circuit in `draggingEntered`; cache image
      data first, fall back to an image file promise when bytes are declared but unavailable, then URL/text.
- [x] **Late-window fallback path** — cache a typed image-or-URL payload instead of only `fallbackWebURL`,
      while preserving the existing geometry, physical mouse-up commit, AppKit ownership handoff,
      stale-pasteboard guards, and one-drop-only behavior.
- [x] **Verify build and static routing** — Debug build succeeds, `git diff --check` passes, and the
      image-first/AppKit/fallback ownership paths were inspected against the existing guards.
- [x] **Verify real interactions** — user-verified Google Images → PNG, Safari tab/link → TXT,
      Finder file → normal AppKit drop, cancel/outside release, and repeated mixed drags, including
      the resulting outputs and diagnostic routing.
- [x] **Capture lesson** — document the mixed-pasteboard priority rule after the correction is verified.
