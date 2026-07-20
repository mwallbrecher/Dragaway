# Lessons Learned — AI Drop

> Updated after every correction. Review at session start.

---

## macOS APIs

### [IPC-01] Sandboxed extension → non-sandboxed app: named NSPasteboard + Darwin notification beats App Groups
- **Context**: the "Add to AI Drop" Finder Quick Action is a macOS Action Extension — a SEPARATE, mandatorily-sandboxed process. It must hand the Finder file selection to the always-running, non-sandboxed main app. First plan used a shared **App Group** container file + a Darwin ping.
- **Why App Group was wrong here**: App Groups require the group ID to be **registered on the developer portal**, which Xcode only does for a paid team via the Signing & Capabilities UI. A free/personal team can't provision App Groups, so codesign fails and the feature dead-ends. You can't tell paid vs free from the cert name ("Apple Development: …" is issued to both).
- **Fix**: drop App Groups. Use a **named `NSPasteboard`** (`NSPasteboard(name:)`, NOT the general pasteboard) for the payload — the extension `clearContents()` + `writeObjects(urls as [NSURL])`, the main app `readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true])`. Pair it with a **Darwin notification** (`CFNotificationCenterGetDarwinNotifyCenter` post/observe) as the cross-sandbox "go read it now" ping (Darwin notes carry no payload, hence the pasteboard side-channel). Named pasteboards live in the system pasteboard server and are reachable from a sandbox with **zero entitlements** — works on any signing tier.
- **Darwin callback gotcha**: the `CFNotificationCallback` is `@convention(c)` and can't capture `self`; it also may fire off the main thread. Have it just re-post a normal `Notification.Name`, and bounce to `Task { @MainActor }` in the observer before touching UI/state.
- **Rule**: for sandboxed-extension ⇄ host-app IPC, reach for named pasteboard + Darwin notification first. Only use App Groups when you actually need a shared file container AND have a paid team.

### [IPC-02] Modern Xcode extension targets get sandbox entitlements from build settings, not a .entitlements file
- **Symptom**: created a No-UI Action Extension; expected to wire `CODE_SIGN_ENTITLEMENTS` to a prepared `.entitlements`, but the target had no `CODE_SIGN_ENTITLEMENTS` set at all — yet it still sandboxes correctly.
- **Root cause**: recent Xcode drives entitlements from build settings — `ENABLE_APP_SANDBOX = YES` and `ENABLE_USER_SELECTED_FILES = readonly` synthesize a `DerivedSources/Entitlements.plist` at build time. A hand-authored `.entitlements` file is then **redundant** (and if pointed at via `CODE_SIGN_ENTITLEMENTS`, can fight the generated one).
- **Fix**: don't add a `.entitlements` file for sandbox/user-selected-files; set `ENABLE_APP_SANDBOX` / `ENABLE_USER_SELECTED_FILES` build settings (which the template already does). Only add a physical entitlements file for keys with no build-setting equivalent.
- **Display name**: the Quick Action's menu title comes from `CFBundleDisplayName`; with `GENERATE_INFOPLIST_FILE=YES` set it via the build setting `INFOPLIST_KEY_CFBundleDisplayName = "Add to AI Drop"` (do NOT also put `CFBundleDisplayName` in the manual `Info.plist` — duplicate-key build error).
- **Rule**: before hand-wiring `CODE_SIGN_ENTITLEMENTS`, check whether `ENABLE_*` build settings already cover what you need.

### [MIC-11] Mic-permission API is OS-version-dependent — branch on `#available(macOS 26)`
- **Context**: lowered the deployment target 26 → 14. The mic code used `AVCaptureDevice` ONLY (the
  macOS-26-correct API). It compiles fine on 14 but is a RUNTIME bug there.
- **The truth table** (reconciles the contradictory-looking MIC-01/04/05): which API maps to
  `kTCCServiceMicrophone` flipped across OS versions —
  - macOS **14 / 15**: `AVAudioApplication` (`.shared.recordPermission` + `requestRecordPermission`).
    `AVCaptureDevice.authorizationStatus(.audio)` returns a false `.denied` here (MIC-04) → the guard
    short-circuits to the "denied" alert without ever prompting.
  - macOS **26+**: `AVCaptureDevice` (`authorizationStatus`/`requestAccess`). `AVAudioApplication`
    defaults `.denied` for accessory/LSUIElement apps here (MIC-05).
- **Fix**: split both the status read AND the request behind `if #available(macOS 26, *) { AVCaptureDevice }
  else { AVAudioApplication }` (`SpeechRecognizer.micAuthStatus()` / `requestMicAccess()`). Keep MIC-06
  (drop overlay to `.normal` before the prompt) in BOTH branches.
- **Rule**: TCC-API↔category mappings are not stable across macOS releases. When lowering a deployment
  target, a clean *compile* does NOT prove permission flows — each OS band needs the API that actually
  owns the TCC category on it. Verify on real hardware per band; a build success is necessary, not sufficient.

### [MIC-07] ENABLE_HARDENED_RUNTIME=YES silently blocks microphone without com.apple.security.device.audio-input entitlement
- **Symptom**: `authorizationStatus` = `.denied` immediately after `tccutil reset`, no dialog ever shown, app never appears in Settings
- **Root cause**: Hardened Runtime checks for `com.apple.security.device.audio-input` entitlement BEFORE consulting TCC. Missing entitlement = auto-deny, no user prompt, no TCC record.
- **Fix**: Create `MacNotchAI.entitlements` with `com.apple.security.device.audio-input = true`, set `CODE_SIGN_ENTITLEMENTS` in build settings
- **Rule**: Any project with `ENABLE_HARDENED_RUNTIME=YES` that uses microphone/camera/location MUST have the corresponding entitlement. Check this FIRST before debugging TCC or permission APIs.

### [MIC-05] On macOS 26, AVAudioApplication and AVCaptureDevice check DIFFERENT TCC categories
- **Symptom**: `AVAudioApplication.recordPermission` = 'deny' but `AVCaptureDevice.authorizationStatus` = `.notDetermined` simultaneously
- **Root cause**: macOS 26 introduced a separate TCC category for `AVAudioApplication` that defaults to `.denied` for LSUIElement/accessory apps. `AVCaptureDevice` still maps to `kTCCServiceMicrophone` correctly.
- **Fix**: Use `AVCaptureDevice` for BOTH status check and request on macOS 26
- **Rule**: Always verify which API actually maps to `kTCCServiceMicrophone` on the target OS. On macOS 26, `AVAudioApplication.recordPermission` ≠ microphone TCC.

### [MIC-06] TCC dialog renders at .normal level — hidden behind .floating overlay
- **Symptom**: `requestAccess` returns false instantly (< 200ms) without user seeing any dialog
- **Root cause**: Overlay window is `level = .floating`; TCC dialogs render at `.normal` → appear behind the pill → auto-dismissed
- **Fix**: Temporarily drop `overlayWindow?.level = .normal` + `NSApp.activate(ignoringOtherApps: true)` before calling `requestAccess`, restore `.floating` after
- **Rule**: For ANY system dialog triggered from a floating-panel app, lower the window level first.

### [MIC-04] AVCaptureDevice.authorizationStatus(for: .audio) returns .denied on macOS 14+ for audio-recording TCC category
- **Mistake**: Used `AVCaptureDevice.authorizationStatus(for: .audio)` to check mic permission status
- **Symptom**: Status returned `.denied` immediately → guard short-circuited → `showPermissionAlert` fired without ever calling `requestAccess`
- **Root cause**: On macOS 14+, audio-recording TCC is owned by `AVAudioApplication`, not `AVCaptureDevice`. `AVCaptureDevice` returns `.denied` by default for this category.
- **Fix**: Check via `AVAudioApplication.shared.recordPermission`, request via `AVAudioApplication.requestRecordPermission { }` callback form
- **Rule**: For microphone access with AVAudioEngine on macOS 14+, ALWAYS use `AVAudioApplication` — both for status check AND for requesting. Never use `AVCaptureDevice` for audio-only (non-camera) permission.

### [MIC-01] AVAudioApplication.requestRecordPermission() is iOS-first — use AVCaptureDevice on macOS
- **Mistake**: Used `AVAudioApplication.requestRecordPermission()` for macOS microphone permission
- **Symptom**: Returned `false` immediately, no system dialog, app never appeared in Settings
- **Root cause**: `AVAudioApplication` is primarily an iOS API; on macOS it silently fails without registering in TCC
- **Fix**: Use `AVCaptureDevice.authorizationStatus(for: .audio)` to check, then `AVCaptureDevice.requestAccess(for: .audio)` with explicit callback wrapped in `withCheckedContinuation`
- **Rule**: When adding any macOS permission, check if the API is macOS-native or ported from iOS. iOS-ported APIs (AVAudioSession, AVAudioApplication) behave differently on macOS.

### [MIC-02] Two separate TCC entries: speech recognition ≠ microphone
- **Mistake**: Only called `SFSpeechRecognizer.requestAuthorization` — thought that covered mic too
- **Symptom**: Engine started silently, no audio captured, no yellow menu-bar indicator
- **Fix**: Chain both: speech recognition first, then explicit microphone request
- **Rule**: Always request BOTH permissions for speech-to-text on macOS. They are separate TCC entries.

### [MIC-03] TCC caches stale entries — use tccutil reset when app not appearing in Settings
- **Mistake**: Added NSMicrophoneUsageDescription late; TCC had cached the app before the key existed
- **Symptom**: App not appearing in System Settings → Microphone at all
- **Fix**: `tccutil reset Microphone <bundle-id>` clears the stale entry; app will re-register on next request
- **Rule**: If an app is missing from a Privacy category in Settings, always try `tccutil reset <Category> <bundle-id>` first.

