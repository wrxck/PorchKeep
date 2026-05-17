import Foundation
@testable import PorchKeepKit

// Tests for BackupCoordinator: clip mirroring into a secondary backup folder
// and the per-clip / overall "are my recordings safe?" state reporting.

@MainActor
func runBackupCoordinatorTests() {
    T.suite("BackupCoordinator")

    // MARK: - 1. No events at all

    do {
        let defaults = TestSupport.isolatedDefaults()
        let logger = AppLogger()
        let settings = SettingsStore(defaults: defaults)
        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        coordinator.refresh(events: [])
        T.expectTrue(coordinator.summary.contains("No recordings"),
                     "empty refresh summary mentions 'No recordings'")
        T.expectTrue(coordinator.allSafe, "empty refresh is considered all-safe")
        T.expectTrue(coordinator.states.isEmpty, "empty refresh leaves no per-clip states")
    }

    // MARK: - 2. mirror(stem:) copies a clip set into the backup folder

    do {
        let archiveDir = TestSupport.makeTempDir("backup-archive")
        let backupDir = TestSupport.makeTempDir("backup-dest")
        defer {
            TestSupport.remove(archiveDir)
            TestSupport.remove(backupDir)
        }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path
        settings.backupEnabled = true
        settings.backupPath = backupDir.path

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        let stem = "event_mirror_1"
        writeClipSet(stem: stem, in: settings.clipsDir,
                     type: .ring, startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        coordinator.mirror(stem: stem)

        guard let backupClips = settings.backupClipsDir else {
            T.expectTrue(false, "backupClipsDir should be set when backup enabled")
            return
        }
        let fm = FileManager.default
        for ext in ["mp4", "jpg", "json"] {
            let copied = backupClips.appendingPathComponent("\(stem).\(ext)")
            T.expectTrue(fm.fileExists(atPath: copied.path),
                         "mirror copied \(stem).\(ext) into backup folder")
        }
    }

    // MARK: - 3. Clip state evaluation

    // 3a. Local mode, no backup configured -> .localOnly
    do {
        let archiveDir = TestSupport.makeTempDir("backup-state-local")
        defer { TestSupport.remove(archiveDir) }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path
        settings.backupEnabled = false

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        let stem = "event_state_localonly"
        writeClipSet(stem: stem, in: settings.clipsDir,
                     type: .motion, startedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let event = makeArchivedEvent(stem: stem, in: settings.clipsDir,
                                      type: .motion,
                                      startedAt: Date(timeIntervalSince1970: 1_700_000_100))

        coordinator.refresh(events: [event])
        T.expectEqual(stateName(coordinator.state(for: stem)), "localOnly",
                      "local mode without backup yields .localOnly")
        T.expectFalse(coordinator.allSafe, "local-only with no backup is not all-safe")
        T.expectTrue(coordinator.summary.contains("no off-device backup"),
                     "local-only summary mentions no off-device backup")
    }

    // 3b. Local mode + backup enabled, clip mirrored -> .synced
    do {
        let archiveDir = TestSupport.makeTempDir("backup-state-synced")
        let backupDir = TestSupport.makeTempDir("backup-state-synced-dest")
        defer {
            TestSupport.remove(archiveDir)
            TestSupport.remove(backupDir)
        }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path
        settings.backupEnabled = true
        settings.backupPath = backupDir.path

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        let stem = "event_state_synced"
        let started = Date(timeIntervalSince1970: 1_700_000_200)
        writeClipSet(stem: stem, in: settings.clipsDir, type: .person, startedAt: started)
        coordinator.mirror(stem: stem)

        let event = makeArchivedEvent(stem: stem, in: settings.clipsDir,
                                      type: .person, startedAt: started)
        coordinator.refresh(events: [event])
        T.expectEqual(stateName(coordinator.state(for: stem)), "synced",
                      "mirrored clip in backup mode yields .synced")
        T.expectTrue(coordinator.allSafe, "all clips mirrored is all-safe")
        T.expectTrue(coordinator.summary.contains("backup folder"),
                     "synced backup summary mentions backup folder")
    }

    // 3c. Backup enabled but clip NOT mirrored -> .pending
    do {
        let archiveDir = TestSupport.makeTempDir("backup-state-pending")
        let backupDir = TestSupport.makeTempDir("backup-state-pending-dest")
        defer {
            TestSupport.remove(archiveDir)
            TestSupport.remove(backupDir)
        }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path
        settings.backupEnabled = true
        settings.backupPath = backupDir.path

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        let stem = "event_state_pending"
        let started = Date(timeIntervalSince1970: 1_700_000_300)
        writeClipSet(stem: stem, in: settings.clipsDir, type: .stranger, startedAt: started)
        // Deliberately do NOT mirror.

        let event = makeArchivedEvent(stem: stem, in: settings.clipsDir,
                                      type: .stranger, startedAt: started)
        coordinator.refresh(events: [event])
        T.expectEqual(stateName(coordinator.state(for: stem)), "pending",
                      "un-mirrored clip in backup mode yields .pending")
        T.expectFalse(coordinator.allSafe, "a pending clip means not all-safe")
        T.expectTrue(coordinator.summary.contains("pending"),
                     "pending backup summary mentions pending")
    }

    // 3d. Clip whose .mp4 file is missing -> .missing
    do {
        let archiveDir = TestSupport.makeTempDir("backup-state-missing")
        defer { TestSupport.remove(archiveDir) }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path
        settings.backupEnabled = false

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        // Build an ArchivedEvent that points at a file that does not exist.
        let stem = "event_state_missing"
        let event = makeArchivedEvent(stem: stem, in: settings.clipsDir,
                                      type: .motion,
                                      startedAt: Date(timeIntervalSince1970: 1_700_000_400))
        coordinator.refresh(events: [event])
        T.expectEqual(stateName(coordinator.state(for: stem)), "missing",
                      "clip with no .mp4 on disk yields .missing")
    }

    // MARK: - 4. Summary text changes between local-only and all-backed-up

    do {
        let archiveDir = TestSupport.makeTempDir("backup-summary-archive")
        let backupDir = TestSupport.makeTempDir("backup-summary-dest")
        defer {
            TestSupport.remove(archiveDir)
            TestSupport.remove(backupDir)
        }

        let logger = AppLogger()
        let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
        settings.storageMode = .local
        settings.localArchivePath = archiveDir.path

        let coordinator = BackupCoordinator(settings: settings, logger: logger)

        let started = Date(timeIntervalSince1970: 1_700_000_500)
        let stems = ["event_sum_a", "event_sum_b"]
        var events: [ArchivedEvent] = []
        for (i, stem) in stems.enumerated() {
            let when = started.addingTimeInterval(Double(i) * 60)
            writeClipSet(stem: stem, in: settings.clipsDir, type: .ring, startedAt: when)
            events.append(makeArchivedEvent(stem: stem, in: settings.clipsDir,
                                            type: .ring, startedAt: when))
        }

        // Local-only first: no backup.
        settings.backupEnabled = false
        coordinator.refresh(events: events)
        let localOnlySummary = coordinator.summary
        T.expectTrue(localOnlySummary.contains("on this Mac"),
                     "local-only summary mentions 'on this Mac'")
        T.expectFalse(coordinator.allSafe, "local-only multi-clip summary is not all-safe")

        // Now enable backup and mirror everything.
        settings.backupEnabled = true
        settings.backupPath = backupDir.path
        coordinator.mirrorAll(events: events)
        coordinator.refresh(events: events)
        let backedUpSummary = coordinator.summary
        T.expectTrue(backedUpSummary != localOnlySummary,
                     "summary changes once clips are backed up")
        T.expectTrue(backedUpSummary.contains("All 2"),
                     "all-backed-up summary reports all 2 recordings")
        T.expectTrue(coordinator.allSafe, "all clips mirrored is all-safe")
    }
}

// MARK: - Helpers

/// Maps a ClipState to a stable string for equality assertions.
@MainActor
private func stateName(_ state: BackupCoordinator.ClipState) -> String {
    switch state {
    case .synced:    return "synced"
    case .pending:   return "pending"
    case .localOnly: return "localOnly"
    case .missing:   return "missing"
    }
}

/// Writes a real clip set (.mp4 + .jpg + .json) sharing `stem` into `dir`.
private func writeClipSet(stem: String, in dir: URL,
                          type: DoorbellEvent.Kind, startedAt: Date) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mp4Bytes = Data("fake-mp4-\(stem)".utf8)
    let jpgBytes = Data("fake-jpg-\(stem)".utf8)
    try? mp4Bytes.write(to: dir.appendingPathComponent("\(stem).mp4"))
    try? jpgBytes.write(to: dir.appendingPathComponent("\(stem).jpg"))

    let sidecar = EventSidecar(
        type: type,
        serialNumber: "T8214TEST",
        startedAt: startedAt,
        durationSeconds: 10.0,
        fileSize: Int64(mp4Bytes.count),
        videoCodec: "h264",
        audioCodec: "aac",
        stem: stem
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let json = try? encoder.encode(sidecar) {
        try? json.write(to: dir.appendingPathComponent("\(stem).json"))
    }
}

/// Builds an ArchivedEvent pointing at the clip-set files under `dir`.
private func makeArchivedEvent(stem: String, in dir: URL,
                               type: DoorbellEvent.Kind, startedAt: Date) -> ArchivedEvent {
    let sidecar = EventSidecar(
        type: type,
        serialNumber: "T8214TEST",
        startedAt: startedAt,
        durationSeconds: 10.0,
        fileSize: 64,
        videoCodec: "h264",
        audioCodec: "aac",
        stem: stem
    )
    return ArchivedEvent(
        id: stem,
        sidecar: sidecar,
        mp4URL: dir.appendingPathComponent("\(stem).mp4"),
        thumbnailURL: dir.appendingPathComponent("\(stem).jpg"),
        sidecarURL: dir.appendingPathComponent("\(stem).json")
    )
}
