import Foundation
import CoreGraphics

enum AutomationAction: Codable, Sendable {
    case switchProfile(profileID: UUID, displayID: CGDirectDisplayID)
    case setBrightness(value: Double, displayID: CGDirectDisplayID)
    case setContrast(value: Double, displayID: CGDirectDisplayID)
    case setColorTemperature(kelvin: Int, displayID: CGDirectDisplayID)
}
