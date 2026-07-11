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

    struct Summary {
        let url: URL
        let events: Int
        let skippedLines: Int
        let countsPerKind: [String: Int]
        /// Trace span in seconds (first event → last event, event time).
        let duration: TimeInterval

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
        let content = try String(contentsOf: url, encoding: .utf8)
        for line in content.split(separator: "\n") {
            guard !line.isEmpty else { continue }
            if let event = try? decoder.decode(SignalEvent.self, from: Data(line.utf8)) {
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
                       countsPerKind: counts, duration: max(duration, 0))
    }
}
