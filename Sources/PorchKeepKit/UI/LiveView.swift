import SwiftUI
import AVKit

struct LiveView: View {
    let serial: String
    let close: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridge: EufyBridge
    @ObservedObject var streamer: LiveStreamer
    @State private var player: AVPlayer? = nil
    @State private var started = false

    init(serial: String, streamer: LiveStreamer, close: @escaping () -> Void) {
        self.serial = serial
        self.streamer = streamer
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live view").font(.headline)
                Spacer()
                if streamer.isStreaming {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.blue).font(.caption.weight(.semibold))
                }
                Button("Close") { close() }
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                        .onAppear { player.play() }
                } else if let err = streamer.lastError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                        Text(err).font(.caption).foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Waking doorbell…").font(.caption).foregroundStyle(.white)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            Divider()
            HStack {
                Text("This uses battery. Closing the window stops the stream.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset idle timer") {
                    streamer.resetIdleTimer(
                        idleTimeout: TimeInterval(appState.settings.liveIdleTimeoutSeconds),
                        serial: serial,
                        bridge: bridge
                    )
                }
            }
            .padding(8)
        }
        .frame(minWidth: 680, minHeight: 460)
        .task {
            guard !started else { return }
            started = true
            let url = await streamer.start(
                serial: serial,
                bridge: bridge,
                idleTimeout: TimeInterval(appState.settings.liveIdleTimeoutSeconds),
                frameRate: appState.settings.streamFrameRate
            )
            if let url { self.player = AVPlayer(url: url) }
        }
    }
}