### [MIC-09] AVAudioEngine tap must capture `req` directly — never go through @MainActor self
- **Symptom**: Engine starts, mic indicator appears, but recognition task gets no audio → 1110/silence after timer
- **Root cause**: Tap closure fires on audio render thread. `self?.request?.append(buf)` goes through `@MainActor`-isolated `self` → under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` this enqueues the append on the main thread → buffer is stale or dropped → silence sent to recognizer
- **Fix**: Capture the local `SFSpeechAudioBufferRecognitionRequest` variable directly: `req.append(buf)`. It's thread-safe and must be called synchronously on the audio thread.
- **Rule**: Any audio tap callback that appends to `SFSpeechAudioBufferRecognitionRequest` must capture the request as a non-isolated local — NEVER through `self` when `self` is `@MainActor`-isolated.

### [MIC-10] AirPods HFP routing prevents OS mic indicator and silences AVAudioEngine
- **Symptom**: With AirPods connected as default input device, no yellow mic indicator, engine starts but recognition gets no audio, session times out after silence timer
- **Root cause**: Bluetooth HFP (Hands-Free Profile) activates a 24 kHz SCO link; its setup latency and format mismatch cause the recognition server to receive no usable audio. The OS mic-active indicator also doesn't show for HFP streams.
- **Fix**: Use Core Audio `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` on `eng.inputNode.auAudioUnit.audioUnit` to pin the AVAudioEngine to the built-in mic device ID, bypassing the system default device selection.
- **Rule**: For any macOS speech recognition feature, always pin AVAudioEngine input to the built-in mic via Core Audio. Never rely on the system default device when Bluetooth devices may be connected.

### [MIC-08] kAFAssistantErrorDomain 1110 = server closed stream with no speech (benign)
- **Symptom**: Error fires after silence timer → `endAudio()` call; was mistakenly treated as fatal
- **Root cause**: When the audio stream ends with no recognised speech, the server returns 1110 instead of completing gracefully. This is a normal end-of-session signal, not a failure.
- **Fix**: Treat 1110 as benign alongside 301. Only call `tearDown()` for unknown domains/codes.
- **Rule**: kAFAssistantErrorDomain 301 AND 1110 are both normal end-of-session codes. kLSRErrorDomain 201 = on-device model not installed (also benign — session just ends).

---

## Swift Concurrency

### [CONC-01] DispatchQueue.main.async inside @MainActor with SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor is a no-op for binding updates
- **Mistake**: Used `DispatchQueue.main.async { self.onTranscript?(text) }` inside an `@MainActor` class
- **Symptom**: Callback ran but SwiftUI `@Binding` setter was silently ignored
- **Root cause**: With strict concurrency + default MainActor isolation, `DispatchQueue.main.async` creates an untracked hop that violates actor isolation for the binding update
- **Fix**: Use `Task { @MainActor in }` or call directly (if already on main thread)
- **Rule**: In `@MainActor` classes with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, never use `DispatchQueue.main.async` to update state — use `Task { @MainActor in }` or direct calls.

### [CONC-02] SFSpeechRecognizer.requestAuthorization callback fires on background thread
- **Mistake**: Accessed `@MainActor` properties directly inside the `requestAuthorization` callback using `[weak self]`
- **Symptom**: Actor isolation violation — properties not updated
- **Fix**: Wrap in `withCheckedContinuation` and `await` inside `Task { @MainActor in }`
- **Rule**: `SFSpeechRecognizer.requestAuthorization` is NOT guaranteed to call back on main thread. Always bridge it with `withCheckedContinuation`.

### [CONC-03] A local `NSEvent` monitor must return synchronously — bridge @MainActor work with `MainActor.assumeIsolated`
- **Context**: Pillar-1 `Option+1…9` launch hotkeys use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, whose handler is `(NSEvent) -> NSEvent?` (return the event to pass it through, `nil` to swallow it).
- **Problem**: The handler needs `@MainActor` state (`OverlayViewModel.stage`, `FavoriteToolsStore`). `Task { @MainActor in }` (the CONC-01 fix) is async — it can't produce the `NSEvent?` return value the monitor needs *now*, so you can't use it here.
- **Fix**: Local monitors are delivered on the main thread/runloop, so wrap the body in `MainActor.assumeIsolated { … }` and return its result. This satisfies isolation checking AND returns synchronously. (`assumeIsolated` is available on the deployment target, macOS 14.)
- **Scope it**: install the monitor only while the relevant stage is live (`stage == .chips`) and remove it otherwise + in `stopDismissMonitors`; gate the match on the exact modifier set (`flags == .option`) and `charactersIgnoringModifiers` so it never eats the prompt field's own keys.
- **Rule**: global monitor + side-effect only → `Task { @MainActor in }`. **Local** monitor that must return a value → `MainActor.assumeIsolated`. Never `DispatchQueue.main.async` (CONC-01).

---

## Drag Detection

### [DRAG-01] stopPolling() snapshots lastDragChangeCount — can cause false triggers
- **Mistake**: `stopPolling()` sets `lastDragChangeCount = current` at drag end. If a background app writes to drag pasteboard later, `count != lastDragChangeCount` fires with stale file data
- **Fix**: `pressTimeChangeCount` — snapshot pasteboard changeCount at leftMouseDown; require `count > pressTimeChangeCount` in handleDrag
- **Rule**: The drag pasteboard changeCount alone is not enough. Always gate on BOTH the stale guard AND the press-time snapshot.

### [DRAG-02] Re-arm blocks in early-return branches cause false triggers
- **Mistake**: Added re-arm logic (`if !isDraggingFile && hasFile()`) inside the `count == lastDragChangeCount` early-return branch
- **Symptom**: Pill appeared on pointer-down + hold with no file dragged
- **Root cause**: Stale pasteboard data evaluated as a new drag
- **Fix**: Remove re-arm from early-return branch entirely; handle dead state via pressedMouseButtons check in mouseUpMonitor instead
- **Rule**: Never read pasteboard contents inside the early-return (same changeCount) branch. That branch means "nothing changed" — treat it as such.

### [DRAG-03] mouseUpMonitor 50ms delay can fire during a new drag session
- **Mistake**: mouseUpMonitor fires after 50ms delay; if a new drag started in that window, it resets isDraggingFile and snapshots the new drag's changeCount → pill never reopens
- **Fix**: Check `NSEvent.pressedMouseButtons & 1 == 0` in the delayed callback; if mouse is still down, skip cleanup entirely
- **Rule**: Always guard delayed mouse-event callbacks with a current button-state check.

### [DRAG-04] Moving a window from a DragGesture: use NSEvent.mouseLocation, not .global translation
- **Symptom**: dragging the overlay to move it jittered/glitched and trailed the cursor.
- **Root cause #1 (feedback loop)**: `DragGesture(coordinateSpace: .global)` translation is measured relative to the *window* — and the window is moving as you drag it — so each frame's translation is computed against an already-shifted origin → drift/jitter.
- **Root cause #2 (lag)**: applying the offset through a Combine sink with `.receive(on: DispatchQueue.main)` adds an async runloop hop even on the main thread, so the window lands one frame behind the cursor.
- **Fix**: read absolute `NSEvent.mouseLocation` (screen coords, y-up) and accumulate `start + (mouse - anchor)`; deliver the offset synchronously (no `.receive(on:)`) and `setFrameOrigin` in the same tick.
- **Rule**: window-follows-cursor must track an absolute reference and move synchronously; never measure window motion in a coordinate space that moves with the window.

### [DRAG-05] Safari tab drags may never discover a destination window shown after drag start
- **Symptom**: the global drag pasteboard monitor sees a Safari tab and shows the pill, but the pill
  never hovers and cannot accept the drop. Adding every declared Safari URL/file-promise type does not
  help.
- **Root cause evidence**: diagnostics show Safari's full payload (`public.url`,
  `WebURLsWithTitlesPboardType`, promise types, `com.apple.safari.tab`) at the global monitor but no
  subsequent `draggingEntered`; Finder produces both lines. The failure is therefore destination
  discovery, before payload parsing, promise receipt, or `performDragOperation`.
- **Fix**: cache the HTTP(S) URL from `NSPasteboard(name: .drag)` at drag recognition. Until AppKit
  calls `draggingEntered`, use the common-mode button poll plus `NSEvent.mouseLocation` and the pill's
  converted screen-space target rect to drive hover and commit on release. The first real
  `draggingEntered` permanently disarms the fallback for that gesture so a drop cannot fire twice.
- **Rule**: when a drag target window is created mid-session, prove callback delivery before debugging
  pasteboard flavours. If a source never sends `draggingEntered`, use a narrowly typed, cached payload
  fallback with explicit AppKit ownership handoff; never weaken the stale-pasteboard guards.

### [DRAG-06] Mixed browser drags must prioritize the visible bitmap over their page URL
- **What was wrong:** browser image-result drags can expose PNG/TIFF/JPEG data, an image promise, plain
  text, and a source/page URL at the same time. A URL-first path materialized the page as TXT even though
  the user visibly dragged an image.
- **Why:** pasteboard flavours are alternative representations of one gesture, not equally authoritative
  independent objects. Generic URL extraction loses the user's visible target when bitmap data is also
  present, and a late-window fallback that caches only a URL repeats the same mistake outside AppKit.
- **Fix:** centralize payload classification with the order bitmap bytes → image promise when declared
  bytes are unavailable → HTTP(S) URL → text. Use the same typed image-or-URL decision in both the normal
  `NSDraggingDestination` path and the Safari late-window fallback while keeping AppKit ownership and
  one-drop guards intact.
- **Rule:** for mixed browser pasteboards, materialize the thing visibly dragged. Bitmap/image-promise
  representations outrank source URLs; tabs and links still resolve to URLs when no image is declared.

### [DRAG-07] A written promised file does not prove a successful receiver callback
- **What was wrong:** Apple Mail reached `draggingEntered` and wrote complete `.eml` files into the
  promise destination, but no session opened. The first diagnosis blamed the unsupported-file filter.
- **Why:** `.eml` already passed that filter through the generic non-empty action pool. The real handoff
  collected a promised URL only when the `NSFilePromiseReceiver` reader returned with `error == nil`;
  Mail's legacy promise can leave the file behind without producing that usable completion, so the
  dispatch group path ends empty or never completes.
- **Fix:** preserve the normal promise route and add recovery only when the drag declares Mail's exact
  message-transfer pasteboard type. Handle Mail callbacks without the generic one-enter/one-leave group
  because one legacy receiver may emit several files. Feed both successful callbacks and recovered files
  through one batch accumulator so a multi-message drag stays one session. For recovery, inspect only
  `receiver.fileNames`, require a new-or-changed size/mtime fingerprint to remain stable across
  observations, validate a regular non-empty `.eml` / `.emlx` with a bounded MIME parse, and dedupe
  delivery against both the current session and the normal callback.
- **Rule:** diagnose promised-file drops as three separate gates: destination entry, physical file
  fulfilment, and reader-callback/session handoff. Never infer the third from the first two, and keep any
  legacy-source recovery narrowly type-gated so proven Safari/image promise behavior cannot change.

### [MAIL-01] AppKit's HTML-to-text importer can load email tracking resources
- **What was wrong:** HTML-only mail was converted with `NSAttributedString(data:options:)` and the HTML
  document type, which looked like a local text conversion.
- **Why:** AppKit's HTML importer resolves external stylesheets and images. A crafted or ordinary HTML
  email can therefore issue GET requests for tracking pixels/CSS while Dragaway extracts it, leaking the
  read event and contradicting the local-extraction privacy boundary.
- **Fix:** keep MIME/charset decoding in Foundation, remove script/style/head/resource markup with a
  bounded string pass, preserve basic block/list/table separators, strip all remaining tags, and decode
  common named/numeric entities. A localhost trap confirmed embedded CSS/image URLs receive zero requests.
- **Rule:** never feed untrusted email HTML to AppKit/WebKit merely to obtain plain text. Email extraction
  must use a no-I/O sanitizer/parser, and remote resources must remain inert data.

### [DRAG-08] Asynchronous promise delivery must not open a session mid-collapse
- **What was wrong:** a complete promised-file batch could arrive after the delayed pill dismissal had
  set `isCollapsing`, but before teardown reset the waiting stage. Opening chips in that interval could
  cancel teardown while leaving the new card visually collapsed.
- **Why:** callback time is independent of the drag-end animation. A nominal elapsed-time guard is not
  sufficient either: if the main thread stalls, the delayed collapse itself can begin later than planned.
- **Fix:** centralise Mail batch delivery after the nominal dismiss/collapse window and also gate it on
  the live `isCollapsing` flag. Retain the complete accumulator and retry after the collapse when either
  guard says the handoff is unsafe; protect retries with the batch generation token.
- **Rule:** any asynchronous drop source that opens a session must respect the overlay's live collapse
  state. Never write a new stage into an in-flight dismiss animation.

### [DRAG-09] Apple Mail inbox rows require the advertised legacy file-promise trigger
- **What was wrong:** Mail reached `draggingEntered` and `performDragOperation`, but no `.eml` appeared;
  the recovery loop had nothing to validate and `NSFilePromiseReceiver` eventually timed out with
  `NSURLErrorDomain -1001`.
- **Why:** inbox-row drags advertise modern promise flavours *and* legacy `Apple files promise pasteboard
  type`, but Mail's modern receiver bridge does not necessarily trigger file creation. The destination
  must call `NSDraggingInfo.namesOfPromisedFilesDropped(atDestination:)` while the drag source is live.
- **Fix:** for the exact Mail message-transfer flavour only, fingerprint the destination, invoke the
  legacy fulfilment method inside `performDragOperation`, then feed its returned filenames into the same
  stable-file/MIME/batch/collapse-safe recovery used by the modern fallback. Use the modern receiver only
  when the legacy call returns no names.
- **Rule:** declared pasteboard compatibility does not prove a modern promise API will fulfil a legacy
  source. When the source advertises `NSFilesPromisePboardType`, trigger that contract during the live
  drop, and isolate the compatibility path by exact source flavour.

### [DRAG-10] A legacy promise's returned label may not be the written filename
- **What was wrong:** the Mail legacy call returned one promised name, but recovery still found no file.
  Filesystem evidence showed complete `.eml` files written at every drop timestamp.
- **Why:** Mail returned an extensionless display label while writing a subject-named `.eml`. Treating
  the label as a literal destination filename constructed a nonexistent extensionless path; the strict
  `.eml/.emlx` validator then correctly rejected it forever.
- **Fix:** retain the returned array only as the expected message count. For this exact legacy-Mail path,
  diff the app-private Drops directory against its pre-fulfilment size/mtime snapshot, then apply the
  existing two-observation stability check, MIME validation, batching, dedupe, and collapse-safe handoff
  to the real changed `.eml/.emlx` URLs. Modern receiver names remain literal.
- **Rule:** verify promise APIs against the destination filesystem. Never assume a legacy source's
  returned display name is byte-for-byte identical to the file it creates.

### [DRAG-11] Do not impose recovery latency on a fulfilled synchronous promise
- **What was wrong:** working Mail drops still took roughly 1–2 seconds to show their actions because
  every legacy fulfilment went through the fallback's two stable-fingerprint observations (0.65 s then
  0.50 s), even when the fulfilment method had already returned with every expected `.eml` on disk.
- **Why:** stability polling is necessary when callbacks fail or files arrive asynchronously, but it
  was being treated as the normal path. MIME extraction was not the visible bottleneck.
- **Fix:** after the exact Mail-only legacy call returns, compare the private Drops directory with the
  pre-call snapshot. When the delta contains exactly the promised count of regular, non-empty mail
  files, open the chips immediately and prepare their bounded MIME context in one shared background
  Task; a fast action click awaits that Task before contacting a provider. Keep the original stable,
  MIME-validated recovery for incomplete deltas. Central session opening must cancel pending teardown
  and clear a live `isCollapsing` flag so the early handoff cannot inherit an invisible card state.
- **Rule:** separate a promised-file happy path from its recovery path. If a synchronous source contract
  has already produced the exact expected private-directory delta, render from the known URLs now,
  prepare expensive content once in the background, and retain conservative polling only as fallback.

### [DRAG-12] A fast synchronous promise call can still publish its file just after returning
- **What was wrong:** the Mail fast path still took almost exactly 1.15 seconds even though the legacy
  fulfilment method returned in 6 ms. The immediate directory scan saw no delta, so recovery deliberately
  waited 0.65 seconds for its first fingerprint and another 0.50 seconds for stability.
- **Why:** synchronous API return only proved that Mail accepted/completed its legacy fulfilment call;
  it did not guarantee that the destination-directory view had exposed the new `.eml` on that exact
  runloop turn. The file was already present by the first delayed observation, making the coarse polling
  cadence—not file writing or MIME extraction—the measured bottleneck.
- **Fix:** after an empty immediate scan, the exact legacy-Mail branch now observes the private directory
  after 40 ms and then every 50 ms for a bounded ~590 ms. It still requires the full advertised count,
  two identical size/mtime fingerprints, a bounded MIME sanity parse, and exact-once delivery. A validated
  batch uses the collapse-cancelling early session handoff directly; the original six-second recovery
  remains independently armed for slow or partial writes.
- **Rule:** measure promise fulfilment, file visibility, stability, and UI handoff separately. Preserve
  safety invariants, but tune observation cadence to the source's measured publication window instead of
  turning a fallback interval into unavoidable product latency.

---

## Xcode / Build

### [SPARKLE-01] Appcast signing depends on SUPublicEDKey in the built app, not just project build settings
- **Mistake**: `INFOPLIST_KEY_SUPublicEDKey` existed in `project.pbxproj`, but the target also pointed
  `INFOPLIST_FILE` at a physical `MacNotchAI/Info.plist` that only contained `SUFeedURL`. The exported
  app therefore had no `SUPublicEDKey`, so `generate_appcast` treated the update as not requiring EdDSA
  signing and emitted an unsigned enclosure even though the private key was present in Keychain.
- **Fix**: put `SUPublicEDKey` in the actual app Info.plist that Xcode processes, and make
  `scripts/release.sh` fail immediately if the exported app lacks `SUPublicEDKey` or the generated
  appcast entry for the current DMG lacks `edSignature`.
- **Rule**: for Sparkle, verify the built/exported `.app/Contents/Info.plist`, not only Xcode build
  settings. `generate_appcast` signs only when the update bundle advertises `SUPublicEDKey`.

### [BUILD-01] INFOPLIST_KEY_* must be added to project.pbxproj with exact tab indentation
- **Mistake**: Used space indentation in Edit tool when the file uses tabs → string not found
- **Fix**: Use Python script with exact `\t` characters to insert keys
- **Rule**: Always inspect raw bytes (`repr()`) before editing project.pbxproj with string replacement.

### [BUILD-02] Run from root xcodeproj, not worktree xcodeproj
- **Mistake**: User was running the root xcodeproj; changes made in worktree were not reflected
- **Fix**: Commit worktree changes and merge to main before testing
- **Rule**: Always confirm which xcodeproj the user is running before debugging "my changes aren't working".

### [BUILD-03] `import Combine` is required when declaring an ObservableObject with @Published
- **Mistake**: New `EntitlementStore: ObservableObject` with `@Published` imported only SwiftUI/AppKit → "does not conform to protocol 'ObservableObject'" + "@Published init unavailable, missing import of 'Combine'"
- **Fix**: Add explicit `import Combine` to any file that *declares* an ObservableObject/@Published
- **Rule**: SwiftUI does not transitively re-export Combine for protocol conformance under this toolchain — import Combine in the file that defines the observable type (existing OverlayViewModel/DragMonitor already do).

### [BUILD-04] New .swift files are auto-included (synchronized file group)
- The project uses `PBXFileSystemSynchronizedRootGroup` (path = MacNotchAI) — any new `.swift` under `MacNotchAI/` is compiled automatically, no project.pbxproj edit needed (unlike INFOPLIST keys, see BUILD-01).
- **Rule**: Add source files freely; only `project.pbxproj` *settings* (not file membership) need the tab-indent surgery.

### [BUILD-05] Default argument expressions are nonisolated — can't read a @MainActor singleton
- **Mistake**: `func notchFrame(..., offset: CGSize = OverlayViewModel.shared.userDragOffset)` → "main actor-isolated property 'userDragOffset' can not be referenced from a nonisolated context". The function *body* is MainActor (its enclosing class is), but the **default-value expression** is evaluated in a nonisolated context.
- **Fix**: Drop the default; make `offset` required and pass `OverlayViewModel.shared.userDragOffset` from each (MainActor) caller.
- **Rule**: Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, never put a MainActor-isolated read in a default argument. Pass it in explicitly.

---

## UI / Animation

### [ANIM-01] Resize-triggering content springs must be critically damped (the window can't follow overshoot)
- **Mistake**: Stage/expand transitions used bouncy springs (e.g. `dampingFraction: 0.58–0.75`). The window snaps to its final size **instantly** (animating the frame is forbidden — crash, see CLAUDE.md). Any content spring that overshoots *past* its final layout makes the content extend beyond the fixed window then settle back. Because the window is top-anchored at the notch and content grows downward, the bottom elements overshoot down-and-back → reads as "the window moves on Y / the buttons jump."
- **Why intermittent**: only fires when the spring is mid-flight / the content actually changes height — so it looks like it happens "sometimes."
- **Fix**: Set `dampingFraction: 1.0` (critically damped, monotonic, no overshoot) on every spring that drives a window resize: `setChips` / `setStage`, `navigateBackToChips`, forward-to-cached, the chips/follow-ups expand toggles, the result ScrollView `maxHeight`, and the `value: vm.stage.tag` jelly-return scale. Slightly lengthen `response` (e.g. 0.32→0.34, 0.38→0.40) so critical damping doesn't feel abrupt.
- **Rule**: If a spring animates anything that changes the content's overall height (= triggers `resizeOverlay`), it must NOT overshoot → damping 1.0. Keep bounce only on purely-visual effects that don't change layout height (hover, jelly wobble in stage 0, entry pop-in scale) — those can't bounce the window because the window size doesn't depend on them.

### [ANIM-02] Critical damping isn't enough for height-changers that get re-triggered mid-flight — use a timing curve
- **Mistake**: Even after raising the chips/follow-ups expand-toggle springs to `dampingFraction: 1.0` (ANIM-01), clicking the toggle **twice fast in the same spot** still bounced the content on Y. Moving the cursor away and clicking again was clean.
- **Why**: a critically-damped spring has zero overshoot only **from rest**. SwiftUI preserves the in-flight **velocity** when a spring is retargeted; click #2 reverses the target while the reflow still has momentum in the old direction → it continues past the new target before settling = overshoot. The "move the cursor away" case is just a proxy for *waiting long enough that spring #1 settled* (zero velocity) before #2 starts.
- **Fix**: drive any **window-height-changing reflow** with a monotonic timing curve — `withAnimation(.easeInOut(duration: 0.28))` for the chips/follow-ups toggles, and `.animation(.easeInOut(...), value:)` for the result ScrollView `maxHeight`. Timing curves restart from **zero velocity** on every retarget and are bounded [start,end] → they can never overshoot, no matter how fast you re-click. Personality/bounce stays on the chips' own slide-in `.transition` (which animates inside the already-reserved layout slot, so it can't move neighbors).
- **Rule**: springs for one-shot/visual flourishes; **timing curves for layout height that the user can rapidly re-toggle**. "Damping 1.0" only protects single, uninterrupted gestures.

### [ANIM-03] To make an elastic deform read as a *landing* (end of reflow), gate it with a keyframeAnimator that HOLDS first
- **Mistake**: a `pulseCardDeform()` that set `cardDeformY = 0.94` instantly then sprang back fired the squash **at the start** of the expand/collapse — the top of the card visibly deformed the moment the button was clicked, before the bottom edge had moved. The user wanted the overshoot to read as the *bottom edge slamming into its final position*, i.e. at the END of the height reflow.
- **Why**: a one-shot spring on a `@Published` starts deforming on frame 0; it has no notion of "wait for the separate height animation to finish." The height reflow (monotonic `easeInOut(0.28)`) and the deform spring were two independent timelines that both began on click.
- **Fix**: drive the deform with `.keyframeAnimator(initialValue: 1.0, trigger: vm.isChipsExpanded)` whose first keyframe is `LinearKeyframe(1.0, duration: 0.26)` — it **holds at rest** while the reflow carries the bottom edge down, THEN `CubicKeyframe(0.93, 0.09)` squashes on impact and `SpringKeyframe(1.0, 0.42, spring: Spring(response:0.32, dampingRatio:0.45))` rebounds past 1.0 and settles. Anchor stays `.top` so only the bottom edge reacts. `keyframeAnimator` runs a self-contained timeline on each `trigger` change, so timing is explicit instead of emergent. Deleted the now-dead `cardDeformY`/`pulseCardDeform()` VM state.
- **Gotchas**: (1) `SpringKeyframe`/`Spring` use the label **`dampingRatio:`**, NOT `dampingFraction:` (the `Animation.spring` modifier uses `dampingFraction`). Mixing them = `incorrect argument label` compile error. (2) the hold duration must be ≥ the reflow duration or the squash starts mid-move again.
- **Rule**: when one animation must visibly *react to another finishing*, don't run two springs and hope — use a `keyframeAnimator` with a leading `LinearKeyframe` hold sized to the first animation's duration. Keep the deform a pure `scaleEffect` (visual-only, never touches window/NSView bounds).

### [ANIM-04] Center the overlay window under the notch — anchor the WINDOW centre, not a fraction of its width
- **Mistake**: the expanded card (chips/loading/result) sat slightly right of the notch camera. `notchFrame(anchorAtNotchCenter:)` placed the left edge at `screenW/2 − size.width·(110/280)` (a legacy "notch at ~39 % from the left edge" rule). 110/280 = 0.393 < 0.5, so the window centre landed at `screenW/2 + size.width·0.107` — ~30 pt right for the 280-wide chips card, ~54 pt for the 500-wide result. The centred `WindowGrabber` made it obvious: the move-handle didn't line up with the notch.
- **Why**: the notch camera is at the screen's horizontal centre. Stage 1 already centres its 288 canvas (`anchorAtNotchCenter=false` → `(screenW − size.width)/2`), so the pill is correct; only the expanded stages used the fractional bias and drifted.
- **Fix**: drop the fractional branch — centre the window for every stage: `x = (screenW − size.width)/2`. Kept the `anchorAtNotchCenter` parameter for call-site compatibility (`_ = anchorAtNotchCenter`) so `place`/`animateTo`/`reapplyUserOffset` signatures are untouched. Bonus: pill→chips→result now grow symmetrically from a fixed centre instead of jumping right.
- **Rule**: "centered below the notch" means the WINDOW centre = screen centre (`(screenW − width)/2`). Don't anchor a fraction of the window width unless you specifically want a non-centre element (e.g. a left badge) under the camera — and the user's reference point is the centre grabber.

### [PERF-01] Cold-start hitch on first drop = uncached chips subtree, not file IO — prewarm the REAL leaf views
- **Mistake**: noticeable lag between dropping a file and the chips card appearing, worst right after launch. First instinct ("file is slow to load / fake the pop") was wrong: `setChips` does **zero IO** (`FileInspector.suggestedActions` is a pure string switch; content extraction only runs later when an action fires), and the window resize is already instant. The lag is SwiftUI's **one-time cold cost** the first time the chips subtree is laid out — generic specialisation, Core Text glyph caches, the LiquidGlass blur/Metal pipeline, NSWorkspace icon service.
- **Why the old prewarm didn't help**: `prewarmSwiftUI()` hosted a 1×1 `Color.clear` — it warmed *NSHostingView in general* but none of the actual chips leaf views, so their first layout still happened on the drop hot path.
- **Fix**: added `OverlayPrewarmView` (composes the SAME leaves the chips card uses — `FilePillsRow` / `ActionChip` / `PromptField` / `MarkdownText` + `.liquidGlass`) and host THAT at launch in an off-screen (`x:-10_000`), zero-alpha window, `orderBack` to force a real layout pass, release after 2 s.
- **Rule**: to kill a cold-render hitch, prewarm the **exact view types** that appear on the hot path, not a placeholder. Keep `OverlayPrewarmView` in sync if the chips card's leaf views change. Diagnose "lag" by first confirming whether the slow path actually does IO — here it didn't.

---

## Menu bar / status item

### [MENU-01] To intercept the menu-bar icon click, use NSStatusItem — not MenuBarExtra
- **Context**: the "minimize / restore" feature needs a LEFT-click on the menu-bar icon to *restore* a parked overlay session (or open the menu if none parked), and a RIGHT-click to always open the menu.
- **Mistake to avoid**: SwiftUI `MenuBarExtra` always presents its content on click — there is **no hook** to run conditional code on the icon click. You cannot make it "restore instead of open menu."
- **Fix**: drop `MenuBarExtra`; create an `NSStatusItem` in `AppDelegate` (`NSStatusBar.system.statusItem(withLength:)`), set `button.action`/`target`, and `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`. In the action read `NSApp.currentEvent?.type` (== `.rightMouseUp`) and `.modifierFlags.contains(.control)` to branch left vs right. Host the SwiftUI menu (`MenuBarView`) in a transient `NSPopover` (`NSHostingController` auto-sizes via `preferredContentSize`). App stays a menu-bar agent (`LSUIElement = YES`); keep the `Settings` scene so the app still has a Scene.
- **Gotcha**: `@Environment(\.openSettings)` only fires inside the App scene graph — it **no-ops from an NSPopover-hosted view**. Replace with `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (the `showSettingsWindow:` selector is macOS 14+; `showPreferencesWindow:` on 13). Rebuild the popover content per open so dynamic labels (hotkey, usage, paused) re-render like MenuBarExtra did.
- **Rule**: any conditional behaviour on the status-bar icon ⇒ own the `NSStatusItem`. Don't fight `MenuBarExtra`.

