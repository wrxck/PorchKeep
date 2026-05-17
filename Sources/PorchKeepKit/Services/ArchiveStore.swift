import Foundation
import Combine
import AppKit

// ArchiveStore owns the iCloud archive folder. It enumerates clip sidecars to
// build the events list (sidecars are tiny and stay local even when iCloud
// offloads the .mp4s) and prunes anything older than the retention window.

@MainActor
final class ArchiveStore: ObservableObject {

    @Published private(set) var events: [ArchivedEvent] = []
    @Published private(set) var totalBytes: Int64 = 0

    private let settings: SettingsStore
    private let icloud: ICloudCoordinator
    private let logger: AppLogger
    private var retentionTimer: Timer?

    init(settings: SettingsStore, icloud: ICloudCoordinator, logger: AppLogger) {
        self.settings = settings
        self.icloud = icloud
        self.logger = logger
        ensureDirectories()
    }

    private func ensureDirectories() {
        let clips = settings.clipsDir
        do {
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        } catch {
            logger.error("Cannot create clips dir at \(clips.path): \(error)")
        }
    }

    func refresh() {
        ensureDirectories()
        let clipsDir = settings.clipsDir
        let fm = FileManager.default
        var loaded: [ArchivedEvent] = []
        var bytes: Int64 = 0
        guard let entries = try? fm.contentsOfDirectory(at: clipsDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            events = []
            totalBytes = 0
            return
        }
        let sidecars = entries.filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in sidecars {
            // Sidecars stay local; they may still be iCloud-pinned. Force-download just in case.
            if let downloadStatus = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus {
                if downloadStatus != .current {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                }
            }
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? decoder.decode(EventSidecar.self, from: data) else {
                continue
            }
            let stem = sidecar.stem
            let mp4 = clipsDir.appendingPathComponent(stem + ".mp4")
            let thumb = clipsDir.appendingPathComponent(stem + ".jpg")
            loaded.append(ArchivedEvent(id: stem, sidecar: sidecar, mp4URL: mp4, thumbnailURL: thumb, sidecarURL: url))
            bytes += sidecar.fileSize
        }
        loaded.sort { $0.date > $1.date }
        events = loaded
        totalBytes = bytes
    }

    func startRetentionTimer() {
        retentionTimer?.invalidate()
        // Run once now, then hourly.
        applyRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyRetention() }
        }
    }

    func applyRetention() {
        let days = max(1, settings.retentionDays)
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3600))
        let fm = FileManager.default
        let clipsDir = settings.clipsDir
        guard let entries = try? fm.contentsOfDirectory(at: clipsDir, includingPropertiesForKeys: nil) else { return }
        let stems = Set(entries.filter { $0.pathExtension == "json" }
            .compactMap { $0.deletingPathExtension().lastPathComponent })
        var removed = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for stem in stems {
            let sidecarURL = clipsDir.appendingPathComponent(stem + ".json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? decoder.decode(EventSidecar.self, from: data) else { continue }
            if sidecar.startedAt < cutoff {
                for ext in ["mp4", "jpg", "json"] {
                    let url = clipsDir.appendingPathComponent("\(stem).\(ext)")
                    try? fm.removeItem(at: url)
                }
                removed += 1
            }
        }
        if removed > 0 {
            logger.info("Retention: removed \(removed) old clip(s) older than \(days) day(s)")
            refresh()
        }
    }

    /// Deletes a single clip set (.mp4/.jpg/.json) from the archive.
    func delete(_ event: ArchivedEvent) {
        let clipsDir = settings.clipsDir
        for ext in ["mp4", "jpg", "json"] {
            let url = clipsDir.appendingPathComponent("\(event.id).\(ext)")
            try? FileManager.default.removeItem(at: url)
        }
        logger.info("Deleted clip \(event.id)")
        refresh()
    }

    func formattedTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    func revealInFinder() {
        let url = settings.archiveRoot
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
