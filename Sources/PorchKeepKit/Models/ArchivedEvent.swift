import Foundation

struct EventSidecar: Codable {
    let type: DoorbellEvent.Kind
    let serialNumber: String
    let startedAt: Date
    let durationSeconds: Double
    let fileSize: Int64
    let videoCodec: String?
    let audioCodec: String?
    let stem: String  // filename stem shared by .mp4 / .jpg / .json
}

struct ArchivedEvent: Identifiable {
    let id: String  // stem
    let sidecar: EventSidecar
    let mp4URL: URL
    let thumbnailURL: URL
    let sidecarURL: URL

    var type: DoorbellEvent.Kind { sidecar.type }
    var date: Date { sidecar.startedAt }
    var duration: TimeInterval { sidecar.durationSeconds }
    var fileSize: Int64 { sidecar.fileSize }
}
