import Foundation
@testable import PorchKeepKit

// Tests for SettingsStore — its defaults, the StorageMode enum, the derived
// archive/backup/bridge paths, the per-event capture toggles, and persistence
// across two stores sharing one UserDefaults instance.
//
// Every store is built with an isolated, throwaway UserDefaults suite so the
// tests never read or mutate the real user defaults.

@MainActor
func runSettingsStoreTests() {
    runSettingsDefaultsTests()
    runStorageModeTests()
    runSettingsPathTests()
    runBackupClipsDirTests()
    runStoresInICloudTests()
    runShouldCaptureTests()
    runSettingsPersistenceTests()
}

// MARK: - Defaults

@MainActor
private func runSettingsDefaultsTests() {
    T.suite("SettingsStore.defaults")

    let store = SettingsStore(defaults: TestSupport.isolatedDefaults())

    T.expectEqual(store.storageMode, .iCloud, "default storageMode is iCloud")
    T.expectEqual(store.retentionDays, 30, "default retentionDays is 30")
    T.expectEqual(store.maxClipSeconds, 120, "default maxClipSeconds is 120")
    T.expectEqual(store.liveIdleTimeoutSeconds, 120, "default liveIdleTimeoutSeconds is 120")
    T.expectEqual(store.bridgePort, 3034, "default bridgePort is 3034")
    T.expectEqual(store.captureCooldownSeconds, 15, "default captureCooldownSeconds is 15")
    T.expectEqual(store.streamFrameRate, 15, "default streamFrameRate is 15")
    T.expectEqual(store.country, "GB", "default country is GB")
    T.expectFalse(store.isConfigured, "fresh store is not configured")
    T.expectFalse(store.backupEnabled, "backup disabled by default")

    T.expectTrue(store.captureMotion, "captureMotion on by default")
    T.expectTrue(store.capturePerson, "capturePerson on by default")
    T.expectTrue(store.captureRing, "captureRing on by default")
    T.expectTrue(store.captureStranger, "captureStranger on by default")
}

// MARK: - StorageMode enum

@MainActor
private func runStorageModeTests() {
    T.suite("StorageMode")

    T.expectEqual(StorageMode.iCloud.label, "iCloud Drive", "iCloud label text")
    T.expectEqual(StorageMode.local.label, "This Mac", "local label text")
    T.expectEqual(StorageMode.allCases.count, 2, "StorageMode has two cases")
}

// MARK: - Derived paths

@MainActor
private func runSettingsPathTests() {
    T.suite("SettingsStore.paths")

    // iCloud mode: archiveRoot lives under the CloudDocs container, and
    // clipsDir is archiveRoot + /clips.
    let iCloudStore = SettingsStore(defaults: TestSupport.isolatedDefaults())
    iCloudStore.storageMode = .iCloud
    T.expectTrue(iCloudStore.archiveRoot.path.hasSuffix("com~apple~CloudDocs/PorchKeep"),
                 "iCloud archiveRoot ends with the CloudDocs/PorchKeep path")
    T.expectEqual(iCloudStore.clipsDir.path,
                  iCloudStore.archiveRoot.appendingPathComponent("clips").path,
                  "clipsDir is archiveRoot + /clips")
    T.expectTrue(iCloudStore.clipsDir.path.hasSuffix("/clips"),
                 "clipsDir ends with /clips")

    // Local mode with no explicit path: archiveRoot falls back to
    // defaultLocalRoot (~/Movies/PorchKeep).
    let localDefaultStore = SettingsStore(defaults: TestSupport.isolatedDefaults())
    localDefaultStore.storageMode = .local
    localDefaultStore.localArchivePath = ""
    T.expectEqual(localDefaultStore.archiveRoot.path,
                  localDefaultStore.defaultLocalRoot.path,
                  "local mode with empty path uses defaultLocalRoot")
    T.expectTrue(localDefaultStore.defaultLocalRoot.path.hasSuffix("Movies/PorchKeep"),
                 "defaultLocalRoot ends with Movies/PorchKeep")

    // Local mode with an explicit path: archiveRoot is that path verbatim.
    let customPath = "/tmp/porchkeep-archive-\(UUID().uuidString)"
    let localCustomStore = SettingsStore(defaults: TestSupport.isolatedDefaults())
    localCustomStore.storageMode = .local
    localCustomStore.localArchivePath = customPath
    T.expectEqual(localCustomStore.archiveRoot.path, customPath,
                  "local mode with explicit path uses that path")

    // bridgeDataDir lives under Application Support / PorchKeep / eufy.
    T.expectTrue(iCloudStore.bridgeDataDir.path.hasSuffix("PorchKeep/eufy"),
                 "bridgeDataDir ends with PorchKeep/eufy")
}

