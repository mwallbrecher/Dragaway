# AI Drop — App Store Roadmap & Review

> Plan written 2026-05-29. Status of the codebase: feature-complete BYOK app, distributed via
> Developer-ID DMG. Goal: ship on the App Store with a metered free → paid model.
> **Nothing below is implemented yet — this is the plan to confirm before building.**

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
- [ ] **Manual test (user)**: drop a file → switch tabs (clean resize, no Y-jump) → run a typed prompt
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
- [ ] **Manual test (user)**: minimize from chips/result → squish to notch, hides → drag a new file
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
- [ ] **Manual test (user)** — reveal opens Finder w/ file selected; rename updates pill + session
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
- [ ] **Manual test (user)** — run actions on a file → session appears in submenu w/ icon + date;
      run a 2nd action → same session updates (not duplicated); new drop → new entry; >10 sessions
      trims oldest; click reopens overlay w/ latest result + back-arrow to prior; ⌥ shows per-row
      remove; Clear History empties; survives app relaunch.
- [ ] **Lesson** — capture any NSMenu attributedTitle/alternate-item or AppSupport-IO gotchas.