### [MENU-02] Minimize must park the session OUTSIDE `stage`, and never during loading
- **Why park outside `stage`**: leaving the live `stage` at `.result` while hidden blocks Stage-1 drag detection (`observeDragState` only shows the pill at `.waitingForDrop`), so new drags would silently do nothing while minimized. Snapshot the session into a separate `MinimizedSnapshot`, then fully tear the overlay down (reuse `hideOverlay()` → `reset()` to `.waitingForDrop`). Crucially, `reset()` must **not** clear the snapshot; only a genuine new drop (`setChips`) supersedes it.
- **Why not during loading**: an in-flight AI `Task` completes by writing `vm.stage = .result`. If you minimize during `.loading`, teardown resets `stage` to `.waitingForDrop`; the Task then overwrites it while hidden and the parked snapshot (still `.loading`) restores to a spinner that never resolves — the reply is lost. **Gate the − button to settled stages** (chips/result/error), never loading.
- **Rule**: "minimize = stash a snapshot + full teardown," not "hide the window with stage intact." Exclude any stage with in-flight async that writes back to `stage`.

### [MENU-03] Show a native NSMenu from the NSStatusItem — don't host the menu view in an NSPopover
- **Context**: after MENU-01 swapped `MenuBarExtra` → `NSStatusItem`, the menu was hosted in an `NSPopover(NSHostingController(MenuBarView()))`. `MenuBarView` is authored as a *menu* (Buttons, `Divider`s, a nested `Menu`, `.keyboardShortcut`). `MenuBarExtra`'s default `.menu` style had rendered those as **native macOS menu items**; the popover instead rendered them as stacked SwiftUI buttons in a card — wrong styling.
- **Fix**: build a real `NSMenu` in `AppDelegate` (`buildStatusMenu()`), rebuilt fresh per open so dynamic labels stay current. Keep the conditional left-click=restore by attaching the menu only for one click: in the click handler set `statusItem.menu = buildStatusMenu(); button.performClick(nil)`, then in `NSMenuDelegate.menuDidClose` **defer** `statusItem.menu = nil` (`DispatchQueue.main.async`) so the next plain left-click reaches `statusItemClicked` again. (If `statusItem.menu` is left set, every click just opens the menu and the action never fires.)
- **Disable submenu**: use one selector `menuDisableUntil(_:)` reading `representedObject` (the absolute `disabledUntil` timestamp) instead of N selectors. Settings item still uses the `showSettingsWindow:` selector (MENU-01).
- **Rule**: a menu-shaped SwiftUI view (`Button`/`Divider`/`Menu`) only looks native inside `MenuBarExtra`'s `.menu` style. Once you own the `NSStatusItem`, author the menu as an `NSMenu`, not a hosted SwiftUI card. (`MenuBarView.swift` was deleted as dead code.)

