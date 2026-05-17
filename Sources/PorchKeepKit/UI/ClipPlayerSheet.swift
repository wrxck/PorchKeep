import SwiftUI
import AVKit

struct ClipPlayerSheet: View {
    let event: ArchivedEvent
    let close: () -> Void

    @EnvironmentObject var icloud: ICloudCoordinator

    @State private var player: AVPlayer? = nil
    @State private var downloading: Bool = false
    @State private var downloadError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.type.rawValue.capitalized).font(.headline)
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { close() }
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                        .onAppear { player.play() }
                } else if downloading {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Downloading from iCloud…").font(.caption).foregroundStyle(.white)
                    }
                } else if let err = downloadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                        Text(err).font(.caption).foregroundStyle(.white)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 680, minHeight: 420)
        .task { await prepare() }
    }

    private func prepare() async {
        downloading = true
        defer { downloading = false }
        do {
            try await icloud.ensureLocal(event.mp4URL)
            player = AVPlayer(url: event.mp4URL)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}
