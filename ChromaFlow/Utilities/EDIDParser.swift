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
        print("[EDID] Searching for EDID data for display \(displayID)")

        // Try IODisplayConnect using vendor/product ID matching
        if let data = getEDIDFromDisplayConnect(for: displayID) {
            print("[EDID] ✓ Found EDID via IODisplayConnect")
            return data
        }

        // Try deprecated but still working CGDisplayIOServicePort
        if let data = getEDIDFromCGDisplayPort(for: displayID) {
            print("[EDID] ✓ Found EDID via CGDisplayIOServicePort")
            return data
        }

        // Try IOFramebuffer as fallback
        if let data = getEDIDFromFramebuffer(for: displayID) {
            print("[EDID] ✓ Found EDID via IOFramebuffer")
            return data
        }

        // Try recursive search (Apple Silicon - IOPortTransportStateDisplayPort)
        if let data = getEDIDFromTransportState(for: displayID) {
            print("[EDID] ✓ Found EDID via recursive IORegistry search")
            return data
        }

        print("[EDID] ✗ No EDID found via any method")
        return nil
    }

    /// Get EDID by iterating IODisplay services
    private static func getEDIDFromCGDisplayPort(for displayID: CGDirectDisplayID) -> Data? {
        // Get expected vendor/product ID for target display
        let expectedIDs = getDisplayVendorProduct(for: displayID)
        print("[EDID] Target display \(displayID) - expected vendor: \(expectedIDs?.vendor ?? 0), product: \(expectedIDs?.product ?? 0)")

        // Search IORegistry for IODisplay services
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplay")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            print("[EDID] Failed to get IODisplay services")
            return nil
        }

        defer { IOObjectRelease(iter) }

        // Try various EDID property keys
        let keys = [
            "IODisplayEDID",
            "AAPL,DisplayEDID",
            "EDID"
        ]

        var foundCount = 0
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            foundCount += 1

            defer { IOObjectRelease(service) }

            // Try each EDID key
            for key in keys {
                if let edidProperty = IORegistryEntryCreateCFProperty(
                    service,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                ) {
                    let edid = edidProperty.takeRetainedValue()
                    if let data = edid as? Data, data.count >= 128 {
                        // Verify this EDID matches the target display
                        if let expectedIDs = expectedIDs,
                           edidMatchesDisplay(data, vendor: expectedIDs.vendor, product: expectedIDs.product) {
                            print("[EDID] ✓ Found matching EDID using key '\(key)' from IODisplay service \(foundCount) (\(data.count) bytes)")
                            return data
                        } else if expectedIDs == nil {
                            // If we couldn't determine expected IDs, return first valid EDID
                            print("[EDID] Found EDID using key '\(key)' from IODisplay service \(foundCount) (no ID verification)")
                            return data
                        } else {
                            print("[EDID] Found EDID but vendor/product mismatch, skipping")
                        }
                    }
                }
            }
        }

        print("[EDID] Checked \(foundCount) IODisplay services, no matching EDID found")
        return nil
    }

    /// Get EDID from IODisplayConnect by matching vendor/product
    private static func getEDIDFromDisplayConnect(for displayID: CGDirectDisplayID) -> Data? {
        // Get expected vendor/product ID for target display
        let expectedIDs = getDisplayVendorProduct(for: displayID)

        var iter: io_iterator_t = 0

        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iter) }

        var foundCount = 0
        while true {
            let servicePort = IOIteratorNext(iter)
            if servicePort == 0 { break }
            foundCount += 1

            defer { IOObjectRelease(servicePort) }

            // Get EDID data from this service
            if let edidProperty = IORegistryEntryCreateCFProperty(
                servicePort,
                "IODisplayEDID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let edid = edidProperty.takeRetainedValue()
                if let data = edid as? Data, data.count >= 128 {
                    // Verify this EDID matches the target display
                    if let expectedIDs = expectedIDs,
                       edidMatchesDisplay(data, vendor: expectedIDs.vendor, product: expectedIDs.product) {
                        print("[EDID] ✓ Found matching EDID from IODisplayConnect service \(foundCount) (\(data.count) bytes)")
                        return data
                    } else if expectedIDs == nil {
                        // If we couldn't determine expected IDs, return first valid EDID
                        print("[EDID] Found EDID from IODisplayConnect service \(foundCount) (no ID verification)")
                        return data
                    } else {
                        print("[EDID] Found EDID from IODisplayConnect but vendor/product mismatch, skipping")
                    }
                }
            }
        }

        print("[EDID] Checked \(foundCount) IODisplayConnect services, no matching EDID found")
        return nil
    }

    /// Get EDID from IOFramebuffer service (more reliable for external displays)
    private static func getEDIDFromFramebuffer(for displayID: CGDirectDisplayID) -> Data? {
        var servicePort: io_service_t = 0
        var iter: io_iterator_t = 0

        let matching = IOServiceMatching("IOFramebuffer")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iter) }

        while true {
            servicePort = IOIteratorNext(iter)
            if servicePort == 0 { break }

            defer { IOObjectRelease(servicePort) }

            // Check if this framebuffer matches our display ID
            if let dependentID = IORegistryEntryCreateCFProperty(
                servicePort,
                "IOFBDependentID" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let depID = dependentID.takeRetainedValue()
                if let id = depID as? UInt32, id == displayID {
                    print("[EDID] Found matching IOFramebuffer for display \(displayID)")
                    // Found matching framebuffer, try to get EDID
                    if let edidProperty = IORegistryEntryCreateCFProperty(
                        servicePort,
                        "AAPL,DisplayEDID" as CFString,  // Try Apple-specific key first
                        kCFAllocatorDefault,
                        0
                    ) ?? IORegistryEntryCreateCFProperty(
                        servicePort,
                        "IODisplayEDID" as CFString,
                        kCFAllocatorDefault,
                        0
                    ) {
                        let edid = edidProperty.takeRetainedValue()
                        if let data = edid as? Data, data.count >= 128 {
                            print("[EDID] ✓ Found EDID from matched framebuffer (\(data.count) bytes)")
                            return data
                        }
                    }
                }
            }
        }

        print("[EDID] No matching IOFramebuffer found for display \(displayID)")
        return nil
    }

    /// Get EDID from IOPortTransportStateDisplayPort (Apple Silicon path)
    private static func getEDIDFromTransportState(for displayID: CGDirectDisplayID) -> Data? {
        let expectedIDs = getDisplayVendorProduct(for: displayID)
        print("[EDID] Searching IOPortTransportStateDisplayPort for display \(displayID), expected vendor: \(expectedIDs?.vendor ?? 0), product: \(expectedIDs?.product ?? 0)")

        var iter: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)

        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else {
            print("[EDID] Failed to create recursive iterator")
            return nil
        }

        defer { IOObjectRelease(iter) }

        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }

            defer { IOObjectRelease(entry) }

            // Check for EDID property (used by Apple Silicon display transport)
            let edidKeys = ["EDID", "IODisplayEDID", "AAPL,DisplayEDID"]
            for key in edidKeys {
                guard let prop = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
                    continue
                }

                guard let nsData = prop.takeRetainedValue() as? NSData else { continue }
                let data = Data(referencing: nsData)
                guard data.count >= 128 else { continue }

                // Validate EDID header
                let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
                guard Array(data.prefix(8)) == header else { continue }

                // Match by vendor/product
                if let expectedIDs = expectedIDs {
                    let edidVendor = UInt32(UInt16(data[8]) << 8 | UInt16(data[9]))
                    let edidProduct = UInt32(UInt16(data[10]) | (UInt16(data[11]) << 8))

                    if edidVendor == expectedIDs.vendor && edidProduct == expectedIDs.product {
                        print("[EDID] ✓ Found matching EDID via recursive search, key '\(key)' (\(data.count) bytes)")
                        return data
                    }
                } else {
                    // No expected IDs, return first valid EDID for non-built-in displays
                    print("[EDID] Found EDID via recursive search, key '\(key)' (no ID verification)")
                    return data
                }
            }
        }

        print("[EDID] No matching EDID found via recursive search")
        return nil
    }

    /// Get expected vendor and product ID for a display from CoreGraphics
    private static func getDisplayVendorProduct(for displayID: CGDirectDisplayID) -> (vendor: UInt32, product: UInt32)? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)

        // CGDisplayVendorNumber returns 0 for unknown displays
        guard vendorID != 0 else { return nil }

        return (vendor: vendorID, product: productID)
    }

    /// Verify EDID data matches expected vendor and product IDs
    private static func edidMatchesDisplay(_ edidData: Data, vendor expectedVendor: UInt32, product expectedProduct: UInt32) -> Bool {
        guard edidData.count >= 128 else { return false }

        // Validate EDID header
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        let dataHeader = Array(edidData.prefix(8))
        guard dataHeader == header else { return false }

        // Extract vendor ID from EDID (bytes 8-9)
        let vendorBytes = UInt16(edidData[8]) << 8 | UInt16(edidData[9])
        let edidVendor = UInt32(vendorBytes)

        // Extract product code from EDID (bytes 10-11, little-endian)
        let edidProduct = UInt32(edidData[10]) | (UInt32(edidData[11]) << 8)

        let matches = edidVendor == expectedVendor && edidProduct == expectedProduct
        print("[EDID] Comparing - EDID vendor:product \(edidVendor):\(edidProduct) vs expected \(expectedVendor):\(expectedProduct) - \(matches ? "MATCH" : "MISMATCH")")

        return matches
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
        let char1 = Character(UnicodeScalar(((vendorBytes >> 10) & 0x1F) + 64) ?? UnicodeScalar(65))
        let char2 = Character(UnicodeScalar(((vendorBytes >> 5) & 0x1F) + 64) ?? UnicodeScalar(65))
        let char3 = Character(UnicodeScalar((vendorBytes & 0x1F) + 64) ?? UnicodeScalar(65))
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
                    let trimmed = name.components(separatedBy: .newlines).first?
                        .trimmingCharacters(in: .controlCharacters)
                        .trimmingCharacters(in: .whitespaces) ?? ""
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
        print("[EDID] Using fallback display info for display \(displayID)")

        // Try to get basic info from CoreGraphics
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

        var manufacturer = "Unknown"
        var model = isBuiltIn ? "Built-in Display" : "External Display"

        if isBuiltIn {
            manufacturer = "Apple"
            model = "Built-in Display"
        }

        // Try to get display name from IODisplayCreateInfoDictionary
        if let displayInfo = getDisplayInfoFromCoreGraphics(for: displayID) {
            // Extract display product name (localized dictionary)
            if let displayName = displayInfo["DisplayProductName"] as? [String: String] {
                // Try multiple locale keys
                if let localizedName = displayName["en_US"] ?? displayName["en"] ?? displayName.values.first {
                    if !localizedName.isEmpty {
                        model = localizedName
                        print("[EDID] Found display name from IOKit: \(model)")
                    }
                }
            } else if let displayName = displayInfo["DisplayProductName"] as? String {
                // Sometimes it's a plain string
                if !displayName.isEmpty {
                    model = displayName
                    print("[EDID] Found display name (string) from IOKit: \(model)")
                }
            }

            if let vendorID = displayInfo["DisplayVendorID"] as? UInt32, vendorID > 0 {
                manufacturer = decodeVendorID(vendorID)
                print("[EDID] Found vendor from IOKit: \(manufacturer) (ID: \(vendorID))")
            }
        }

        // If still "External Display", try manufacturer code from CG vendor number
        if model == "External Display" && !isBuiltIn {
            let vendorNum = CGDisplayVendorNumber(displayID)
            let modelNum = CGDisplayModelNumber(displayID)
            if vendorNum != 0 {
                manufacturer = decodeVendorID(vendorNum)
                // Use vendor + model number as a last resort name
                model = "\(manufacturer) Display (\(modelNum))"
                print("[EDID] Using CG vendor/model numbers: \(model)")
            }
        }

        return EDIDInfo(
            manufacturer: manufacturer,
            model: model,
            serialNumber: nil,
            productCode: 0,
            vendorID: 0
        )
    }

    /// Get display info using IODisplayCreateInfoDictionary (IOKit API)
    private static func getDisplayInfoFromCoreGraphics(for displayID: CGDirectDisplayID) -> [String: Any]? {
        let expectedVendor = CGDisplayVendorNumber(displayID)
        let expectedProduct = CGDisplayModelNumber(displayID)

        print("[EDID] getDisplayInfoFromCoreGraphics: looking for vendor=\(expectedVendor), product=\(expectedProduct)")

        // Search IORegistry for display services
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            print("[EDID] Failed to get IODisplayConnect services")
            return nil
        }

        defer { IOObjectRelease(iter) }

        var foundCount = 0

        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            foundCount += 1

            defer { IOObjectRelease(service) }

            // Safely call IODisplayCreateInfoDictionary - it returns Unmanaged<CFDictionary>! which is nil-crashable
            guard let rawDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)) else {
                continue
            }

            let infoDict = rawDict.takeRetainedValue() as NSDictionary
            guard let dict = infoDict as? [String: Any] else { continue }

            // Match by vendor and product ID
            let dictVendor = dict["DisplayVendorID"] as? UInt32 ?? 0
            let dictProduct = dict["DisplayProductID"] as? UInt32 ?? 0

            print("[EDID] Service \(foundCount): vendor=\(dictVendor), product=\(dictProduct)")

            if expectedVendor != 0 && (dictVendor == expectedVendor && dictProduct == expectedProduct) {
                print("[EDID] ✓ Found matching display info from service \(foundCount)")
                return dict
            }
        }

        // Fallback: if no match by ID, try again and return the first non-built-in
        // (This handles cases where CGDisplayVendorNumber returns 0)
        if expectedVendor == 0 {
            var iter2: io_iterator_t = 0
            let matching2 = IOServiceMatching("IODisplayConnect")
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching2, &iter2) == KERN_SUCCESS else {
                return nil
            }
            defer { IOObjectRelease(iter2) }

            while true {
                let service = IOIteratorNext(iter2)
                if service == 0 { break }
                defer { IOObjectRelease(service) }

                guard let rawDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)) else {
                    continue
                }

                let infoDict = rawDict.takeRetainedValue() as NSDictionary
                guard let dict = infoDict as? [String: Any] else { continue }

                // Skip built-in displays
                if let isInternal = dict["IODisplayIsInternal"] as? Bool, isInternal {
                    continue
                }

                print("[EDID] ✓ Found display info (no ID match, using first external)")
                return dict
            }
        }

        print("[EDID] Checked \(foundCount) services, no display info found")
        return nil
    }

    /// Decode vendor ID to manufacturer code
    private static func decodeVendorID(_ vendorID: UInt32) -> String {
        // Vendor ID is encoded similar to EDID: 3 letters in 5-bit chunks
        let char1 = Character(UnicodeScalar(((vendorID >> 10) & 0x1F) + 64) ?? UnicodeScalar(65))
        let char2 = Character(UnicodeScalar(((vendorID >> 5) & 0x1F) + 64) ?? UnicodeScalar(65))
        let char3 = Character(UnicodeScalar((vendorID & 0x1F) + 64) ?? UnicodeScalar(65))
        return String([char1, char2, char3])
    }
}
