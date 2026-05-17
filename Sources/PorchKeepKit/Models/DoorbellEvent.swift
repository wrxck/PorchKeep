import Foundation

struct DoorbellEvent: Identifiable, Equatable {
    enum Kind: String, Codable {
        case motion
        case person
        case ring
        case stranger
        case stateChange
    }

    let id = UUID()
    let type: Kind
    let serialNumber: String
    let timestamp: Date
    let isStart: Bool  // motion/ring fires with state=true (start) and state=false (end)

    static func == (lhs: DoorbellEvent, rhs: DoorbellEvent) -> Bool {
        lhs.id == rhs.id
    }
}
