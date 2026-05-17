import AppKit

// A plain AppKit delegate so we can run first-launch logic (open the setup
// window) without depending on a SwiftUI view appearing — the MenuBarExtra
// popover content only materialises when the user clicks the menu bar.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // We write H.264 buffers into ffmpeg via pipes. When ffmpeg exits, the
        // next write would raise SIGPIPE and terminate the whole app. Ignore it
        // process-wide so the write throws instead and we handle it gracefully.
        signal(SIGPIPE, SIG_IGN)

        Task { @MainActor in
            let state = AppState.shared
            if !state.settings.isConfigured || !state.keychain.hasCredentials {
                state.presentSetup()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure the Node bridge child does not orphan and hold the port.
        AppState.shared.bridge.shutdownNow()
    }
}