// MARK: - backupClipsDir

@MainActor
private func runBackupClipsDirTests() {
    T.suite("SettingsStore.backupClipsDir")

    // Disabled backup: always nil.
    let disabled = SettingsStore(defaults: TestSupport.isolatedDefaults())
    disabled.backupEnabled = false
    disabled.backupPath = "/tmp/porchkeep-backup"
    T.expectNil(disabled.backupClipsDir, "backupClipsDir is nil when backup disabled")

    // Enabled but no path: still nil.
    let enabledNoPath = SettingsStore(defaults: TestSupport.isolatedDefaults())
    enabledNoPath.backupEnabled = true
    enabledNoPath.backupPath = ""
    T.expectNil(enabledNoPath.backupClipsDir, "backupClipsDir is nil when backupPath empty")

    // Enabled with a path: non-nil and ends with /clips.
    let enabled = SettingsStore(defaults: TestSupport.isolatedDefaults())
    enabled.backupEnabled = true
    let backupPath = "/tmp/porchkeep-backup-\(UUID().uuidString)"
    enabled.backupPath = backupPath
    T.expectNotNil(enabled.backupClipsDir, "backupClipsDir is set when backup enabled with path")
    if let dir = enabled.backupClipsDir {
        T.expectTrue(dir.path.hasSuffix("/clips"), "backupClipsDir ends with /clips")
        T.expectEqual(dir.path, backupPath + "/clips", "backupClipsDir is backupPath + /clips")
    }
}

// MARK: - storesInICloud

@MainActor
private func runStoresInICloudTests() {
    T.suite("SettingsStore.storesInICloud")

    let store = SettingsStore(defaults: TestSupport.isolatedDefaults())
    store.storageMode = .iCloud
    T.expectTrue(store.storesInICloud, "storesInICloud is true in iCloud mode")

    store.storageMode = .local
    T.expectFalse(store.storesInICloud, "storesInICloud is false in local mode")
}

// MARK: - shouldCapture

@MainActor
private func runShouldCaptureTests() {
    T.suite("SettingsStore.shouldCapture")

    let store = SettingsStore(defaults: TestSupport.isolatedDefaults())

    // With all toggles at their default (on), each event kind maps to its toggle.
    T.expectTrue(store.shouldCapture(.motion), "shouldCapture(.motion) reflects captureMotion")
    T.expectTrue(store.shouldCapture(.person), "shouldCapture(.person) reflects capturePerson")
    T.expectTrue(store.shouldCapture(.ring), "shouldCapture(.ring) reflects captureRing")
    T.expectTrue(store.shouldCapture(.stranger), "shouldCapture(.stranger) reflects captureStranger")

    // stateChange is never captured regardless of toggles.
    T.expectFalse(store.shouldCapture(.stateChange), "shouldCapture(.stateChange) is always false")

    // Flipping a toggle off is reflected by shouldCapture.
    store.captureMotion = false
    T.expectFalse(store.shouldCapture(.motion), "shouldCapture(.motion) follows toggle off")
    T.expectTrue(store.shouldCapture(.person), "other toggles unaffected by motion toggle")
}

// MARK: - Persistence

@MainActor
private func runSettingsPersistenceTests() {
    T.suite("SettingsStore.persistence")

    let defaults = TestSupport.isolatedDefaults()

    // First store: mutate several values.
    let first = SettingsStore(defaults: defaults)
    first.retentionDays = 14
    first.storageMode = .local
    first.captureMotion = false
    first.country = "US"
    first.bridgePort = 9999
    first.isConfigured = true
    first.backupEnabled = true

    // Second store on the SAME defaults instance must see the persisted values.
    let second = SettingsStore(defaults: defaults)
    T.expectEqual(second.retentionDays, 14, "retentionDays persisted")
    T.expectEqual(second.storageMode, .local, "storageMode persisted")
    T.expectFalse(second.captureMotion, "captureMotion persisted")
    T.expectEqual(second.country, "US", "country persisted")
    T.expectEqual(second.bridgePort, 9999, "bridgePort persisted")
    T.expectTrue(second.isConfigured, "isConfigured persisted")
    T.expectTrue(second.backupEnabled, "backupEnabled persisted")

    // Untouched values still come back at their defaults.
    T.expectEqual(second.maxClipSeconds, 120, "untouched maxClipSeconds keeps default")
    T.expectTrue(second.capturePerson, "untouched capturePerson keeps default")
}
