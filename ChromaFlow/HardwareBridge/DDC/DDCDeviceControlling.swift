import Foundation
import CoreGraphics
import DDCKit

protocol DDCDeviceControlling: Sendable {
    var capabilities: DDCCapabilities { get async }
    func readVCP(_ code: VCPCode) async throws -> (current: UInt16, max: UInt16)
    func writeVCP(_ code: VCPCode, value: UInt16) async throws
    func setBrightness(_ value: Double) async throws
    func setContrast(_ value: Double) async throws
    func setColorTemperature(_ kelvin: Int) async throws
}
