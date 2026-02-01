import Foundation

public enum VCPCode: UInt8, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case colorTemperature = 0x14
    case inputSource = 0x60
    case powerMode = 0xD6
    case capabilities = 0xF3
}

public struct DDCCapabilities: Sendable {
    public let supportedCodes: Set<VCPCode>
    public let modelName: String?
    public let protocolClass: String?
    public let supportsBrightness: Bool
    public let supportsContrast: Bool
    public let supportsColorTemperature: Bool
    public let supportsInputSource: Bool
    public let supportedColorPresets: [Int]
    public let maxBrightness: UInt16
    public let maxContrast: UInt16
    public let rawCapabilityString: String?

    public init(
        supportedCodes: Set<VCPCode>,
        modelName: String? = nil,
        protocolClass: String? = nil,
        supportsBrightness: Bool = false,
        supportsContrast: Bool = false,
        supportsColorTemperature: Bool = false,
        supportsInputSource: Bool = false,
        supportedColorPresets: [Int] = [],
        maxBrightness: UInt16 = 100,
        maxContrast: UInt16 = 100,
        rawCapabilityString: String? = nil
    ) {
        self.supportedCodes = supportedCodes
        self.modelName = modelName
        self.protocolClass = protocolClass
        self.supportsBrightness = supportsBrightness
        self.supportsContrast = supportsContrast
        self.supportsColorTemperature = supportsColorTemperature
        self.supportsInputSource = supportsInputSource
        self.supportedColorPresets = supportedColorPresets
        self.maxBrightness = maxBrightness
        self.maxContrast = maxContrast
        self.rawCapabilityString = rawCapabilityString
    }
}
