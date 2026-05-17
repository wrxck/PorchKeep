import SwiftUI
import AppKit

struct LogView: View {
    let close: () -> Void
    @EnvironmentObject var logger: AppLogger

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Log").font(.title2.weight(.semibold))
                Spacer()
                Button("Reveal file") {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.logFileURL])
                }
                Button("Clear") { logger.clear() }
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logger.entries) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption2.weight(.bold).monospaced())
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: logger.entries.count) { _, _ in
                    if let last = logger.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private func color(for level: AppLogger.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
