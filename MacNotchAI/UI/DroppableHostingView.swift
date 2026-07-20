import AppKit
import SwiftUI

/// NSHostingView subclass that acts as an NSDraggingDestination.
/// Drop detection is intentionally permissive — we always return .copy
/// for valid file URLs and guard the actual state transition in
/// performDragOperation. This prevents missed drops due to timing races.
///
/// NOTE: intentionally NON-generic (concrete `NSHostingView<OverlayView>`).
/// A generic `NSHostingView` subclass crashes the Swift compiler's IRGen pass
/// while emitting the implicit `deinit` under x86_64 + optimization (Release
/// archive only — arm64 Debug is fine), aborting the notarization archive.
/// Every call site already builds it with `rootView: OverlayView(...)`, so
/// pinning Content to `OverlayView` costs nothing and sidesteps the bug.
final class DroppableHostingView: NSHostingView<OverlayView> {

    // ── URL cache ─────────────────────────────────────────────────────────────
    // pasteboard.readObjects() can stall 150-300 ms in performDragOperation
    // because the source app starts tearing down its drag session the instant
    // the user releases the mouse — the pasteboard IPC round-trip races that
    // teardown and can block the main thread.
    //
    // draggingEntered fires while the drag is still fully in flight (source app
    // is alive and the pasteboard is open), so the read is always fast there.
    // Cache the result and reuse it in performDragOperation so we never touch
    // the pasteboard again at drop time.
    private var cachedDropURLs: [URL] = []
    /// Non-file payload (text / link / raw image) captured at draggingEntered —
    /// materialized into a small local file only when the drop actually lands.
    private var cachedPayload: DropMaterializer.Payload?
    /// Drag carries file PROMISES (Safari tab, Photos, Mail) — the real file is only
    /// written by the source app AFTER we accept the drop.
    private var cachedHasPromise = false
    /// Apple Mail inbox rows advertise a legacy promise alongside the modern receiver,
    /// which can time out without ever writing the `.eml`. Kept separate so fulfilment
    /// and recovery can never change proven Safari / browser-image promise behaviour.
    private var cachedIsMailPromise = false
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1      // serial → safe shared accumulator
        return q
    }()

    required init(rootView: OverlayView) {
        super.init(rootView: rootView)
        // Register all file drag flavours — modern + legacy fallback
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.file-url"),
            // "Drag anything" — text selections, links, raw images (no file behind them).
            .string,
            .URL,
            NSPasteboard.PasteboardType("public.url"),
            // Safari link/tab drags: legacy URL-with-title flavours. Without these
            // registered, AppKit never even offers us the drop.
            NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
            NSPasteboard.PasteboardType("public.url-name"),
            NSPasteboard.PasteboardType("Apple URL pasteboard type"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
            NSPasteboard.PasteboardType("com.apple.Safari.bookmarkDictionaryList"),
            NSPasteboard.PasteboardType("com.apple.safari.tab"),
            .tiff,
            .png,
        ] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // Transparent layer — prevents gray/white flash before SwiftUI paints
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        layer?.borderWidth     = 0
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - NSDraggingDestination

    /// Returning false prevents excessive timer-based draggingUpdated calls.
    /// Movement-based calls (cursor moves within the view) still fire — sufficient
    /// to update the hover state as the cursor crosses the pill boundary.
    var wantsPeriodicDraggingUpdates: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // If AppKit reached us, it owns this gesture. Disarm the global Safari
        // release fallback before reading any payload so one drag cannot commit twice.
        DragMonitor.shared.appKitDragEntered()
#if DEBUG
        dragDiag("ENTERED types: "
            + (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: " | "))
#endif
        cachedIsMailPromise = false
        let urls = extractURLs(from: sender.draggingPasteboard)
        if urls.isEmpty {
            // Non-file drag (text / link / raw image) — capture the payload now while
            // the drag pasteboard is fully open; it's written to disk only on drop.
            // Bitmap data is deliberately checked before URL: browser image drags vend
            // both, whereas tab/link drags have no bitmap and still resolve to webURL.
            let payload = DropMaterializer.preferredBrowserPayload(
                from: sender.draggingPasteboard)
            let hasPromise = sender.draggingPasteboard.canReadObject(
                forClasses: [NSFilePromiseReceiver.self], options: nil)
            let declaresImage = DropMaterializer.declaresImage(
                on: sender.draggingPasteboard)
            // Prefer a promise over a text-only payload: a Safari TAB drag offers
            // both a title string and a .webloc promise — the promise has the URL.
            var preferPromise = hasPromise && payload == nil
            if hasPromise, let payload {
                if payload.isText { preferPromise = true }
                // An advertised image whose eager bytes could not be read should stay
                // an image via its promise, never silently degrade to the page URL.
                if declaresImage, !payload.isImage { preferPromise = true }
            }
            if preferPromise {
                cachedHasPromise = true
                cachedIsMailPromise = sender.draggingPasteboard.types?.contains(
                    NSPasteboard.PasteboardType("com.apple.mail.PasteboardTypeMessageTransfer")
                ) == true
                cachedPayload = nil
            } else if let payload {
                cachedPayload = payload
            } else {
                return []
            }
            cachedDropURLs = []
            OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
            return .copy
        }
        // Cache here — pasteboard is fully open while the drag is in flight.
        cachedDropURLs = urls
        // Hover only when cursor is actually over the visible pill, not the transparent
        // canvas that surrounds it. The window is 288×96 but the pill is only 240×68
        // pinned to the top — the 28pt strip below the pill is transparent dead space.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Payload already cached from draggingEntered — no second pasteboard read needed.
        // Accept while EITHER file URLs or a non-file payload (text/link/image) is
        // cached; guarding on URLs alone silently refused every "drag anything" drop.
        guard !cachedDropURLs.isEmpty || cachedPayload != nil || cachedHasPromise else { return [] }
        // Re-evaluate hover as the cursor moves within the window so the jelly fires
        // exactly when the cursor crosses into the pill, not into the canvas border.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cachedDropURLs = []
        cachedPayload = nil
        cachedHasPromise = false
        cachedIsMailPromise = false
        OverlayViewModel.shared.isDragHovering = false
    }

    /// Must return true for performDragOperation to be called.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Clear hover and signal drag-end UNCONDITIONALLY — the user released the
        // mouse button so the drag session is over regardless of payload validity.
        OverlayViewModel.shared.isDragHovering = false
        DragMonitor.shared.dragCompleted()

        var urls = cachedDropURLs
        cachedDropURLs = []
        // File-promise drop (Safari tab, Photos, Mail): accept NOW, the source app
        // writes the real file(s) asynchronously — the session opens on delivery.
        if urls.isEmpty, cachedHasPromise {
            let isMailPromise = cachedIsMailPromise
            cachedHasPromise = false
            cachedIsMailPromise = false
            cachedPayload = nil
            var mailBaseline: [String: MailFileFingerprint]?

            if isMailPromise {
                let dest = DropMaterializer.dropsDirectory()
                // Mail still advertises the pre-NSFilePromiseReceiver contract for
                // inbox rows. Snapshot first: invoking this method is what asks Mail
                // to create the promised `.eml` files in our destination.
                let baseline = Self.mailFingerprints(in: dest)
                mailBaseline = baseline
#if DEBUG
                let legacyStartedAt = ProcessInfo.processInfo.systemUptime
#endif
                let legacyNames = sender.namesOfPromisedFilesDropped(
                    atDestination: dest
                ) ?? []
#if DEBUG
                let legacyMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - legacyStartedAt) * 1_000
                )
                let extensions = legacyNames.map {
                    ($0 as NSString).pathExtension.lowercased()
                }.filter { !$0.isEmpty }
                dragDiag(
                    "MAIL LEGACY PROMISE names=\(legacyNames.count) "
                    + "extensions=\(extensions.joined(separator: ",")) "
                    + "fulfilMs=\(legacyMilliseconds)"
                )
