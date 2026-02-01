import Foundation
import IOKit

public struct EDIDInfo: Sendable {
    public let manufacturerID: String
    public let productCode: UInt16
    public let serialNumber: UInt32
    public let modelName: String?
    public let rawData: Data

    public init(
        manufacturerID: String,
        productCode: UInt16,
        serialNumber: UInt32,
        modelName: String? = nil,
        rawData: Data
    ) {
        self.manufacturerID = manufacturerID
        self.productCode = productCode
        self.serialNumber = serialNumber
        self.modelName = modelName
        self.rawData = rawData
    }
}

public enum EDIDError: Error, Sendable {
    case ioKitError(String)
    case invalidData(String)
    case displayNotFound
    case notExternalDisplay
}

public final class EDIDReader: @unchecked Sendable {

    public init() {}

    /// Read EDID from an IOKit display service
    public func readEDID(for displayID: UInt32) async throws -> EDIDInfo {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect")
        )
        guard service != 0 else {
            throw EDIDError.displayNotFound
        }

        defer {
            IOObjectRelease(service)
        }

        // Get EDID data from IOKit
        var edidData: Data?
        var iterator: io_iterator_t = 0

        let result = IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator)
        guard result == KERN_SUCCESS else {
            throw EDIDError.ioKitError("Failed to get child iterator: \(result)")
        }

        defer {
            IOObjectRelease(iterator)
        }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }

            // Try to get EDID property
            if let edidProperty = IORegistryEntryCreateCFProperty(
                child,
                "IODisplayEDID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                if let data = edidProperty.takeRetainedValue() as? Data {
                    edidData = data
                    break
                }
            }
        }

        guard let data = edidData, data.count >= 128 else {
            throw EDIDError.invalidData("EDID data missing or too short")
        }

        return try parseEDID(data)
    }

    /// Parse EDID binary data into EDIDInfo
    private func parseEDID(_ data: Data) throws -> EDIDInfo {
        guard data.count >= 128 else {
            throw EDIDError.invalidData("EDID must be at least 128 bytes")
        }

        // Verify EDID header (00 FF FF FF FF FF FF 00)
        let expectedHeader: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        let actualHeader = Array(data[0..<8])
        guard actualHeader == expectedHeader else {
            throw EDIDError.invalidData("Invalid EDID header")
        }

        // Extract manufacturer ID (bytes 8-9)
        let manufacturerBytes = UInt16(data[8]) << 8 | UInt16(data[9])
        let manufacturerID = decodeManufacturerID(manufacturerBytes)

        // Extract product code (bytes 10-11, little-endian)
        let productCode = UInt16(data[10]) | (UInt16(data[11]) << 8)

        // Extract serial number (bytes 12-15, little-endian)
        let serialNumber = UInt32(data[12])
            | (UInt32(data[13]) << 8)
            | (UInt32(data[14]) << 16)
            | (UInt32(data[15]) << 24)

        // Extract model name from descriptor blocks (bytes 54-125)
        let modelName = extractModelName(from: data)

        return EDIDInfo(
            manufacturerID: manufacturerID,
            productCode: productCode,
            serialNumber: serialNumber,
            modelName: modelName,
            rawData: data
        )
    }

    /// Decode 3-character manufacturer ID from compressed format
    /// Format: bits 14-10 = 1st char, bits 9-5 = 2nd char, bits 4-0 = 3rd char
    /// Each character is 'A' (1) to 'Z' (26)
    private func decodeManufacturerID(_ value: UInt16) -> String {
        let char1 = Character(UnicodeScalar(((value >> 10) & 0x1F) + 64)!)
        let char2 = Character(UnicodeScalar(((value >> 5) & 0x1F) + 64)!)
        let char3 = Character(UnicodeScalar((value & 0x1F) + 64)!)
        return String([char1, char2, char3])
    }

    /// Extract model name from EDID descriptor blocks
    /// Descriptor blocks are at offsets 54, 72, 90, 108 (18 bytes each)
    /// Descriptor type 0xFC indicates display name
    private func extractModelName(from data: Data) -> String? {
        let descriptorOffsets = [54, 72, 90, 108]

        for offset in descriptorOffsets {
            guard offset + 18 <= data.count else { continue }

            // Check if this is a display name descriptor (bytes 0-1 = 0, byte 3 = 0xFC)
            if data[offset] == 0 && data[offset + 1] == 0 && data[offset + 3] == 0xFC {
                // Display name is at bytes 5-17 (13 bytes), null-terminated or padded with 0x0A
                let nameBytes = data.subdata(in: (offset + 5)..<(offset + 18))
                let nameString = String(
                    bytes: nameBytes.prefix(while: { $0 != 0x0A && $0 != 0x00 }),
                    encoding: .ascii
                )
                return nameString?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Check if display is external (not built-in)
    public func isExternalDisplay(for displayID: UInt32) async -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect")
        )
        guard service != 0 else {
            return false
        }

        defer {
            IOObjectRelease(service)
        }

        // Check for "built-in" property
        if let builtInProperty = IORegistryEntryCreateCFProperty(
            service,
            "built-in" as CFString,
            kCFAllocatorDefault,
            0
        ) {
            let isBuiltIn = builtInProperty.takeRetainedValue() as? Bool ?? false
            return !isBuiltIn
        }

        // If no explicit built-in property, assume external
        return true
    }
}
