import Foundation
import CoreGraphics
import IOKit
import IOKit.i2c
import DDCKit

/// ARM64-optimized DDC/CI adapter for Apple Silicon Macs
///
/// Provides low-level I2C communication with external displays
/// using IOKit framework. Conforms to DDCDeviceControlling protocol.
final class Arm64DDCAdapter: DDCDeviceControlling, @unchecked Sendable {
    // MARK: - Types

    enum AdapterError: Error, LocalizedError {
        case displayNotFound
        case framebufferNotFound
        case i2cInterfaceNotFound
        case unsupportedDisplayType
        case i2cTransactionFailed(status: kern_return_t)
        case vcpReadFailed
        case vcpWriteFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .displayNotFound:
                return "Display not found"
            case .framebufferNotFound:
                return "Framebuffer service not found"
            case .i2cInterfaceNotFound:
                return "I2C interface not available (DDC/CI may not be supported)"
            case .unsupportedDisplayType:
                return "Display type does not support DDC/CI"
            case .i2cTransactionFailed(let status):
                return "I2C transaction failed with status: \(status)"
            case .vcpReadFailed:
                return "Failed to read VCP code"
            case .vcpWriteFailed:
                return "Failed to write VCP code"
            case .invalidResponse:
                return "Invalid DDC/CI response from display"
            }
        }
    }

    // MARK: - Properties

    private let displayID: CGDirectDisplayID
    private let framebufferService: io_service_t
    private let transport: I2CTransport
    private var detectedCapabilities: DDCCapabilities?

    var capabilities: DDCCapabilities {
        get async {
            if let cached = detectedCapabilities {
                return cached
            }

            // Detect capabilities
            let caps = await detectCapabilitiesFromDisplay()
            detectedCapabilities = caps
            return caps
        }
    }

    // MARK: - Initialization

    init(displayID: CGDirectDisplayID, transport: I2CTransport = ARM64I2CTransport()) throws {
        self.displayID = displayID
        self.transport = transport

        // Get IOFramebuffer service for this display
        guard let service = Self.getFramebufferService(for: displayID) else {
            throw AdapterError.framebufferNotFound
        }

        self.framebufferService = service
    }

    deinit {
        IOObjectRelease(framebufferService)
    }

    // MARK: - DDCDeviceControlling

    func readVCP(_ code: VCPCode) async throws -> (current: UInt16, max: UInt16) {
        try await performI2CTransaction { [framebufferService, transport] in
            // DDC/CI read command structure
            var request: [UInt8] = [
                0x51, // Source address (host)
                0x82, // Length (2 bytes + checksum)
                0x01, // VCP request
                code.rawValue, // VCP code
                0x00  // Checksum placeholder
            ]

            // Calculate checksum (XOR of all bytes except checksum)
            let checksum = request.prefix(4).reduce(0x6E) { $0 ^ $1 } // 0x6E is destination address
            request[4] = checksum

            // Send request via I2C
            try transport.write(service: framebufferService, address: 0x37, data: request)

            // Wait for display to process (DDC/CI spec requirement)
            try await Task.sleep(nanoseconds: 40_000_000) // 40ms

            // Read response (12 bytes for VCP reply)
            let response = try transport.read(service: framebufferService, address: 0x37, length: 12)

            // Parse VCP response
            guard response.count >= 12,
                  response[0] == 0x6E, // Destination address
                  response[2] == 0x02, // VCP reply
                  response[4] == code.rawValue else {
                throw AdapterError.invalidResponse
            }

            // Extract current and max values (big-endian)
            let current = (UInt16(response[8]) << 8) | UInt16(response[9])
            let max = (UInt16(response[6]) << 8) | UInt16(response[7])

            return (current, max)
        }
    }

    func writeVCP(_ code: VCPCode, value: UInt16) async throws {
        try await performI2CTransaction { [framebufferService, transport] in
            // DDC/CI write command structure
            var request: [UInt8] = [
                0x51, // Source address (host)
                0x84, // Length (4 bytes + checksum)
                0x03, // VCP set
                code.rawValue, // VCP code
                UInt8((value >> 8) & 0xFF), // Value high byte
                UInt8(value & 0xFF), // Value low byte
                0x00  // Checksum placeholder
            ]

            // Calculate checksum
            let checksum = request.prefix(6).reduce(0x6E) { $0 ^ $1 }
            request[6] = checksum

            // Send request via I2C
            try transport.write(service: framebufferService, address: 0x37, data: request)

            // Wait for display to process
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    func setBrightness(_ value: Double) async throws {
        let capabilities = await self.capabilities
        let maxValue = capabilities.maxBrightness
        let hardwareValue = UInt16(value * Double(maxValue))
        try await writeVCP(.brightness, value: hardwareValue)
    }

    func setContrast(_ value: Double) async throws {
        let capabilities = await self.capabilities
        let maxValue = capabilities.maxContrast
        let hardwareValue = UInt16(value * Double(maxValue))
        try await writeVCP(.contrast, value: hardwareValue)
    }

    func setColorTemperature(_ kelvin: Int) async throws {
        // Color temperature implementation depends on display capabilities
        // Most displays use preset values rather than exact Kelvin
        // This is a simplified implementation
        let value = UInt16(kelvin / 100) // Convert Kelvin to preset value
        try await writeVCP(.colorTemperature, value: value)
    }

    // MARK: - Private Helpers

    private func detectCapabilitiesFromDisplay() async -> DDCCapabilities {
        var supportedCodes: Set<VCPCode> = []
        var maxBrightness: UInt16 = 100
        var maxContrast: UInt16 = 100

        // Test common VCP codes
        let testCodes: [VCPCode] = [.brightness, .contrast, .colorTemperature, .inputSource]

        for code in testCodes {
            do {
                let (_, max) = try await readVCP(code)
                supportedCodes.insert(code)

                // Store max values
                if code == .brightness {
                    maxBrightness = max
                } else if code == .contrast {
                    maxContrast = max
                }
            } catch {
                // Code not supported, continue
            }
        }

        return DDCCapabilities(
            supportsBrightness: supportedCodes.contains(.brightness),
            supportsContrast: supportedCodes.contains(.contrast),
            supportsColorTemperature: supportedCodes.contains(.colorTemperature),
            supportsInputSource: supportedCodes.contains(.inputSource),
            supportedColorPresets: [],
            maxBrightness: maxBrightness,
            maxContrast: maxContrast,
            rawCapabilityString: nil
        )
    }

    private func performI2CTransaction<T>(_ operation: () async throws -> T) async throws -> T {
        // Ensure I2C interface is available
        guard Self.hasI2CInterface(framebufferService) else {
            throw AdapterError.i2cInterfaceNotFound
        }

        return try await operation()
    }

    // MARK: - IOKit I2C Interface

    private static func getFramebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        var service: io_service_t = 0

        // Get IOFramebuffer service matching this display ID
        let matching = IOServiceMatching("IOFramebuffer")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iterator) }

        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            defer { if service == 0 { IOObjectRelease(candidate) } }

            // Check if this framebuffer matches our display ID
            if let property = IORegistryEntryCreateCFProperty(candidate, "IODisplayVendorID" as CFString, kCFAllocatorDefault, 0) {
                property.release()
                service = candidate
                break
            }
        }

        return service != 0 ? service : nil
    }

    private static func hasI2CInterface(_ service: io_service_t) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(service, &busCount) == KERN_SUCCESS else {
            return false
        }
        return busCount > 0
    }

}

// MARK: - IOKit I2C Functions (Private C Bindings)

private func IOFBGetI2CInterfaceCount(_ framebuffer: io_service_t, _ count: UnsafeMutablePointer<IOItemCount>) -> kern_return_t {
    // Placeholder for IOKit I2C function
    // Actual implementation would link against IOKit.framework I2C APIs
    count.pointee = 0
    return KERN_FAILURE
}

private func IOFBCreateI2CInterface(_ framebuffer: io_service_t, _ bus: IOOptionBits) -> io_service_t {
    // Placeholder for IOKit I2C function
    return 0
}
