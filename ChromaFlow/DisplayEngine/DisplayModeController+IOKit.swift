//
//  DisplayModeController+IOKit.swift
//  ChromaFlow
//
//  IOKit extensions for enhanced display mode detection
//

import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics
import os.log

// MARK: - IOKit Integration

extension DisplayModeController {

    /// Enhanced display mode parsing using IOKit
    func parseDisplayModeWithIOKit(_ cgMode: CGDisplayMode, displayID: CGDirectDisplayID) -> DisplayMode? {
        let logger = Logger(subsystem: "com.chromaflow.display", category: "DisplayModeController.IOKit")

        // Get basic properties from CoreGraphics
        let width = cgMode.pixelWidth
        let height = cgMode.pixelHeight
        let refreshRate = cgMode.refreshRate

        // Try to get enhanced info from IOKit
        var displayInfo = DisplayIOKitInfo()

        if let service = getIOServiceForDisplay(displayID) {
            defer { IOObjectRelease(service) }

            // Get display properties
            displayInfo = extractDisplayInfo(from: service)

            // Try to match this CGDisplayMode with IOKit mode info
            if let modeInfo = findIOKitModeInfo(for: cgMode, service: service) {
                displayInfo.merge(with: modeInfo)
            }
        }

        // Determine encoding properties
        let bitDepth = displayInfo.bitDepth ?? 8
        let colorEncoding = displayInfo.colorEncoding ?? .rgb
        let range = displayInfo.range ?? .full
        let pixelEncoding = displayInfo.pixelEncoding

        logger.debug("Parsed mode: \(width)×\(height)@\(refreshRate)Hz, \(bitDepth)-bit \(colorEncoding.description) \(range.description)")

        return DisplayMode(
            cgMode: cgMode,
            bitDepth: bitDepth,
            colorEncoding: colorEncoding,
            range: range,
            refreshRate: refreshRate,
            resolution: DisplayMode.Resolution(width: width, height: height),
            pixelEncoding: pixelEncoding
        )
    }

    /// Get IOService for a display
    private func getIOServiceForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t? {
        var service: io_service_t = 0
        var iterator: io_iterator_t = 0

        // Create matching dictionary for displays
        let matching = IOServiceMatching("IODisplayConnect")

        // Get iterator for matching services
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }

        defer { IOObjectRelease(iterator) }

        // Iterate through services to find our display
        while case let nextService = IOIteratorNext(iterator), nextService != 0 {
            defer { IOObjectRelease(nextService) }

            // Check if this is our display by comparing vendor/model IDs
            if isServiceForDisplay(nextService, displayID: displayID) {
                service = nextService
                IOObjectRetain(service)
                break
            }
        }

