import Foundation
@testable import PorchKeepKit

// Tests for ArchiveStore: enumerating clip sidecars into the events list,
// reporting the total size, applying the retention window, and deleting clips.

@MainActor
func runArchiveStoreTests() {
    T.suite("ArchiveStore")

    // MARK: - 1. Empty archive

    do {
        let archiveDir = TestSupport.makeTempDir("archive-empty")
        defer { TestSupport.remove(archiveDir) }

        let (store, _) = makeStore(archiveDir: archiveDir)
        store.refresh()
        T.expectTrue(store.events.isEmpty, "fresh archive has no events")
        T.expectEqual(store.totalBytes, 0, "fresh archive reports zero bytes")
    }

    // MARK: - 2. Enumerating clip sets, sorted newest-first

    do {
        let archiveDir = TestSupport.makeTempDir("archive-list")
        defer { TestSupport.remove(archiveDir) }

        let (store, settings) = makeStore(archiveDir: archiveDir)
        let clipsDir = settings.clipsDir

        // Write three clip sets out of chronological order.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        writeClipSet(stem: "event_b", date: base.addingTimeInterval(120),
                     type: .ring, in: clipsDir, mp4Size: 200)
        writeClipSet(stem: "event_a", date: base,
                     type: .motion, in: clipsDir, mp4Size: 100)
        writeClipSet(stem: "event_c", date: base.addingTimeInterval(240),
                     type: .person, in: clipsDir, mp4Size: 300)

        store.refresh()
        T.expectEqual(store.events.count, 3, "all three clip sets enumerated")

        // Events should be sorted newest-first by date.
        if store.events.count == 3 {
            T.expectEqual(store.events[0].id, "event_c", "newest clip is first")
            T.expectEqual(store.events[1].id, "event_b", "middle clip is second")
            T.expectEqual(store.events[2].id, "event_a", "oldest clip is last")
            T.expectTrue(store.events[0].date > store.events[1].date,
                         "events strictly descending by date (0 > 1)")
            T.expectTrue(store.events[1].date > store.events[2].date,
                         "events strictly descending by date (1 > 2)")
        }

        // totalBytes sums the sidecar fileSize fields.
        T.expectEqual(store.totalBytes, 600, "totalBytes sums clip file sizes")
    }

    // MARK: - 3. formattedTotalSize()

    do {
        let archiveDir = TestSupport.makeTempDir("archive-size")
        defer { TestSupport.remove(archiveDir) }

        let (store, settings) = makeStore(archiveDir: archiveDir)
        writeClipSet(stem: "event_size", date: Date(timeIntervalSince1970: 1_700_000_000),
                     type: .ring, in: settings.clipsDir, mp4Size: 4096)
        store.refresh()
        let formatted = store.formattedTotalSize()
        T.expectFalse(formatted.isEmpty, "formattedTotalSize returns a non-empty string")
    }

    // MARK: - 4. Retention prunes clips older than the window

    do {
        let archiveDir = TestSupport.makeTempDir("archive-retention")
        defer { TestSupport.remove(archiveDir) }

        let (store, settings) = makeStore(archiveDir: archiveDir)
        settings.retentionDays = 30

        let clipsDir = settings.clipsDir
        let now = Date()
        // One clip well outside the 30-day window, one well inside it.
        let oldDate = now.addingTimeInterval(-60 * 24 * 3600)
        let recentDate = now.addingTimeInterval(-1 * 24 * 3600)
        writeClipSet(stem: "event_old", date: oldDate, type: .motion,
                     in: clipsDir, mp4Size: 100)
        writeClipSet(stem: "event_recent", date: recentDate, type: .ring,
                     in: clipsDir, mp4Size: 100)

        store.refresh()
        T.expectEqual(store.events.count, 2, "both clips present before retention")

        store.applyRetention()

        let fm = FileManager.default
        for ext in ["mp4", "jpg", "json"] {
            let oldFile = clipsDir.appendingPathComponent("event_old.\(ext)")
            T.expectFalse(fm.fileExists(atPath: oldFile.path),
                          "retention deleted old clip's .\(ext)")
            let recentFile = clipsDir.appendingPathComponent("event_recent.\(ext)")
            T.expectTrue(fm.fileExists(atPath: recentFile.path),
                         "retention kept recent clip's .\(ext)")
        }
        T.expectEqual(store.events.count, 1, "events list has only the recent clip after retention")
        T.expectEqual(store.events.first?.id, "event_recent",
                      "surviving event is the recent clip")
    }

    // MARK: - 5. delete(_:) removes a single clip set

    do {
        let archiveDir = TestSupport.makeTempDir("archive-delete")
        defer { TestSupport.remove(archiveDir) }

        let (store, settings) = makeStore(archiveDir: archiveDir)
        let clipsDir = settings.clipsDir
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        writeClipSet(stem: "event_keep", date: base, type: .person,
                     in: clipsDir, mp4Size: 100)
        writeClipSet(stem: "event_drop", date: base.addingTimeInterval(60),
                     type: .ring, in: clipsDir, mp4Size: 100)

        store.refresh()
        T.expectEqual(store.events.count, 2, "two clips present before delete")

        guard let target = store.events.first(where: { $0.id == "event_drop" }) else {
            T.expectTrue(false, "event_drop should be present before delete")
            return
        }
        store.delete(target)

        let fm = FileManager.default
        for ext in ["mp4", "jpg", "json"] {
            let dropped = clipsDir.appendingPathComponent("event_drop.\(ext)")
            T.expectFalse(fm.fileExists(atPath: dropped.path),
                          "delete removed event_drop's .\(ext)")
        }
        T.expectEqual(store.events.count, 1, "events list shrinks to one after delete")
        T.expectFalse(store.events.contains(where: { $0.id == "event_drop" }),
                      "events no longer contains the deleted clip")
        T.expectTrue(store.events.contains(where: { $0.id == "event_keep" }),
                     "the other clip is untouched")
    }
}

// MARK: - Helpers

/// Builds an ArchiveStore whose SettingsStore is in .local mode pointed at
/// `archiveDir`, so the archive uses a temp clipsDir. Returns both so tests
/// can reach derived paths and tweak retention settings.
@MainActor
private func makeStore(archiveDir: URL) -> (store: ArchiveStore, settings: SettingsStore) {
    let logger = AppLogger()
    let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
    settings.storageMode = .local
    settings.localArchivePath = archiveDir.path
    let icloud = ICloudCoordinator(logger: logger)
    let store = ArchiveStore(settings: settings, icloud: icloud, logger: logger)
    return (store, settings)
}

/// Creates a clip set on disk: encodes an EventSidecar to <stem>.json and
/// writes small dummy data to <stem>.mp4 and <stem>.jpg.
private func writeClipSet(stem: String, date: Date, type: DoorbellEvent.Kind,
                          in clipsDir: URL, mp4Size: Int) {
    try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)

    let mp4Bytes = Data(repeating: 0x4D, count: max(1, mp4Size))
    let jpgBytes = Data("fake-jpg-\(stem)".utf8)
    try? mp4Bytes.write(to: clipsDir.appendingPathComponent("\(stem).mp4"))
    try? jpgBytes.write(to: clipsDir.appendingPathComponent("\(stem).jpg"))

    let sidecar = EventSidecar(
        type: type,
        serialNumber: "T8214TEST",
        startedAt: date,
        durationSeconds: 10.0,
        fileSize: Int64(mp4Size),
        videoCodec: "h264",
        audioCodec: "aac",
        stem: stem
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let json = try? encoder.encode(sidecar) {
        try? json.write(to: clipsDir.appendingPathComponent("\(stem).json"))
    }
}
