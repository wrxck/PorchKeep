import SwiftUI
import AppKit

struct MenuBarRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridge: EufyBridge
    @EnvironmentObject var archive: ArchiveStore
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: AppLogger
    @EnvironmentObject var backup: BackupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.tint)
                Text("PorchKeep").font(.headline)
                Spacer()
                statusBadge
            }
            if let err = bridge.lastError, bridge.state == .error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let last = archive.events.first {
                Text("Last event: \(relative(last.date))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No events yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch bridge.state {
            case .ready: return ("Ready", .green)
            case .connecting: return ("Connecting…", .yellow)
            case .authenticating: return ("Auth…", .yellow)
            case .disconnected: return ("Offline", .gray)
            case .error: return ("Error", .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            latestEventBlock
            Divider()
            Text("Recent events").font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(archive.events) { event in
                        EventRowView(event: event) {
                            appState.presentPlayer(for: event)
                        }
                        Divider().padding(.leading, 64)
                    }
                    if archive.events.isEmpty {
                        Text("Captured motion and ring events will appear here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 240)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var latestEventBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(url: archive.events.first?.thumbnailURL)
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                if let latest = archive.events.first {
                    Text(latest.type.rawValue.capitalized).font(.subheadline.weight(.semibold))
                    Text(relative(latest.date)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Doorbell idle").font(.subheadline.weight(.semibold))
                    Text(settings.knownDeviceName.isEmpty ? "No device known" : settings.knownDeviceName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button {
                        appState.presentLiveView()
                    } label: {
                        Label("View Live", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(bridge.state != .ready || settings.knownDeviceSerial.isEmpty)
                    if recorder.isRecording {
                        Label("Recording", systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .font(.caption.weight(.semibold))
                    }
                }
                Text("Live view wakes the doorbell — uses battery.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: backup.allSafe ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(backup.allSafe ? .green : .orange)
                    .font(.caption)
                Text(backup.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
            }
            HStack {
                Button {
                    appState.presentRecordings()
                } label: {
                    Label("\(archive.events.count) Recording\(archive.events.count == 1 ? "" : "s")", systemImage: "film.stack")
                }
                .controlSize(.small)
                Text(archive.formattedTotalSize())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Recordings…") { appState.presentRecordings() }
                    Button("Settings…") { appState.presentSettings() }
                    Button("View log…") { appState.presentLog() }
                    Button("Open archive in Finder") { archive.revealInFinder() }
                    Button("Re-run setup…") { appState.presentSetup() }
                    Button("Reconnect bridge") { appState.relaunchBridge() }
                    Divider()
                    Button("Quit PorchKeep") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct EventRowView: View {
    let event: ArchivedEvent
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                ThumbnailView(url: event.thumbnailURL)
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.type.rawValue.capitalized).font(.subheadline.weight(.medium))
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.0fs", event.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThumbnailView: View {
    let url: URL?
    @State private var nsImage: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = nsImage {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.18))
                Image(systemName: "bell").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url?.path) { load() }
    }

    private func load() {
        guard let url else { nsImage = nil; return }
        guard FileManager.default.fileExists(atPath: url.path) else { nsImage = nil; return }
        if let img = NSImage(contentsOf: url) {
            self.nsImage = img
        } else {
            self.nsImage = nil
        }
    }
}