### [MENU-04] `showSettingsWindow:` silently no-ops from an NSMenu in an accessory app — manage the Settings NSWindow yourself
- **Symptom**: after MENU-01/03 (MenuBarExtra → NSStatusItem + NSMenu), the "Settings…" menu item did nothing — no window appeared.
- **Root cause**: `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (the MENU-01/03 approach) walks the responder chain looking for a handler installed by SwiftUI's `Settings` scene. For an `LSUIElement` agent with no key window — and dispatched from a status-item NSMenu action — that responder is **not reachable**, so `sendAction` returns false and nothing opens. (`MenuBarExtra` had provided a working Settings command for free; hand-rolling the menu lost it.)
- **Fix**: open a real `NSWindow` we own (`NSHostingController(rootView: SettingsView())`, `isReleasedWhenClosed = false`, `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`) — the exact pattern already used by `showHotkeyPicker` / `showOnboarding`. Keep the `Settings { SettingsView() }` scene for the system ⌘, (it shares the same singleton stores, so a second instance stays state-consistent).
- **Rule**: in a menu-bar/accessory app, don't rely on `showSettingsWindow:` from menu actions — present settings via a self-managed `NSWindow`. Selector-based scene routing only works when the SwiftUI scene's responder is in the chain.

---

## General

### [GEN-01] Always enter plan mode before multi-step changes
- Per CLAUDE.md: plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- Write plan to tasks/todo.md first, check in before implementing

### [GEN-02] After a correction, capture the lesson immediately
- Don't wait until end of session — write it to tasks/lessons.md right away
- Pattern: What was wrong → Why → Fix → Rule to prevent recurrence

## Backend / Worker

### [WORK-01] Client↔Worker request contract drifted silently (messages vs content)
- **What was wrong:** the Cloudflare Worker `/v1/complete` was scaffolded for the OLD
  single-shot API (`{ action, system, content: String }`) and validated `typeof
  body.content !== "string"` → 400. But the chat redesign changed the app to send the
  multi-turn array `{ system, messages: [...] }` with NO `content` field. Result: every
  hosted free-tier call would have 400'd, and nobody noticed because the app defaults to
  BYOK and the hosted tier is gated behind `EntitlementStore.tier != .byok`.
- **Why:** there is no shared type / no compile-time link across the Swift↔JS boundary, and
  no test exercises the hosted path. A protocol change on the client (`complete` → `reply`)
  didn't fan out to the Worker.
- **Also found:** the Worker hardcoded `max_tokens: 1024`, ignoring the per-action ceilings
  the app sends AND re-introducing the exact 2.5-Flash cut-off (thinking tokens eat the cap).
- **Fix:** Worker now reads `messages` (legacy `content` still accepted), forwards the full
  multi-turn conversation, honors `body.max_tokens` with Gemini headroom
  (`max(req+1024, 2048)` + `reasoning_effort: low`), and inlines the image into the first
  user turn. Requires `wrangler deploy` (the agent can edit JS but cannot deploy).
- **Rule:** when changing the `AIProvider` wire shape, grep `worker/src` in the SAME change
  and update `/v1/complete` to match. The Worker is a provider too — treat it like one.

### [COST-01] "Supporting" a new file type can silently bill the operator — binary → Latin-1 garbage
- **Context:** added video/audio (`.mp4`/`.mp3`/…) as droppable so they reach the chips stage.
  The naive change is to delete them from `FileInspector`'s unsupported list — but that ALSO routes
  them into the hosted-AI path.
- **What was wrong:** `FileContentExtractor.extract` has a catch-all `default:` text reader whose last
  resort decodes raw bytes as `isoLatin1` (so non-UTF-8 *text* never throws). For a binary mp4/mp3 that
  yields ~24k chars of garbage that would be POSTed to Gemini on any prompt → real operator tokens spent
  for a guaranteed-nonsense answer. A clean build hides this completely.
- **Fix:** decouple "droppable" from "has AI actions." `isUnsupportedFileType` exempts media (droppable
  for Pillar 1/2) while `suggestedActions` returns `[]`. The media chips stage hides the prompt field +
  AI tabs so the model can't be invoked by construction, and `buildMultiFileContent` ALSO guards
  (single-media throws; multi-file skips with a placeholder) as defense-in-depth.
- **Rule:** before marking any file type "supported," trace what `FileContentExtractor` does with it.
  If it can't produce meaningful text/vision input, it must NOT reach the model — block at the UI
  (no prompt path) AND in the content builder. Operator cost first: a metering hole opened by a
  too-permissive extractor is invisible until the bill arrives.

### [MEDIA-01] Media utilities are async — sync dispatch would beach-ball; keep heavy work off the main actor
- **Context:** batch-2 media tools (`Core/MediaTools.swift`: extract audio, transcribe, GIF, frame,
  compress, mute, convert). The batch-1 utility dispatch (`FileToolActions.run` → `try op()`) runs the
  op **synchronously on the main thread** — fine for instant ImageIO/PDFKit, fatal for AVFoundation.
- **What was wrong (avoided by design):** an `AVAssetExportSession` export, a 100-frame GIF decode, or a
  whole-file transcription takes seconds. Reusing the sync path would freeze the overlay (spinning
  beachball) for the duration. Also: the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
  plain `enum MediaTools` is implicitly `@MainActor` — naive `async` funcs would still hop back to main
  for CPU work.
- **Fix:** separate async path. `FileToolActions.performAsync(_:fileURL:sessionFiles:) async` for the
  9 media cases (sync `perform` untouched for the rest). The view sets `@State runningTool` → `Task { await
  performAsync(); runningTool = nil }`, and `MenuActionRow(isLoading:)` shows a per-row spinner +
  `.disabled` (re-entrancy guarded so one media op runs at a time). Heavy CPU (GIF/frame `copyCGImage`
  loops) runs inside `DispatchQueue.global(qos:.userInitiated).async` bridged by
  `withCheckedThrowingContinuation`, so the main actor is never blocked even though the type is
  MainActor-isolated. Exports/transcription are already off-main via AVFoundation/Speech's own threads.
- **Gotchas baked in:** (1) deployment target is 14 → use `session.exportAsynchronously` (NOT the 15+
  `export(to:as:)`); the modern async `load(.duration)` / `loadTracks(_:)` are 13+ so they're fine.
  (2) Container convert + mute try `AVAssetExportPresetPassthrough` first, fall back to `HighestQuality`
  on codec/container incompatibility (and delete the partial output before retry). (3) Transcription:
  authorize via `SFSpeechRecognizer.requestAuthorization`, set `requiresOnDeviceRecognition` only when
  `supportsOnDeviceRecognition` (on-device = no network, no length cap, no operator cost; the
  `NSSpeechRecognitionUsageDescription` string was already in the pbxproj from dictation, so NO Info.plist
  edit). For VIDEO, extract audio to a temp `.m4a` first — feeding a video container to
  `SFSpeechURLRecognitionRequest` is unreliable. (4) Every op writes a deduped sibling via
  `FileTools.uniqueDestination` and the caller reveals it in Finder — same contract as batch 1.
- **Rule:** any new utility backed by AVFoundation/Speech/Vision (or anything that can take >100 ms) goes
  through `performAsync` + `runningTool` spinner, with the blocking work explicitly dispatched off the
  main actor. Never extend the sync `run` path for slow ops. Cost note: all of this is local/on-device →
  zero proxy/Gemini spend, consistent with operator-bill-first.

### [TEXT-01] Not every utility produces a file — add an INFO path; build CSV/JSON by hand to keep order & types
- **Context:** batch-3 text/data tools (`Core/FileTools.swift`: sort/dedupe lines, count, SHA-256,
  Base64 ↔, minify JSON, CSV ↔ JSON). All synchronous Foundation/CryptoKit — correctly kept on the sync
  `run` path (instant, unlike batch-2 media; the `isAsync` flag stays false).
- **What was new:** two ops (`countStats`, `sha256`) return a VALUE, not a sibling file, so the existing
  "return URL → reveal in Finder" contract didn't fit. Added `FileToolActions.runInfo(title:) { String }`
  + `presentInfo` → an `NSAlert` with **Copy** (→ `NSPasteboard`) / **Done**. New presentation path, no
  new stage, no enum flag. SHA-256 streams the file in 1 MB chunks via `FileHandle.read(upToCount:)` +
  `SHA256().update`/`finalize` so a multi-GB file never loads into RAM.
- **CSV/JSON gotchas (the real work):** `JSONSerialization` on a Swift dictionary loses key ORDER and you
  can't choose it — so `csvToJSON` builds the JSON string BY HAND (column order preserved) and treats
  every cell as a STRING (CSV has no types → lossless, no number/bool guessing). `jsonToCSV` goes the
  other way: union of keys SORTED (dicts are unordered, so first-seen order is meaningless), RFC-4180
  quoting (`csvField`: quote on comma/quote/newline, double embedded quotes), nested values → compact
  JSON, `NSNull` → empty, `NSNumber` bool detected via `CFGetTypeID(n) == CFBooleanGetTypeID()`. The CSV
  reader is a hand-rolled RFC-4180 state machine (handles quoted commas/newlines, `""` escapes, `\r\n`).
- **Trailing-newline trap:** `text.components(separatedBy:"\n")` on a file ending in `\n` yields a trailing
  empty element. Sorting/deduping it silently reorders or drops the blank line and changes the file. Fix:
  `splitLines` strips the trailing empty element and reports `trailingNewline` so transforms re-emit it.
- **Gating:** new `FileInspector.isTextFile` + `textExtensions` (plain text/code/data only — deliberately
  NOT pdf/docx/rtf, which are containers, not line-oriented text). `.b64`/`.base64` are in the set so a
  dropped Base64 file offers Decode instead of Encode. SHA-256 is the one UNIVERSAL addition (any file).
- **Rule:** a utility that yields a value (hash, counts, info) uses `runInfo`/`presentInfo` (Copy button),
  not the reveal-sibling path. For structured-data conversions, hand-build the output when you need to
  preserve column order or avoid type coercion — `JSONSerialization`'s dict round-trip will betray both.
  All local → zero API cost, operator-bill-first intact.

### [QL-01] The Quick Look "accepts" hook is `acceptsPreviewPanelControl(_:)`, not `acceptsPreviewPanel(_:)`
- **Context:** adding system Quick Look (`QLPreviewPanel`) preview on pill click. `QLPreviewPanel` walks
  the key window's responder chain for an object implementing the informal `QLPreviewPanelController`
  protocol. `OverlayWindow` (NSPanel, `canBecomeKey`) is the responder; I added the three hooks with
  `override func` since they live on a category that NSResponder picks up.
- **What was wrong:** I named the first hook `acceptsPreviewPanel(_:)`. Build failed with exactly one
  error: `method does not override any method from its superclass`. The other two hooks
  (`beginPreviewPanelControl`/`endPreviewPanelControl`) compiled — so it looked like *they* were the
  problem, but the real culprit was the misnamed accepts-hook (the only one whose name I'd shortened).
- **Fix:** rename to `acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool`. All three hooks use
  `override` (the category methods are inherited via NSResponder); none need a bare `@objc`.
- **Why it misled:** a wrong-name `override` reports against the *declaration line that has no match*,
  not against the conceptually-related neighbors. When one of N `override`s in a cluster fails, suspect a
  typo'd selector on THAT line first — don't assume the whole protocol is mis-imported.
- **Rule:** the QL responder-chain trio is `acceptsPreviewPanelControl(_:) -> Bool` /
  `beginPreviewPanelControl(_:)` / `endPreviewPanelControl(_:)`, all `override` on an NSResponder
  subclass. Point the panel's `dataSource`/`delegate` at your controller in `begin`, nil them in `end`.
  NSURL conforms to `QLPreviewItem` natively — no wrapper needed. Works from any non-sandboxed app;
  Quick Look is not Finder-only.

### [CLIP-01] An NSEvent local monitor's `?? event` resurrects a key you meant to swallow
- **Context:** the ⌃⌘V clipboard picker (`ClipboardPicker`) installs a local keyDown monitor so digit
  keys (1–9, 0) and Esc select/dismiss while the borderless panel is key. The monitor closure must
  return `NSEvent?` — return the event to pass it through, return `nil` to swallow it.
- **What was wrong:** I wrote `MainActor.assumeIsolated { self?.handleKey(event) ?? event }`. When
  `handleKey` returns `nil` (its signal for "I handled this, swallow it") the `?? event` immediately
  substitutes the original event back — so every matched digit/Esc was *passed through* to the app under
  the panel. The swallow never happened; numbers would type into whatever was focused.
- **Why:** optional-chaining + `??` collapses two distinct nils ("self is gone" and "handler swallowed")
  into one branch, and the fallback (`event`) is exactly the value the handler was trying to suppress.
- **Fix:** guard `self` first, then return the handler's result verbatim:
  `guard let self else { return event }; return MainActor.assumeIsolated { self.handleKey(event) }`.
  Now `nil` from the handler propagates as the swallow.
- **Rule:** in an `addLocalMonitorForEvents` closure, never `?? event` the handler's return. Unwrap
  `self` separately and pass the handler's `NSEvent?` through untouched, so its `nil`-means-swallow
  contract survives. (The favorite-tools `handleToolHotkey` already does this — it returns the event or
  `nil` directly with no coalescing.)

### [CLIP-02] Carbon `RegisterEventHotKey` is the right tool for a system hotkey that must NOT leak
- **Context:** ⌃⌘V should open the clipboard picker from anywhere and the combo must not also reach the
  frontmost app's text field. An `NSEvent` global monitor can observe keys app-wide but **cannot consume
  them** (and needs Accessibility). Carbon `RegisterEventHotKey` registers a system hotkey that the OS
  routes to us and **swallows** before the focused app sees it — and needs no Accessibility permission.
- **Pattern (`Core/GlobalHotkey.swift`):** `InstallEventHandler` + `RegisterEventHotKey`; the C callback
  is a bare function (no captured context), so pass `Unmanaged.passUnretained(self).toOpaque()` as
  `userData` and recover it INSIDE `MainActor.assumeIsolated { Unmanaged<GlobalHotkey>.fromOpaque(...) }`
  — only the raw pointer crosses the actor boundary, never a non-Sendable value. Carbon hotkey events are
  delivered on the main runloop so `assumeIsolated` is sound.
- **Rule:** "global shortcut that consumes the keystroke + no Accessibility" → Carbon RegisterEventHotKey.
  "observe our own app's keys, optionally swallow, no system scope" → `addLocalMonitorForEvents`.
  "observe other apps' keys, cannot swallow, needs Accessibility" → `addGlobalMonitorForEvents`.

### [CLIP-03] Restore focus permission-free; gate cross-app paste on intent + live TCC state
- **What was wrong:** Clipboard History selection copied the entry and closed its panel, but Dragaway
  had activated itself to receive number keys and never returned activation. The user therefore had
  to click the original app before pressing ⌘V. Simply posting ⌘V would hide that focus bug behind a
  mandatory Accessibility permission.
- **Why:** pasteboard ownership and application activation are separate. `NSPasteboard` can provide
  data but cannot command another process to consume it. `NSRunningApplication` activation is ungated;
  synthesizing the Command-V keyboard events is TCC-gated. Activation is also asynchronous, so a fixed
  delay can paste into Dragaway or into a third app selected during the handoff.
- **Fix:** capture `NSWorkspace.frontmostApplication` before showing the picker; after selection use
  macOS 14 cooperative activation (`NSApp.yieldActivation` + `activate(from:options:)`). Default-off
  `EnhancedAccess` stores user intent separately from `CGPreflightPostEventAccess()` and requests via
  `CGRequestPostEventAccess()` only on OFF→ON. When both gates pass, a one-shot token waits for the
  exact target's activation notification, re-checks the frontmost PID and TCC, then posts one ⌘V.
  Timeout, a third-app activation, revocation, failed payload write, or failed activation cancels it.
- **Rule:** never conflate focus restoration with auto-paste. Always restore focus without permission;
  synthesize input only after explicit opt-in + live authorization + exact-target confirmation, and
  clear one-shot state before posting so competing callbacks cannot double-fire.

### [SUGG-01] Adding an `AIAction` case ripples into several exhaustive switches
- **Context:** the heuristic smart-suggestions work added `AIAction.translateEnglish`. The build broke
  at `ModelRouting.swift:63` ("switch must be exhaustive") — `AIAction.routing` switches on every case
  with no `default`.
- **Why:** `AIAction` is a fixed enum consumed by several **exhaustive** switches that deliberately omit
  `default` so a new case forces a compile-time decision. Known sites: `AIAction.icon`, `.systemPrompt`
  (both in `AIAction.swift`) and `.routing` (`ModelRouting.swift`).
- **Fix:** add the new case to all three (icon, systemPrompt, routing tier). Build is the check.
- **Rule:** when adding an `AIAction`, grep for `switch self`/`switch action` over `AIAction` and update
  every exhaustive one. Other suggestion lists (`FileInspector.baseActions`, the follow-ups map in
  `OverlayView.swift`) use `default`, so they compile without the new case but won't *surface* it until
  you add it where wanted.

### [SUGG-02] Content-aware suggestions must peek cheaply AND be memoised (body recompute)
- **Context:** making `FileInspector.suggestedActions(for:)` content-aware meant reading file bytes. It's
  called not just at drop time but inside a SwiftUI `ForEach` in the result-stage Suggested rail
  (`OverlayView.leftColumn`), which re-evaluates on every body render.
- **Why:** an un-memoised per-render file read (PDFKit first-page parse / 16 KB FileHandle read) on the
  main thread would hitch the result UI.
- **Fix:** `Core/FileSignals.peek` is hard-bounded (text → first 16 KB via `FileHandle.read(upToCount:)`;
  PDF → first page only; else nothing) and `FileInspector` memoises it in a `peekCache` keyed by
  `path#mtime`. All callers are @MainActor (stage writes + SwiftUI body), so a plain dictionary is safe.
  `isUnsupportedFileType` uses `baseActions` (emptiness only) to skip the peek entirely.
