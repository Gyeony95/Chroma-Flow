//
//  IORegistryReader.swift
//  ChromaFlow
//
//  Reads IORegistry to detect available display connection modes
//  (RGB/YCbCr, Full/Limited range, bit depths) from TimingElements → ColorElements.
//
//  On Apple Silicon Macs, CGDisplayCopyAllDisplayModes does NOT return separate
//  modes for different pixel encodings — the RGB/YCbCr switching happens at the
//  DCP (Display Coprocessor) firmware level. This reader queries the IORegistry
//  directly to discover what modes the display actually supports.
//

import Foundation
import CoreGraphics
import ColorSync
import IOKit
import os.log

// MARK: - PixelEncoding

/// Pixel encoding format matching IOGraphicsTypes.h bitmask values.
public enum PixelEncoding: Int, Codable, Sendable, Hashable, CaseIterable {
    case rgb444   = 1   // 0x01
    case ycbcr444 = 2   // 0x02
    case ycbcr422 = 4   // 0x04
    case ycbcr420 = 8   // 0x08

    public var description: String {
        switch self {
        case .rgb444:   return "RGB 4:4:4"
        case .ycbcr444: return "YCbCr 4:4:4"
        case .ycbcr422: return "YCbCr 4:2:2"
        case .ycbcr420: return "YCbCr 4:2:0"
        }
    }
}

// MARK: - BitsPerComponent

/// Bits per color component matching IOGraphicsTypes.h bitmask values.
public enum BitsPerComponent: Int, Codable, Sendable, Hashable, CaseIterable {
    case bpc6  = 1   // 0x01
    case bpc8  = 2   // 0x02
    case bpc10 = 4   // 0x04
    case bpc12 = 8   // 0x08

    public var numericValue: Int {
        switch self {
        case .bpc6:  return 6
        case .bpc8:  return 8
        case .bpc10: return 10
        case .bpc12: return 12
        }
    }

    public var description: String {
        "\(numericValue)-bit"
    }

    /// Initialize from a numeric bit depth value (6, 8, 10, 12).
    public init?(numericBitDepth: Int) {
        switch numericBitDepth {
        case 6:  self = .bpc6
        case 8:  self = .bpc8
        case 10: self = .bpc10
        case 12: self = .bpc12
        default: return nil
        }
    }
}

// MARK: - ColorRange

/// Quantization range for the signal.
public enum ColorRange: Int, Codable, Sendable, Hashable, CaseIterable {
    case limited = 1   // 0x01 — 16-235 (8-bit)
    case full    = 2   // 0x02 — 0-255  (8-bit)

    public var description: String {
        switch self {
        case .limited: return "Limited Range"
        case .full:    return "Full Range"
        }
    }
}

// MARK: - DynamicRange

/// Electro-optical transfer function / dynamic range.
public enum DynamicRange: Int, Codable, Sendable, Hashable, CaseIterable {
    case sdr   = 1   // 0x01
    case hdr10 = 2   // 0x02

    public var description: String {
        switch self {
        case .sdr:   return "SDR"
        case .hdr10: return "HDR10"
        }
    }
}

// MARK: - ConnectionColorMode

/// Represents a single color mode configuration that a display connection supports.
public struct ConnectionColorMode: Codable, Sendable, Hashable, Equatable {
    public let pixelEncoding: PixelEncoding
    public let bitsPerComponent: BitsPerComponent
    public let colorRange: ColorRange
    public let dynamicRange: DynamicRange

    public init(
        pixelEncoding: PixelEncoding,
        bitsPerComponent: BitsPerComponent,
        colorRange: ColorRange,
        dynamicRange: DynamicRange
    ) {
        self.pixelEncoding = pixelEncoding
        self.bitsPerComponent = bitsPerComponent
        self.colorRange = colorRange
        self.dynamicRange = dynamicRange
    }

    /// Human-readable description, e.g. "RGB 4:4:4, 8-bit, Full Range, SDR"
    public var description: String {
        "\(pixelEncoding.description), \(bitsPerComponent.description), \(colorRange.description), \(dynamicRange.description)"
    }
}

