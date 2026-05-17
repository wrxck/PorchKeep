import Foundation
@testable import PorchKeepKit

// Tests for AppLogger.stripANSI — the bundled bridge emits ANSI colour codes
// and they must be scrubbed before reaching the log file / log viewer.

@MainActor
func runAppLoggerTests() {
    T.suite("AppLogger.stripANSI")

    // Plain text is untouched.
    T.expectEqual(AppLogger.stripANSI("hello world"), "hello world",
                  "plain text passes through unchanged")
    T.expectEqual(AppLogger.stripANSI(""), "", "empty string passes through")

    // A single SGR colour code is removed.
    let single = "\u{1B}[33mwarning\u{1B}[0m"
    T.expectEqual(AppLogger.stripANSI(single), "warning",
                  "single colour code pair stripped")

    // The real shape of a eufy-security-ws log line.
    let bridgeLine = "\u{1B}[37m2026-05-17 16:00:00\u{1B}[39m\u{1B}[0m\t\u{1B}[34m\u{1B}[1mINFO\u{1B}[22m\u{1B}[39m\u{1B}[0m\teufy-security-ws"
    let cleaned = AppLogger.stripANSI(bridgeLine)
    T.expectFalse(cleaned.contains("\u{1B}"), "no escape characters remain")
    T.expectFalse(cleaned.contains("[33m"), "no leftover colour tokens")
    T.expectTrue(cleaned.contains("INFO"), "log level text is kept")
    T.expectTrue(cleaned.contains("eufy-security-ws"), "log content is kept")
    T.expectTrue(cleaned.contains("2026-05-17 16:00:00"), "timestamp text is kept")

    // Codes with multiple parameters and various final letters.
    T.expectEqual(AppLogger.stripANSI("\u{1B}[1;31;40mX\u{1B}[0m"), "X",
                  "multi-parameter SGR code stripped")

    // A literal "[33m" with no ESC prefix is NOT stripped (not an ANSI code).
    T.expectEqual(AppLogger.stripANSI("price [33m]"), "price [33m]",
                  "bracket text without ESC is left intact")

    // Newlines and tabs survive.
    let multiline = "\u{1B}[32mline1\u{1B}[0m\nline2"
    T.expectEqual(AppLogger.stripANSI(multiline), "line1\nline2",
                  "newlines preserved while codes stripped")
}
