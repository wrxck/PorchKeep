import SwiftUI
import AppKit

struct SettingsView: View {
    let close: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var archive: ArchiveStore
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    captureSection
                    storageSection
                    liveViewSection
                    connectionSection
                    systemSection
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 660)
    }

    // MARK: - Capture

    @ViewBuilder private var captureSection: some View {
        GroupBox {
            settingsRows {
                Text("Record these events").font(.callout.weight(.medium))
                Toggle("Motion detected", isOn: $settings.captureMotion)
                Toggle("Person detected", isOn: $settings.capturePerson)
                Toggle("Doorbell ring", isOn: $settings.captureRing)
                Toggle("Stranger detected", isOn: $settings.captureStranger)
                Divider()
                Stepper("Maximum clip length: \(settings.maxClipSeconds)s",
                        value: $settings.maxClipSeconds, in: 30...300, step: 10)
                Stepper("Cooldown between clips: \(settings.captureCooldownSeconds)s",
                        value: $settings.captureCooldownSeconds, in: 0...120, step: 5)
                Stepper("Keep recordings for \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")",
                        value: $settings.retentionDays, in: 7...90)
                Text("Older recordings are deleted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: { sectionLabel("Capture", "video.badge.checkmark") }
    }

    // MARK: - Storage & Backup

    @ViewBuilder private var storageSection: some View {
        GroupBox {
            settingsRows {
                Picker("Store recordings in", selection: $settings.storageMode) {
                    ForEach(StorageMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: settings.storageMode) { _, _ in
                    archive.refresh()
                    appState.backup.refresh(events: archive.events)
                }
                if settings.storageMode == .local {
                    folderRow(title: "Folder",
                              path: settings.localArchivePath.isEmpty ? settings.defaultLocalRoot.path : settings.localArchivePath) {
                        if let url = Self.chooseFolder() {
                            settings.localArchivePath = url.path
                            archive.refresh()
                        }
                    }
                } else {
                    LabeledContent("Folder") {
                        Text(settings.iCloudRoot.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("Changing this only affects new recordings — existing clips stay in their current folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Keep a second backup copy", isOn: $settings.backupEnabled)
                if settings.backupEnabled {
                    folderRow(title: "Backup folder",
                              path: settings.backupPath.isEmpty ? "Not set" : settings.backupPath) {
                        if let url = Self.chooseFolder() {
                            settings.backupPath = url.path
                            appState.resyncBackups()
                        }
                    }
                    Button("Copy all existing recordings to backup now") {
                        appState.resyncBackups()
                    }
                    .disabled(settings.backupPath.isEmpty)
                }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: appState.backup.allSafe ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(appState.backup.allSafe ? .green : .orange)
                    Text(appState.backup.summary).font(.caption)
                }
                HStack {
                    Text("\(archive.events.count) clip\(archive.events.count == 1 ? "" : "s") — \(archive.formattedTotalSize())")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder") { archive.revealInFinder() }
                    Button("Run cleanup now") { archive.applyRetention() }
                }
            }
        } label: { sectionLabel("Storage & Backup", "externaldrive.badge.icloud") }
    }

    // MARK: - Live View

    @ViewBuilder private var liveViewSection: some View {
        GroupBox {
            settingsRows {
                Stepper("Auto-stop live view after \(settings.liveIdleTimeoutSeconds)s idle",
                        value: $settings.liveIdleTimeoutSeconds, in: 30...600, step: 15)
                Stepper("Assumed stream frame rate: \(settings.streamFrameRate) fps",
                        value: $settings.streamFrameRate, in: 5...30, step: 1)
                Text("Frame rate affects clip & live-view playback speed. Most eufy doorbells stream around 15 fps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: { sectionLabel("Live View", "dot.radiowaves.left.and.right") }
    }

    // MARK: - Connection

    @ViewBuilder private var connectionSection: some View {
        GroupBox {
            settingsRows {
                LabeledContent("Bridge port") {
                    Stepper(value: $settings.bridgePort, in: 1024...65535) {
                        Text("\(settings.bridgePort)").monospacedDigit()
                    }
                }
                LabeledContent("Country") {
                    TextField("", text: $settings.country).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                HStack {
                    Button("Reconnect bridge") { appState.relaunchBridge() }
                    Button("Re-run setup…") {
                        close()
                        appState.presentSetup()
                    }
                }
            }
        } label: { sectionLabel("Connection", "antenna.radiowaves.left.and.right") }
    }

    // MARK: - System

    @ViewBuilder private var systemSection: some View {
        GroupBox {
            settingsRows {
                Toggle("Launch PorchKeep at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LaunchAtLogin.setEnabled(on) }
                        catch { appState.lastError = error.localizedDescription }
                    }
                Button("View log…") { appState.presentLog() }
                Divider()
                Text("PorchKeep \(AppInfo.versionString)")
                    .font(.caption.weight(.medium))
                Text("Experimental build — pair-programmed with Claude Code, minimally tested. Docs: porchkeep.hesketh.pro")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: { sectionLabel("System", "gearshape") }
    }

    // MARK: - Helpers

    @ViewBuilder private func settingsRows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }

    @ViewBuilder private func folderRow(title: String, path: String, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…", action: action)
            }
        }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
