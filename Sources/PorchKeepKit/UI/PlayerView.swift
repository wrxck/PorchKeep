import SwiftUI
import AVKit

// A thin NSViewRepresentable wrapper around AppKit's AVPlayerView.
//
// We deliberately avoid SwiftUI's `VideoPlayer`: it lives in the `_AVKit_SwiftUI`
// cross-import overlay, whose generic metadata fails to instantiate in this
// SwiftPM-built app bundle and aborts the process. AVPlayerView is plain AVKit
// and has no such dependency.

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .inline

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
