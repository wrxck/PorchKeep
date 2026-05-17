import Foundation

// PorchKeep test runner. Run with:  swift run PorchKeepTests
//
// Each test file exposes one `run<Area>Tests()` function; they are all invoked
// here. Process exits non-zero if any check fails (CI-friendly).

@MainActor
func runEverything() {
    runModelTests()
    runAppLoggerTests()
    runSettingsStoreTests()
    runBackupCoordinatorTests()
    runEufyBridgeParsingTests()
    runRecorderTests()
    runArchiveStoreTests()
}

print("Running PorchKeep test suite…")
MainActor.assumeIsolated {
    runEverything()
}
let ok = TestReport.shared.summarize()
exit(ok ? 0 : 1)
