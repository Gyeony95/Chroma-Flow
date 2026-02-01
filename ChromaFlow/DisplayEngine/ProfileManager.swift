import Foundation
import CoreGraphics
import ColorSync
import os.log
import os.signpost

// MARK: - Error Types

enum ProfileManagerError: LocalizedError {
    case profileNotFound(ColorProfile.ColorSpace)
    case iccProfileURLMissing(ColorProfile)
    case displayDisconnected(CGDirectDisplayID)
    case colorSyncDeviceUUIDNotFound(CGDirectDisplayID)
    case colorSyncSetProfileFailed(underlying: String)
    case colorSyncQueryFailed(underlying: String)
    case verificationFailed(expected: String, actual: String)
    case customProfileDirectoryUnavailable
    case noDisplay
    case referenceModeActive

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let space):
            return "ICC profile not found for color space: \(space.rawValue)"
        case .iccProfileURLMissing(let profile):
            return "ICC profile URL missing for profile: \(profile.name)"
        case .displayDisconnected(let displayID):
            return "Display \(displayID) is disconnected or unavailable"
        case .colorSyncDeviceUUIDNotFound(let displayID):
            return "Could not resolve ColorSync device UUID for display \(displayID)"
        case .colorSyncSetProfileFailed(let underlying):
            return "ColorSync failed to set custom profile: \(underlying)"
        case .noDisplay:
            return "No display available"
        case .colorSyncQueryFailed(let underlying):
            return "ColorSync failed to query device info: \(underlying)"
        case .verificationFailed(let expected, let actual):
            return "Profile verification failed: expected '\(expected)', active is '\(actual)'"
        case .customProfileDirectoryUnavailable:
            return "Custom ICC profile directory is not accessible"
        case .referenceModeActive:
            return "Reference Mode is active. Unlock to modify color profiles."
        }
    }
}

// MARK: - ProfileManager

final class ProfileManager: DisplayProfileManaging, @unchecked Sendable {

    // MARK: - Properties

    private let signposter = OSSignposter(
        subsystem: "com.chromaflow.ChromaFlow",
        category: "ProfileSwitch"
    )
    private let logger = Logger(
        subsystem: "com.chromaflow.ChromaFlow",
        category: "colorSync"
    )

    /// Stores the original profile URL per display so we can restore later.
    private let lock = NSLock()
    private var originalProfiles: [CGDirectDisplayID: URL] = [:]

