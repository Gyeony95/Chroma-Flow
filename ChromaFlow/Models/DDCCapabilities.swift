import Foundation

struct DDCCapabilities: Codable, Sendable {
    let supportsBrightness: Bool
    let supportsContrast: Bool
    let supportsColorTemperature: Bool
    let supportsInputSource: Bool
    let supportedColorPresets: [Int]
    let maxBrightness: UInt16
    let maxContrast: UInt16
    let rawCapabilityString: String?
}
