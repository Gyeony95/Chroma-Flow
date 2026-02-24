//
//  ConnectionModeController.swift
//  ChromaFlow
//
//  High-level controller that combines IORegistryReader and WindowServerPlistWriter
//  to read, convert, and apply display connection color modes on Apple Silicon Macs.
//

import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import os.log

// MARK: - ConnectionModeError

/// Errors specific to connection mode operations
public enum ConnectionModeError: LocalizedError {
    case plistReadFailed
    case plistBuildFailed
    case noCurrentCGMode

    public var errorDescription: String? {
        switch self {
        case .plistReadFailed:
            return "Failed to read the WindowServer displays plist"
        case .plistBuildFailed:
            return "Failed to build modified plist for the target display"
        case .noCurrentCGMode:
            return "Could not retrieve the current CGDisplayMode for the display"
        }
    }
}

// MARK: - ConnectionModeController

/// Combines IORegistry reading and WindowServer plist writing to provide a unified
/// interface for querying and changing display connection color modes.
///
/// On Apple Silicon Macs, RGB/YCbCr pixel encoding and color range are controlled
/// at the DCP firmware level and are not exposed through `CGDisplayCopyAllDisplayModes`.
/// This controller bridges the gap by:
/// 1. Reading available modes from the IORegistry (`IORegistryReader`)
/// 2. Reading/writing the active mode via the WindowServer plist (`WindowServerPlistWriter`)
/// 3. Converting between `ConnectionColorMode` and `DisplayModeController.DisplayMode`
public final class ConnectionModeController: Sendable {

    // MARK: - Properties

    private let ioRegistryReader = IORegistryReader()
    private let plistWriter = WindowServerPlistWriter()
    private let logger = Logger(subsystem: "com.chromaflow.display", category: "ConnectionModeController")

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Returns all connection color modes available for the given display.
    ///
    /// These modes represent the pixel encoding, bit depth, color range, and
    /// dynamic range combinations that the display connection supports.
    public func availableModes(for displayID: CGDirectDisplayID) -> [ConnectionColorMode] {
        ioRegistryReader.availableConnectionModes(for: displayID)
    }

    /// Returns the currently active connection color mode for a display.
    ///
    /// Reads from the WindowServer plist first (most accurate for the active session),
    /// then falls back to IORegistry parsing if the plist read fails.
    public func currentMode(for displayID: CGDirectDisplayID) -> ConnectionColorMode? {
        // Primary: read from WindowServer plist via LinkDescription
        if let linkDesc = plistWriter.readLinkDescription(for: displayID) {
            let mode = toConnectionColorMode(linkDesc)
            logger.info("Current mode from plist: \(mode.description)")
            return mode
        }

        // Fallback: read from IORegistry
        logger.info("Falling back to IORegistry for current mode")
        return ioRegistryReader.currentConnectionMode(for: displayID)
    }

    /// Apply a connection color mode to a display.
    ///
    /// Writes the `LinkDescription` entry for the target display in
    /// `/Library/Preferences/com.apple.windowserver.displays.plist` (requires
    /// administrator privileges) and then attempts to apply instantly via the
    /// `CoreDisplay_Display_SetLinkDescription` private API.
    ///
    /// - Returns: `true` if instant apply succeeded (no logout needed),
    ///   `false` if a logout/restart is required for the change to take effect.
    @discardableResult
    public func setMode(_ mode: ConnectionColorMode, for displayID: CGDirectDisplayID) async throws -> Bool {
        let linkDesc = toLinkDescription(mode)

        logger.info("Setting connection mode for display \(displayID): \(mode.description)")

        guard let originalPlist = plistWriter.readCurrentPlist() else {
            logger.error("Cannot read current WindowServer plist")
            throw ConnectionModeError.plistReadFailed
        }

        guard let modifiedPlist = plistWriter.buildModifiedPlist(
            original: originalPlist,
            displayID: displayID,
            linkDescription: linkDesc
        ) else {
            logger.error("Cannot build modified plist for display \(displayID)")
            throw ConnectionModeError.plistBuildFailed
        }

        try await plistWriter.writePlistWithPrivileges(modifiedPlist)
        logger.info("Successfully wrote plist for \(mode.description)")

        // Attempt instant apply via SkyLight private API
        let instantOK = instantApplyViaSkyLight(displayID: displayID, linkDesc: linkDesc)

        if !instantOK {
            // Fallback: force display reconnect via pmset sleep/wake cycle.
            // This causes the monitor to briefly disconnect and reconnect,
            // at which point WindowServer re-reads the plist.
            logger.info("SkyLight instant apply failed, falling back to display sleep/wake")
            await forceDisplayReconnect()
        }

        return instantOK
    }

