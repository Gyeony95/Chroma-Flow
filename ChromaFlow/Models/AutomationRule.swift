import Foundation
import CoreGraphics

struct AutomationRule: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [Condition]
    var actions: [AutomationAction]
    var priority: Int

    enum Condition: Codable, Sendable {
        case appForeground(bundleID: String)
        case timeRange(start: DateComponents, end: DateComponents)
        case solarEvent(SolarTrigger)
        case ambientLight(below: Double)
        case displayConnected(serialNumber: String)
    }

    enum SolarTrigger: String, Codable, Sendable {
        case sunrise
        case sunset
        case goldenHour
    }
}
