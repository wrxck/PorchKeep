import Foundation

// A minimal in-repo test harness. The Command Line Tools on this machine ship
// neither a usable XCTest nor a resolvable Swift Testing overlay, so tests are
// plain functions that record results into this shared report.
//
// Usage in a test file:
//     func runThingTests() {
//         T.suite("Thing")
//         T.expectEqual(thing.value, 42, "value should be 42")
//     }

final class TestReport {
    static let shared = TestReport()

    private(set) var passed = 0
    private(set) var failed = 0
    private var currentSuite = "—"
    private var failures: [String] = []
    private var suitesSeen: [String] = []

    func suite(_ name: String) {
        currentSuite = name
        if !suitesSeen.contains(name) { suitesSeen.append(name) }
    }

    func expect(_ condition: Bool, _ message: String,
                file: StaticString = #fileID, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            failures.append("  ✗ [\(currentSuite)] \(message)  (\(file):\(line))")
        }
    }

    func expectEqual<V: Equatable>(_ actual: V, _ expected: V, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) {
        expect(actual == expected,
               "\(message) — expected \(expected), got \(actual)",
               file: file, line: line)
    }

    func expectNil(_ value: Any?, _ message: String,
                   file: StaticString = #fileID, line: UInt = #line) {
        expect(value == nil, "\(message) — expected nil, got \(String(describing: value))",
               file: file, line: line)
    }

    func expectNotNil(_ value: Any?, _ message: String,
                      file: StaticString = #fileID, line: UInt = #line) {
        expect(value != nil, "\(message) — expected a value, got nil", file: file, line: line)
    }

    func expectTrue(_ value: Bool, _ message: String,
                    file: StaticString = #fileID, line: UInt = #line) {
        expect(value, message, file: file, line: line)
    }

    func expectFalse(_ value: Bool, _ message: String,
                     file: StaticString = #fileID, line: UInt = #line) {
        expect(!value, message, file: file, line: line)
    }

    /// Prints the summary and returns true if everything passed.
    func summarize() -> Bool {
        print("")
        print("════════════════════════════════════════")
        if failures.isEmpty {
            print("  All \(passed) checks passed across \(suitesSeen.count) suites.")
        } else {
            print("  Failures:")
            for f in failures { print(f) }
            print("")
            print("  \(passed) passed, \(failed) failed.")
        }
        print("════════════════════════════════════════")
        return failed == 0
    }
}

/// Shorthand used throughout the test files.
let T = TestReport.shared

// MARK: - Temp-directory helpers

enum TestSupport {
    /// Creates a fresh unique temporary directory; caller should clean it up.
    static func makeTempDir(_ label: String = "porchkeep-test") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A UserDefaults backed by a unique throwaway suite.
    static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "porchkeep.tests.\(UUID().uuidString)")!
    }
}