    /// Convert available connection color modes into `DisplayModeController.DisplayMode` instances.
    ///
    /// Each `ConnectionColorMode` is paired with the current `CGDisplayMode` (resolution and
    /// refresh rate stay the same; only encoding, bit depth, and range vary).
    ///
    /// - Returns: An array of `DisplayMode` values, one per available connection color mode.
    ///   Returns an empty array if the current CGDisplayMode cannot be obtained.
    public func toDisplayModeArray(for displayID: CGDirectDisplayID) -> [DisplayModeController.DisplayMode] {
        let connectionModes = availableModes(for: displayID)

        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else {
            logger.error("Cannot get current CGDisplayMode for display \(displayID)")
            return []
        }

        let refreshRate = cgMode.refreshRate
        let resolution = DisplayModeController.DisplayMode.Resolution(
            width: cgMode.pixelWidth,
            height: cgMode.pixelHeight
        )

        return connectionModes.map { connectionMode in
            DisplayModeController.DisplayMode(
                cgMode: cgMode,
                bitDepth: connectionMode.bitsPerComponent.numericValue,
                colorEncoding: toColorEncoding(connectionMode.pixelEncoding),
                range: toRGBRange(connectionMode.colorRange),
                refreshRate: refreshRate,
                resolution: resolution,
                pixelEncoding: connectionMode.description
            )
        }
    }

    // MARK: - Instant Apply

    /// Attempt to apply display output mode instantly via SkyLight private APIs.
    ///
    /// Tries multiple approaches in order:
    /// 1. `SLSSetDisplayOutputMode` - standalone set (most promising)
    /// 2. `SLSConfigureDisplayOutputMode` within a transaction
    /// 3. Falls back to display sleep/wake via pmset
    ///
    /// Returns true if any approach triggered immediate mode change.
    private func instantApplyViaSkyLight(displayID: CGDirectDisplayID, linkDesc: LinkDescription) -> Bool {
        guard let skylight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            logger.warning("Could not load SkyLight.framework")
            return false
        }
        defer { dlclose(skylight) }

        // --- Approach 1: SLSSetDisplayOutputMode (standalone, no transaction) ---
        if let result = trySetDisplayOutputMode(skylight: skylight, displayID: displayID, linkDesc: linkDesc) {
            return result
        }

        // --- Approach 2: SLSConfigureDisplayOutputMode (transaction-based) ---
        if let result = tryConfigureDisplayOutputMode(skylight: skylight, displayID: displayID, linkDesc: linkDesc) {
            return result
        }

