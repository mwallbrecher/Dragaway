import Foundation
import Combine

// THESIS (Computational Intent Pipeline, L1) — see docs/thesis/ARCHITECTURE.md.
//
// Event model + SignalBus. Two invariants every sensor and consumer must honour:
//
//  1. PRIVACY — raw content never crosses the bus. Sensors compute content-derived
//     scalars AT CAPTURE TIME and discard the content itself. NB: what remains
//     (hashes, embeddings, app identities, timing) is content-MINIMISED behavioural
//     data — pseudonymous, NOT anonymous: embeddings are partially invertible and
//     hashes support membership tests. It stays on-device; export only through the
//     M5 consent flow (ARCHITECTURE §4).
//
//  2. REPLAY — every event carries its own timestamp `t`. Downstream logic must use
//     event time, never Date()/wall clock. Sensors stamp at PUBLISH time, so bus
//     time is monotonic (the DEBUG tripwire below guards this). This is what makes
//     recorded traces replay deterministically through the whole pipeline (golden
//     traces = regression tests for intent detection).

// MARK: - Event model

enum SignalKind: String, Codable {
    case clipboard, appFocus, scrollBurst, dwell, selection
}

/// A copy/cut landed on the general pasteboard. Content is classified and discarded.
struct ClipboardPayload: Codable {
    /// "text" | "url" | "image" | "files" | "other"
    let contentClass: String
    let charCount: Int
    let wordCount: Int
    /// BCP-47-ish top language guess ("de", "en", …) — nil for non-text.
    let language: String?
    let langConfidence: Double?
    /// Top language is confidently not one of the user's preferred languages.
    let isForeignLanguage: Bool
    /// "prose" | "code" | "table" | "list" | "question" | "fragment" | "" (non-text)
    let shape: String
    let hasURL: Bool
    /// First 16 hex chars of SHA-256 — re-copy/dedup detection without content.
    let hashPrefix: String
    /// Bundle id of the frontmost app at copy time (best-effort source attribution).
    let sourceApp: String?
    /// Lowercased path extensions when contentClass == "files".
    let fileExtensions: [String]?
    /// On-device sentence embedding (NLEmbedding), rounded — derived data, safe to
    /// persist. Feeds the `topic_coherence` detector. nil when unavailable.
    var embedding: [Double]? = nil
}

/// A text selection (or translator-context flip) read via the Accessibility API.
/// M2, opt-in — the ONLY permission-gated sensor (ARCHITECTURE §3). Raw selection,
/// window title, and document path are classified at capture and discarded.
struct SelectionPayload: Codable {
    let app: String?
    let charCount: Int
    let wordCount: Int
    let language: String?
    let langConfidence: Double?
    let isForeignLanguage: Bool
    let shape: String
    /// Hash prefix of the selected text (repeat-selection detection).
    let hashPrefix: String
    /// Hash prefix of document path / window title — same-document identity
    /// without storing the document. nil when the app exposes neither.
    let docID: String?
    /// Focused window looks like a translator (deepl/translate/dict…) — computed
    /// from the title AT CAPTURE, title itself is discarded.
    let isTranslatorContext: Bool
}

/// The frontmost application changed.
struct AppFocusPayload: Codable {
    let bundleID: String
    let appName: String
    /// Coarse category ("browser", "editor", "pdf", "mail", "translator", …, "other").
    let category: String
    let previousBundleID: String?
    /// How long the previous app held focus.
    let secondsInPrevious: Double?
}

/// A contiguous scroll gesture (events closer than 0.8 s), aggregated at burst end.
/// Direction changes are the raw material of the M2 `re_reading` detector.
struct ScrollBurstPayload: Codable {
    let app: String?
    let duration: Double
    let netDeltaY: Double
    let totalAbsDeltaY: Double
    let directionChanges: Int
}

/// The mouse was stationary for at least 10 s (emitted when movement resumes).
/// Mouse-quiet conflates reading and typing; disambiguation comes with AX (M2).
struct DwellPayload: Codable {
    let app: String?
    let seconds: Double
}

/// One observation on the bus. Exactly one payload is non-nil, matching `kind`.
/// Flat optional payloads (rather than an enum with associated values) keep the
/// JSONL schema forgiving: unknown/extra fields never break a decode.
struct SignalEvent: Codable {
    /// Event time (epoch seconds). THE timestamp — never use Date() downstream.
    let t: TimeInterval
    let kind: SignalKind
    var clipboard: ClipboardPayload? = nil
    var appFocus: AppFocusPayload? = nil
    var scroll: ScrollBurstPayload? = nil
    var dwell: DwellPayload? = nil
    var selection: SelectionPayload? = nil
}

// MARK: - SignalBus

/// The spine of the pipeline: sensors publish, consumers subscribe.
/// Also keeps a short ring buffer for windowed feature extraction (L2, M2).
final class SignalBus {

    /// Live stream. Subscribers: TraceRecorder (M1), FeatureExtractor (M2).
    let events = PassthroughSubject<SignalEvent, Never>()

    /// Recent-events window for L2 detectors. Trimmed against the NEWEST event's
    /// timestamp — not wall clock — so replayed traces window identically (§4).
    private(set) var buffer: [SignalEvent] = []

    private let windowSeconds: TimeInterval = 120
    private let capacity = 600
    private var lastPublishedT: TimeInterval = -.infinity

    func publish(_ event: SignalEvent) {
#if DEBUG
        // Monotonicity tripwire: sensors stamp at publish time, so time can never
        // run backwards on the bus. If this prints, a sensor regressed to stamping
        // past timestamps — fix the sensor, don't relax the invariant.
        if event.t < lastPublishedT - 0.001 {
            print("[intent] ⚠️ non-monotonic publish: \(event.kind.rawValue) " +
                  "t=\(event.t) < last=\(lastPublishedT)")
        }
#endif
        lastPublishedT = max(lastPublishedT, event.t)
        buffer.append(event)
        let cutoff = event.t - windowSeconds
        if buffer.first.map({ $0.t < cutoff }) == true {
            buffer.removeAll { $0.t < cutoff }
        }
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        events.send(event)
    }

    /// Full wipe — required before replaying a trace: stale live events carry
    /// timestamps FAR ahead of the recorded timeline and would corrupt windowing.
    func reset() {
        buffer = []
        lastPublishedT = -.infinity
    }

    /// Events within `seconds` before the reference time (defaults to newest event).
    func recent(within seconds: TimeInterval, before reference: TimeInterval? = nil) -> [SignalEvent] {
        guard let newest = reference ?? buffer.last?.t else { return [] }
        return buffer.filter { $0.t > newest - seconds && $0.t <= newest }
    }
}

// MARK: - Sensor protocol

protocol IntentSensor: AnyObject {
    var name: String { get }
    func start(bus: SignalBus)
    func stop()
}
