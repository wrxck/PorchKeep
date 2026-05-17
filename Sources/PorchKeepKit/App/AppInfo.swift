import Foundation

/// Build identity for PorchKeep. v0.1.0 is an experimental release —
/// pair-programmed with Claude Code and only lightly tested on real hardware.
enum AppInfo {
    static let version = "0.1.0"
    static let channel = "experimental"
    static let versionString = "v\(version) · \(channel)"
    static let docsURL = "https://porchkeep.hesketh.pro"
    static let repoURL = "https://github.com/wrxck/PorchKeep"
}
