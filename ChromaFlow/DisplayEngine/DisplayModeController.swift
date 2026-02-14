//
//  DisplayModeController.swift
//  ChromaFlow
//
//  Created on 2/1/26.
//

import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics
import os.log

/// Controls display pixel format and RGB range using CoreGraphics APIs
public final class DisplayModeController: @unchecked Sendable {

    // MARK: - Types

    /// Represents a display mode with encoding information
    public struct DisplayMode: Equatable, Hashable, @unchecked Sendable {
        public let cgMode: CGDisplayMode
        public let bitDepth: Int
        public let colorEncoding: ColorEncoding
        public let range: RGBRange
        public let refreshRate: Double
        public let resolution: Resolution
        public let pixelEncoding: String?

        public struct Resolution: Equatable, Hashable, Sendable {
            public let width: Int
            public let height: Int

            public var description: String {
                "\(width)×\(height)"
            }
        }

        public var description: String {
            var components = [resolution.description]

            if refreshRate > 0 {
                components.append(String(format: "%.0fHz", refreshRate))
            }

            components.append("\(bitDepth)-bit")
            components.append(colorEncoding.description)
            components.append(range.description)

            if let encoding = pixelEncoding {
                components.append("(\(encoding))")
            }

            return components.joined(separator: " ")
        }

        /// Check if this mode has the same resolution and refresh rate as another
        public func hasSameTimingAs(_ other: DisplayMode) -> Bool {
            resolution == other.resolution &&
            abs(refreshRate - other.refreshRate) < 0.01
        }

        // Manual Equatable - compare by properties, not cgMode reference
        public static func == (lhs: DisplayMode, rhs: DisplayMode) -> Bool {
            lhs.bitDepth == rhs.bitDepth &&
            lhs.colorEncoding == rhs.colorEncoding &&
            lhs.range == rhs.range &&
            lhs.refreshRate == rhs.refreshRate &&
            lhs.resolution == rhs.resolution &&
            lhs.pixelEncoding == rhs.pixelEncoding
        }

        // Manual Hashable - hash by properties, not cgMode reference
        public func hash(into hasher: inout Hasher) {
            hasher.combine(bitDepth)
            hasher.combine(colorEncoding)
            hasher.combine(range)
            hasher.combine(refreshRate)
            hasher.combine(resolution)
            hasher.combine(pixelEncoding)
        }
    }

    /// Color encoding format
    public enum ColorEncoding: String, CaseIterable, Sendable {
        case rgb = "RGB"
        case ycbcr444 = "YCbCr 4:4:4"
        case ycbcr422 = "YCbCr 4:2:2"
        case ycbcr420 = "YCbCr 4:2:0"

        var description: String { rawValue }

        init(fromPixelEncoding encoding: String) {
            let lowercased = encoding.lowercased()

            if lowercased.contains("ycbcr") || lowercased.contains("ycrcb") {
                if lowercased.contains("420") {
                    self = .ycbcr420
                } else if lowercased.contains("422") {
                    self = .ycbcr422
                } else if lowercased.contains("444") {
                    self = .ycbcr444
                } else {
                    self = .ycbcr444 // Default YCbCr
                }
            } else {
                self = .rgb
            }
        }
    }

    /// RGB range
    public enum RGBRange: String, CaseIterable, Sendable {
        case full = "Full (0-255)"
        case limited = "Limited (16-235)"
        case auto = "Auto"

        var description: String { rawValue }

        init(fromPixelEncoding encoding: String, bitDepth: Int) {
            let lowercased = encoding.lowercased()

            // Check for explicit range indicators
            if lowercased.contains("full") || lowercased.contains("pc") {
                self = .full
            } else if lowercased.contains("limited") || lowercased.contains("tv") {
                self = .limited
            } else if bitDepth > 8 {
                // HDR modes typically use limited range
                self = .limited
            } else {
                // Default to auto/full for RGB
                self = .auto
            }
        }
    }

    public enum DisplayModeError: LocalizedError {
        case modeNotSupported
        case modeChangeFailed(CGError)
        case displayNotFound
        case permissionDenied
        case invalidConfiguration

        public var errorDescription: String? {
            switch self {
            case .modeNotSupported:
                return "Display mode is not supported by this display"
            case .modeChangeFailed(let error):
                return "Failed to change display mode: \(error)"
            case .displayNotFound:
                return "Display not found"
            case .permissionDenied:
                return "Permission denied to change display settings"
            case .invalidConfiguration:
                return "Invalid display configuration"
            }
        }
    }

    // MARK: - Properties