#endif
                if !legacyNames.isEmpty {
                    receiveLegacyMailPromises(
                        named: legacyNames,
                        at: dest,
                        baseline: baseline
                    )
                    return true
                }
            }

            if let receivers = sender.draggingPasteboard.readObjects(
                   forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
               !receivers.isEmpty {
                receivePromises(
                    receivers,
                    isMailPromise: isMailPromise,
                    mailBaseline: mailBaseline
                )
                return true
            }
            return false
        }
        cachedHasPromise = false
        cachedIsMailPromise = false
        // Non-file drop → materialize the captured text / link / image into a small
        // local file so the whole downstream file pipeline works unchanged.
        if urls.isEmpty, let payload = cachedPayload,
           let materialized = DropMaterializer.materialize(payload) {
            urls = [materialized]
        }
        cachedPayload = nil
        guard let first = urls.first else { return false }

        let vm = OverlayViewModel.shared

        // ── Active session: offer add/replace ────────────────────────────────────
        // Stage 2/3 is open — don't replace the session silently. Instead set the
        // pending URLs so the (batch-aware) banner prompt appears inside the card.
        guard case .waitingForDrop = vm.stage else {
            // Only the analysable files can be added to a session.
            let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
            guard !supported.isEmpty else { return false }
            withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                vm.pendingDroppedURLs = supported
            }
            grabFocusAfterDrop()
            return true
        }

        // ── Normal first-drop flow (one or many files → one session) ──────────────
        let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
        if supported.isEmpty {
            vm.stage = .error(
                url: first,
                message: "\"\(first.lastPathComponent)\" can't be analysed.\nDragaway supports PDF, text, images, and code files."
            )
            grabFocusAfterDrop()
            return true
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) {
            vm.setChips(urls: supported)
        }
        grabFocusAfterDrop()
        return true
    }

    /// Receive promised files into the Drops folder, unwrap .webloc links (Safari
    /// tabs) through the normal web path, then open/merge the session on the main
    /// actor. Failures simply produce no session — the drop can never wedge anything.
    private func receivePromises(
        _ receivers: [NSFilePromiseReceiver],
        isMailPromise: Bool,
        mailBaseline: [String: MailFileFingerprint]? = nil
    ) {
        let dest = DropMaterializer.dropsDirectory()
        if isMailPromise {
            receiveMailPromises(
                receivers,
                at: dest,
                baseline: mailBaseline ?? Self.mailFingerprints(in: dest)
            )
            return
        }

        // Keep the proven Safari / Photos promise route unchanged. Mail is split
        // above because one legacy receiver may invoke its reader more than once.
        var received: [URL] = []                      // mutated only on the serial queue
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                          operationQueue: Self.promiseQueue) { url, error in
                if error == nil { received.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let final = received.map { DropMaterializer.normalizeReceived($0) }
                    .filter { !FileInspector.isUnsupportedFileType($0) }
                guard !final.isEmpty else { return }
                let vm = OverlayViewModel.shared
                if case .waitingForDrop = vm.stage {
                    NotificationCenter.default.post(name: .radialOpenSession, object: final)
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                        vm.pendingDroppedURLs = final
                    }
                }
            }
        }
    }

    /// Mail uses the legacy promise shape where one receiver can represent multiple
    /// messages and invoke its reader once per file. Do not use the generic one-enter /
    /// one-leave group here: batch successful callbacks briefly, then independently
    /// recover stable expected files if Mail never supplies a usable callback.
    private func receiveMailPromises(
        _ receivers: [NSFilePromiseReceiver],
        at dest: URL,
        baseline: [String: MailFileFingerprint]
    ) {
        let state = MailPromiseDeliveryState()
        let nameSource = MailPromiseNameSource.receivers(receivers)

        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                          operationQueue: Self.promiseQueue) { [weak self, state] url, error in
#if DEBUG
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                let nsError = error as NSError?
                let errorCode = nsError.map { "\($0.domain)#\($0.code)" } ?? "nil"
                let message = "MAIL PROMISE CALLBACK ext=\(url.pathExtension.lowercased()) "
                    + "exists=\(FileManager.default.fileExists(atPath: url.path)) "
                    + "bytes=\(values?.fileSize ?? -1) error=\(errorCode)"
                DispatchQueue.main.async { dragDiag(message) }
#endif
                DispatchQueue.main.async { [weak self, state] in
                    self?.collectMailPromiseCallback(
                        successfulURL: error == nil ? url : nil,
                        state: state
                    )
                }
            }
        }

        // `fileNames` is populated by receivePromisedFiles. It is an array because a
        // single legacy receiver can promise several messages.
        state.expectedFileCount = Set(nameSource.currentNames.map {
            ($0 as NSString).lastPathComponent
        }).count

        scheduleMailRecovery(
            nameSource,
            at: dest,
            baseline: baseline,
            state: state,
            attempt: 0
        )
    }

    /// Apple Mail inbox rows still use the legacy dragging-source promise even
    /// though their pasteboard also looks readable as an NSFilePromiseReceiver.
    /// `namesOfPromisedFilesDropped` has already triggered the write; from here on,
    /// use exactly the same validation, batching, and handoff as the modern fallback.
    private func receiveLegacyMailPromises(
        named names: [String],
        at dest: URL,
        baseline: [String: MailFileFingerprint]
    ) {
        let state = MailPromiseDeliveryState()
        // Mail's legacy method can return display labels with no extension even
        // though it writes subject-named `.eml` files. The label count is useful;
        // the literal labels are not reliable destination paths.
        let nameSource = MailPromiseNameSource.directoryChanges(
            expectedCount: names.count
        )
        state.expectedFileCount = nameSource.expectedFileCountHint

        // Mail's legacy fulfilment call returns quickly, but the destination file can
        // become visible a few runloop turns later. Take the zero-delay win when the
        // complete delta is already present; otherwise the eager observer below keeps
        // the same stability/MIME guards without imposing the old fixed ~1.15 s wait.
        // A partial multi-message delta is never delivered as several sessions.
        let immediate = Self.changedMailURLs(in: dest, since: baseline)
        if state.expectedFileCount > 0,
           immediate.count == state.expectedFileCount {
#if DEBUG
            dragDiag(
                "MAIL PROMISE FAST PATH expected=\(state.expectedFileCount) "
                + "candidates=\(immediate.count)"
            )
#endif
            deliverMailPromiseURLs(immediate, state: state)
        } else {
            scheduleLegacyMailEagerRecovery(
                at: dest,
                baseline: baseline,
                state: state,
                attempt: 0
            )
        }

        // Keep the hardened stable-fingerprint/MIME-validation recovery alive as a
        // fallback. When the fast path delivered everything, its exact-once state
        // makes the first recovery observation terminate without another handoff.
        scheduleMailRecovery(
            nameSource,
            at: dest,
            baseline: baseline,
            state: state,
            attempt: 0
        )
    }

    /// Mail normally exposes its just-written `.eml` within a few dozen milliseconds
    /// of the legacy fulfilment call returning. Observe that private-directory delta
    /// at a short bounded cadence and require two identical fingerprints plus a MIME
    /// sanity parse before handing off the complete advertised batch. The independent
    /// slow recovery remains armed for unusually slow or partial writes.
    private func scheduleLegacyMailEagerRecovery(
        at dest: URL,
        baseline: [String: MailFileFingerprint],
        state: MailPromiseDeliveryState,
        attempt: Int
    ) {
        let maxAttempts = 12                  // 40 ms, then every 50 ms through ~590 ms
        guard attempt < maxAttempts,
              state.expectedFileCount > 0,
              state.deliveredPaths.count < state.expectedFileCount
        else { return }

        let delay = attempt == 0 ? 0.04 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, state] in
            guard let self,
                  state.deliveredPaths.count < state.expectedFileCount
            else { return }

            let candidates = Self.changedMailURLs(in: dest, since: baseline)
            var stable: [URL] = []
            for url in candidates {
                let path = url.standardizedFileURL.path
                guard !state.deliveredPaths.contains(path),
                      let current = Self.mailFingerprint(for: url),
                      baseline[path] != current
                else { continue }

                if state.recoveryObservations[path] == current,
                   Self.isValidMailPromiseFile(url) {
                    stable.append(url)
                }
                state.recoveryObservations[path] = current
            }