// MARK: - IORegistryReader

/// Reads IORegistry to discover display connection color modes
/// that are not exposed through CGDisplayCopyAllDisplayModes on Apple Silicon.
public final class IORegistryReader: Sendable {

    private let logger = Logger(subsystem: "com.chromaflow.display", category: "IORegistryReader")

    public init() {}

    // MARK: - Public API

    /// Find the IORegistry service that has TimingElements for a given display.
    ///
    /// On Apple Silicon Macs, `TimingElements` lives on `IOMobileFramebufferShim` or
    /// `IOMobileFramebufferAP` services (not on `IODisplayConnect` or its parent chain).
    /// We search these framebuffer services first, then fall back to the legacy approach.
    ///
    /// The caller is responsible for calling `IOObjectRelease` on the returned service.
    public func findDisplayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)

        logger.debug("Searching for display service: vendor=\(vendorID), product=\(productID)")

        // Get current resolution in physical pixels to match TimingElements (which store native pixels).
        // CGDisplayPixelsWide/High returns logical pixels (e.g. 1920x1080 for a 4K@2x display),
        // but TimingElements stores physical pixels (e.g. 3840x2160).
        let currentWidth: Int
        let currentHeight: Int
        if let cgMode = CGDisplayCopyDisplayMode(displayID) {
            currentWidth = cgMode.pixelWidth
            currentHeight = cgMode.pixelHeight
        } else {
            currentWidth = Int(CGDisplayPixelsWide(displayID))
            currentHeight = Int(CGDisplayPixelsHigh(displayID))
        }

        // Strategy 1: Search framebuffer services that have TimingElements (Apple Silicon)
        let framebufferClasses = ["IOMobileFramebufferShim", "IOMobileFramebufferAP", "AppleCLCD2"]
        for className in framebufferClasses {
            if let service = findServiceWithTimingElements(
                className: className,
                displayID: displayID,
                vendorID: vendorID,
                productID: productID,
                currentWidth: currentWidth,
                currentHeight: currentHeight
            ) {
                logger.info("Found TimingElements on \(className) service")
                return service
            }
        }

        // Strategy 2: Walk parent chain from IODisplayConnect (legacy / Intel Macs)
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            logger.error("IOServiceGetMatchingServices failed: \(result)")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            // Check if this service matches our display by vendor/product ID
            guard matchesDisplay(service, vendorID: vendorID, productID: productID) else {
                IOObjectRelease(service)
                continue
            }

            // Walk the parent chain to find a service that has TimingElements
            if let parentWithTiming = findParentWithTimingElements(from: service) {
                IOObjectRelease(service)
                return parentWithTiming
            }

            // If the service itself has TimingElements, return it
            if hasProperty(service, key: "TimingElements") {
                // Do NOT release — caller will release
                return service
            }

            IOObjectRelease(service)
        }

        // Strategy 3: Find any external framebuffer with TimingElements
        // by checking if IONameMatch contains "dispext" entries
        for className in ["IOMobileFramebufferShim", "IOMobileFramebufferAP"] {
            var iter: io_iterator_t = 0
            let match = IOServiceMatching(className)
            guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }

            while true {
                let svc = IOIteratorNext(iter)
                guard svc != 0 else { break }

                // Check if it's an external framebuffer
                if let nameMatch = getProperty(svc, key: "IONameMatch") as? [String],
                   nameMatch.contains(where: { $0.contains("dispext") }),
                   hasProperty(svc, key: "TimingElements") {
                    logger.info("Found external framebuffer with TimingElements via dispext match")
                    return svc
                }
                IOObjectRelease(svc)
            }
        }

        logger.warning("No display service with TimingElements found for display \(displayID)")
        return nil
    }

    /// Read TimingElements property from a service.
    public func readTimingElements(from service: io_service_t) -> [[String: Any]]? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "TimingElements" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            logger.debug("No TimingElements property on service")
            return nil
        }

        let value = property.takeRetainedValue()
        guard let elements = value as? [[String: Any]] else {
            logger.warning("TimingElements property is not an array of dictionaries")
            return nil
        }

        logger.debug("Read \(elements.count) timing elements")
        return elements
    }

    /// Parse ColorElements from a single timing element dictionary.
    public func parseColorElements(from timingElement: [String: Any]) -> [ConnectionColorMode] {
        // ColorElements may be stored under several possible keys.
        // On Apple Silicon DCP, the key is "ColorModes" (not "ColorElements").
        let colorElementsKeys = ["ColorModes", "ColorElements", "colorElements", "Color Elements"]
        var rawElements: [[String: Any]]?

        for key in colorElementsKeys {
            if let elements = timingElement[key] as? [[String: Any]] {
                rawElements = elements
                break
            }
        }

        guard let colorElements = rawElements else {
            logger.debug("No ColorElements found in timing element")
            return []
        }

        var modes: [ConnectionColorMode] = []

        for element in colorElements {
            guard let mode = parseColorElement(element) else { continue }
            modes.append(mode)
        }

        logger.debug("Parsed \(modes.count) color modes from timing element")
        return modes
    }

    /// Get all available connection color modes for a display.
    ///
    /// Finds the timing element matching the current resolution and refresh rate,
    /// then returns its color elements. If no exact match is found, aggregates
    /// unique modes from all timing elements.
    public func availableConnectionModes(for displayID: CGDirectDisplayID) -> [ConnectionColorMode] {
        guard let service = findDisplayService(for: displayID) else {
            logger.warning("No display service found for display \(displayID)")
            return []
        }
        defer { IOObjectRelease(service) }

        guard let timingElements = readTimingElements(from: service) else {
            logger.warning("No timing elements for display \(displayID)")
            return []
        }

        // Get current resolution in physical pixels and refresh rate.
        // CGDisplayPixelsWide/High returns logical pixels, but TimingElements stores native pixels.
        let currentWidth: Int
        let currentHeight: Int
        let currentRefresh: Double
        if let cgMode = CGDisplayCopyDisplayMode(displayID) {
            currentWidth = cgMode.pixelWidth
            currentHeight = cgMode.pixelHeight
            currentRefresh = cgMode.refreshRate
        } else {
            currentWidth = Int(CGDisplayPixelsWide(displayID))
            currentHeight = Int(CGDisplayPixelsHigh(displayID))
            currentRefresh = 0
        }

        logger.info("Current mode: \(currentWidth)x\(currentHeight) @ \(currentRefresh)Hz")

        // Try to find timing element matching current resolution/refresh
        let matchingElement = findMatchingTimingElement(
            in: timingElements,
            width: currentWidth,
            height: currentHeight,
            refreshRate: currentRefresh
        )

        if let element = matchingElement {
            let modes = parseColorElements(from: element)
            if !modes.isEmpty {
                logger.info("Found \(modes.count) color modes from matching timing element")
                return deduplicateModes(modes)
            }
        }

        // Fallback: aggregate unique modes from all timing elements
        logger.info("No exact timing match found, aggregating from all \(timingElements.count) elements")
        var allModes: [ConnectionColorMode] = []
        for element in timingElements {
            let modes = parseColorElements(from: element)
            allModes.append(contentsOf: modes)
        }

        let deduplicated = deduplicateModes(allModes)
        logger.info("Aggregated \(deduplicated.count) unique color modes from all timing elements")
        return deduplicated
    }

    /// Read the currently active connection color mode from WindowServer preferences.
    ///
    /// Reads from `/Library/Preferences/com.apple.windowserver.displays.plist`
    /// and navigates DisplaySets to find the active display configuration.
    public func currentConnectionMode(for displayID: CGDirectDisplayID) -> ConnectionColorMode? {
        let plistPath = "/Library/Preferences/com.apple.windowserver.displays.plist"

        guard let plistData = FileManager.default.contents(atPath: plistPath) else {
            logger.warning("Cannot read WindowServer plist at \(plistPath)")
            return nil
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            )
        } catch {
            logger.error("Failed to parse WindowServer plist: \(error.localizedDescription)")
            return nil
        }

        guard let root = plist as? [String: Any] else {
            logger.warning("WindowServer plist root is not a dictionary")
            return nil
        }

        // Get UUID for this display
        let targetUUID: String?
        if let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = uuidUnmanaged.takeRetainedValue()
            if let cfStr = CFUUIDCreateString(kCFAllocatorDefault, uuid) {
                targetUUID = cfStr as String
            } else {
                targetUUID = nil
            }
        } else {
            targetUUID = nil
        }

        logger.debug("Looking for display UUID=\(targetUUID ?? "unknown") in WindowServer plist")

        // Search DisplayAnyUserSets first, then DisplaySets
        let sectionKeys = ["DisplayAnyUserSets", "DisplaySets"]

        for sectionKey in sectionKeys {
            guard let section = root[sectionKey] as? [String: Any],
                  let configs = section["Configs"] as? [[String: Any]] else {
                continue
            }

            for configGroup in configs {
                guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]] else {
                    continue
                }

                for displayConfig in displayConfigs {
                    // Match by UUID if available
                    if let targetUUID = targetUUID,
                       let configUUID = displayConfig["UUID"] as? String,
                       configUUID == targetUUID {
                        if let linkDesc = displayConfig["LinkDescription"] as? [String: Any] {
                            logger.info("Found LinkDescription by UUID match in \(sectionKey)")
                            return parseLinkDescription(linkDesc)
                        }
                    }
                }
            }
        }

        // Fallback: find any display config with LinkDescription (only external displays have it)
        for sectionKey in sectionKeys {
            guard let section = root[sectionKey] as? [String: Any],
                  let configs = section["Configs"] as? [[String: Any]] else {
                continue
            }

            for configGroup in configs {
                guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]] else {
                    continue
                }

                for displayConfig in displayConfigs {
                    if let linkDesc = displayConfig["LinkDescription"] as? [String: Any] {
                        logger.info("Found LinkDescription via fallback in \(sectionKey)")
                        return parseLinkDescription(linkDesc)
                    }
                }
            }
        }

        logger.warning("No LinkDescription found in WindowServer plist")
        return nil
    }

    // MARK: - Private: Service Matching

    /// Search for a framebuffer service of the given class that has `TimingElements`.
    ///
    /// Matching strategy:
    /// 1. Check if a child `IODisplayConnect` has matching vendor/product IDs
    /// 2. Check if TimingElements contain a timing matching the current resolution
    /// 3. For external displays, check if the service name contains "dispext"
    private func findServiceWithTimingElements(
        className: String,
        displayID: CGDirectDisplayID,
        vendorID: UInt32,
        productID: UInt32,
        currentWidth: Int,
        currentHeight: Int
    ) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(className) else { return nil }

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            // Must have TimingElements
            guard hasProperty(service, key: "TimingElements") else {
                IOObjectRelease(service)
                continue
            }

            // Try to match: check if child IODisplayConnect has our vendor/product
            if hasChildDisplayConnect(service, vendorID: vendorID, productID: productID) {
                return service
            }

            // Try to match: check if TimingElements contain the current resolution
            if let timingElements = readTimingElements(from: service) {
                let hasMatchingResolution = timingElements.contains { element in
                    let w = resolutionWidth(from: element)
                    let h = resolutionHeight(from: element)
                    return w == currentWidth && h == currentHeight
                }
                if hasMatchingResolution {
                    return service
                }
            }

            IOObjectRelease(service)
        }

        return nil
    }

    /// Check if a framebuffer service has a child IODisplayConnect with matching vendor/product.
    private func hasChildDisplayConnect(_ service: io_service_t, vendorID: UInt32, productID: UInt32) -> Bool {
        var childIterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator)
        guard result == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            if matchesDisplay(child, vendorID: vendorID, productID: productID) {
                return true
            }

            // Also check grandchildren (IODisplayConnect might be one level deeper)
            var grandchildIterator: io_iterator_t = 0
            let gcResult = IORegistryEntryGetChildIterator(child, kIOServicePlane, &grandchildIterator)
            guard gcResult == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(grandchildIterator) }

            while true {
                let grandchild = IOIteratorNext(grandchildIterator)
                guard grandchild != 0 else { break }
                defer { IOObjectRelease(grandchild) }

                if matchesDisplay(grandchild, vendorID: vendorID, productID: productID) {
                    return true
                }
            }
        }

        return false
    }

    /// Extract resolution width from a timing element (handles nested HorizontalAttributes).
    private func resolutionWidth(from element: [String: Any]) -> Int? {
        // Nested: HorizontalAttributes.Active
        if let hAttr = element["HorizontalAttributes"] as? [String: Any],
           let active = hAttr["Active"] as? Int {
            return active
        }
        // Flat keys
        return firstIntValue(from: element, keys: ["Width", "HorizontalActive", "HActive", "width"])
    }

    /// Extract resolution height from a timing element (handles nested VerticalAttributes).
    private func resolutionHeight(from element: [String: Any]) -> Int? {
        // Nested: VerticalAttributes.Active
        if let vAttr = element["VerticalAttributes"] as? [String: Any],
           let active = vAttr["Active"] as? Int {
            return active
        }
        // Flat keys
        return firstIntValue(from: element, keys: ["Height", "VerticalActive", "VActive", "height"])
    }

    /// Check whether a service matches the display by vendor/product ID.
    /// IOKit properties may be stored as Int, UInt32, or NSNumber depending on the driver.
    private func matchesDisplay(_ service: io_service_t, vendorID: UInt32, productID: UInt32) -> Bool {
        guard let serviceVendorValue = getProperty(service, key: "DisplayVendorID"),
              let serviceProductValue = getProperty(service, key: "DisplayProductID") else {
            return false
        }

        let serviceVendor: UInt32
        let serviceProduct: UInt32

        if let v = serviceVendorValue as? Int { serviceVendor = UInt32(v) }
        else if let v = serviceVendorValue as? UInt32 { serviceVendor = v }
        else if let v = serviceVendorValue as? NSNumber { serviceVendor = v.uint32Value }
        else { return false }

        if let p = serviceProductValue as? Int { serviceProduct = UInt32(p) }
        else if let p = serviceProductValue as? UInt32 { serviceProduct = p }
        else if let p = serviceProductValue as? NSNumber { serviceProduct = p.uint32Value }
        else { return false }

        return serviceVendor == vendorID && serviceProduct == productID
    }

    /// Walk the parent chain from a service to find an ancestor with TimingElements.
    ///
    /// Returns the parent service (retained — caller must release), or nil.
    private func findParentWithTimingElements(from service: io_service_t) -> io_service_t? {
        var current = service
        IOObjectRetain(current)

        // Walk up to 10 levels to avoid infinite loops
        for _ in 0..<10 {
            var parent: io_service_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)

            // Release the current entry (unless it is the original service)
            if current != service {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS, parent != 0 else {
                break
            }

            if hasProperty(parent, key: "TimingElements") {
                logger.debug("Found TimingElements on parent service")
                return parent
            }

            current = parent
        }

        // Release the last "current" if we retained it and it isn't the original
        if current != service {
            IOObjectRelease(current)
        }

        return nil
    }

    /// Check if a service has a given property.
    private func hasProperty(_ service: io_service_t, key: String) -> Bool {
        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return false
        }
        // takeRetainedValue to release the CF object
        let _ = prop.takeRetainedValue()
        return true
    }

    /// Read a single property from a service.
    private func getProperty(_ service: io_service_t, key: String) -> Any? {
        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return prop.takeRetainedValue()
    }

    // MARK: - Private: Timing Element Matching

    /// Find a timing element that matches the given resolution and refresh rate.
    ///
    /// On Apple Silicon DCP, resolution and refresh are stored in nested dictionaries:
    /// - `HorizontalAttributes.Active` for width
    /// - `VerticalAttributes.Active` for height
    /// - `VerticalAttributes.SyncRate` or `PreciseSyncRate` as fixed-point (* 65536)
    ///
    /// Also supports flat key layouts for legacy compatibility.
    private func findMatchingTimingElement(
        in elements: [[String: Any]],
        width: Int,
        height: Int,
        refreshRate: Double
    ) -> [String: Any]? {
        // Common flat key variations for width/height/refresh in TimingElements
        let widthKeys  = ["Width", "HorizontalActive", "HActive", "width"]
        let heightKeys = ["Height", "VerticalActive", "VActive", "height"]
        let refreshKeys = ["RefreshRate", "VerticalRate", "VRate", "refreshRate"]

        for element in elements {
            // Try nested attributes first (Apple Silicon DCP), then flat keys
            let elementWidth = resolutionWidth(from: element)
                ?? firstIntValue(from: element, keys: widthKeys)
            let elementHeight = resolutionHeight(from: element)
                ?? firstIntValue(from: element, keys: heightKeys)

            // Refresh rate: try flat keys first, then nested SyncRate (fixed-point / 65536)
            var elementRefresh = firstDoubleValue(from: element, keys: refreshKeys)

            if elementRefresh == nil {
                if let vAttr = element["VerticalAttributes"] as? [String: Any] {
                    if let syncRate = vAttr["SyncRate"] as? Int, syncRate > 0 {
                        elementRefresh = Double(syncRate) / 65536.0
                    } else if let preciseSyncRate = vAttr["PreciseSyncRate"] as? Int, preciseSyncRate > 0 {
                        elementRefresh = Double(preciseSyncRate) / 65536.0
                    }
                }
            }

            guard let w = elementWidth, let h = elementHeight else { continue }

            if w == width && h == height {
                // If refresh rate is available, require it to be close
                if let r = elementRefresh {
                    if abs(r - refreshRate) < 1.0 {
                        return element
                    }
                } else {
                    // No refresh info — match on resolution alone
                    return element
                }
            }
        }

        // Second pass: if no exact refresh match, try resolution-only match
        for element in elements {
            let elementWidth = resolutionWidth(from: element)
                ?? firstIntValue(from: element, keys: widthKeys)
            let elementHeight = resolutionHeight(from: element)
                ?? firstIntValue(from: element, keys: heightKeys)

            guard let w = elementWidth, let h = elementHeight else { continue }

            if w == width && h == height {
                return element
            }
        }

        return nil
    }

    // MARK: - Private: ColorElement Parsing

    /// Parse a single color element dictionary into a ConnectionColorMode.
    ///
    /// Handles both legacy IOGraphicsTypes.h bitmask values and Apple Silicon DCP
    /// sequential ID values (e.g., `PixelEncoding=0` for RGB, `Depth=8`).
    private func parseColorElement(_ element: [String: Any]) -> ConnectionColorMode? {
        // Try multiple key variations
        let encodingKeys = ["PixelEncoding", "pixelEncoding", "Encoding", "encoding"]
        // Apple Silicon DCP uses "Depth" instead of "BitsPerComponent" or "BitDepth"
        let bpcKeys = ["Depth", "BitsPerComponent", "bitsPerComponent", "BitDepth", "bitDepth", "BPC", "bpc"]
        let rangeKeys = ["ColorRange", "colorRange", "Range", "range", "QuantizationRange"]
        let dynamicKeys = ["DynamicRange", "dynamicRange", "EOTF", "eotf", "HDR", "hdr"]

        guard let encoding = parsePixelEncoding(from: element, keys: encodingKeys) else {
            logger.debug("Could not parse pixel encoding from color element")
            return nil
        }

        guard let bpc = parseBitsPerComponent(from: element, keys: bpcKeys) else {
            logger.debug("Could not parse bits per component from color element")
            return nil
        }

        // Parse dynamic range first (needed for color range inference)
        let dynamic = parseDynamicRange(from: element, keys: dynamicKeys) ?? .sdr

        // Color range: try explicit keys first, then infer from encoding + dynamic range.
        // Apple Silicon DCP ColorModes do not include an explicit color range field.
        let range = parseColorRange(from: element, keys: rangeKeys)
            ?? inferColorRange(encoding: encoding, dynamicRange: dynamic)

        return ConnectionColorMode(
            pixelEncoding: encoding,
            bitsPerComponent: bpc,
            colorRange: range,
            dynamicRange: dynamic
        )
    }

    private func parsePixelEncoding(from dict: [String: Any], keys: [String]) -> PixelEncoding? {
        for key in keys {
            if let intVal = dict[key] as? Int {
                // Apple Silicon DCP sequential IDs (most common on modern hardware):
                //   0 = RGB 4:4:4
                //   2 = YCbCr 4:4:4
                //   3 = YCbCr 4:2:2
                //   4 = YCbCr 4:2:0
                // Also handle legacy IOGraphicsTypes.h bitmask values:
                //   1 = RGB (bitmask), 2 = YCbCr444, 4 = YCbCr422, 8 = YCbCr420
                switch intVal {
                case 0: return .rgb444
                case 1: return .rgb444       // Legacy bitmask for RGB
                case 2: return .ycbcr444     // Both DCP sequential and legacy bitmask
                case 3: return .ycbcr422     // DCP sequential
                case 4: return .ycbcr420     // DCP sequential (also legacy bitmask for YCbCr422)
                case 8: return .ycbcr420     // Legacy bitmask for YCbCr420
                default: break
                }
            }
            if let strVal = dict[key] as? String {
                let lowered = strVal.lowercased()
                if lowered.contains("rgb")   { return .rgb444 }
                if lowered.contains("420")   { return .ycbcr420 }
                if lowered.contains("422")   { return .ycbcr422 }
                if lowered.contains("ycbcr") || lowered.contains("444") { return .ycbcr444 }
            }
        }
        return nil
    }

    private func parseBitsPerComponent(from dict: [String: Any], keys: [String]) -> BitsPerComponent? {
        for key in keys {
            if let intVal = dict[key] as? Int {
                // Try numeric bit depth first (6, 8, 10, 12) since Apple Silicon DCP
                // uses plain numeric values (e.g., Depth=8 means 8-bit).
                // Must check this BEFORE rawValue, because rawValue 8 = bpc12 (bitmask),
                // which would incorrectly map DCP Depth=8 to 12-bit.
                if let bpc = BitsPerComponent(numericBitDepth: intVal) {
                    return bpc
                }
                // Fallback: try legacy bitmask value (1=6bit, 2=8bit, 4=10bit, 8=12bit)
                if let bpc = BitsPerComponent(rawValue: intVal) {
                    return bpc
                }
            }
        }
        return nil
    }

    private func parseColorRange(from dict: [String: Any], keys: [String]) -> ColorRange? {
        for key in keys {
            if let intVal = dict[key] as? Int {
                if let range = ColorRange(rawValue: intVal) {
                    return range
                }
                // Numeric code: 0=Limited, 1=Full
                switch intVal {
                case 0: return .limited
                case 1: return .full
                default: break
                }
            }
            if let strVal = dict[key] as? String {
                let lowered = strVal.lowercased()
                if lowered.contains("full") { return .full }
                if lowered.contains("limited") { return .limited }
            }
        }
        return nil
    }

    private func parseDynamicRange(from dict: [String: Any], keys: [String]) -> DynamicRange? {
        for key in keys {
            if let intVal = dict[key] as? Int {
                // Apple Silicon DCP values: 0=SDR, 1=HDR
                // Must check these BEFORE rawValue init, because DynamicRange.sdr.rawValue == 1
                // which would incorrectly match DCP value 1 (HDR) to SDR.
                switch intVal {
                case 0: return .sdr
                case 1: return .hdr10
                case 2: return .hdr10    // Legacy bitmask for HDR
                default: break
                }
            }
            if let strVal = dict[key] as? String {
                let lowered = strVal.lowercased()
                if lowered.contains("hdr") { return .hdr10 }
                if lowered.contains("sdr") { return .sdr }
            }
            if let boolVal = dict[key] as? Bool {
                return boolVal ? .hdr10 : .sdr
            }
        }
        return nil
    }

    /// Infer color range when no explicit value is provided in the color mode data.
    ///
    /// Apple Silicon DCP `ColorModes` do not include an explicit color range field.
    /// Convention: RGB + SDR defaults to Full Range; YCbCr defaults to Limited Range.
    private func inferColorRange(encoding: PixelEncoding, dynamicRange: DynamicRange) -> ColorRange {
        if encoding == .rgb444 && dynamicRange == .sdr {
            return .full
        }
        return .limited
    }

    // MARK: - Private: WindowServer Plist Parsing

    /// Parse LinkDescription dictionary from WindowServer plist.
    ///
    /// Expected keys:
    /// - `PixelEncoding`: 0=RGB, 1=YCbCr
    /// - `Range`: 0=Limited, 1=Full
    /// - `BitDepth`: 8, 10, 12
    /// - `EOTF`: 0=SDR
    private func parseLinkDescription(_ linkDesc: [String: Any]) -> ConnectionColorMode? {
        // Pixel encoding
        let pixelEncoding: PixelEncoding
        if let encodingVal = linkDesc["PixelEncoding"] as? Int {
            switch encodingVal {
            case 0: pixelEncoding = .rgb444
            case 1: pixelEncoding = .ycbcr444
            case 2: pixelEncoding = .ycbcr422
            case 3: pixelEncoding = .ycbcr420
            default: pixelEncoding = .rgb444
            }
        } else {
            logger.debug("No PixelEncoding in LinkDescription, defaulting to RGB")
            pixelEncoding = .rgb444
        }

        // Bits per component
        let bpc: BitsPerComponent
        if let bitDepth = linkDesc["BitDepth"] as? Int,
           let parsed = BitsPerComponent(numericBitDepth: bitDepth) {
            bpc = parsed
        } else if let bitsPerComponent = linkDesc["BitsPerComponent"] as? Int,
                  let parsed = BitsPerComponent(numericBitDepth: bitsPerComponent) {
            bpc = parsed
        } else {
            logger.debug("No BitDepth in LinkDescription, defaulting to 8-bit")
            bpc = .bpc8
        }

        // Color range
        let colorRange: ColorRange
        if let rangeVal = linkDesc["Range"] as? Int {
            switch rangeVal {
            case 0: colorRange = .limited
            case 1: colorRange = .full
            default: colorRange = .full
            }
        } else {
            colorRange = .full
        }

        // Dynamic range (EOTF)
        let dynamicRange: DynamicRange
        if let eotfVal = linkDesc["EOTF"] as? Int {
            switch eotfVal {
            case 0: dynamicRange = .sdr
            case 1, 2: dynamicRange = .hdr10
            default: dynamicRange = .sdr
            }
        } else {
            dynamicRange = .sdr
        }

        let mode = ConnectionColorMode(
            pixelEncoding: pixelEncoding,
            bitsPerComponent: bpc,
            colorRange: colorRange,
            dynamicRange: dynamicRange
        )

        logger.info("Current connection mode from WindowServer: \(mode.description)")
        return mode
    }

    // MARK: - Private: Utilities

    /// Get the first Int value found under any of the given keys.
    private func firstIntValue(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let val = dict[key] as? Int {
                return val
            }
        }
        return nil
    }

    /// Get the first Double value found under any of the given keys.
    private func firstDoubleValue(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let val = dict[key] as? Double {
                return val
            }
            if let val = dict[key] as? Int {
                return Double(val)
            }
        }
        return nil
    }

    /// Remove duplicate modes from an array, preserving order.
    private func deduplicateModes(_ modes: [ConnectionColorMode]) -> [ConnectionColorMode] {
        var seen = Set<ConnectionColorMode>()
        var result: [ConnectionColorMode] = []

        for mode in modes {
            if seen.insert(mode).inserted {
                result.append(mode)
            }
        }

        return result
    }
}
