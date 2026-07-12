import Foundation

// THESIS (replay harness, M1 slice) — feeds a recorded JSONL trace back through the
// SignalBus, deterministically.
//
// Replay works because of the bus's core rule: events carry their own timestamp and
// downstream logic uses event time, never wall clock. Replay is instant (no sleeps) —
// windowing, decay, and (from M2) scoring all read `event.t`, so results are
// identical no matter how fast events are pushed.
//
// Golden traces — including the intent keyframes encoded from the formative
// observation sessions — thereby become regression tests: "did the pipeline see /
// score this real situation the way we expect?"
//
// NOTE: stop live sensors before replaying (IntentEngine handles this) — mixing
// live events into a replayed timeline would corrupt the buffer's time window.
enum TraceReplayer {

    enum TraceError: LocalizedError {
        case nonMonotonic(line: Int, regressionSeconds: Double)
        var errorDescription: String? {
            switch self {
            case .nonMonotonic(let line, let r):
                return "Trace rejected: event at line \(line) jumps "
                     + String(format: "%.1f", r)
                     + " s backwards. Order is part of the recorded interaction — a broken "
                     + "trace must be visibly broken, never silently re-sorted. "
                     + "(Sub-second regressions are tolerated as clock jitter: Date() is "
                     + "not monotonic across NTP adjustments.)"
            }
        }
    }

    struct Summary {
        let url: URL
        let events: Int
        let skippedLines: Int
        let countsPerKind: [String: Int]
        /// Trace span in seconds (first event → last event, event time).
        let duration: TimeInterval
        /// Event time of the last event — pass this to the scorer after a replay
        /// (wall clock would decay all replayed evidence to zero).
        let lastEventTime: TimeInterval?

        var description: String {
            let kinds = countsPerKind.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "  ·  ")
            return """
            \(url.lastPathComponent)
            \(events) events over \(Int(duration)) s   (\(skippedLines) non-event lines skipped)
            \(kinds)
            """
        }
    }

    static func load(_ url: URL) throws -> (events: [SignalEvent], skipped: Int) {
        let decoder = JSONDecoder()
        var events: [SignalEvent] = []
        var skipped = 0
        var lastT = -Double.infinity
        var lineNo = 0
        let content = try String(contentsOf: url, encoding: .utf8)
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            guard !line.isEmpty else { continue }
            if let event = try? decoder.decode(SignalEvent.self, from: Data(line.utf8)) {
                // The bus guarantees monotonic publish time (±clock jitter), so a
                // regression > 1 s means a corrupted or hand-spliced trace.
                if event.t < lastT - 1.0 {
                    throw TraceError.nonMonotonic(line: lineNo, regressionSeconds: lastT - event.t)
                }
                lastT = max(lastT, event.t)
                events.append(event)
            } else {
                skipped += 1   // header line, comments, future schema extensions
            }
        }
        return (events, skipped)
    }

    @discardableResult
    static func replay(_ url: URL, into bus: SignalBus) throws -> Summary {
        let (events, skipped) = try load(url)
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.kind.rawValue, default: 0] += 1
            bus.publish(event)
        }
        let duration = (events.last?.t ?? 0) - (events.first?.t ?? 0)
        return Summary(url: url, events: events.count, skippedLines: skipped,
                       countsPerKind: counts, duration: max(duration, 0),
                       lastEventTime: events.last?.t)
    }
}
