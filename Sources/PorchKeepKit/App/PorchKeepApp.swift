import SwiftUI

/// Entry point. The app lives in the PorchKeepKit library so its logic can be
/// unit tested; the thin `PorchKeep` executable target just calls this.
public func launchPorchKeep() {
    PorchKeepApp.main()
}

struct PorchKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environmentObject(appState)
                .environmentObject(appState.bridge)
                .environmentObject(appState.archive)
                .environmentObject(appState.recorder)
                .environmentObject(appState.settings)
                .environmentObject(appState.logger)
                .environmentObject(appState.backup)
                .frame(width: 380, height: 560)
        } label: {
            MenuBarIcon()
                .environmentObject(appState)
                .environmentObject(appState.bridge)
                .environmentObject(appState.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridge: EufyBridge
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .help(tooltip)
    }

    private var iconName: String {
        if bridge.state == .error || bridge.state == .disconnected {
            return "bell.slash"
        }
        if appState.liveViewActive {
            return "dot.radiowaves.left.and.right"
        }
        if recorder.isRecording {
            return "record.circle"
        }
        return "bell"
    }

    private var tooltip: String {
        switch bridge.state {
        case .disconnected: return "PorchKeep — bridge disconnected"
        case .connecting: return "PorchKeep — connecting…"
        case .authenticating: return "PorchKeep — authenticating…"
        case .ready:
            if recorder.isRecording { return "PorchKeep — recording event" }
            if appState.liveViewActive { return "PorchKeep — live view" }
            return "PorchKeep — idle"
        case .error: return "PorchKeep — bridge error"
        }
    }
}
