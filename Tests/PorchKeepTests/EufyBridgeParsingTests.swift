import Foundation
@testable import PorchKeepKit

// Tests for EufyBridge's pure parsing helpers: codecName, parseStreamFrame and
// parseDevice. These are the bits that normalise the loosely-typed JSON the
// eufy-security-ws bridge emits, so they're worth pinning down exactly.

@MainActor
func runEufyBridgeParsingTests() {
    T.suite("EufyBridgeParsing")

    // Build one bridge instance to call the methods on. The constructors
    // chain: AppLogger -> KeychainStore -> SettingsStore -> EufyBridge.
    let logger = AppLogger()
    let keychain = KeychainStore()
    let settings = SettingsStore(defaults: TestSupport.isolatedDefaults())
    let bridge = EufyBridge(logger: logger, keychain: keychain, settings: settings)

    runCodecNameTests(bridge)
    runParseStreamFrameTests(bridge)
    runParseDeviceTests(bridge)
}

// MARK: - codecName

@MainActor
private func runCodecNameTests(_ bridge: EufyBridge) {
    T.suite("EufyBridge.codecName")

    // Numeric video codecs: 0 -> h264, 1 -> h265.
    T.expectEqual(bridge.codecName(["videoCodec": 0], kind: .video), "h264",
                  "videoCodec 0 maps to h264")
    T.expectEqual(bridge.codecName(["videoCodec": 1], kind: .video), "h265",
                  "videoCodec 1 maps to h265")

    // A string codec is normalised to lower case.
    T.expectEqual(bridge.codecName(["videoCodec": "H264"], kind: .video), "h264",
                  "string videoCodec is lowercased")
    T.expectEqual(bridge.codecName(["videoCodec": "H265"], kind: .video), "h265",
                  "string H265 is lowercased")

    // Audio codec: any numeric value resolves to aac.
    T.expectEqual(bridge.codecName(["audioCodec": 0], kind: .audio), "aac",
                  "numeric audioCodec maps to aac")

    // nil metadata yields nil.
    T.expectNil(bridge.codecName(nil, kind: .video),
                "nil metadata yields nil codec")

    // Metadata present but missing the relevant key yields nil.
    T.expectNil(bridge.codecName(["somethingElse": 7], kind: .video),
                "metadata without videoCodec yields nil")
    T.expectNil(bridge.codecName(["videoCodec": 0], kind: .audio),
                "video-only metadata yields nil for audio kind")
}

// MARK: - parseStreamFrame

