import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var liveViewActive: Bool = false
    @Published var lastError: String? = nil

    let logger: AppLogger
    let settings: SettingsStore
    let keychain: KeychainStore
    let archive: ArchiveStore
    let bridge: EufyBridge
    let recorder: Recorder
    let icloud: ICloudCoordinator
    let liveStreamer: LiveStreamer
    let backup: BackupCoordinator
    let windows = WindowPresenter()

    private var eventTask: Task<Void, Never>?
    private var backupTimer: Timer?

    private init() {
        let logger = AppLogger()
        let settings = SettingsStore()
        let keychain = KeychainStore()
        let icloud = ICloudCoordinator(logger: logger)
        let archive = ArchiveStore(settings: settings, icloud: icloud, logger: logger)
        let bridge = EufyBridge(logger: logger, keychain: keychain, settings: settings)
        let backup = BackupCoordinator(settings: settings, logger: logger)
        let recorder = Recorder(logger: logger, archive: archive, settings: settings, backup: backup)
        self.logger = logger
        self.settings = settings
        self.keychain = keychain
        self.icloud = icloud
        self.archive = archive
        self.bridge = bridge
        self.backup = backup
        self.recorder = recorder
        self.liveStreamer = LiveStreamer(logger: logger)

        archive.refresh()
        archive.startRetentionTimer()
        backup.refresh(events: archive.events)

        if settings.isConfigured && keychain.hasCredentials {
            Task { await bridge.start() }
        }

        // iCloud uploads complete asynchronously; re-check backup status
        // periodically so the "all backed up" reassurance stays accurate.
        backupTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.backup.refresh(events: self.archive.events)
            }
        }

        wireWindowCallbacks()
        observeBridge()
    }

    /// Re-mirrors every clip and refreshes backup status — used after the user
    /// changes the storage location or enables a backup folder.
    func resyncBackups() {
        archive.refresh()
        backup.mirrorAll(events: archive.events)
        backup.refresh(events: archive.events)
    }

    // MARK: - Doorbell events

    private func observeBridge() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.bridge.events {
                await self.handleDoorbellEvent(event)
            }
        }
    }

    private func handleDoorbellEvent(_ event: DoorbellEvent) async {
        logger.info("Event received: \(event.type.rawValue) device=\(event.serialNumber)")
        guard event.type != .stateChange else { return }
        guard event.isStart else { return }
        await recorder.captureEvent(event, bridge: bridge)
    }

    func relaunchBridge() {
        Task {
            await bridge.stop()
            await bridge.start()
        }
    }

    // MARK: - Windows

    private func wireWindowCallbacks() {
        windows.onClose = { [weak self] id in
            guard let self else { return }
            if id == WindowID.liveView {
                self.liveViewActive = false
                let serial = self.settings.knownDeviceSerial
                Task { await self.liveStreamer.stop(serial: serial, bridge: self.bridge) }
            }
        }
    }

    func presentSetup() {
        let root = SetupWizardView(close: { [weak self] in self?.windows.close(id: WindowID.setup) })
            .environmentObject(self)
            .environmentObject(bridge)
            .environmentObject(settings)
            .environmentObject(keychain)
        windows.present(id: WindowID.setup, title: "Set up PorchKeep",
                        size: CGSize(width: 560, height: 460), resizable: false, view: root)
    }

    func presentSettings() {
        let root = SettingsView(close: { [weak self] in self?.windows.close(id: WindowID.settings) })
            .environmentObject(self)
            .environmentObject(settings)
            .environmentObject(archive)
        windows.present(id: WindowID.settings, title: "PorchKeep Settings",
                        size: CGSize(width: 560, height: 580), resizable: false, view: root)
    }

    func presentLog() {
        let root = LogView(close: { [weak self] in self?.windows.close(id: WindowID.log) })
            .environmentObject(logger)
        windows.present(id: WindowID.log, title: "PorchKeep Log",
                        size: CGSize(width: 720, height: 480), resizable: true, view: root)
    }

    func presentRecordings() {
        archive.refresh()
        backup.refresh(events: archive.events)
        let root = RecordingsView(close: { [weak self] in self?.windows.close(id: WindowID.recordings) })
            .environmentObject(self)
            .environmentObject(archive)
            .environmentObject(backup)
            .environmentObject(settings)
        windows.present(id: WindowID.recordings, title: "PorchKeep Recordings",
                        size: CGSize(width: 780, height: 620), resizable: true, view: root)
    }

    func presentLiveView() {
        guard !settings.knownDeviceSerial.isEmpty else {
            lastError = "No doorbell selected — run setup first."
            return
        }
        liveViewActive = true
        let root = LiveView(serial: settings.knownDeviceSerial,
                            streamer: liveStreamer,
                            close: { [weak self] in self?.windows.close(id: WindowID.liveView) })
            .environmentObject(self)
            .environmentObject(bridge)
        windows.present(id: WindowID.liveView, title: "Live view",
                        size: CGSize(width: 680, height: 460), resizable: true, view: root)
    }

    func presentPlayer(for event: ArchivedEvent) {
        let id = WindowID.player(event.id)
        let root = ClipPlayerSheet(event: event, close: { [weak self] in self?.windows.close(id: id) })
            .environmentObject(icloud)
        windows.present(id: id, title: event.type.rawValue.capitalized,
                        size: CGSize(width: 680, height: 420), resizable: true, view: root)
    }
}
