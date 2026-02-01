import Foundation
import IOKit
import CoreGraphics

struct EDIDParser {

    /// Parsed EDID information
    struct EDIDInfo {
        let manufacturer: String
        let model: String
        let serialNumber: String?
        let productCode: UInt16
        let vendorID: UInt16
    }

    /// Parse EDID data for a given display ID
    static func parseEDID(for displayID: CGDirectDisplayID) -> EDIDInfo? {
        guard let edidData = getEDIDData(for: displayID) else {
            return fallbackEDIDInfo(for: displayID)
        }

        return parseEDIDBytes(edidData)
    }

    // MARK: - Private Methods

    /// Get raw EDID data from IOKit
    private static func getEDIDData(for displayID: CGDirectDisplayID) -> Data? {
        var servicePort: io_service_t = 0
        var iter: io_iterator_t = 0

        // Get IODisplayConnect service for this display
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iter) }

        // Iterate through matching services
        while true {
            servicePort = IOIteratorNext(iter)
            if servicePort == 0 { break }

            defer { IOObjectRelease(servicePort) }

            // Check if this service belongs to our display
            var displayIDProperty: Unmanaged<CFTypeRef>?
            displayIDProperty = IORegistryEntryCreateCFProperty(
                servicePort,
                "IODisplayPrefsKey" as CFString,
                kCFAllocatorDefault,
                0
            )

            // Get EDID data
            if let edidProperty = IORegistryEntryCreateCFProperty(
                servicePort,
                "IODisplayEDID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let edid = edidProperty.takeRetainedValue()
                if let data = edid as? Data {
                    displayIDProperty?.release()
                    return data
                }
            }

            displayIDProperty?.release()
        }

        return nil
    }

    /// Parse EDID byte array
    private static func parseEDIDBytes(_ data: Data) -> EDIDInfo? {
        guard data.count >= 128 else { return nil }

        // Validate EDID header (00 FF FF FF FF FF FF 00)
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        let dataHeader = Array(data.prefix(8))
        guard dataHeader == header else { return nil }

        // Parse vendor ID (bytes 8-9)
        let vendorBytes = UInt16(data[8]) << 8 | UInt16(data[9])
        let vendorID = vendorBytes

        // Decode 3-letter manufacturer ID (compressed ASCII)
        let char1 = Character(UnicodeScalar(((vendorBytes >> 10) & 0x1F) + 64)!)
        let char2 = Character(UnicodeScalar(((vendorBytes >> 5) & 0x1F) + 64)!)
        let char3 = Character(UnicodeScalar((vendorBytes & 0x1F) + 64)!)
        let manufacturer = String([char1, char2, char3])

        // Parse product code (bytes 10-11, little-endian)
        let productCode = UInt16(data[10]) | (UInt16(data[11]) << 8)

        // Parse serial number (bytes 12-15, little-endian)
        let serialValue = UInt32(data[12]) |
                         (UInt32(data[13]) << 8) |
                         (UInt32(data[14]) << 16) |
                         (UInt32(data[15]) << 24)

        let serialNumber = serialValue > 0 ? String(serialValue) : nil

        // Extract model name from descriptor blocks (bytes 54-125)
        let model = extractModelName(from: data) ?? "Unknown Model"

        return EDIDInfo(
            manufacturer: manufacturer,
            model: model,
            serialNumber: serialNumber,
            productCode: productCode,
            vendorID: vendorID
        )
    }

    /// Extract model name from EDID descriptor blocks
    private static func extractModelName(from data: Data) -> String? {
        guard data.count >= 128 else { return nil }

        // EDID has 4 descriptor blocks starting at byte 54, each 18 bytes
        let descriptorOffsets = [54, 72, 90, 108]

        for offset in descriptorOffsets {
            // Check if this is a monitor name descriptor (type 0xFC)
            if data[offset] == 0x00 && data[offset + 1] == 0x00 &&
               data[offset + 2] == 0x00 && data[offset + 3] == 0xFC {

                // Model name is bytes 5-17 of descriptor block
                let nameStart = offset + 5
                let nameEnd = offset + 18
                let nameBytes = data[nameStart..<nameEnd]

                // Convert to string, trimming null bytes and whitespace
                if let name = String(bytes: nameBytes, encoding: .ascii) {
                    let trimmed = name.trimmingCharacters(in: .controlCharacters)
                                     .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        return nil
    }

    /// Fallback EDID info when EDID data is unavailable
    private static func fallbackEDIDInfo(for displayID: CGDirectDisplayID) -> EDIDInfo? {
        // Try to get basic info from CoreGraphics
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

        let manufacturer = isBuiltIn ? "Apple" : "Unknown"
        let model = isBuiltIn ? "Built-in Display" : "External Display"

        return EDIDInfo(
            manufacturer: manufacturer,
            model: model,
            serialNumber: nil,
            productCode: 0,
            vendorID: 0
        )
    }
}
