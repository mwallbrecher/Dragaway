import Foundation
import Combine

// THESIS (study instrumentation, M1 slice) — records the SignalBus to a JSONL trace.
//
// One event per line, schema = SignalEvent (Codable). The first line is a header
// object that intentionally does NOT decode as a SignalEvent — the replayer skips
// undecodable lines, so the format stays forgiving and versionable.
//
// Traces are content-free by construction (the bus privacy invariant), so a trace
// file is safe to share/analyse; it is still user data and stays local unless the
// participant explicitly exports it (consent flow lands with M5).
final class TraceRecorder {

    private(set) var isRecording = false
    private(set) var currentFile: URL?
    private(set) var eventCount = 0

    private var handle: FileHandle?
    private var subscription: AnyCancellable?
    private let encoder = JSONEncoder()

    static func tracesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dragaway/IntentTraces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start(bus: SignalBus) {
        guard !isRecording else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = Self.tracesDirectory()
            .appendingPathComponent("trace-\(stamp.string(from: Date())).jsonl")

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }

        handle = h
        currentFile = url
        eventCount = 0

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = "{\"header\":{\"v\":1,\"app\":\"\(version)\",\"started\":\(Date().timeIntervalSince1970)}}\n"
        h.write(Data(header.utf8))

        subscription = bus.events.sink { [weak self] event in
            self?.write(event)
        }
        isRecording = true
    }

    func stop() {
        subscription = nil
        try? handle?.close()
        handle = nil
        isRecording = false
    }

    private func write(_ event: SignalEvent) {
        guard let data = try? encoder.encode(event) else { return }
        handle?.write(data)
        handle?.write(Data("\n".utf8))
        eventCount += 1
    }
}
