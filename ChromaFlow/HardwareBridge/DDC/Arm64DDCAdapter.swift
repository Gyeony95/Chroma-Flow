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
            do {
                try transport.write(service: framebufferService, address: 0x37, data: request)
                print("[DDC] Wrote VCP read request for code 0x\(String(code.rawValue, radix: 16))")
            } catch {
                print("[DDC] Failed to write I2C request: \(error)")
                throw error
            }

            // Wait for display to process (DDC/CI spec requirement)
            try await Task.sleep(nanoseconds: 40_000_000) // 40ms

            // Read response (12 bytes for VCP reply)
            let response: [UInt8]
            do {
                response = try transport.read(service: framebufferService, address: 0x37, length: 12)
                print("[DDC] Read I2C response: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            } catch {
                print("[DDC] Failed to read I2C response: \(error)")
                throw error
            }

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

    private static func getFramebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        print("[DDC] Starting IOFramebuffer service search for display \(displayID)")

        // First, get EDID info for the target display
        let targetEDID = EDIDParser.parseEDID(for: displayID)
        print("[DDC] Target display EDID: vendor=\(targetEDID?.manufacturer ?? "unknown"), product=\(targetEDID?.productCode ?? 0), serial=\(targetEDID?.serialNumber ?? "none")")

        // Find IOFramebuffer service by matching EDID properties
        let matching = IOServiceMatching("IOFramebuffer")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            print("[DDC] Failed to enumerate IOFramebuffer services")
            return nil
        }

        defer { IOObjectRelease(iterator) }

        var bestMatch: (service: io_service_t, score: Int) = (0, 0)

        // Iterate through all IOFramebuffer services
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            defer {
                if bestMatch.service != candidate && candidate != 0 {
                    IOObjectRelease(candidate)
                }
            }

            var matchScore = 0
            print("[DDC] Checking IOFramebuffer candidate...")

            // Method 1: Try IOFBDependentID first (fastest and most reliable for built-in displays)
            if let dependentIDProperty = IORegistryEntryCreateCFProperty(
                candidate,
                "IOFBDependentID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let dependentIDValue = dependentIDProperty.takeRetainedValue()

                if let candidateID = dependentIDValue as? UInt32 {
                    print("[DDC]   IOFBDependentID: \(candidateID)")
                    if candidateID == displayID {
                        print("[DDC] ✓ Exact match via IOFBDependentID for display \(displayID)")
                        if bestMatch.service != 0 { IOObjectRelease(bestMatch.service) }
                        return candidate
                    }
                }
            }

            // Method 2: EDID-based matching (most reliable for external displays)
            if let targetEDID = targetEDID {
                var candidateVendor: UInt16?
                var candidateProduct: UInt16?
                var candidateSerial: UInt32?

                // Try to read EDID data directly from the framebuffer
                if let edidData = IORegistryEntryCreateCFProperty(
                    candidate,
                    "IODisplayEDID" as CFString,
                    kCFAllocatorDefault,
                    0
                ) {
                    if let data = edidData.takeRetainedValue() as? Data, data.count >= 16 {
                        // Parse vendor and product from EDID bytes
                        let vendorBytes = UInt16(data[8]) << 8 | UInt16(data[9])
                        candidateVendor = vendorBytes
                        candidateProduct = UInt16(data[10]) | (UInt16(data[11]) << 8)
                        candidateSerial = UInt32(data[12]) | (UInt32(data[13]) << 8) |
                                         (UInt32(data[14]) << 16) | (UInt32(data[15]) << 24)

                        print("[DDC]   EDID: vendor=\(String(format: "0x%04X", candidateVendor ?? 0)), product=\(candidateProduct ?? 0), serial=\(candidateSerial ?? 0)")
                    }
                }

                // Also check IODisplayVendorID and IODisplayProductID properties
                if candidateVendor == nil {
                    if let vendorProp = IORegistryEntryCreateCFProperty(
                        candidate,
                        "IODisplayVendorID" as CFString,
                        kCFAllocatorDefault,
                        0
                    ) {
                        candidateVendor = vendorProp.takeRetainedValue() as? UInt16
                        print("[DDC]   IODisplayVendorID: \(String(format: "0x%04X", candidateVendor ?? 0))")
                    }
                }

                if candidateProduct == nil {
                    if let productProp = IORegistryEntryCreateCFProperty(
                        candidate,
                        "IODisplayProductID" as CFString,
                        kCFAllocatorDefault,
                        0
                    ) {
                        candidateProduct = productProp.takeRetainedValue() as? UInt16
                        print("[DDC]   IODisplayProductID: \(candidateProduct ?? 0)")
                    }
                }

                // Also check DisplayVendorID and DisplayProductID (alternative names)
                if candidateVendor == nil {
                    if let vendorProp = IORegistryEntryCreateCFProperty(
                        candidate,
                        "DisplayVendorID" as CFString,
                        kCFAllocatorDefault,
                        0
                    ) {
                        candidateVendor = vendorProp.takeRetainedValue() as? UInt16
                        print("[DDC]   DisplayVendorID: \(String(format: "0x%04X", candidateVendor ?? 0))")
                    }
                }

                if candidateProduct == nil {
                    if let productProp = IORegistryEntryCreateCFProperty(
                        candidate,
                        "DisplayProductID" as CFString,
                        kCFAllocatorDefault,
                        0
                    ) {
                        candidateProduct = productProp.takeRetainedValue() as? UInt16
                        print("[DDC]   DisplayProductID: \(candidateProduct ?? 0)")
                    }
                }

                // Calculate match score
                if let candidateVendor = candidateVendor,
                   candidateVendor == targetEDID.vendorID {
                    matchScore += 1
                    print("[DDC]   ✓ Vendor ID matches")

                    if let candidateProduct = candidateProduct,
                       candidateProduct == targetEDID.productCode {
                        matchScore += 2
                        print("[DDC]   ✓ Product ID matches")

                        if let targetSerial = targetEDID.serialNumber,
                           let candidateSerial = candidateSerial,
                           targetSerial == String(candidateSerial) {
                            matchScore += 3
                            print("[DDC]   ✓ Serial number matches")
                        }
                    }
                }

                // If we have a perfect match (vendor + product + serial), return immediately
                if matchScore >= 6 {
                    print("[DDC] ✓ Perfect EDID match found for display \(displayID)")
                    if bestMatch.service != 0 { IOObjectRelease(bestMatch.service) }
                    return candidate
                }
            }

            // Method 3: Check IODisplayPrefsKey (UUID-based matching)
            if let prefsKey = IORegistryEntryCreateCFProperty(
                candidate,
                "IODisplayPrefsKey" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                if let keyString = prefsKey.takeRetainedValue() as? String {
                    print("[DDC]   IODisplayPrefsKey: \(keyString)")
                    // The prefs key often contains display ID information
                    if keyString.contains("DisplayID-\(String(format: "%x", displayID))") {
                        matchScore += 4
                        print("[DDC]   ✓ Display ID found in IODisplayPrefsKey")
                    }
                }
            }

            // Update best match if this candidate has a higher score
            if matchScore > bestMatch.score {
                if bestMatch.service != 0 { IOObjectRelease(bestMatch.service) }
                bestMatch = (candidate, matchScore)
                print("[DDC]   New best match with score: \(matchScore)")
            }
        }

        // Return the best match if we found any
        if bestMatch.service != 0 && bestMatch.score > 0 {
            print("[DDC] ✓ Returning best match for display \(displayID) with score: \(bestMatch.score)")
            return bestMatch.service
        }

        // Fallback: If no EDID match found, try ALL framebuffers for external displays
        print("[DDC] EDID matching failed, trying all framebuffers as fallback...")

        var servicePort: io_service_t = 0
        var iter2: io_iterator_t = 0

        let matching2 = IOServiceMatching("IOFramebuffer")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching2, &iter2) == KERN_SUCCESS else {
            print("[DDC] ✗ Failed to enumerate IOFramebuffer services for fallback")
            return nil
        }

        defer { IOObjectRelease(iter2) }

        var candidateServices: [(service: io_service_t, isBuiltIn: Bool)] = []
        var totalFramebuffers = 0

        while true {
            servicePort = IOIteratorNext(iter2)
            if servicePort == 0 { break }

            totalFramebuffers += 1
            print("[DDC] Examining framebuffer #\(totalFramebuffers)")

            // Check if this is the built-in display framebuffer (skip it)
            var isBuiltIn = false
            var dependentDisplayID: UInt32?

            if let dependentID = IORegistryEntryCreateCFProperty(
                servicePort,
                "IOFBDependentID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let depID = dependentID.takeRetainedValue()
                if let id = depID as? UInt32 {
                    dependentDisplayID = id
                    isBuiltIn = CGDisplayIsBuiltin(id) != 0
                    print("[DDC]   - IOFBDependentID: \(id)")
                    print("[DDC]   - CGDisplayIsBuiltin(\(id)): \(isBuiltIn)")
                } else {
                    print("[DDC]   - IOFBDependentID exists but not UInt32")
                }
            } else {
                print("[DDC]   - No IOFBDependentID property")
            }

            if !isBuiltIn {
                candidateServices.append((servicePort, isBuiltIn))
                print("[DDC]   ✓ Added as external candidate #\(candidateServices.count)")
            } else {
                print("[DDC]   ✗ Skipped (built-in display)")
                IOObjectRelease(servicePort)
            }
        }

        print("[DDC] Total framebuffers found: \(totalFramebuffers), external candidates: \(candidateServices.count)")

        // Try the first external framebuffer
        if let candidate = candidateServices.first {
            print("[DDC] Using first external framebuffer as fallback for display \(displayID)")
            // Release all other candidates
            for (index, candidatePair) in candidateServices.enumerated() where index > 0 {
                IOObjectRelease(candidatePair.service)
            }
            return candidate.service
        } else {
            print("[DDC] No external framebuffer candidates found")
        }

        print("[DDC] ✗ No matching IOFramebuffer service found for display \(displayID)")
        return nil
    }

}