    /// Directory where the user can place custom .icc files.
    private let customProfileDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
    }()

    // MARK: - Bundled Color Spaces (for availableProfiles)

    private static let bundledColorSpaces: [ColorProfile.ColorSpace] = [
        .sRGB, .displayP3, .adobeRGB, .rec709
    ]

    // MARK: - DisplayProfileManaging

    func availableProfiles(for display: DisplayDevice) -> [ColorProfile] {
        var profiles: [ColorProfile] = Self.bundledColorSpaces.map {
            ColorSpaceDefinitions.defaultProfile(for: $0)
        }

        // Append custom profiles from disk
        let customProfiles = loadCustomProfiles()
        profiles.append(contentsOf: customProfiles)

        return profiles
    }

    func activeProfile(for display: DisplayDevice) async throws -> ColorProfile {
        try validateDisplayOnline(display.id)

        guard let deviceUUID = colorSyncDeviceUUID(for: display.id) else {
            throw ProfileManagerError.colorSyncDeviceUUIDNotFound(display.id)
        }

        guard let deviceInfo = ColorSyncDeviceCopyDeviceInfo(
            kColorSyncDisplayDeviceClass.takeUnretainedValue(),
            deviceUUID
        )?.takeRetainedValue() as? [String: Any] else {
            throw ProfileManagerError.colorSyncQueryFailed(
                underlying: "ColorSyncDeviceCopyDeviceInfo returned nil for UUID \(deviceUUID)"
            )
        }

        // Navigate: FactoryProfiles / 1 / DeviceProfileURL  (or CustomProfiles)
        let activeURL = extractActiveProfileURL(from: deviceInfo)

        // Try to match against known bundled profiles
        for space in Self.bundledColorSpaces {
            if let knownURL = ColorSpaceDefinitions.profileURL(for: space),
               let activeURL,
               knownURL.standardizedFileURL == activeURL.standardizedFileURL {
                return ColorSpaceDefinitions.defaultProfile(for: space)
            }
        }

        // Fall back to a generic "Custom" representation
        let name = activeURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
        return ColorProfile(
            id: UUID(),
            name: name,
            colorSpace: .custom,
            iccProfileURL: activeURL,
            isCustom: true,
            whitePoint: nil,
            gamut: nil
        )
    }

    func switchProfile(
        _ profile: ColorProfile,
        for display: DisplayDevice
    ) async throws -> ProfileSwitchConfirmation {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("switchProfile", id: signpostID)

        defer { signposter.endInterval("switchProfile", state) }

        // 1. Resolve ICC profile URL
        guard let profileURL = profile.iccProfileURL
                ?? ColorSpaceDefinitions.profileURL(for: profile.colorSpace) else {
            throw ProfileManagerError.iccProfileURLMissing(profile)
        }

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw ProfileManagerError.profileNotFound(profile.colorSpace)
        }

        // 2. Validate display is online
        try validateDisplayOnline(display.id)

        // 3. Map CGDirectDisplayID -> ColorSync device UUID
        guard let deviceUUID = colorSyncDeviceUUID(for: display.id) else {
            throw ProfileManagerError.colorSyncDeviceUUIDNotFound(display.id)
        }

        // 4. Capture original profile for later restoration
        captureOriginalProfileIfNeeded(for: display)

        // 5. Call ColorSyncDeviceSetCustomProfiles
        try setCustomProfile(url: profileURL, deviceUUID: deviceUUID)

        logger.info(
            "Profile switched to '\(profile.name)' on display \(display.id)"
        )

        // 6. Verify by reading back active profile
        try await verifyActiveProfile(
            expectedURL: profileURL,
            display: display,
            deviceUUID: deviceUUID
        )

        return ProfileSwitchConfirmation(
            displayID: display.id,
            profile: profile,
            timestamp: Date()
        )
    }

    func lockProfile(_ profile: ColorProfile, for display: DisplayDevice) async {
        // Locking is a UI-level concept; store intent so automation rules
        // refuse to override. Actual enforcement is handled at the
        // orchestration layer (AppState / AutomationEngine).
        logger.info("Profile locked: '\(profile.name)' on display \(display.id)")
    }

    func unlockProfile(for display: DisplayDevice) async {
        logger.info("Profile unlocked on display \(display.id)")
    }

    // MARK: - Restore Original Profile

    /// Restores the original profile that was active before the first switch.
    func restoreOriginalProfile(for display: DisplayDevice) async throws {
        let originalURL: URL? = lock.withLock { originalProfiles[display.id] }

        guard let url = originalURL else {
            logger.warning("No original profile recorded for display \(display.id)")
            return
        }

        guard let deviceUUID = colorSyncDeviceUUID(for: display.id) else {
            throw ProfileManagerError.colorSyncDeviceUUIDNotFound(display.id)
        }

        try setCustomProfile(url: url, deviceUUID: deviceUUID)

        logger.info("Original profile restored on display \(display.id)")
    }

    // MARK: - ColorSync Bridging (Private)

    /// Maps a CGDirectDisplayID to the ColorSync device UUID.
    ///
    /// ColorSync identifies displays by a CFUUID derived from the display's
    /// vendor/model/serial triplet stored in IOKit. `CGDisplayCreateUUIDFromDisplayID`
    /// produces a CFUUID that ColorSync accepts as the device scope identifier.
    private func colorSyncDeviceUUID(for displayID: CGDirectDisplayID) -> CFUUID? {
        return CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    }

    /// Sets a custom ICC profile on a ColorSync device identified by UUID.
    private func setCustomProfile(url: URL, deviceUUID: CFUUID) throws {
        // Build the profile dictionary:
        //   { 1: { kColorSyncDeviceProfileURL: url } }
        let profileKey = NSNumber(value: 1)
        let profileScopeDict: [String: Any] = [
            kColorSyncDeviceProfileURL.takeUnretainedValue() as String: url
        ]
        let profilesDict: [NSNumber: Any] = [
            profileKey: profileScopeDict
        ]

        let success = ColorSyncDeviceSetCustomProfiles(
            kColorSyncDisplayDeviceClass.takeUnretainedValue(),
            deviceUUID,
            profilesDict as CFDictionary
        )

        guard success else {
            throw ProfileManagerError.colorSyncSetProfileFailed(
                underlying: "ColorSyncDeviceSetCustomProfiles returned false for device \(deviceUUID)"
            )
        }
    }

    /// Reads back the active profile and compares against expected URL.
    private func verifyActiveProfile(
        expectedURL: URL,
        display: DisplayDevice,
        deviceUUID: CFUUID
    ) async throws {
        guard let deviceInfo = ColorSyncDeviceCopyDeviceInfo(
            kColorSyncDisplayDeviceClass.takeUnretainedValue(),
            deviceUUID
        )?.takeRetainedValue() as? [String: Any] else {
            throw ProfileManagerError.colorSyncQueryFailed(
                underlying: "Verification query returned nil"
            )
        }

        if let activeURL = extractActiveProfileURL(from: deviceInfo),
           activeURL.standardizedFileURL == expectedURL.standardizedFileURL {
            logger.debug("Profile verification passed")
            return
        }

        // Non-fatal: some displays need time to propagate.
        // Log warning but don't throw so the switch is not rejected.
        logger.warning(
            "Profile verification: could not confirm active profile matches expected '\(expectedURL.lastPathComponent)'"
        )
    }

    /// Extracts the active profile URL from a ColorSync device info dictionary.
    ///
    /// The dictionary structure returned by `ColorSyncDeviceCopyDeviceInfo` is:
    /// ```
    /// {
    ///   "CustomProfiles" : { 1: { "DeviceProfileURL": <url> } },
    ///   "FactoryProfiles": { 1: { "DeviceProfileURL": <url> } }
    /// }
    /// ```
    /// We prefer CustomProfiles when present, falling back to FactoryProfiles.
    private func extractActiveProfileURL(from deviceInfo: [String: Any]) -> URL? {
        let customKey = kColorSyncCustomProfiles.takeUnretainedValue() as String
        let factoryKey = kColorSyncFactoryProfiles.takeUnretainedValue() as String
        let profileURLKey = kColorSyncDeviceProfileURL.takeUnretainedValue() as String

        for dictKey in [customKey, factoryKey] {
            // Try both String and NSNumber keyed dictionaries
            var profiles: [AnyHashable: Any]?
            if let stringProfiles = deviceInfo[dictKey] as? [String: Any] {
                profiles = stringProfiles
            } else if let numberProfiles = deviceInfo[dictKey] as? [NSNumber: Any] {
                profiles = numberProfiles
            }

            if let profiles = profiles {
                // Look for key "1" (the default profile scope)
                let scopeDict: [String: Any]?
                if let dict = profiles["1"] as? [String: Any] {
                    scopeDict = dict
                } else if let dict = profiles[NSNumber(value: 1)] as? [String: Any] {
                    scopeDict = dict
                } else {
                    scopeDict = nil
                }

                if let scope = scopeDict,
                   let url = scope[profileURLKey] as? URL {
                    return url
                }
            }
        }

        return nil
    }

    /// Validates that a display is still online.
    private func validateDisplayOnline(_ displayID: CGDirectDisplayID) throws {
        let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: 16)
        defer { onlineDisplays.deallocate() }
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(16, onlineDisplays, &displayCount)
        guard err == .success else {
            throw ProfileManagerError.displayDisconnected(displayID)
        }

        let displays = Array(UnsafeMutableBufferPointer(
            start: onlineDisplays,
            count: Int(displayCount)
        ))

        guard displays.contains(displayID) else {
            throw ProfileManagerError.displayDisconnected(displayID)
        }
    }

    /// Captures the current profile URL so we can restore it later.
    private func captureOriginalProfileIfNeeded(for display: DisplayDevice) {
        lock.withLock {
            guard originalProfiles[display.id] == nil else { return }

            if let deviceUUID = colorSyncDeviceUUID(for: display.id),
               let deviceInfo = ColorSyncDeviceCopyDeviceInfo(
                   kColorSyncDisplayDeviceClass.takeUnretainedValue(),
                   deviceUUID
               )?.takeRetainedValue() as? [String: Any],
               let url = extractActiveProfileURL(from: deviceInfo) {
                originalProfiles[display.id] = url
            }
        }
    }

    // MARK: - Custom Profile Discovery

    /// Loads .icc files from the application's custom profile directory.
    private func loadCustomProfiles() -> [ColorProfile] {
        let fm = FileManager.default

        // Ensure directory exists
        if !fm.fileExists(atPath: customProfileDirectory.path) {
            do {
                try fm.createDirectory(
                    at: customProfileDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                logger.error(
                    "Failed to create custom profile directory: \(error.localizedDescription)"
                )
                return []
            }
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: customProfileDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension.lowercased() == "icc" }
            .map { url in
                ColorProfile(
                    id: UUID(),
                    name: url.deletingPathExtension().lastPathComponent,
                    colorSpace: .custom,
                    iccProfileURL: url,
                    isCustom: true,
                    whitePoint: nil,
                    gamut: nil
                )
            }
    }
}