- **Rule:** if a function called from SwiftUI `body` touches the filesystem, bound the read AND cache it
  (mtime-keyed); never let `body` trigger an unbounded or repeated file parse.

### [OUTDIR-01] Redirect file-utility output by RELOCATING, not by threading a dir through producers
- **Context:** the "Output Directory" feature needed every file-PRODUCING utility (≈15 in `FileTools`
  + media in `MediaTools`) to write into a user-chosen folder instead of next to the original.
- **Why not edit each producer:** each computes its own `url.deletingLastPathComponent()` output dir
  inline — adding an `outputDir:` param to ~15 funcs is a huge, error-prone signature change, and some
  are `async` / off-main (AVFoundation).
- **Fix:** leave ALL producers untouched. They write the sibling as before and return the URL; the two
  dispatch wrappers (`FileToolActions.runFile` + `performAsync`) then call `relocate(output, original:)`
  = `try? FileTools.move(output, to: dir)` BEFORE `presentFileResult`. One resolver
  (`effectiveOutputDir`) consults the session override then `OutputDirectoryStore`. `FileTools.move`
  already dedupes and works on the folder outputs (split/pdf→images) too. Best-effort: on move failure
  return the produced file where it is (never lose output).
- **Rule:** to redirect where a pipeline's artifact lands, prefer a single post-production relocate at
  the dispatch funnel over editing every producer. Mirror an existing per-category store
  (`FavoriteToolsStore`) for the persisted General + per-`FileCategory` + `useGeneral` shape.
