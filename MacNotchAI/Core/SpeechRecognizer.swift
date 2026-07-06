import AppKit
import Combine
import CoreAudio
import Speech
import AVFoundation

/// Tap-to-start / tap-to-stop speech recogniser.
/// Uses macOS native SFSpeechRecognizer — zero API tokens, on-device where available.
///
/// AirPods / Bluetooth fix: audio input is always pinned to the built-in microphone
/// via Core Audio so that Bluetooth HFP routing never prevents the OS mic-active
/// indicator from lighting up and never mangles the audio format mid-session.
@MainActor
final class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()
    private init() {}

    @Published var isRecording = false

    // ── Session state ──────────────────────────────────────────────────────────
    private var recognizer:   SFSpeechRecognizer?
    private var request:      SFSpeechAudioBufferRecognitionRequest?
    private var task:         SFSpeechRecognitionTask?
    private var engine:       AVAudioEngine?
    private var onTranscript: ((String) -> Void)?

    /// Auto-stop after this many seconds of silence between words.
    private var silenceTimer: Timer?
    private let kSilenceSeconds = 3.0

    // MARK: - Public API

    func toggle(onTranscript: @escaping (String) -> Void) {
        isRecording ? stop() : begin(onTranscript: onTranscript)
    }

    // MARK: - Start

    private func begin(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript

        // async/await keeps every hop on @MainActor — no actor isolation violation.
        Task { @MainActor in
            // Step 1 — speech recognition permission
            let speechOK = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            guard speechOK else {
                showPermissionAlert("Speech Recognition")
                self.onTranscript = nil
                return
            }

            // Step 2 — microphone permission. WHICH API owns the audio-recording TCC
            // category flipped in macOS 26 (lessons MIC-04/05): on 14/15 it's
            // AVAudioApplication (AVCaptureDevice returns a false .denied); on 26 it's
            // AVCaptureDevice (AVAudioApplication defaults .denied for accessory apps).
            // `micAuthStatus()` / `requestMicAccess()` pick the right one per OS.
            let micStatus = micAuthStatus()

            if micStatus != .authorized {
                guard micStatus == .notDetermined else {
                    showPermissionAlert("Microphone")
                    self.onTranscript = nil
                    return
                }

                // Drop the overlay to .normal so the TCC dialog isn't hidden behind the
                // floating pill (MIC-06); restore .floating after.
                let overlayWindow = NSApp.windows.first { $0 is OverlayWindow }
                overlayWindow?.level = .normal
                NSApp.activate(ignoringOtherApps: true)

                let micOK = await requestMicAccess()

                overlayWindow?.level = .floating
                guard micOK else {
                    showPermissionAlert("Microphone")
                    self.onTranscript = nil
                    return
                }
            }

            startSession()
        }
    }

    // MARK: - Session

    private func startSession() {
        let eng = AVAudioEngine()
        engine = eng

        recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { tearDown(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true   // live word-by-word updates in the text field
        req.requiresOnDeviceRecognition = false // server fallback keeps latency low
        request = req

        // Create the recognition task BEFORE installing the tap / starting the engine.
        // The recognizer must be ready to accept the very first audio buffer; creating
        // the task afterwards causes early frames to be silently dropped.
        // SFSpeechRecognitionTask callbacks are documented to fire on the main queue;
        // MainActor.assumeIsolated satisfies Swift 6 without a Task allocation per result.
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let result {
                    self.onTranscript?(result.bestTranscription.formattedString)
                    result.isFinal ? self.tearDown() : self.resetSilenceTimer()
                }
                if let error {
                    let ns = error as NSError
                    // 301  = normal end-of-audio cancellation (our silence-timer stop)
                    // 1110 = server closed stream with no speech (benign, fires after endAudio)
                    // 201  = on-device model not installed (kLSRErrorDomain, benign)
                    let benign = (ns.domain == "kAFAssistantErrorDomain" && (ns.code == 301 || ns.code == 1110))
                              || (ns.domain == "kLSRErrorDomain"         &&  ns.code == 201)
                    if !benign { self.tearDown() }
                }
            }
        }

        // Pin input to the built-in microphone so Bluetooth / AirPods HFP routing
        // doesn't intercept audio. AVAudioEngine latches its input device the first
        // time `inputNode` is accessed, so we briefly set the system default to the
        // built-in mic beforehand and restore it immediately after — total duration
        // is a few ms and invisible to other apps.
        let prevDefaultID = Self.defaultInputDeviceID()
        if let builtInID = Self.builtInMicDeviceID() {
            Self.setDefaultInputDevice(builtInID)
        }

        // Capture `req` directly in the tap closure.
        // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe and MUST run
        // synchronously on the audio render thread. Routing through @MainActor `self`
        // would enqueue the call on the main thread — the buffer timestamp is already
        // stale by the time it arrives, sending silence to the recogniser.
        let node = eng.inputNode   // ← device selection happens here
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }

        do {
            eng.prepare()
            try eng.start()
        } catch {
            if let prev = prevDefaultID { Self.setDefaultInputDevice(prev) }
            tearDown()
            return
        }

        // Engine is running and latched to built-in mic — safe to restore system default.
        if let prev = prevDefaultID { Self.setDefaultInputDevice(prev) }

        isRecording = true
        resetSilenceTimer()
    }

    // MARK: - Stop

    /// Manual stop (second mic tap). Ends audio; task delivers the final transcription.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        // Recognition task callback fires once more with isFinal = true → tearDown()
    }

    // MARK: - Silence timer

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        // Timer fires on the main run loop; MainActor.assumeIsolated satisfies Swift 6.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: kSilenceSeconds,
                                            repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.stop()
            }
        }
    }

    // MARK: - Tear-down

    private func tearDown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        task?.cancel()
        task = nil
        if let eng = engine, eng.isRunning {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine       = nil
        request      = nil
        recognizer   = nil
        onTranscript = nil
        isRecording  = false
    }

    // MARK: - Microphone permission (OS-version-aware)

    private enum MicAuth { case authorized, denied, notDetermined }

    /// Microphone auth status, read from the API that actually maps to
    /// `kTCCServiceMicrophone` on the RUNNING OS. macOS 26 flipped which API owns the
    /// audio-recording TCC category (lessons MIC-04/05) — using the wrong one yields a
    /// false `.denied`. 26+ → `AVCaptureDevice`; 14/15 → `AVAudioApplication`.
    private func micAuthStatus() -> MicAuth {
        if #available(macOS 26, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .authorized
            case .notDetermined: return .notDetermined
            default:             return .denied
            }
        } else {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:      return .authorized
            case .undetermined: return .notDetermined
            default:            return .denied
            }
        }
    }

    /// Request mic access via the OS-correct API (see `micAuthStatus`). Returns granted.
    private func requestMicAccess() async -> Bool {
        if #available(macOS 26, *) {
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        } else {
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: - Permission alerts

    private func showPermissionAlert(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) access denied"
        alert.informativeText = "Enable \(name) for Dragaway in System Settings → Privacy & Security."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        }
    }

    // MARK: - Device helpers

    /// Current system default input device, or `nil` on error.
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr
        else { return nil }
        return deviceID
    }

    /// Sets the system default input device. Used to temporarily pin AVAudioEngine
    /// to the built-in mic; call is a no-op if it fails.
    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    /// Returns the `AudioDeviceID` of the first built-in audio device that has
    /// input streams (the MacBook's internal microphone). Returns `nil` on any
    /// error or if no built-in input exists — the engine then uses the system default.
    private static func builtInMicDeviceID() -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr
        else { return nil }

        for id in ids {
            // Must be built-in transport (not USB, Bluetooth, Thunderbolt, etc.)
            var transport: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &sz, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn
            else { continue }

            // Must have at least one input stream
            var streamSize: UInt32 = 0
            var sAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope:    kAudioObjectPropertyScopeInput,
                mElement:  kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &streamSize)
            if streamSize > 0 { return id }
        }
        return nil
    }
}
