import Foundation
@testable import PorchKeepKit

// Tests for the plain value types: DoorbellEvent, EventSidecar, ArchivedEvent.

func runModelTests() {
    T.suite("DoorbellEvent")

    let motion = DoorbellEvent(type: .motion, serialNumber: "T8214", timestamp: Date(), isStart: true)
    T.expectEqual(motion.type, .motion, "type is motion")
    T.expectEqual(motion.serialNumber, "T8214", "serial preserved")
    T.expectTrue(motion.isStart, "isStart preserved")

    // Identifiable: each event gets a distinct id, so two otherwise-identical
    // events are not equal.
    let now = Date()
    let a = DoorbellEvent(type: .ring, serialNumber: "X", timestamp: now, isStart: true)
    let b = DoorbellEvent(type: .ring, serialNumber: "X", timestamp: now, isStart: true)
    T.expectFalse(a == b, "distinct events with same fields are not equal (id differs)")
    T.expectTrue(a == a, "an event equals itself")

    // Kind raw values — used to build filenames and JSON.
    T.expectEqual(DoorbellEvent.Kind.motion.rawValue, "motion", "motion raw value")
    T.expectEqual(DoorbellEvent.Kind.person.rawValue, "person", "person raw value")
    T.expectEqual(DoorbellEvent.Kind.ring.rawValue, "ring", "ring raw value")
    T.expectEqual(DoorbellEvent.Kind.stranger.rawValue, "stranger", "stranger raw value")

    runEventSidecarTests()
    runArchivedEventTests()
}

private func runEventSidecarTests() {
    T.suite("EventSidecar")

    // Whole-second date so the ISO-8601 encoder used by the Recorder
    // round-trips exactly.
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let sidecar = EventSidecar(
        type: .person,
        serialNumber: "T8214510244511E4",
        startedAt: started,
        durationSeconds: 12.5,
        fileSize: 2_345_678,
        videoCodec: "h264",
        audioCodec: nil,
        stem: "event_2023-11-14T22-13-20_person"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard let data = try? encoder.encode(sidecar),
          let decoded = try? decoder.decode(EventSidecar.self, from: data) else {
        T.expectTrue(false, "sidecar should encode and decode")
        return
    }

    T.expectEqual(decoded.type, .person, "type survives round-trip")
    T.expectEqual(decoded.serialNumber, sidecar.serialNumber, "serial survives round-trip")
    T.expectEqual(decoded.startedAt, started, "startedAt survives round-trip")
    T.expectEqual(decoded.durationSeconds, 12.5, "duration survives round-trip")
    T.expectEqual(decoded.fileSize, 2_345_678, "fileSize survives round-trip")
    T.expectEqual(decoded.videoCodec, "h264", "videoCodec survives round-trip")
    T.expectNil(decoded.audioCodec, "nil audioCodec survives round-trip")
    T.expectEqual(decoded.stem, sidecar.stem, "stem survives round-trip")

    // The JSON should be human-readable text containing the stem.
    if let json = String(data: data, encoding: .utf8) {
        T.expectTrue(json.contains("event_2023-11-14T22-13-20_person"), "JSON contains the stem")
    } else {
        T.expectTrue(false, "sidecar JSON should be UTF-8 text")
    }
}

private func runArchivedEventTests() {
    T.suite("ArchivedEvent")

    let started = Date(timeIntervalSince1970: 1_700_000_500)
    let sidecar = EventSidecar(
        type: .ring,
        serialNumber: "T8214",
        startedAt: started,
        durationSeconds: 8.0,
        fileSize: 1024,
        videoCodec: "h264",
        audioCodec: "aac",
        stem: "event_ring_1"
    )
    let base = URL(fileURLWithPath: "/tmp/clips")
    let event = ArchivedEvent(
        id: "event_ring_1",
        sidecar: sidecar,
        mp4URL: base.appendingPathComponent("event_ring_1.mp4"),
        thumbnailURL: base.appendingPathComponent("event_ring_1.jpg"),
        sidecarURL: base.appendingPathComponent("event_ring_1.json")
    )

    T.expectEqual(event.id, "event_ring_1", "id is the stem")
    T.expectEqual(event.type, .ring, "type proxies to sidecar")
    T.expectEqual(event.date, started, "date proxies to sidecar.startedAt")
    T.expectEqual(event.duration, 8.0, "duration proxies to sidecar")
    T.expectEqual(event.fileSize, 1024, "fileSize proxies to sidecar")
    T.expectTrue(event.mp4URL.lastPathComponent == "event_ring_1.mp4", "mp4 URL built correctly")
}