- **Caveat:** the move runs on the main actor (dispatch funnel is `@MainActor`). Same-volume = instant
  rename; a cross-volume output dir would copy+delete on main and could hitch for large media. Move it
  off-main if that ever bites.

### [PDF-MD-01] PDF→Markdown: use PDFPage.attributedString; detect bold by font NAME, not traits
- **Context:** "Export as Markdown" needs structure (headings/bold/lists) that `PDFPage.string` throws
  away. `PDFPage.attributedString` keeps it.
- **Findings (verified with a standalone PDFKit probe):**
  - **Font point SIZE round-trips reliably** → heading detection by size ratio (vs the doc's modal body
    size) is the solid primary signal. `ratio≥1.7→#`, `≥1.35→##`, `≥1.22→###`.
  - **`NSFont.fontDescriptor.symbolicTraits.contains(.bold)` is UNRELIABLE through a PDF** — PDFs encode
    weight in the font NAME (e.g. "Times-Bold"), not as a trait. Detect bold by sniffing the font name
    (`bold`/`black`/`heavy`/`semibold`) and the descriptor's numeric `.weight ≥ 0.4`, not just traits.
    (System-font synthetic test PDFs flatten bold entirely via the headless `.SFNS`→Times fallback —
    a misleading test; real Word/LaTeX/Pages PDFs carry named bold faces.)
  - **Reading order:** `attributedString` is in reading order for well-formed PDFs. A synthetic PDF drawn
    into a `flipped:true` CGContext comes back REVERSED — a test artifact, not an app bug. Verify by
    printing `attr.string` order, and generate test PDFs line-by-line top-down in native (non-flipped)
    coords.
