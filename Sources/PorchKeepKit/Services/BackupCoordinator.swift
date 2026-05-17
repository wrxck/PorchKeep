import Foundation
import Combine

// BackupCoordinator is the "are my recordings safe?" service.
//
// It does two things:
//  1. Mirrors each finished clip set into an optional secondary backup folder.
//  2. Reports, per clip and overall, whether the recording is safely backed up
//     — uploaded to iCloud (when storing in iCloud) and/or copied to the
//     backup folder — so the UI can give the user concrete reassurance.

@MainActor
final class BackupCoordinator: ObservableObject {

    enum ClipState {
        case synced        // safely backed up everywhere it should be
        case pending       // still uploading / not yet mirrored
        case localOnly     // on this Mac, no off-device copy configured
        case missing       // the clip file is gone
    }

    @Published private(set) var states: [String: ClipState] = [:]
    @Published private(set) var summary: String = "No recordings yet"
    @Published private(set) var allSafe: Bool = true

    private let settings: SettingsStore
    private let logger: AppLogger

    init(settings: SettingsStore, logger: AppLogger) {
        self.settings = settings
        self.logger = logger
    }

    // MARK: - Mirroring

    /// Copies a clip set (.mp4/.jpg/.json) into the backup folder, if enabled.
    func mirror(stem: String) {
        guard let backupClips = settings.backupClipsDir else { return }
        let sourceDir = settings.clipsDir
        do {
            try FileManager.default.createDirectory(at: backupClips, withIntermediateDirectories: true)
        } catch {
            logger.error("Backup: cannot create backup folder: \(error)")
            return
        }
        var copied = 0
        for ext in ["mp4", "jpg", "json"] {
            let src = sourceDir.appendingPathComponent("\(stem).\(ext)")
            let dst = backupClips.appendingPathComponent("\(stem).\(ext)")
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                logger.error("Backup: failed to mirror \(stem).\(ext): \(error)")
            }
        }
        if copied > 0 {
            logger.info("Backup: mirrored \(stem) to \(backupClips.path)")
        }
    }

    /// Mirrors every archived clip that isn't already in the backup folder.
    func mirrorAll(events: [ArchivedEvent]) {
        guard settings.backupClipsDir != nil else { return }
        for event in events {
            mirror(stem: event.id)
        }
        logger.info("Backup: mirror sweep complete for \(events.count) clip(s)")
    }

    // MARK: - Status

    func refresh(events: [ArchivedEvent]) {
        var newStates: [String: ClipState] = [:]
        var safeCount = 0
        let inICloud = settings.storesInICloud
        let backupDir = settings.backupClipsDir

        for event in events {
            newStates[event.id] = evaluate(event, inICloud: inICloud, backupDir: backupDir)
        }
        for (_, s) in newStates where s == .synced || s == .localOnly { safeCount += 1 }

        states = newStates
        let total = events.count

        if total == 0 {
            summary = "No recordings yet"
            allSafe = true
            return
        }

        let pending = newStates.values.filter { $0 == .pending }.count
        if inICloud {
            if pending == 0 {
                summary = "✓ All \(total) recording\(total == 1 ? "" : "s") backed up to iCloud"
                allSafe = true
            } else {
                summary = "\(total - pending) of \(total) backed up to iCloud — \(pending) uploading…"
                allSafe = false
            }
        } else if backupDir != nil {
            if pending == 0 {
                summary = "✓ All \(total) recording\(total == 1 ? "" : "s") copied to backup folder"
                allSafe = true
            } else {
                summary = "\(total - pending) of \(total) copied to backup — \(pending) pending…"
                allSafe = false
            }
        } else {
            summary = "\(total) recording\(total == 1 ? "" : "s") on this Mac — no off-device backup"
            allSafe = false
        }
    }

    private func evaluate(_ event: ArchivedEvent, inICloud: Bool, backupDir: URL?) -> ClipState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: event.mp4URL.path) else { return .missing }

        if inICloud {
            // Uploaded to iCloud == safely backed up.
            let values = try? event.mp4URL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            if let uploaded = values?.ubiquitousItemIsUploaded {
                return uploaded ? .synced : .pending
            }
            // No ubiquity info — treat as pending until iCloud reports.
            return .pending
        }

        if let backupDir {
            let mirrored = fm.fileExists(atPath: backupDir.appendingPathComponent("\(event.id).mp4").path)
            return mirrored ? .synced : .pending
        }

        return .localOnly
    }

    func state(for stem: String) -> ClipState {
        states[stem] ?? .localOnly
    }
}
