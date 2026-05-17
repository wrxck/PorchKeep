import SwiftUI
import AppKit

struct RecordingsView: View {
    let close: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var archive: ArchiveStore
    @EnvironmentObject var backup: BackupCoordinator
    @EnvironmentObject var settings: SettingsStore

    @State private var filter: EventFilter = .all

    enum EventFilter: String, CaseIterable, Identifiable {
        case all, motion, person, ring
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            backupBanner
            Divider()
            if filteredEvents.isEmpty {
                emptyState
            } else {
                recordingsList
            }
        }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recordings").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    archive.refresh()
                    backup.refresh(events: archive.events)
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Picker("", selection: $filter) {
                    ForEach(EventFilter.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Text("\(filteredEvents.count) clip\(filteredEvents.count == 1 ? "" : "s") • \(archive.formattedTotalSize())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private var backupBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: backup.allSafe ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath.icloud")
                .foregroundStyle(backup.allSafe ? .green : .orange)
            Text(backup.summary).font(.callout)
            Spacer()
            Text(settings.storesInICloud ? "iCloud Drive" : "This Mac")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bell.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No recordings yet").foregroundStyle(.secondary)
            Text("Motion and ring events will be captured automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    @ViewBuilder private var recordingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedDays, id: \.self) { day in
                    Section {
                        ForEach(eventsByDay[day] ?? []) { event in
                            RecordingRow(
                                event: event,
                                state: backup.state(for: event.id),
                                onPlay: { appState.presentPlayer(for: event) },
                                onReveal: { reveal(event) },
                                onDelete: { archive.delete(event); backup.refresh(events: archive.events) }
                            )
                            Divider().padding(.leading, 96)
                        }
                    } header: {
                        Text(day)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var filteredEvents: [ArchivedEvent] {
        archive.events.filter { event in
            switch filter {
            case .all: return true
            case .motion: return event.type == .motion
            case .person: return event.type == .person || event.type == .stranger
            case .ring: return event.type == .ring
            }
        }
    }

    private var eventsByDay: [String: [ArchivedEvent]] {
        Dictionary(grouping: filteredEvents) { dayLabel($0.date) }
    }

    private var groupedDays: [String] {
        eventsByDay.keys.sorted { a, b in
            (eventsByDay[a]?.first?.date ?? .distantPast) > (eventsByDay[b]?.first?.date ?? .distantPast)
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }

    private func reveal(_ event: ArchivedEvent) {
        NSWorkspace.shared.activateFileViewerSelecting([event.mp4URL])
    }
}

struct RecordingRow: View {
    let event: ArchivedEvent
    let state: BackupCoordinator.ClipState
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: event.thumbnailURL)
                .frame(width: 80, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.type.rawValue.capitalized).font(.subheadline.weight(.medium))
                    backupBadge
                }
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.0fs", event.duration))
                    .font(.caption.monospacedDigit())
                Text(ByteCountFormatter.string(fromByteCount: event.fileSize, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if hovering {
                HStack(spacing: 4) {
                    Button { onPlay() } label: { Image(systemName: "play.fill") }
                        .help("Play")
                    Button { onReveal() } label: { Image(systemName: "folder") }
                        .help("Reveal in Finder")
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help("Delete")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
        .onHover { hovering = $0 }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var backupBadge: some View {
        switch state {
        case .synced:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.caption2).help("Backed up")
        case .pending:
            Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                .font(.caption2).help("Backing up…")
        case .localOnly:
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
                .font(.caption2).help("On this Mac only")
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .font(.caption2).help("File missing")
        }
    }
}
