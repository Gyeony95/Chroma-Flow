import Foundation
import CoreGraphics

struct DisplayDevice: Identifiable, Codable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let manufacturer: String
    let model: String
    let serialNumber: String?
    let connectionType: ConnectionType
    let isBuiltIn: Bool
    let maxBrightness: Double?
    let ddcCapabilities: DDCCapabilities?

    enum ConnectionType: String, Codable, Sendable {
        case builtIn
        case hdmi
        case displayPort
        case usbC
        case thunderbolt
        case unknown
    }
}