- **Rule:** structure from font SIZE (trustworthy) + emphasis from font NAME/weight (traits lie). Tables
  are out of reach locally — degrade to paragraphs. Validate PDF heuristics with a real top-down PDF, not
  a flipped-context synthetic one.

### [WEB-01] Decorative overflow layers can steal clicks from controls outside the demo viewport
- **What was wrong:** moving the website's file-type controls above the AI Drop demo rendered correctly,
  but Playwright clicks did nothing. The `.sim .backdrop` / `.scrim` layers use large negative insets
  and `overflow: visible`, so they visually/physically extended over the new toggle and intercepted
  pointer events.
- **Why:** visual background layers are still hit-testable unless explicitly disabled. A control can look
  unobstructed while an invisible absolute child from a later sibling sits above it in the hit-test stack.
- **Fix:** give the external toggle a positioned z-index and set `pointer-events: none` on decorative
  `.backdrop` / `.scrim` layers.
- **Rule:** when a demo viewport intentionally lets decorative absolute layers bleed outside its box,
  make those layers non-interactive or explicitly stack nearby controls above them before trusting visual
  placement.

### [WEB-02] Idle replay hover guards need a coordinate fallback
- **What was wrong:** the AI Drop website demo paused correctly when the cursor entered the demo area,
  but a leave-only implementation was brittle during verification and could leave the idle replay timer
  cancelled if the pointer transition was missed.
- **Why:** `pointerenter`/`pointerleave` are fine for normal UI, but animated hero surfaces with transparent
  layers, browser automation, and viewport edges can make hover state hard to observe and easy to miss.
- **Fix:** keep the direct enter/leave listeners, but also listen for document pointer movement and compare
  `clientX/clientY` against the live `.sim-col` bounds. Treat document/window leave or blur as not hovered.
- **Rule:** when hover state controls a timer, maintain it from both boundary events and coordinates; always
  have an explicit "outside the document/window" path that resumes the timer.

### [WEB-03] Large scrollable lists should animate as one block, not one fill per row
- **What was wrong:** after expanding the AI Drop website demo from 7-ish actions to the full catalogue,
  each action was still wrapped in its own `.fill`. The hero choreography had to reveal many more rows
  than there were orbit arrivals, making the card animation feel broken once the list height was capped.
- **Why:** `.fill` is a structural animation primitive for major card sections, not for unbounded list
  items. A scroll container with many animated children fights the fixed max-height and delays later
  sections such as Open-in and the prompt.
- **Fix:** wrap `.ph-tabcontent` itself in a single `.fill`, and render the full catalogue as `.ph-chip`
  children inside that scrollbox. Only the first bounded visible set (seven rows in the website hero)
  gets a lightweight `.ph-chip--pop`; rows after that are skipped so the Open-in launcher can animate.
  Keep the old window metrics with a baseline visible-row count, while `scrollHeight` carries the full
  catalogue.
- **Rule:** when a demo card contains a scrollable list, animate the scrollbox once and populate it with
  normal rows. Per-row reveal is okay only for a short visible subset; never wrap an unbounded list in
  one `.fill` per row.

### [WEB-04] Version touched static assets when verifying local website animation changes
- **What was wrong:** the website preview picked up the updated `app.js` markup for the prompt mic button,
  but kept an older `icons.js`, so the new `mic` symbol hydrated as the generic fallback dot.
- **Why:** changing the page URL query string does not necessarily invalidate separate static assets whose
  script/style URLs stay unchanged.
- **Fix:** add a matching query version to the touched CSS/JS asset URLs in `index.html` before browser
  verification, then load the preview with a fresh page URL.
- **Rule:** for static demos served by a simple local server, cache-bust every touched asset, not just the
  page URL, before trusting browser evidence.

### [WEB-05] Keep curated hero actions separate from the exhaustive feature grid
- **What was wrong:** the AI Drop hero demo had been switched to derive all chip rows only from the lower
  `fileTypes[].does` catalogue. That dropped older curated demo options such as "Find trends" and mixed
  generic utility actions like "Show in Finder" into the hero.
- **Why:** the feature grid is an exhaustive catalogue, while the hero card needs a curated, product-demo
  set that can include narrative options not listed in the bottom grid.
- **Fix:** restore `pill.tabRows` as hero-only seed data from the website backup, merge it before the
  catalogue-derived rows, dedupe by action label, and keep unwanted generic fallback rows out of `any`.
- **Rule:** do not make the hero action list depend solely on the lower feature-grid catalogue; preserve a
  hero-only action layer for curated examples and merge it deliberately.

### [WEB-06] Re-hydrating a single icon element requires replacing that element's inner SVG
- **What was wrong:** the website's cursor-attached file ghost changed its `data-icon` per file type, but
  the visible SVG disappeared and the file thumbnail looked like an empty gray surface.
- **Why:** `SFIcons.hydrate(root)` scans descendants with `[data-icon]`; when called with the icon element
  itself as `root`, it does not hydrate that root node. Clearing `innerHTML` before that call removed the
  prior SVG and inserted nothing.
- **Fix:** for single-element updates, set `icon.innerHTML = SF.svg(file.icon, ...)` directly and update
  `data-icon` / `data-icon-done`. Use `SF.hydrate(container)` only when the target icons are descendants
  of the passed container.
- **Rule:** know whether a hydrator includes the root element or only queries descendants before using it
  for dynamic updates; if it is descendant-only, update the single icon directly.

### [WEB-07] Retiming one property in a combined WAAPI animation can require splitting timelines
- **What was wrong:** delaying the cursor/file fade by changing keyframe offsets inside the existing
  transform+opacity animation still made the fade visually coincide with the pill expansion.
- **Why:** the animation used a global cubic-bezier easing. That easing remapped the whole animation's
  progress, so offset math alone did not preserve absolute millisecond timing for the opacity segment.
- **Fix:** keep the transform keyframes on their original eased timeline, but move opacity to a separate
  linear WAAPI animation with its own `VANISH` end time.
- **Rule:** when a website demo needs one property to hit an exact timestamp, split that property into its
  own animation instead of relying on offsets inside a globally eased multi-property animation.

### [WEB-08] Smooth auto-height morphs by tracking layout height, not transformed bounds
- **What was wrong:** smoothing the website pill-to-card morph with a fixed start height worked, but using
  `getBoundingClientRect().height` for follow-up height updates picked up the liquid scale transform and
  made the target height bounce.
- **Why:** transformed bounds are visual bounds. During squash/stretch keyframes they are not the same as
  the element's layout height, so feeding them back into `style.height` couples the distortion to layout.
- **Fix:** use `offsetHeight`/`scrollHeight` from the card content, update the outer pill height
  monotonically while rows fill in, then release the inline height after the choreography finishes.
- **Rule:** when animating a container's height while separately animating transform distortion, measure
  layout height only; never feed transformed visual bounds back into layout.

### [WEB-09] Delay a sub-animation inside its own curve, not by shifting shared timeline beats
- **What was wrong:** an 80 ms delay request for the orbit radius expansion was implemented by moving the
  shared `EXPAND` / `VANISH` / `FILL_START` beats, which retimed the pill/card morph instead of only the
  radius pre-ramp.
- **Why:** those constants coordinate multiple choreography tracks. Moving them changes the visible drop,
  vanish and fill sequence even when the desired change is limited to one visual property.
- **Fix:** restore the shared beats and add a dedicated radius hold window before the 0.9 → 1.2 pre-ramp.
- **Rule:** for local timing polish, add timing state to the local property curve first. Only move global
  timeline constants when the whole choreography beat is intentionally changing.

### [WEB-10] Cancel fill-forwards WAAPI animations before reusing the same DOM element
- **What was wrong:** a replay prelude faded out the existing pill with a `fill: "forwards"` animation,
  then reused the same `#pill` element for the next waiting/card state.
- **Why:** a completed WAAPI animation still owns the animated property while its forwards fill is active.
  Reassigning classes or inner HTML does not automatically release that opacity/transform override.
- **Fix:** cancel the pill's completed animations immediately after the fade and before rebuilding the next
  state. Do it in the same task as the reset so there is no visible flash back to the old card.
- **Rule:** if a static website demo reuses a DOM node after a one-off WAAPI transition, cancel that node's
  fill-forwards animations before relying on CSS classes for the next state.

### [WEB-11] Keep prelude-only motion from advancing the next choreography's property curve
- **What was wrong:** the replay prelude made tools rotate while popping in, but the helper also advanced
  the orbit radius curve. When the normal choreography started, the chips snapped back to the initial
  0.9 radius.
- **Why:** the handoff intentionally carried the spin phase into the next loop, but reused the same `t`
  for radius. Spin phase should continue; the local radius pre-ramp should still start at frame 0.
- **Fix:** during the replay pop-in, sample the orbit transform with a fixed radius time and only advance
  the spin offset. Pass that spin offset into the normal choreography.