    internal let logger = Logger(subsystem: "com.chromaflow.display", category: "DisplayModeController")

    // MARK: - Initialization

    public init() {
        logger.info("DisplayModeController initialized")
    }

    // MARK: - Public Methods

    /// Get all available display modes for a display
    public func availableModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        logger.info("Enumerating display modes for display \(displayID)")

        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            logger.error("Failed to get display modes for display \(displayID)")
            return []
        }

        let displayModes = allModes.compactMap { cgMode -> DisplayMode? in
            parseDisplayMode(cgMode)
        }

        logger.info("Found \(displayModes.count) display modes")

        // Log unique mode configurations
        let uniqueEncodings = Set(displayModes.map { "\($0.bitDepth)-bit \($0.colorEncoding.description) \($0.range.description)" })
        for encoding in uniqueEncodings.sorted() {
            logger.debug("Available encoding: \(encoding)")
        }

        return displayModes
    }

    /// Get display modes with the same timing (resolution/refresh) but different encodings
    public func encodingVariants(for displayID: CGDirectDisplayID, matchingCurrent: Bool = true) -> [DisplayMode] {
        let allModes = availableModes(for: displayID)

        guard let referenceMode = matchingCurrent ? currentMode(for: displayID) : allModes.first else {
            return allModes
        }

        let variants = allModes.filter { mode in
            mode.hasSameTimingAs(referenceMode)
        }

        logger.info("Found \(variants.count) encoding variants for \(referenceMode.resolution.description) @ \(referenceMode.refreshRate)Hz")

        return variants.sorted { mode1, mode2 in
            // Sort by: RGB before YCbCr, higher bit depth first, full range before limited
            if mode1.colorEncoding == .rgb && mode2.colorEncoding != .rgb { return true }
            if mode1.colorEncoding != .rgb && mode2.colorEncoding == .rgb { return false }
            if mode1.bitDepth != mode2.bitDepth { return mode1.bitDepth > mode2.bitDepth }
            if mode1.range == .full && mode2.range != .full { return true }
            return false
        }
    }

    /// Get the current display mode
    public func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else {
            logger.error("Failed to get current display mode for display \(displayID)")
            return nil
        }

        let mode = parseDisplayMode(cgMode)

        if let mode = mode {
            logger.info("Current mode: \(mode.description)")
        }

        return mode
    }

    /// Set a new display mode
    public func setMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) throws {
        logger.info("Attempting to set display mode: \(mode.description)")

        // Validate the mode is supported
        let supportedModes = availableModes(for: displayID)
        guard supportedModes.contains(where: { $0 == mode }) else {
            logger.error("Mode not supported: \(mode.description)")
            throw DisplayModeError.modeNotSupported
        }

        // Get current mode for comparison
        let currentMode = self.currentMode(for: displayID)
        if let current = currentMode, current == mode {
            logger.info("Mode is already active, no change needed")
            return
        }

        // Create display configuration
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, let config = config else {
            logger.error("Failed to begin display configuration: \(beginResult.rawValue)")
            throw DisplayModeError.invalidConfiguration
        }

        defer {
            CGCancelDisplayConfiguration(config)
        }

        // Configure the display mode change
        let configResult = CGConfigureDisplayWithDisplayMode(config, displayID, mode.cgMode, nil)
        guard configResult == .success else {
            logger.error("Failed to configure display mode: \(configResult.rawValue)")
            throw DisplayModeError.modeChangeFailed(configResult)
        }

        // Apply the configuration
        let applyResult = CGCompleteDisplayConfiguration(config, .permanently)
        guard applyResult == .success else {
            logger.error("Failed to apply display configuration: \(applyResult.rawValue)")
            throw DisplayModeError.modeChangeFailed(applyResult)
        }

        logger.info("Successfully changed display mode to: \(mode.description)")

        // Verify the change
        if let newMode = self.currentMode(for: displayID) {
            if newMode != mode {
                logger.warning("Mode change verification failed - expected \(mode.description), got \(newMode.description)")
            }
        }
    }

    /// Find a mode matching specific criteria
    public func findMode(
        for displayID: CGDirectDisplayID,
        bitDepth: Int? = nil,
        colorEncoding: ColorEncoding? = nil,
        range: RGBRange? = nil,
        matchCurrentTiming: Bool = true
    ) -> DisplayMode? {

        let modes = matchCurrentTiming ?
            encodingVariants(for: displayID, matchingCurrent: true) :
            availableModes(for: displayID)

        return modes.first { mode in
            if let bitDepth = bitDepth, mode.bitDepth != bitDepth { return false }
            if let colorEncoding = colorEncoding, mode.colorEncoding != colorEncoding { return false }
            if let range = range, mode.range != range { return false }
            return true
        }
    }

    // MARK: - Private Methods

    internal func parseDisplayMode(_ cgMode: CGDisplayMode) -> DisplayMode? {
        let width = cgMode.pixelWidth
        let height = cgMode.pixelHeight
        let refreshRate = cgMode.refreshRate

        // Get pixel encoding string if available
        let pixelEncoding = extractPixelEncoding(from: cgMode)

        // Parse bit depth from IOKit properties or pixel encoding
        let bitDepth = extractBitDepth(from: cgMode, pixelEncoding: pixelEncoding)

        // Determine color encoding and range
        let colorEncoding = pixelEncoding.map(ColorEncoding.init(fromPixelEncoding:)) ?? .rgb
        let range = pixelEncoding.map { RGBRange(fromPixelEncoding: $0, bitDepth: bitDepth) } ?? .full

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

    private func extractPixelEncoding(from mode: CGDisplayMode) -> String? {
        // Try to get pixel encoding from IOKit
        // This requires accessing the IODisplayModeID and querying IOKit

        guard let modeID = mode.iODisplayModeID else { return nil }

        // The pixel encoding is typically in the mode's IOKit properties
        // For now, we'll use a heuristic based on common patterns

        // CGDisplayMode doesn't expose description in public API
        // Would need IOKit queries via modeID to get pixel encoding details

        return nil
    }

    private func extractBitDepth(from mode: CGDisplayMode, pixelEncoding: String?) -> Int {
        // Try to get bit depth from IOKit bitsPerPixel
        // CoreGraphics doesn't directly expose bit depth

        // Use heuristics based on pixel encoding
        if let encoding = pixelEncoding?.lowercased() {
            if encoding.contains("10") || encoding.contains("30bit") {
                return 10
            } else if encoding.contains("12") || encoding.contains("36bit") {
                return 12
            } else if encoding.contains("16") || encoding.contains("48bit") {
                return 16
            }
        }

        // Default to 8-bit
        return 8
    }

    private func parseEncodingFromDescription(_ description: String) -> String? {
        // Parse encoding hints from mode description
        // This is a fallback when IOKit properties aren't accessible

        let patterns = [
            "RGB", "YCbCr", "4:4:4", "4:2:2", "4:2:0",
            "Full", "Limited", "PC", "TV",
            "8-bit", "10-bit", "12-bit", "HDR", "SDR"
        ]

        var foundPatterns: [String] = []
        for pattern in patterns {
            if description.localizedCaseInsensitiveContains(pattern) {
                foundPatterns.append(pattern)
            }
        }

        return foundPatterns.isEmpty ? nil : foundPatterns.joined(separator: " ")
    }
}