        return service != 0 ? service : nil
    }

    /// Check if an IOService corresponds to a specific display
    private func isServiceForDisplay(_ service: io_service_t, displayID: CGDirectDisplayID) -> Bool {
        // Get display vendor and model from CGDisplay
        let cgVendor = CGDisplayVendorNumber(displayID)
        let cgModel = CGDisplayModelNumber(displayID)

        // Get vendor and model from IOService
        if let vendorID = getIOServiceProperty(service, key: "DisplayVendorID") as? Int,
           let productID = getIOServiceProperty(service, key: "DisplayProductID") as? Int {
            return UInt32(vendorID) == cgVendor && UInt32(productID) == cgModel
        }

        return false
    }

    /// Get a property from an IOService
    private func getIOServiceProperty(_ service: io_service_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    /// Extract display information from IOService
    private func extractDisplayInfo(from service: io_service_t) -> DisplayIOKitInfo {
        var info = DisplayIOKitInfo()

        // Check for HDR support
        if let hdrSupported = getIOServiceProperty(service, key: "HDRSupported") as? Bool {
            info.hdrSupported = hdrSupported
        }

        // Check for bit depth hints
        if let displayBPC = getIOServiceProperty(service, key: "DisplayBPC") as? Int {
            // BPC = Bits Per Component (per color channel)
            info.bitDepth = displayBPC * 3 / 3  // Simplified, actual may vary
        }

        // Check for color space info
        if let colorSpace = getIOServiceProperty(service, key: "ColorSpace") as? String {
            info.pixelEncoding = colorSpace
            info.colorEncoding = ColorEncoding(fromPixelEncoding: colorSpace)
        }

        return info
    }

    /// Find IOKit mode information for a CGDisplayMode
    private func findIOKitModeInfo(for cgMode: CGDisplayMode, service: io_service_t) -> DisplayIOKitInfo? {
        var info = DisplayIOKitInfo()

        // Try to get display modes from IOKit
        guard let modes = getIOServiceProperty(service, key: "IODisplayModes") as? [[String: Any]] else {
            return nil
        }

        let targetWidth = cgMode.pixelWidth
        let targetHeight = cgMode.pixelHeight
        let targetRefresh = cgMode.refreshRate

        // Find matching mode
        for mode in modes {
            guard let width = mode["Width"] as? Int,
                  let height = mode["Height"] as? Int else { continue }

            // Check if resolution matches
            if width == targetWidth && height == targetHeight {
                // Check refresh rate if available
                if let refresh = mode["RefreshRate"] as? Double,
                   abs(refresh - targetRefresh) < 0.1 {

                    // Extract mode properties
                    if let bpc = mode["BitsPerComponent"] as? Int {
                        info.bitDepth = bpc
                    }

                    if let pixelFormat = mode["PixelFormat"] as? String {
                        info.pixelEncoding = pixelFormat
                        parsePixelFormat(pixelFormat, into: &info)
                    }

                    if let colorModel = mode["ColorModel"] as? String {
                        info.colorEncoding = parseColorModel(colorModel)
                    }

                    return info
                }
            }
        }

        return nil
    }

    /// Parse pixel format string for encoding info
    private func parsePixelFormat(_ format: String, into info: inout DisplayIOKitInfo) {
        let lowercased = format.lowercased()

        // Check for bit depth
        if lowercased.contains("30") || lowercased.contains("10bit") {
            info.bitDepth = 10
        } else if lowercased.contains("36") || lowercased.contains("12bit") {
            info.bitDepth = 12
        } else if lowercased.contains("24") || lowercased.contains("8bit") {
            info.bitDepth = 8
        }

        // Check for color encoding
        if lowercased.contains("ycbcr") || lowercased.contains("ycrcb") {
            if lowercased.contains("420") {
                info.colorEncoding = .ycbcr420
            } else if lowercased.contains("422") {
                info.colorEncoding = .ycbcr422
            } else {
                info.colorEncoding = .ycbcr444
            }
        } else {
            info.colorEncoding = .rgb
        }

        // Check for range
        if lowercased.contains("full") || lowercased.contains("pc") {
            info.range = .full
        } else if lowercased.contains("limited") || lowercased.contains("tv") {
            info.range = .limited
        }
    }

    /// Parse color model string
    private func parseColorModel(_ model: String) -> ColorEncoding {
        switch model.lowercased() {
        case "rgb":
            return .rgb
        case "ycbcr", "ycrcb":
            return .ycbcr444
        default:
            return .rgb
        }
    }

    /// Container for IOKit display information
    private struct DisplayIOKitInfo {
        var bitDepth: Int?
        var colorEncoding: ColorEncoding?
        var range: RGBRange?
        var pixelEncoding: String?
        var hdrSupported: Bool?

        mutating func merge(with other: DisplayIOKitInfo) {
            bitDepth = other.bitDepth ?? bitDepth
            colorEncoding = other.colorEncoding ?? colorEncoding
            range = other.range ?? range
            pixelEncoding = other.pixelEncoding ?? pixelEncoding
            hdrSupported = other.hdrSupported ?? hdrSupported
        }
    }
}

// MARK: - Enhanced Public Methods

extension DisplayModeController {

    /// Get available modes with enhanced IOKit parsing
    public func availableModesEnhanced(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        logger.info("Enumerating display modes with IOKit enhancement for display \(displayID)")

        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            logger.error("Failed to get display modes for display \(displayID)")
            return []
        }

        let displayModes = allModes.compactMap { cgMode -> DisplayMode? in
            // Try enhanced parsing first, fall back to basic
            parseDisplayModeWithIOKit(cgMode, displayID: displayID) ?? parseDisplayMode(cgMode)
        }

        logger.info("Found \(displayModes.count) display modes with enhanced parsing")