- **Rule:** when stitching two WAAPI timelines, carry forward only the property state that should be
  continuous. Pin every other property to the receiving timeline's expected start value.

### [WEB-12] Split positional transforms from visible tile styling before pop-in effects
- **What was wrong:** separating the orbit transform from the icon pop removed the loop hitch, but left
  the glass tool tiles visible from the start because the background still lived on the rotating outer
  `.orbit-chip`.
- **Why:** the outer element had to remain present and rotating for a smooth handoff. Any visible styling
  on that element shows immediately, even if the logo/content child is hidden.
- **Fix:** keep `.orbit-chip` as the invisible positioning/rotation layer and move the glass background,
  stroke, shadow, and content into an inner `.orbit-chip__shell`. Pop the shell, not just the logo.
- **Rule:** for animated orbit items, reserve the outer node for position-only transforms. Put visible
  tile styling on an inner node when the whole tile needs an independent reveal animation.

### [WEB-13] Preserve animated progress by freezing computed pseudo-element state
- **What was wrong:** the website file-type toggle progress looked like a late shine instead of an
  actual timer, and hover cancelled the replay by removing the progress class, which reset the fill.
- **Why:** the progress animation used an eased keyframe curve with most visual growth near the end, and
  the CSS pseudo-element state was not stored anywhere when the timer was cancelled.
- **Fix:** make the thumb progress transform linear from the start, freeze the computed `::after`
  scale/opacity/filter into CSS variables on hover, and resume the remaining timeout from that stored
  progress.
- **Rule:** if a CSS animation is meant to communicate elapsed time, keep its progress property linear
  and persist the computed state before pausing or cancelling it.

### [WEB-14] Keep shared beats unchanged when inserting a boot prelude
- **What was wrong:** adding an initial tool/letter pop could have been done by moving `T.APPEAR`,
  `T.PILL_APPEAR`, `T.EXPAND`, and the fill timings directly.
- **Why:** those constants define the established drag/drop/morph choreography and are reused by replay
  paths. Changing them makes unrelated beats drift and makes later timing requests harder to reason about.
- **Fix:** keep the `T.*` values unchanged and run any new intro beat before the main choreography starts.
  If the intro should match replay, use the replay prelude handoff instead of duplicating offset math.
- **Rule:** preserve shared timing constants unless the existing choreography itself is meant to change.
  Insert new lead-in beats outside the main timeline.

### [WEB-15] Share the replay prelude when first boot must match the loop
- **What was wrong:** the first boot inserted the tool/letter pop by delaying the existing choreography
  with a local timeline offset and a longer custom pop window.
- **Why:** delaying the main animations while also carrying the pop duration into the spin phase changed
  the perceived acceleration window. It made the first boot diverge from the replay loop and reintroduced a
  small handoff hitch when the last tool finished appearing.
- **Fix:** route first boot and replay through the same prelude/handoff helper. Keep the established
  `runChoreography` timeline unshifted, keep visible tool shells on the inner node, and carry forward only
  the spin phase from the prelude.
- **Rule:** when first-run choreography should behave like replay, share the exact prelude implementation;
  do not approximate it with extra offsets inside the main choreography.

### [WEB-16] Change replay content after the outgoing surface is hidden
- **What was wrong:** the website replay advanced the file-type tab at the start of the replay prelude,
  while the expanded demo window was still visible.
- **Why:** the tab push changes the active content immediately, so users see the next file type appear on
  the old, still-open card before the reset/fade choreography has visually handed off.
- **Fix:** keep the existing replay delays and fade duration, but move `advanceFileTypeForReplay()` after
  the pill fade completes and before rebuilding the next replay state.
- **Rule:** when a loop changes demo content between cycles, perform the content swap after the outgoing
  surface is hidden, not at the same moment the transition begins.

### [WEB-17] Keep marketing-page scroll progress spatially deterministic
- **What was wrong:** the product-page Stage replaced its linear scroll scrub with duration-weighted
  dwell and then a gate that combined trackpad distance with elapsed video playback.
- **Why:** media scheduling, looping playback, scroll inertia, and discrete chapter transitions made the
  same gesture feel inconsistent; users could meet the text before the video, get held between states,
  or advance at an unexpected point in an ongoing gesture.
- **Fix:** restore one pinned ScrollTrigger that scrubs the master timeline directly, while keeping the
  seven recording switch points and settled progress-dot destinations independent of video duration.
- **Rule:** for a marketing-page narrative, keep chapter position a deterministic function of scroll
  position. Validate any time-based resistance as an isolated prototype before replacing the baseline.

---

## UI ownership

### [UI-01] Keep object-scoped actions attached to the object's surface
- **What was wrong:** the first two-row header plan moved Share into the global header-control cluster
  together with collapse, navigation, minimize, and close.
- **Why:** Share acts on the file/session represented by the file pill, while the other controls act on
  the overlay itself. Moving it away weakens that ownership cue and changes a proven interaction even
  though the request only called for reorganising the surrounding layout.
- **Fix:** keep Share at the far right inside the full-width file-pill row and move only overlay/session
  controls into the compact top row.
- **Rule:** when rearranging a header, classify controls by ownership first. Object actions stay on the
  object surface unless the user explicitly asks to change that interaction.

### [UI-02] Shared rows can need asymmetric edge alignment
- **What was wrong:** a symmetric negative horizontal inset pulled both the trailing controls and the
  leading type label toward the card corners, although the label was meant to align with the file pill.
- **Why:** the two ends of the row have different visual anchors: the label belongs to the content
  column, while the window controls belong near the card edge.
- **Fix:** retain the normal leading inset and pull only the trailing edge outward; keep both distances
  scaled through `uiScale` and let the flexible spacer absorb width changes.
- **Rule:** do not assume both sides of a responsive row share an alignment target. Apply directional
  insets to the side that actually needs them instead of offsetting the entire row.

---

## AI model selection

### [MODEL-01] A live `/models` endpoint is availability data, not a compatibility contract
- **What was wrong:** treating every ID returned by a provider as a usable Dragaway chat model would
  expose embeddings, speech, image-generation, moderation, guard, and endpoint-specific models in the
  same picker as normal text/vision models.
- **Why:** OpenAI-compatible catalogues often mix several product APIs, and most do not report the
  request parameters or modalities supported by each ID.
- **Fix:** fetch the live account catalogue, exclude obvious non-chat families, annotate capabilities
  where the provider reports them, and place unrecognised but plausible chat IDs under an explicit
  "Other available models" group.
- **Rule:** use live catalogues to avoid stale IDs, but keep a small compatibility layer between raw
  provider data and a production model picker.

### [MODEL-02] Persist exact selections under stable provider keys
- **What was wrong:** provider `rawValue`s contain old marketing/model copy and the providers themselves
  hard-coded model IDs, so a UI-only picker would either become stale or silently disagree with the
  actual request route.
- **Why:** display labels are not durable identifiers, and replacing a disappeared model automatically
  breaks user trust and makes cost/quality unpredictable.
- **Fix:** give every provider a stable storage key, migrate each legacy hard-coded model once into its
  own persisted selection, inject that exact ID into every request, and keep missing selections visible
  as unavailable instead of substituting a default.
- **Rule:** provider/model selection is configuration, not routing advice. Persist exact IDs per provider
  and require an explicit user action to change them.

### [MODEL-03] Discover models from the same API surface used to execute them

- **What was wrong:** Gemini's first live picker used the native `generateContent` model catalogue
  while requests were sent through Google's OpenAI-compatible Chat Completions endpoint.
- **Why:** a provider can expose different model sets and capabilities on native, compatibility, and
  specialised APIs. "Available somewhere on this account" does not prove compatibility with the
  endpoint Dragaway actually calls.
- **Fix:** query Gemini's documented OpenAI-compatible `/models` endpoint, invalidate the old cache,
  and keep every provider catalogue aligned with its request surface.
- **Rule:** availability checks and execution must share an API family. If the request endpoint changes,
  version or invalidate its cached catalogue as part of the same change.

### [MODEL-04] Capability overrides must target documented model profiles

- **What was wrong:** broad family checks treated every Groq `qwen3` ID as supporting the same
  `reasoning_effort` values and missed newer vision-capable variants; unknown OpenAI aliases could
  likewise inherit the wrong image or sampling assumptions.
- **Why:** naming families are not capability schemas. Providers reuse family strings across text,
  vision, reasoning, preview, and endpoint-specific variants with different accepted parameters.
- **Fix:** keep live discovery broad, but apply request parameters and vision overrides only to
  documented exact variants or narrowly stable patterns; unknown models retain provider defaults.
- **Rule:** never infer a wire parameter from a loose substring when a provider documents support per
  model. A false negative may disable a feature; a false positive can make every request fail.

---

## Git coordination

### [GIT-01] Never create a branch or worktree just to relocate changes
- **What was wrong:** an agent found product-page files in the `thesis` checkout and created a new
  `codex/product-page` branch plus a third project worktree to hold them, even though an existing
  `main` worktree already contained the live-product development.
- **Why:** branches and worktrees are shared coordination state. Creating an agent-named branch or
  another checkout changes the repository topology for every person and agent, obscures the canonical
  `main`/`thesis` model, and makes ownership of uncommitted files harder to establish.
- **Fix:** move only the specifically approved files into the already existing checkout for the correct
  canonical branch, verify the destination, then remove only the agent-created temporary state.
- **Rule:** this repository has exactly two canonical branches, `main` and `thesis`. Never create,
  rename, copy, or remove a branch/worktree without explicit user approval. Use `git worktree list` to
  locate the existing checkout for the required branch.

### [GIT-02] Unexpected dirty or staged paths belong to someone else until proven otherwise
- **What was wrong:** after repository state changed between turns, an agent interpreted staged Thesis
  file deletions as accidental cleanup state and restored them without first establishing which person
  or agent had staged them.
- **Why:** multiple coding agents and the user can work concurrently. A dirty index or worktree is not
  evidence of a mistake; restoring, stashing, moving, or deleting those paths can destroy active work.
- **Fix:** inspect branch, status, worktree list, staged diff, and overlapping active work; touch only
  paths whose ownership and requested destination are known. Stop and ask when ownership is unclear.
- **Rule:** before every repository mutation run `git branch --show-current`,
  `git status --short --branch`, and `git worktree list`. Never restore, stash, stage, commit, move, or
  delete unexpected changes. In a shared dirty worktree, stage exact reviewed paths—never `git add .`.