        logger.warning("All SkyLight instant-apply approaches failed")
        return false
    }

    /// Approach 1: Use `SLSSetDisplayOutputMode` with connection ID.
    /// Signature guess: (connectionID: Int32, displayID: UInt32, pixelEncoding: Int32, bitDepth: Int32, range: Int32, eotf: Int32) -> Int32
    private func trySetDisplayOutputMode(skylight: UnsafeMutableRawPointer, displayID: CGDirectDisplayID, linkDesc: LinkDescription) -> Bool? {
        guard let mainConnSym = dlsym(skylight, "SLSMainConnectionID"),
              let setOutputSym = dlsym(skylight, "SLSSetDisplayOutputMode") else {
            logger.info("SLSSetDisplayOutputMode not available")
            return nil
        }

        typealias MainConnFn = @convention(c) () -> Int32
        let getMainConn = unsafeBitCast(mainConnSym, to: MainConnFn.self)
        let connID = getMainConn()
        logger.info("SLSMainConnectionID = \(connID)")

        // Try with 4 output mode parameters: pixelEncoding, bitDepth, range, eotf
        typealias SetOutputModeFn = @convention(c) (Int32, UInt32, Int32, Int32, Int32, Int32) -> Int32
        let setOutputMode = unsafeBitCast(setOutputSym, to: SetOutputModeFn.self)

        let result = setOutputMode(
            connID,
            displayID,
            Int32(linkDesc.pixelEncoding),
            Int32(linkDesc.bitDepth),
            Int32(linkDesc.range),
            Int32(linkDesc.eotf)
        )

        logger.info("SLSSetDisplayOutputMode(\(connID), \(displayID), enc=\(linkDesc.pixelEncoding), bpc=\(linkDesc.bitDepth), range=\(linkDesc.range), eotf=\(linkDesc.eotf)) → \(result)")

        if result == 0 {
            logger.info("SLSSetDisplayOutputMode succeeded")
            return true
        }

        // Try alternative parameter order: pixelEncoding, range, bitDepth, eotf
        let result2 = setOutputMode(
            connID,
            displayID,
            Int32(linkDesc.pixelEncoding),
            Int32(linkDesc.range),
            Int32(linkDesc.bitDepth),
            Int32(linkDesc.eotf)
        )

        logger.info("SLSSetDisplayOutputMode (alt order: enc, range, bpc, eotf) → \(result2)")

        if result2 == 0 {
            logger.info("SLSSetDisplayOutputMode (alt order) succeeded")
            return true
        }

        return nil // Signal to try next approach
    }

    /// Approach 2: Use `SLSConfigureDisplayOutputMode` within a display configuration transaction.
    private func tryConfigureDisplayOutputMode(skylight: UnsafeMutableRawPointer, displayID: CGDirectDisplayID, linkDesc: LinkDescription) -> Bool? {
        guard let beginSym = dlsym(skylight, "SLSBeginDisplayConfiguration"),
              let outputModeSym = dlsym(skylight, "SLSConfigureDisplayOutputMode"),
              let completeSym = dlsym(skylight, "SLSCompleteDisplayConfiguration") else {
            logger.info("SLSConfigureDisplayOutputMode transaction APIs not available")
            return nil
        }

        typealias BeginConfigFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
        typealias ConfigOutputModeFn = @convention(c) (OpaquePointer, UInt32, Int32, Int32, Int32, Int32) -> Int32
        typealias CompleteConfigFn = @convention(c) (OpaquePointer, Int32) -> Int32

        let beginConfig = unsafeBitCast(beginSym, to: BeginConfigFn.self)
        let configOutputMode = unsafeBitCast(outputModeSym, to: ConfigOutputModeFn.self)
        let completeConfig = unsafeBitCast(completeSym, to: CompleteConfigFn.self)

        // Begin configuration transaction
        var configRef: OpaquePointer?
        let beginResult = beginConfig(&configRef)
        guard beginResult == 0, let config = configRef else {
            logger.error("SLSBeginDisplayConfiguration failed: \(beginResult)")
            return nil
        }

        // Configure output mode: pixelEncoding, range, bitDepth, eotf
        let configResult = configOutputMode(
            config,
            displayID,
            Int32(linkDesc.pixelEncoding),
            Int32(linkDesc.range),
            Int32(linkDesc.bitDepth),
            Int32(linkDesc.eotf)
        )

        logger.info("SLSConfigureDisplayOutputMode(\(displayID), enc=\(linkDesc.pixelEncoding), range=\(linkDesc.range), bpc=\(linkDesc.bitDepth), eotf=\(linkDesc.eotf)) → \(configResult)")

        // Complete configuration (option 2 = permanently)
        let completeResult = completeConfig(config, 2)
        logger.info("SLSCompleteDisplayConfiguration → \(completeResult)")

        if completeResult == 0 {
            logger.info("SkyLight transaction completed successfully")
            return true
        }

        return nil
    }

    /// Force display reconnect by putting displays to sleep then waking.
    ///
    /// Uses `pmset displaysleepnow` command which reliably triggers display sleep
    /// on all macOS versions. When displays wake, WindowServer re-reads the plist
    /// and re-negotiates the display link with updated settings.
    private func forceDisplayReconnect() async {
        logger.info("Forcing display reconnect via pmset sleep/wake")

        // Sleep displays via pmset (reliable across macOS versions)
        let sleepProcess = Process()
        sleepProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        sleepProcess.arguments = ["displaysleepnow"]
        do {
            try sleepProcess.run()
            sleepProcess.waitUntilExit()
            logger.info("pmset displaysleepnow exit code: \(sleepProcess.terminationStatus)")
        } catch {
            logger.error("pmset displaysleepnow failed: \(error.localizedDescription)")
            return
        }

        // Wait for display to sleep and link to drop
        try? await Task.sleep(for: .seconds(3))

        // Wake displays by simulating user activity (mouse move)
        let wakeEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 1, y: 1),
            mouseButton: .left
        )
        wakeEvent?.post(tap: .cghidEventTap)
        logger.info("Display wake requested via mouse event")

        // Also declare user activity as backup wake mechanism
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "ChromaFlow Display Mode Change" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )

        // Give time for wake
        try? await Task.sleep(for: .milliseconds(500))
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    // MARK: - Private Conversion Helpers

    /// Convert `PixelEncoding` to `DisplayModeController.ColorEncoding`.
    private func toColorEncoding(_ encoding: PixelEncoding) -> DisplayModeController.ColorEncoding {
        switch encoding {
        case .rgb444:   return .rgb
        case .ycbcr444: return .ycbcr444
        case .ycbcr422: return .ycbcr422
        case .ycbcr420: return .ycbcr420
        }
    }

    /// Convert `ColorRange` to `DisplayModeController.RGBRange`.
    private func toRGBRange(_ range: ColorRange) -> DisplayModeController.RGBRange {
        switch range {
        case .full:    return .full
        case .limited: return .limited
        }
    }

    /// Convert a `ConnectionColorMode` to a `LinkDescription` for plist writing.
    ///
    /// The plist `PixelEncoding` field only distinguishes RGB (0) vs YCbCr (1);
    /// the specific YCbCr subsampling variant is not stored in the plist.
    private func toLinkDescription(_ mode: ConnectionColorMode) -> LinkDescription {
        let pixelEncoding: Int
        switch mode.pixelEncoding {
        case .rgb444:
            pixelEncoding = 0
        case .ycbcr444, .ycbcr422, .ycbcr420:
            pixelEncoding = 1
        }

        let range: Int
        switch mode.colorRange {
        case .limited: range = 0
        case .full:    range = 1
        }

        let eotf: Int
        switch mode.dynamicRange {
        case .sdr:   eotf = 0
        case .hdr10: eotf = 2
        }

        return LinkDescription(
            pixelEncoding: pixelEncoding,
            range: range,
            bitDepth: mode.bitsPerComponent.numericValue,
            eotf: eotf
        )
    }

    /// Convert a `LinkDescription` from the plist back to a `ConnectionColorMode`.
    private func toConnectionColorMode(_ linkDesc: LinkDescription) -> ConnectionColorMode {
        let pixelEncoding: PixelEncoding
        switch linkDesc.pixelEncoding {
        case 0:  pixelEncoding = .rgb444
        case 1:  pixelEncoding = .ycbcr444   // Plist doesn't distinguish YCbCr subsampling
        default: pixelEncoding = .rgb444
        }

        let bpc = BitsPerComponent(numericBitDepth: linkDesc.bitDepth) ?? .bpc8

        let colorRange: ColorRange
        switch linkDesc.range {
        case 0:  colorRange = .limited
        case 1:  colorRange = .full
        default: colorRange = .full
        }

        let dynamicRange: DynamicRange
        switch linkDesc.eotf {
        case 0:      dynamicRange = .sdr
        case 1, 2:   dynamicRange = .hdr10
        default:     dynamicRange = .sdr
        }

        return ConnectionColorMode(
            pixelEncoding: pixelEncoding,
            bitsPerComponent: bpc,
            colorRange: colorRange,
            dynamicRange: dynamicRange
        )
    }
}