#if DEBUG
            let elapsedMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - state.startedAt) * 1_000
            )
            dragDiag(
                "MAIL PROMISE EAGER attempt=\(attempt + 1) "
                + "elapsedMs=\(elapsedMilliseconds) "
                + "expected=\(state.expectedFileCount) "
                + "candidates=\(candidates.count) stable=\(stable.count)"
            )
#endif

            // Exact count is intentional: a multi-message drag opens atomically, and
            // an unexpected extra delta falls through to the conservative recovery.
            if candidates.count == state.expectedFileCount,
               stable.count == state.expectedFileCount {
#if DEBUG
                dragDiag("MAIL PROMISE EAGER HANDOFF elapsedMs=\(elapsedMilliseconds)")
#endif
                self.deliverMailPromiseURLs(stable, state: state)
                return
            }

            if attempt + 1 < maxAttempts {
                self.scheduleLegacyMailEagerRecovery(
                    at: dest,
                    baseline: baseline,
                    state: state,
                    attempt: attempt + 1
                )
            }
        }
    }

    private func collectMailPromiseCallback(
        successfulURL: URL?,
        state: MailPromiseDeliveryState
    ) {
        guard let successfulURL else { return }
        collectMailPromiseURLs([successfulURL], state: state)
    }

    /// Callback and filesystem-recovery results share one accumulator. This matters
    /// for a single Mail drag containing several messages: whichever source reports
    /// each file, all advertised paths open as one multi-file session when possible.
    private func collectMailPromiseURLs(
        _ urls: [URL],
        state: MailPromiseDeliveryState
    ) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !state.deliveredPaths.contains(path),
                  state.callbackPaths.insert(path).inserted
            else { continue }
            state.callbackURLs.append(url)
        }
        guard !state.callbackURLs.isEmpty else { return }

        let accountedFor = state.deliveredPaths.union(state.callbackPaths).count
        if state.expectedFileCount > 0, accountedFor >= state.expectedFileCount {
            flushMailCallbackBatch(state: state)
        } else if state.expectedFileCount == 0 {
            // Some legacy promises do not publish fileNames. In that shape, use one
            // short rolling batch window instead of flushing each late callback alone.
            scheduleUnknownMailBatchFlush(state: state)
        } else {
            // An advertised sibling may still be arriving (or may never arrive).
            // Wait long enough to coalesce normal Mail writes, but keep the wait bounded.
            scheduleIncompleteMailBatchFlush(state: state)
        }
    }

    private func scheduleUnknownMailBatchFlush(state: MailPromiseDeliveryState) {
        guard !state.shortBatchFlushScheduled else { return }
        state.shortBatchFlushScheduled = true
        let generation = state.batchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self, state] in
            guard state.batchGeneration == generation else { return }
            state.shortBatchFlushScheduled = false
            let accountedFor = state.deliveredPaths.union(state.callbackPaths).count
            if state.expectedFileCount > 0, accountedFor < state.expectedFileCount {
                self?.scheduleIncompleteMailBatchFlush(state: state)
            } else {
                self?.flushMailCallbackBatch(state: state)
            }
        }
    }

    private func scheduleIncompleteMailBatchFlush(state: MailPromiseDeliveryState) {
        guard !state.hardBatchFlushScheduled else { return }
        state.hardBatchFlushScheduled = true
        let generation = state.batchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.50) { [weak self, state] in
            guard state.batchGeneration == generation else { return }
            state.hardBatchFlushScheduled = false
            self?.flushMailCallbackBatch(state: state)
        }
    }

    private func flushMailCallbackBatch(state: MailPromiseDeliveryState) {
        // `dragCompleted()` starts the normal delayed pill dismissal. Opening a
        // session after that collapse begins but before it finishes can leave
        // `isCollapsing` latched on the newly opened card. Mail always hands off after
        // the nominal collapse window: `.radialOpenSession` itself hops through a Task,
        // so a pre-dismiss notification could otherwise still lose the main-queue race.
        let elapsed = ProcessInfo.processInfo.systemUptime - state.startedAt
        if elapsed < 0.55 {
            scheduleMailSafeFlush(state: state, after: 0.55 - elapsed)
            return
        }
        // Also check the live flag because a stalled main thread can run the delayed
        // collapse later than its nominal deadline.
        if OverlayViewModel.shared.isCollapsing {
            scheduleMailSafeFlush(state: state, after: 0.40)
            return
        }

        // Invalidate any still-scheduled short fallback before handing the batch off.
        state.batchGeneration += 1
        state.shortBatchFlushScheduled = false
        state.hardBatchFlushScheduled = false
        state.safeFlushScheduled = false
        let batch = state.callbackURLs
        state.callbackURLs.removeAll()
        state.callbackPaths.removeAll()
        guard !batch.isEmpty else { return }
        deliverMailPromiseURLs(batch, state: state)
    }

    private func scheduleMailSafeFlush(
        state: MailPromiseDeliveryState,
        after delay: TimeInterval
    ) {
        guard !state.safeFlushScheduled else { return }
        state.safeFlushScheduled = true
        let generation = state.batchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self, state] in
            guard state.batchGeneration == generation else { return }
            state.safeFlushScheduled = false
            self?.flushMailCallbackBatch(state: state)
        }
    }

    /// Poll Mail's advertised destination names (modern receiver) or the private Drops
    /// directory delta (legacy inbox-row promise), at a bounded 0.5 s cadence. Two
    /// identical fingerprints are required, so a file that finishes near the end of
    /// the five-second promise horizon still gets one later observation.
    private func scheduleMailRecovery(
        _ nameSource: MailPromiseNameSource,
        at dest: URL,
        baseline: [String: MailFileFingerprint],
        state: MailPromiseDeliveryState,
        attempt: Int
    ) {
        let maxAttempts = 12                  // 0.65 s, then through ~6.15 s
        guard attempt < maxAttempts else { return }
        let delay = attempt == 0 ? 0.65 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, state] in
            guard let self else { return }
            let names = nameSource.currentNames
            var expectedByPath: [String: URL] = [:]
            if nameSource.discoversDirectoryChanges {
                // The Drops directory is private to Dragaway. A pre-drop fingerprint
                // snapshot lets the legacy Mail path identify the files it actually
                // wrote even when its returned promise labels omit `.eml` entirely.
                for (path, fingerprint) in Self.mailFingerprints(in: dest)
                where baseline[path] != fingerprint {
                    expectedByPath[path] = URL(fileURLWithPath: path).standardizedFileURL
                }
            } else {
                for name in names {
                    let url = dest.appendingPathComponent((name as NSString).lastPathComponent)
                        .standardizedFileURL
                    expectedByPath[url.path] = url
                }
            }
            state.expectedFileCount = max(
                state.expectedFileCount,
                max(nameSource.expectedFileCountHint, expectedByPath.count)
            )

            var stable: [URL] = []
            for (path, url) in expectedByPath where !state.deliveredPaths.contains(path) {
                guard let current = Self.mailFingerprint(for: url),
                      baseline[path] != current
                else { continue }
                if state.recoveryObservations[path] == current,
                   Self.isValidMailPromiseFile(url) {
                    stable.append(url)
                }
                state.recoveryObservations[path] = current
            }