        return displayModes
    }

    /// Get the current mode with enhanced IOKit parsing
    public func currentModeEnhanced(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else {
            logger.error("Failed to get current display mode for display \(displayID)")
            return nil
        }

        let mode = parseDisplayModeWithIOKit(cgMode, displayID: displayID) ?? parseDisplayMode(cgMode)

        if let mode = mode {
            logger.info("Current mode (enhanced): \(mode.description)")
        }

        return mode
    }

    /// Get detailed display capabilities
    public func displayCapabilities(for displayID: CGDirectDisplayID) -> DisplayCapabilities {
        var capabilities = DisplayCapabilities()

        // Get all available modes
        let modes = availableModesEnhanced(for: displayID)

        // Analyze capabilities
        capabilities.supports8Bit = modes.contains { $0.bitDepth == 8 }
        capabilities.supports10Bit = modes.contains { $0.bitDepth == 10 }
        capabilities.supports12Bit = modes.contains { $0.bitDepth == 12 }

        capabilities.supportsRGB = modes.contains { $0.colorEncoding == .rgb }
        capabilities.supportsYCbCr444 = modes.contains { $0.colorEncoding == .ycbcr444 }
        capabilities.supportsYCbCr422 = modes.contains { $0.colorEncoding == .ycbcr422 }
        capabilities.supportsYCbCr420 = modes.contains { $0.colorEncoding == .ycbcr420 }

        capabilities.supportsFullRange = modes.contains { $0.range == .full }
        capabilities.supportsLimitedRange = modes.contains { $0.range == .limited }

        // Check HDR from IOKit
        if let service = getIOServiceForDisplay(displayID) {
            defer { IOObjectRelease(service) }

            if let hdrSupported = getIOServiceProperty(service, key: "HDRSupported") as? Bool {
                capabilities.supportsHDR = hdrSupported
            }
        }

        // Get max refresh rate
        capabilities.maxRefreshRate = modes.map { $0.refreshRate }.max() ?? 60.0

        // Get supported resolutions
        capabilities.supportedResolutions = Array(Set(modes.map { $0.resolution }))
            .sorted { r1, r2 in
                if r1.width != r2.width { return r1.width > r2.width }
                return r1.height > r2.height
            }

        return capabilities
    }

    /// Display capabilities structure
    public struct DisplayCapabilities {
        public var supports8Bit = false
        public var supports10Bit = false
        public var supports12Bit = false

        public var supportsRGB = false
        public var supportsYCbCr444 = false
        public var supportsYCbCr422 = false
        public var supportsYCbCr420 = false

        public var supportsFullRange = false
        public var supportsLimitedRange = false

        public var supportsHDR = false
        public var maxRefreshRate: Double = 60.0

        public var supportedResolutions: [DisplayMode.Resolution] = []

        public var description: String {
            var features: [String] = []

            // Bit depths
            var bitDepths: [String] = []
            if supports8Bit { bitDepths.append("8-bit") }
            if supports10Bit { bitDepths.append("10-bit") }
            if supports12Bit { bitDepths.append("12-bit") }
            if !bitDepths.isEmpty {
                features.append("Bit Depth: \(bitDepths.joined(separator: ", "))")
            }

            // Color encodings
            var encodings: [String] = []
            if supportsRGB { encodings.append("RGB") }
            if supportsYCbCr444 { encodings.append("YCbCr 4:4:4") }
            if supportsYCbCr422 { encodings.append("YCbCr 4:2:2") }
            if supportsYCbCr420 { encodings.append("YCbCr 4:2:0") }
            if !encodings.isEmpty {
                features.append("Encodings: \(encodings.joined(separator: ", "))")
            }

            // Ranges
            var ranges: [String] = []
            if supportsFullRange { ranges.append("Full") }
            if supportsLimitedRange { ranges.append("Limited") }
            if !ranges.isEmpty {
                features.append("RGB Range: \(ranges.joined(separator: ", "))")
            }

            // HDR
            if supportsHDR {
                features.append("HDR: Supported")
            }

            // Refresh rate
            features.append(String(format: "Max Refresh: %.0f Hz", maxRefreshRate))

            // Resolutions
            if !supportedResolutions.isEmpty {
                let resStrings = supportedResolutions.prefix(3).map { $0.description }
                let resText = resStrings.joined(separator: ", ")
                let suffix = supportedResolutions.count > 3 ? " (+\(supportedResolutions.count - 3) more)" : ""
                features.append("Resolutions: \(resText)\(suffix)")
            }

            return features.joined(separator: "\n")
        }
    }
}