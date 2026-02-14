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

        // Get DCPAVServiceProxy service for this display (Apple Silicon)
        guard let service = Self.getDisplayService(for: displayID) else {
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
            // DDC/CI read request - buffer does NOT include source address (0x51)
            // IOAVService sends 0x51 as dataAddress automatically
            var request: [UInt8] = [
                0x82, // Length (2 bytes) | 0x80
                0x01, // VCP request
                code.rawValue, // VCP code
                0x00  // Checksum placeholder
            ]

            // Checksum = XOR of destination (0x6E) ^ source (0x51) ^ all data bytes
            request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]

            // Send request via I2C (address 0x37, dataAddress 0x51 handled by transport)
            do {
                try transport.write(service: framebufferService, address: 0x37, data: request)
                print("[DDC] Wrote VCP read request for code 0x\(String(code.rawValue, radix: 16))")
            } catch {
                print("[DDC] Failed to write I2C request: \(error)")
                throw error
            }

            // Wait for display to process (DDC/CI spec requirement)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // Read 11-byte response
            let response: [UInt8]
            do {
                response = try transport.read(service: framebufferService, address: 0x37, length: 11)
                print("[DDC] Read I2C response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            } catch {
                print("[DDC] Failed to read I2C response: \(error)")
                throw error
            }

            // Parse VCP response
            // Response format: [0x6E, length, 0x02, result, vcp_code, type, max_hi, max_lo, cur_hi, cur_lo, checksum]
            guard response.count >= 11,
                  response[0] == 0x6E,
                  response[2] == 0x02,
                  response[4] == code.rawValue else {
                throw AdapterError.invalidResponse
            }

            // Extract current and max values (big-endian)
            let max = (UInt16(response[6]) << 8) | UInt16(response[7])
            let current = (UInt16(response[8]) << 8) | UInt16(response[9])

            return (current, max)
        }
    }

    func writeVCP(_ code: VCPCode, value: UInt16) async throws {
        try await performI2CTransaction { [framebufferService, transport] in
            // DDC/CI write command - buffer does NOT include source address (0x51)
            // IOAVService sends 0x51 as dataAddress automatically
            var request: [UInt8] = [
                0x84, // Length (4 bytes) | 0x80
                0x03, // VCP set
                code.rawValue, // VCP code
                UInt8((value >> 8) & 0xFF), // Value high byte
                UInt8(value & 0xFF), // Value low byte
                0x00  // Checksum placeholder
            ]

            // Checksum = XOR of destination (0x6E) ^ source (0x51) ^ all data bytes
            request[5] = request.prefix(5).reduce(0x6E ^ 0x51) { $0 ^ $1 }

            do {
                try transport.write(service: framebufferService, address: 0x37, data: request)
                print("[DDC] Wrote VCP write request for code 0x\(String(code.rawValue, radix: 16)), value: \(value)")
            } catch {
                print("[DDC] Failed to write I2C request: \(error)")
                throw error
            }

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
        try await writeVCP(.colorPresetSelect, value: value)
    }

    // MARK: - Private Helpers

    private func detectCapabilitiesFromDisplay() async -> DDCCapabilities {
        var supportedCodes: Set<VCPCode> = []
        var maxBrightness: UInt16 = 100
        var maxContrast: UInt16 = 100

        // Test common VCP codes
        let testCodes: [VCPCode] = [.brightness, .contrast, .colorPresetSelect, .inputSource]

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
            supportsColorTemperature: supportedCodes.contains(.colorPresetSelect),
            supportsInputSource: supportedCodes.contains(.inputSource),
            supportedColorPresets: [],
            maxBrightness: maxBrightness,
            maxContrast: maxContrast,
            rawCapabilityString: nil
        )
    }

    private func performI2CTransaction<T>(_ operation: () async throws -> T) async throws -> T {
        // Validate that transport is available (ARM64I2CTransport will handle IOKit validation)
        if let arm64Transport = transport as? ARM64I2CTransport {
            guard arm64Transport.isAvailable else {
                print("[DDC] Transport unavailable for display \(displayID)")
                throw AdapterError.i2cInterfaceNotFound
            }
        }

        do {
            return try await operation()
        } catch {
            print("[DDC] I2C transaction failed for display \(displayID): \(error)")
            throw error
        }
    }

    // MARK: - IOKit I2C Interface

    /// Find the DCPAVServiceProxy io_service_t for a given display ID.
    ///
    /// On Apple Silicon, IOFramebuffer does not exist. Instead, we enumerate
    /// `DCPAVServiceProxy` services (one per display output) and match them
    /// to the target CGDirectDisplayID by reading the EDID over I2C from
    /// address 0x50 and comparing vendor/product IDs.
    private static func getDisplayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        print("[DDC] Starting DCPAVServiceProxy search for display \(displayID)")

        // Get expected vendor/product from CoreGraphics
        let expectedVendor = CGDisplayVendorNumber(displayID)
        let expectedProduct = CGDisplayModelNumber(displayID)
        print("[DDC] Expected vendor=0x\(String(format: "%X", expectedVendor)), product=\(expectedProduct)")

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else {
            print("[DDC] Failed to enumerate DCPAVServiceProxy services")
            return nil
        }
        defer { IOObjectRelease(iter) }

        // Collect external services
        var externalServices: [(service: io_service_t, vendor: UInt32, product: UInt32)] = []

        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }

            // Only consider external displays
            var loc = "?"
            if let p = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0) {
                if let s = p.takeRetainedValue() as? String { loc = s }
            }
            guard loc == "External" else {
                IOObjectRelease(service)
                continue
            }

            print("[DDC] Found external DCPAVServiceProxy service")

            // Read EDID via I2C to identify the display
            if let avServiceRef = Self.createIOAVService(for: service) {
                // Read EDID from I2C address 0x50
                var offset: [UInt8] = [0x00]
                var edid = [UInt8](repeating: 0, count: 128)

                // Get IOAVService symbols for direct I2C EDID read
                let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
                if let handle = dlopen(frameworkPath, RTLD_LAZY),
                   let writeSym = dlsym(handle, "IOAVServiceWriteI2C"),
                   let readSym = dlsym(handle, "IOAVServiceReadI2C") {

                    typealias WF = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> Int32
                    typealias RF = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> Int32

                    let writeFn = unsafeBitCast(writeSym, to: WF.self)
                    let readFn = unsafeBitCast(readSym, to: RF.self)

                    let writeResult = writeFn(avServiceRef, 0x50, 0x00, &offset, 1)
                    if writeResult == 0 {
                        usleep(20000) // 20ms
                        let readResult = readFn(avServiceRef, 0x50, 0x00, &edid, 128)
                        if readResult == 0 {
                            let edidVendor = UInt32(UInt16(edid[8]) << 8 | UInt16(edid[9]))
                            let edidProduct = UInt32(UInt16(edid[10]) | (UInt16(edid[11]) << 8))
                            print("[DDC] Service EDID: vendor=0x\(String(format: "%X", edidVendor)), product=\(edidProduct)")

                            externalServices.append((service, edidVendor, edidProduct))

                            // Exact match - return immediately
                            if edidVendor == expectedVendor && edidProduct == expectedProduct {
                                print("[DDC] Exact EDID match for display \(displayID)")
                                // Release non-matching services
                                for other in externalServices where other.service != service {
                                    IOObjectRelease(other.service)
                                }
                                return service
                            }
                            continue // Don't release - stored in externalServices
                        }
                    }
                }
            }

            // If EDID read failed, still keep this as a candidate
            externalServices.append((service, 0, 0))
        }

        // No exact match found - return first unmatched external service
        if let first = externalServices.first {
            print("[DDC] No exact match, using first external service for display \(displayID)")
            for (idx, other) in externalServices.enumerated() where idx > 0 {
                IOObjectRelease(other.service)
            }
            return first.service
        }

        print("[DDC] No DCPAVServiceProxy found for display \(displayID)")
        return nil
    }

    /// Create an IOAVService reference from an io_service_t handle (for EDID reading).
    private static func createIOAVService(for service: io_service_t) -> UnsafeMutableRawPointer? {
        let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let sym = dlsym(handle, "IOAVServiceCreateWithService") else { return nil }

        typealias CF = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
        let createFn = unsafeBitCast(sym, to: CF.self)
        return createFn(nil, service)
    }

}