#if DEBUG
            dragDiag(
                "MAIL PROMISE RECOVERY attempt=\(attempt + 1) "
                + "expected=\(state.expectedFileCount) "
                + "candidates=\(expectedByPath.count) stable=\(stable.count)"
            )
#endif
            self.collectMailPromiseURLs(stable, state: state)

            let expectedPaths = Set(expectedByPath.keys)
            let allDelivered = state.expectedFileCount > 0
                && state.deliveredPaths.count >= state.expectedFileCount
                && expectedPaths.isSubset(of: state.deliveredPaths)
            if !allDelivered {
                if attempt + 1 < maxAttempts {
                    self.scheduleMailRecovery(
                        nameSource,
                        at: dest,
                        baseline: baseline,
                        state: state,
                        attempt: attempt + 1
                    )
                } else {
                    // Final bounded recovery pass: deliver any verified remainder,
                    // even if one advertised message never appeared on disk.
                    self.flushMailCallbackBatch(state: state)
                }
            }
        }
    }

    /// Main-thread, exact-once handoff used only by Apple Mail promise recovery.
    private func deliverMailPromiseURLs(_ urls: [URL], state: MailPromiseDeliveryState) {
        let final = urls.map { DropMaterializer.normalizeReceived($0) }
            .filter { !FileInspector.isUnsupportedFileType($0) }
        guard !final.isEmpty else { return }

        let vm = OverlayViewModel.shared
        let occupied = Set((vm.sessionFileURLs + vm.pendingDroppedURLs).map {
            $0.standardizedFileURL.path
        })
        var fresh: [URL] = []
        for url in final {
            let path = url.standardizedFileURL.path
            guard !occupied.contains(path), state.deliveredPaths.insert(path).inserted else { continue }
            fresh.append(url)
        }
        guard !fresh.isEmpty else { return }

        if case .waitingForDrop = vm.stage {
            NotificationCenter.default.post(name: .radialOpenSession, object: fresh)
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                vm.pendingDroppedURLs = vm.pendingDroppedURLs + fresh
            }
        }
    }

    /// Conservative RFC-message sanity check for the Mail-only fallback. Parsing is
    /// bounded to 64 KiB and requires a regular non-empty `.eml` / `.emlx` file.
    private static func isValidMailPromiseFile(_ url: URL) -> Bool {
        guard FileInspector.isEmailFile(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return false }
        return (try? EmailContentExtractor.extract(from: url, byteLimit: 64 * 1024)) != nil
    }

    private static func mailFingerprints(in directory: URL) -> [String: MailFileFingerprint] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        )) ?? []
        var result: [String: MailFileFingerprint] = [:]
        for url in files where FileInspector.isEmailFile(url) {
            if let fingerprint = mailFingerprint(for: url) {
                result[url.standardizedFileURL.path] = fingerprint
            }
        }
        return result
    }

    /// New or changed Mail message files written after a pre-fulfilment snapshot.
    /// `mailFingerprints` already guarantees regular, non-empty `.eml` / `.emlx`
    /// files; full bounded MIME extraction is intentionally left to the background
    /// session preparation so the UI can react immediately.
    private static func changedMailURLs(
        in directory: URL,
        since baseline: [String: MailFileFingerprint]
    ) -> [URL] {
        mailFingerprints(in: directory)
            .filter { path, fingerprint in baseline[path] != fingerprint }
            .keys
            .sorted()
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private static func mailFingerprint(for url: URL) -> MailFileFingerprint? {
        guard FileInspector.isEmailFile(url),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
              ]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              let modified = values.contentModificationDate
        else { return nil }
        return MailFileFingerprint(size: size, modified: modified.timeIntervalSinceReferenceDate)
    }

    private struct MailFileFingerprint: Equatable {
        let size: Int
        let modified: TimeInterval
    }

    private final class MailPromiseDeliveryState {
        var deliveredPaths: Set<String> = []
        var callbackURLs: [URL] = []
        var callbackPaths: Set<String> = []
        var expectedFileCount = 0
        var shortBatchFlushScheduled = false
        var hardBatchFlushScheduled = false
        var safeFlushScheduled = false
        var batchGeneration = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        var recoveryObservations: [String: MailFileFingerprint] = [:]
    }

    private enum MailPromiseNameSource {
        case directoryChanges(expectedCount: Int)
        case receivers([NSFilePromiseReceiver])

        var currentNames: [String] {
            switch self {
            case .directoryChanges:
                return []
            case .receivers(let receivers):
                return receivers.flatMap(\.fileNames)
            }
        }

        var expectedFileCountHint: Int {
            switch self {
            case .directoryChanges(let expectedCount):
                return expectedCount
            case .receivers:
                return Set(currentNames.map {
                    ($0 as NSString).lastPathComponent
                }).count
            }
        }

        var discoversDirectoryChanges: Bool {
            if case .directoryChanges = self { return true }
            return false
        }
    }

    /// Pull the app + overlay window into focus right after a completed drop, so the
    /// user can immediately type a prompt or use Tab without clicking first.
    ///
    /// The pill window is shown with a plain `orderFront` during the drag (it's a
    /// `.nonactivatingPanel`, so it deliberately does NOT steal focus mid-drag and
    /// cancel the Finder drag session). Once the drop lands the mouse is already
    /// released — there's no live drag to disturb — so it's safe to activate.
    ///
    /// Deferred one run-loop tick to stay clear of the drop's in-flight SwiftUI
    /// layout pass (this codebase aborts if a second AppKit layout re-enters the
    /// constraint solver mid-transition).
    private func grabFocusAfterDrop() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKey()
        }
    }

    // MARK: - Pill hit-test helper

    /// Returns true if the drag cursor is over the visible pill area.
    ///
    /// In stage 1 the window canvas is 288×96 but the pill is 240×68 pinned to the
    /// top — the bottom 28pt strip is transparent. Without this check `isDragHovering`
    /// would fire for the transparent zone, triggering the jelly wobble while the cursor
    /// appears to be hovering BELOW the pill. In stages 2/3 the whole card is the target
    /// so we return true unconditionally.
    private func isOverPillArea(_ sender: NSDraggingInfo) -> Bool {
        guard case .waitingForDrop = OverlayViewModel.shared.stage else { return true }
        // draggingLocation is in the window's base coordinate system.
        // convert(_:from:nil) maps that to the view's own coordinate space.
        let loc = convert(sender.draggingLocation, from: nil)
        // Pill content: 240×68 pt at base scale, centred horizontally in the
        // 288×96 canvas (24 pt each side) and pinned to the TOP of the canvas
        // (AppKit y=0 is at the BOTTOM, so bottom edge = bounds.height − 68).
        // Both the canvas and the pill content scale by the same multiplier, so
        // the margins stay proportional and the formula stays the same with `s`.
        // NSHostingView.isFlipped == true: y=0 is at the VISUAL top of the view.
        // convert(_:from:nil) maps from the non-flipped window base system into this
        // flipped space, so "top of pill" → small y, "bottom of pill" → larger y.
        // Using y=0 here correctly anchors the rect to the visual top of the canvas
        // (where the pill sits) and covers the full 240×68 pill area.
        // The 28pt transparent strip BELOW the pill has y > pillH in flipped coords
        // and is therefore excluded, which is the intended behaviour.
        return dropTargetRect.contains(loc)
    }

    /// True when a global AppKit screen point is over the visible drop target.
    /// Used only for browser drags whose source never discovers this late-created
    /// NSDraggingDestination. Normal drags continue through isOverPillArea(_:).
    static func isScreenPointOverDropTarget(_ point: NSPoint) -> Bool {
        screenDropTargetFrame()?.contains(point) == true
    }

    /// Current drop target in global AppKit screen coordinates.
    static func screenDropTargetFrame() -> NSRect? {
        guard let view = NSApp.windows
            .compactMap({ $0.contentView as? DroppableHostingView })
            .first(where: { $0.window?.isVisible == true }),
              let window = view.window else { return nil }
        let inWindow = view.convert(view.dropTargetRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Stage 1 accepts only the visible 240×68 pill; later stages accept the card.
    private var dropTargetRect: NSRect {
        guard case .waitingForDrop = OverlayViewModel.shared.stage else { return bounds }
        let s = UIScale(rawValue: UserDefaults.standard.string(forKey: "uiScale") ?? "")?.multiplier ?? 1.0
        let pillW = 240 * s
        let pillH =  68 * s
        return NSRect(x: (bounds.width - pillW) / 2, y: 0, width: pillW, height: pillH)
    }

    // MARK: - Helper

    private func extractURLs(from pasteboard: NSPasteboard) -> [URL] {
        // Primary: modern fileURL type — returns ALL dragged files in order.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }
        // Fallback: legacy NSFilenamesPboardType (older apps, Finder on some OS versions)
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
