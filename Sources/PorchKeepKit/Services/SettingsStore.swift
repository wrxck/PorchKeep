import Foundation
import Combine

enum StorageMode: String, CaseIterable {
    case iCloud
    case local
    var label: String { self == .iCloud ? "iCloud Drive" : "This Mac" }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let configured = "porchkeep.configured"
        static let country = "porchkeep.country"
        static let retentionDays = "porchkeep.retentionDays"
        static let maxClipLength = "porchkeep.maxClipLength"
        static let liveIdleTimeout = "porchkeep.liveIdleTimeout"
        static let bridgePort = "porchkeep.bridgePort"
        static let knownDeviceSerial = "porchkeep.knownDeviceSerial"
        static let knownDeviceName = "porchkeep.knownDeviceName"
        static let storageMode = "porchkeep.storageMode"
        static let localArchivePath = "porchkeep.localArchivePath"
        static let backupEnabled = "porchkeep.backupEnabled"
        static let backupPath = "porchkeep.backupPath"
        static let captureMotion = "porchkeep.captureMotion"
        static let capturePerson = "porchkeep.capturePerson"
        static let captureRing = "porchkeep.captureRing"
        static let captureStranger = "porchkeep.captureStranger"
        static let captureCooldown = "porchkeep.captureCooldown"
        static let streamFrameRate = "porchkeep.streamFrameRate"
    }

    @Published var isConfigured: Bool { didSet { d.set(isConfigured, forKey: Key.configured) } }
    @Published var country: String { didSet { d.set(country, forKey: Key.country) } }
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: Key.retentionDays) } }
    @Published var maxClipSeconds: Int { didSet { d.set(maxClipSeconds, forKey: Key.maxClipLength) } }
    @Published var liveIdleTimeoutSeconds: Int { didSet { d.set(liveIdleTimeoutSeconds, forKey: Key.liveIdleTimeout) } }
    @Published var bridgePort: Int { didSet { d.set(bridgePort, forKey: Key.bridgePort) } }
    @Published var knownDeviceSerial: String { didSet { d.set(knownDeviceSerial, forKey: Key.knownDeviceSerial) } }
    @Published var knownDeviceName: String { didSet { d.set(knownDeviceName, forKey: Key.knownDeviceName) } }

    @Published var storageMode: StorageMode { didSet { d.set(storageMode.rawValue, forKey: Key.storageMode) } }
    @Published var localArchivePath: String { didSet { d.set(localArchivePath, forKey: Key.localArchivePath) } }
    @Published var backupEnabled: Bool { didSet { d.set(backupEnabled, forKey: Key.backupEnabled) } }
    @Published var backupPath: String { didSet { d.set(backupPath, forKey: Key.backupPath) } }

    @Published var captureMotion: Bool { didSet { d.set(captureMotion, forKey: Key.captureMotion) } }
    @Published var capturePerson: Bool { didSet { d.set(capturePerson, forKey: Key.capturePerson) } }
    @Published var captureRing: Bool { didSet { d.set(captureRing, forKey: Key.captureRing) } }
    @Published var captureStranger: Bool { didSet { d.set(captureStranger, forKey: Key.captureStranger) } }
    @Published var captureCooldownSeconds: Int { didSet { d.set(captureCooldownSeconds, forKey: Key.captureCooldown) } }
    @Published var streamFrameRate: Int { didSet { d.set(streamFrameRate, forKey: Key.streamFrameRate) } }

    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        isConfigured = d.bool(forKey: Key.configured)
        country = d.string(forKey: Key.country) ?? "GB"
        retentionDays = d.object(forKey: Key.retentionDays) as? Int ?? 30
        maxClipSeconds = d.object(forKey: Key.maxClipLength) as? Int ?? 120
        liveIdleTimeoutSeconds = d.object(forKey: Key.liveIdleTimeout) as? Int ?? 120
        bridgePort = d.object(forKey: Key.bridgePort) as? Int ?? 3034
        knownDeviceSerial = d.string(forKey: Key.knownDeviceSerial) ?? ""
        knownDeviceName = d.string(forKey: Key.knownDeviceName) ?? ""
        storageMode = StorageMode(rawValue: d.string(forKey: Key.storageMode) ?? "") ?? .iCloud
        localArchivePath = d.string(forKey: Key.localArchivePath) ?? ""
        backupEnabled = d.bool(forKey: Key.backupEnabled)
        backupPath = d.string(forKey: Key.backupPath) ?? ""
        captureMotion = d.object(forKey: Key.captureMotion) as? Bool ?? true
        capturePerson = d.object(forKey: Key.capturePerson) as? Bool ?? true
        captureRing = d.object(forKey: Key.captureRing) as? Bool ?? true
        captureStranger = d.object(forKey: Key.captureStranger) as? Bool ?? true
        captureCooldownSeconds = d.object(forKey: Key.captureCooldown) as? Int ?? 15
        streamFrameRate = d.object(forKey: Key.streamFrameRate) as? Int ?? 15
    }

    // MARK: - Derived paths

    var iCloudRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/PorchKeep", isDirectory: true)
    }

    var defaultLocalRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/PorchKeep", isDirectory: true)
    }

    var archiveRoot: URL {
        switch storageMode {
        case .iCloud:
            return iCloudRoot
        case .local:
            return localArchivePath.isEmpty ? defaultLocalRoot : URL(fileURLWithPath: localArchivePath)
        }
    }

    var clipsDir: URL { archiveRoot.appendingPathComponent("clips", isDirectory: true) }

    /// The secondary backup clips directory, if a backup folder is set.
    var backupClipsDir: URL? {
        guard backupEnabled, !backupPath.isEmpty else { return nil }
        return URL(fileURLWithPath: backupPath).appendingPathComponent("clips", isDirectory: true)
    }

    var storesInICloud: Bool { storageMode == .iCloud }

    var bridgeDataDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("PorchKeep/eufy", isDirectory: true)
    }

    /// Whether a given doorbell event type should be recorded.
    func shouldCapture(_ type: DoorbellEvent.Kind) -> Bool {
        switch type {
        case .motion: return captureMotion
        case .person: return capturePerson
        case .ring: return captureRing
        case .stranger: return captureStranger
        case .stateChange: return false
        }
    }
}
