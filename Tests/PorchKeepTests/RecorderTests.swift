import Foundation
@testable import PorchKeepKit

// Tests for Recorder's pure helper: filenameStem(for:). The stem becomes the
// on-disk basename for .mp4/.jpg/.json clip files, so it must be filesystem-safe
// and unique per event.

@MainActor
func runRecorderTests() {
    T.suite("Recorder")

    // Construct a Recorder by chaining the service constructors.
    let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
    let logger = AppLogger()
    let icloud = ICloudCoordinator(logger: logger)
    let archive = ArchiveStore(settings: settings, icloud: icloud, logger: logger)
    let backup = BackupCoordinator(settings: settings, logger: logger)
    let recorder = Recorder(logger: logger, archive: archive, settings: settings, backup: backup)

    runFilenameStemTests(recorder)
}

@MainActor
private func runFilenameStemTests(_ recorder: Recorder) {
    T.suite("Recorder.filenameStem")

    // A motion event: stem begins with "event_" and ends with "_motion".
    let motion = DoorbellEvent(type: .motion, serialNumber: "T8214",
                               timestamp: Date(), isStart: true)
    let motionStem = recorder.filenameStem(for: motion)
    T.expectTrue(motionStem.hasPrefix("event_"), "motion stem starts with event_")
    T.expectTrue(motionStem.hasSuffix("_motion"), "motion stem ends with _motion")

    // A ring event ends with "_ring".
    let ring = DoorbellEvent(type: .ring, serialNumber: "T8214",
                             timestamp: Date(), isStart: true)
    let ringStem = recorder.filenameStem(for: ring)
    T.expectTrue(ringStem.hasPrefix("event_"), "ring stem starts with event_")
    T.expectTrue(ringStem.hasSuffix("_ring"), "ring stem ends with _ring")

    // No colons anywhere — they are illegal-ish in filenames and the Recorder
    // replaces them with hyphens.
    T.expectFalse(motionStem.contains(":"), "stem contains no colon characters")
    T.expectFalse(ringStem.contains(":"), "ring stem contains no colon characters")

    // No dots in the timestamp portion: drop the leading "event_" prefix and
    // the trailing "_<kind>" suffix, then assert the timestamp has no ".".
    let tsPortion = String(motionStem.dropFirst("event_".count).dropLast("_motion".count))
    T.expectFalse(tsPortion.contains("."), "timestamp portion of the stem has no dot characters")
    T.expectFalse(tsPortion.isEmpty, "timestamp portion is non-empty")

    // Two events at different timestamps produce different stems.
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let earlier = DoorbellEvent(type: .motion, serialNumber: "T8214",
                                timestamp: base, isStart: true)
    let later = DoorbellEvent(type: .motion, serialNumber: "T8214",
                              timestamp: base.addingTimeInterval(5), isStart: true)
    let earlierStem = recorder.filenameStem(for: earlier)
    let laterStem = recorder.filenameStem(for: later)
    T.expectFalse(earlierStem == laterStem,
                  "events 5s apart produce distinct filename stems")

    // The same event timestamp produces a stable, reproducible stem.
    let sameAgain = DoorbellEvent(type: .motion, serialNumber: "T8214",
                                  timestamp: base, isStart: true)
    T.expectEqual(recorder.filenameStem(for: sameAgain), earlierStem,
                  "the same timestamp and kind produce the same stem")
}