// MARK: - CGDisplayMode Extensions

extension CGDisplayMode {
    /// Try to get the IODisplayModeID for IOKit queries
    var iODisplayModeID: Int32? {
        // This would need to be extracted from the CGDisplayMode's opaque data
        // For now, return nil as a placeholder
        return nil
    }
}

// MARK: - Convenience Methods

extension DisplayModeController {

    /// Switch to 8-bit SDR RGB mode
    public func setSSDRMode(for displayID: CGDirectDisplayID) throws {
        guard let mode = findMode(
            for: displayID,
            bitDepth: 8,
            colorEncoding: .rgb,
            range: .full
        ) else {
            throw DisplayModeError.modeNotSupported
        }

        try setMode(mode, for: displayID)
    }

    /// Switch to 10-bit HDR mode
    public func setHDRMode(for displayID: CGDirectDisplayID) throws {
        guard let mode = findMode(
            for: displayID,
            bitDepth: 10,
            colorEncoding: .rgb,
            range: .limited
        ) else {
            throw DisplayModeError.modeNotSupported
        }

        try setMode(mode, for: displayID)
    }

    /// Toggle between full and limited RGB range
    public func toggleRGBRange(for displayID: CGDirectDisplayID) throws {
        guard let current = currentMode(for: displayID) else {
            throw DisplayModeError.displayNotFound
        }

        let targetRange: RGBRange = current.range == .full ? .limited : .full

        guard let mode = findMode(
            for: displayID,
            bitDepth: current.bitDepth,
            colorEncoding: current.colorEncoding,
            range: targetRange
        ) else {
            throw DisplayModeError.modeNotSupported
        }

        try setMode(mode, for: displayID)
    }
}