@MainActor
private func runParseStreamFrameTests(_ bridge: EufyBridge) {
    T.suite("EufyBridge.parseStreamFrame")

    let knownBytes = Data([1, 2, 3, 4])

    // 1. buffer as a base64 string.
    let b64Event: [String: Any] = [
        "metadata": ["videoCodec": 0],
        "buffer": knownBytes.base64EncodedString()
    ]
    if let frame = bridge.parseStreamFrame(b64Event, kind: .video) {
        T.expectEqual(frame.data, knownBytes, "base64-string buffer decodes to the original bytes")
        T.expectEqual(frame.codec, "h264", "codec populated from metadata for base64 buffer")
    } else {
        T.expectTrue(false, "base64-string buffer should parse into a StreamFrame")
    }

    // 2. buffer as a JSON Buffer object: {type: Buffer, data: [Int]}.
    let bufferObjEvent: [String: Any] = [
        "metadata": ["videoCodec": 1],
        "buffer": ["type": "Buffer", "data": [1, 2, 3, 4]]
    ]
    if let frame = bridge.parseStreamFrame(bufferObjEvent, kind: .video) {
        T.expectEqual(frame.data, knownBytes, "JSON Buffer object decodes to the original bytes")
        T.expectEqual(frame.codec, "h265", "codec populated from metadata for Buffer object")
    } else {
        T.expectTrue(false, "JSON Buffer object should parse into a StreamFrame")
    }

    // 3. buffer as an object carrying a base64 string under "data".
    let dataB64Event: [String: Any] = [
        "metadata": ["audioCodec": 0],
        "buffer": ["data": knownBytes.base64EncodedString()]
    ]
    if let frame = bridge.parseStreamFrame(dataB64Event, kind: .audio) {
        T.expectEqual(frame.data, knownBytes, "object with base64 data field decodes correctly")
        T.expectEqual(frame.codec, "aac", "codec populated from metadata for audio frame")
    } else {
        T.expectTrue(false, "object with base64 data field should parse into a StreamFrame")
    }

    // 4. buffer as a plain [Int] array.
    let intArrayEvent: [String: Any] = [
        "buffer": [5, 6, 7]
    ]
    if let frame = bridge.parseStreamFrame(intArrayEvent, kind: .video) {
        T.expectEqual(frame.data, Data([5, 6, 7]), "plain [Int] array decodes to Data")
        T.expectNil(frame.codec, "no metadata yields nil codec")
    } else {
        T.expectTrue(false, "plain [Int] array buffer should parse into a StreamFrame")
    }

    // 5. event with no buffer key returns nil.
    let noBufferEvent: [String: Any] = ["metadata": ["videoCodec": 0]]
    T.expectNil(bridge.parseStreamFrame(noBufferEvent, kind: .video),
                "event with no buffer key yields nil")

    // 6. the returned frame's kind matches the requested kind.
    if let videoFrame = bridge.parseStreamFrame(b64Event, kind: .video) {
        T.expectTrue(videoFrame.kind == .video, "frame parsed with .video kind reports .video")
    } else {
        T.expectTrue(false, "video kind frame should parse")
    }
    if let audioFrame = bridge.parseStreamFrame(b64Event, kind: .audio) {
        T.expectTrue(audioFrame.kind == .audio, "frame parsed with .audio kind reports .audio")
    } else {
        T.expectTrue(false, "audio kind frame should parse")
    }
}

// MARK: - parseDevice

@MainActor
private func runParseDeviceTests(_ bridge: EufyBridge) {
    T.suite("EufyBridge.parseDevice")

    // Flat dict with serial, name and model at the top level.
    let flat: [String: Any] = [
        "serialNumber": "T8214",
        "name": "Front Door",
        "model": "T8214"
    ]
    if let dev = bridge.parseDevice(flat) {
        T.expectEqual(dev.serialNumber, "T8214", "flat dict serial parsed")
        T.expectEqual(dev.name, "Front Door", "flat dict name parsed")
        T.expectEqual(dev.model, "T8214", "flat dict model parsed")
    } else {
        T.expectTrue(false, "flat device dict should parse")
    }

    // Nested dict: fields live under a "properties" sub-object.
    let nested: [String: Any] = [
        "properties": ["serialNumber": "T8023", "name": "Hub"]
    ]
    if let dev = bridge.parseDevice(nested) {
        T.expectEqual(dev.serialNumber, "T8023", "nested dict serial parsed from properties")
        T.expectEqual(dev.name, "Hub", "nested dict name parsed from properties")
        T.expectNil(dev.model, "nested dict with no model yields nil model")
    } else {
        T.expectTrue(false, "nested device dict should parse")
    }

    // No serial number anywhere -> nil.
    T.expectNil(bridge.parseDevice(["name": "Nameless"]),
                "dict with no serial number yields nil")

    // Empty-string serial -> nil.
    T.expectNil(bridge.parseDevice(["serialNumber": "", "name": "Empty"]),
                "dict with empty-string serial yields nil")

    // Serial present but no name -> name falls back to the serial number.
    if let dev = bridge.parseDevice(["serialNumber": "T9999"]) {
        T.expectEqual(dev.name, "T9999", "missing name falls back to the serial number")
        T.expectEqual(dev.serialNumber, "T9999", "serial parsed when name absent")
    } else {
        T.expectTrue(false, "device with serial but no name should still parse")
    }
}
