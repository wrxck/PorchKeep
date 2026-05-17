import SwiftUI
import AppKit

// WindowPresenter manages standalone NSWindows that host SwiftUI views.
//
// We deliberately do NOT use SwiftUI .sheet from inside the MenuBarExtra
// popover: a menu-bar window is a transient panel, and presenting a sheet with
// a focusable TextField inside it makes the panel resign key the moment you
// click the field — which tears down the whole popover. Real top-level windows
// own their own key state and behave correctly.

@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var idByWindow: [ObjectIdentifier: String] = [:]

    /// Called (with the window id) after a window closes — lets the app clean
    /// up associated state, e.g. stopping a livestream.
    var onClose: ((String) -> Void)?

    func present<V: View>(id: String, title: String, size: CGSize, resizable: Bool, view: V) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        window.styleMask = mask
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[id] = window
        idByWindow[ObjectIdentifier(window)] = id
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let id = idByWindow[ObjectIdentifier(w)] else { return }
        windows.removeValue(forKey: id)
        idByWindow.removeValue(forKey: ObjectIdentifier(w))
        onClose?(id)
    }
}

enum WindowID {
    static let setup = "setup"
    static let settings = "settings"
    static let log = "log"
    static let liveView = "liveView"
    static let recordings = "recordings"
    static func player(_ stem: String) -> String { "player-\(stem)" }
}
