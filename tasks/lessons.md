# Lessons Learned — AI Drop

> Updated after every correction. Review at session start.

---

## macOS APIs

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

---

## Xcode / Build

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

### [PERF-01] Cold-start hitch on first drop = uncached chips subtree, not file IO — prewarm the REAL leaf views
- **Mistake**: noticeable lag between dropping a file and the chips card appearing, worst right after launch. First instinct ("file is slow to load / fake the pop") was wrong: `setChips` does **zero IO** (`FileInspector.suggestedActions` is a pure string switch; content extraction only runs later when an action fires), and the window resize is already instant. The lag is SwiftUI's **one-time cold cost** the first time the chips subtree is laid out — generic specialisation, Core Text glyph caches, the LiquidGlass blur/Metal pipeline, NSWorkspace icon service.
- **Why the old prewarm didn't help**: `prewarmSwiftUI()` hosted a 1×1 `Color.clear` — it warmed *NSHostingView in general* but none of the actual chips leaf views, so their first layout still happened on the drop hot path.
- **Fix**: added `OverlayPrewarmView` (composes the SAME leaves the chips card uses — `FilePillsRow` / `ActionChip` / `PromptField` / `MarkdownText` + `.liquidGlass`) and host THAT at launch in an off-screen (`x:-10_000`), zero-alpha window, `orderBack` to force a real layout pass, release after 2 s.
- **Rule**: to kill a cold-render hitch, prewarm the **exact view types** that appear on the hot path, not a placeholder. Keep `OverlayPrewarmView` in sync if the chips card's leaf views change. Diagnose "lag" by first confirming whether the slow path actually does IO — here it didn't.

---

## General

### [GEN-01] Always enter plan mode before multi-step changes
- Per CLAUDE.md: plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- Write plan to tasks/todo.md first, check in before implementing

### [GEN-02] After a correction, capture the lesson immediately
- Don't wait until end of session — write it to tasks/lessons.md right away
- Pattern: What was wrong → Why → Fix → Rule to prevent recurrence
