import Foundation
import Combine

@MainActor
final class AppLogger: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
    }

    enum Level: String { case debug, info, warn, error }

    private let queue = DispatchQueue(label: "porchkeep.logger")
    private let fileURL: URL
    private let dateFormatter: DateFormatter

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PorchKeep/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.fileURL = supportDir.appendingPathComponent("porchkeep.log")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        self.dateFormatter = df
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        rollIfNeeded()
        info("PorchKeep logger started — log at \(fileURL.path)")
    }

    var logFileURL: URL { fileURL }

    func debug(_ msg: String) { write(.debug, msg) }
    func info(_ msg: String) { write(.info, msg) }
    func warn(_ msg: String) { write(.warn, msg) }
    func error(_ msg: String) { write(.error, msg) }

    nonisolated func writeRaw(_ level: Level, _ msg: String) {
        // Safe to call from any thread.
        Task { @MainActor in self.write(level, msg) }
    }

    // The bundled bridge's logger emits ANSI colour codes (ESC[33m …). Strip
    // them so the log viewer and log file stay plain text.
    static let ansiRegex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    static func stripANSI(_ s: String) -> String {
        guard let regex = ansiRegex else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private func write(_ level: Level, _ rawMsg: String) {
        let msg = Self.stripANSI(rawMsg)
        let entry = LogEntry(timestamp: Date(), level: level, message: msg)
        entries.append(entry)
        if entries.count > 1500 {
            entries.removeFirst(entries.count - 1500)
        }
        let line = "[\(dateFormatter.string(from: entry.timestamp))] \(level.rawValue.uppercased()) \(msg)\n"
        let fileURL = self.fileURL
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    func clear() {
        entries.removeAll()
        let url = fileURL
        queue.async {
            try? Data().write(to: url)
        }
    }

    private func rollIfNeeded() {
        let url = fileURL
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64, size > 5_000_000 else { return }
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }
}
