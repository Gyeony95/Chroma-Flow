//
//  WindowServerPlistWriter.swift
//  ChromaFlow
//
//  Created on 2/23/26.
//

import Foundation
import CoreGraphics
import ColorSync
import Security
import os.log

// MARK: - LinkDescription

/// Describes the display link configuration stored in WindowServer plist
public struct LinkDescription: Codable, Sendable, Equatable {
    public var pixelEncoding: Int  // 0=RGB, 1=YCbCr
    public var range: Int          // 0=Limited, 1=Full
    public var bitDepth: Int       // 8 or 10
    public var eotf: Int           // 0=SDR

    public init(pixelEncoding: Int, range: Int, bitDepth: Int, eotf: Int) {
        self.pixelEncoding = pixelEncoding
        self.range = range
        self.bitDepth = bitDepth
        self.eotf = eotf
    }
}

// MARK: - WindowServerPlistError

/// Errors that can occur when reading or writing the WindowServer displays plist
public enum WindowServerPlistError: LocalizedError {
    case plistNotFound
    case displayNotFound
    case invalidStructure
    case writeFailed(String)
    case privilegeEscalationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .plistNotFound:
            return "WindowServer displays plist not found at expected path"
        case .displayNotFound:
            return "Could not find the specified display in the WindowServer plist"
        case .invalidStructure:
            return "WindowServer plist has an unexpected structure"
        case .writeFailed(let reason):
            return "Failed to write WindowServer plist: \(reason)"
        case .privilegeEscalationFailed(let reason):
            return "Failed to obtain administrator privileges: \(reason)"
        }
    }
}

// MARK: - DisplayEntryLocation

/// Describes the location of a display config entry within the WindowServer plist.
///
/// The plist structure is:
/// ```
/// Root
/// +-- "DisplayAnyUserSets" (or "DisplaySets"): {    // dict
/// |   +-- "Configs": [                               // array of config groups
/// |   |   +-- {
/// |   |       +-- "DisplayConfig": [                 // array of display configs
/// |   |           +-- { "UUID": "...", "LinkDescription": {...}, ... }
/// |   |           +-- { "UUID": "...", ... }
/// |   |       ]
/// |   |   }
/// |   ]
/// }
/// ```
public struct DisplayEntryLocation {
    /// Top-level key: "DisplayAnyUserSets" or "DisplaySets"
    let sectionKey: String
    /// Index into the "Configs" array
    let configsIndex: Int
    /// Index into the "DisplayConfig" array within a Configs element
    let displayConfigIndex: Int
}

// MARK: - WindowServerPlistWriter

/// Reads and writes the WindowServer display settings plist to change
/// display connection mode (RGB/YCbCr, Full/Limited range, etc.) on Apple Silicon Macs.
///
/// The plist lives at `/Library/Preferences/com.apple.windowserver.displays.plist`
/// and has two main sections: `DisplayAnyUserSets` and `DisplaySets`, both dicts
/// containing a `Configs` array of config groups, each with a `DisplayConfig` array
/// of individual display entries identified by UUID.
public final class WindowServerPlistWriter: @unchecked Sendable {

    // MARK: - Constants

    public static let plistPath = "/Library/Preferences/com.apple.windowserver.displays.plist"

    /// Top-level section keys to search within the plist, in priority order.
    private static let sectionKeys = ["DisplayAnyUserSets", "DisplaySets"]

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.chromaflow.display", category: "WindowServerPlistWriter")

    /// Cached authorization reference for privileged file operations.
    /// Once the user authenticates, this ref is reused for the rest of the session.
    private var cachedAuthRef: AuthorizationRef?
    private let authLock = NSLock()

    // MARK: - Initialization

    public init() {}

    // MARK: - Reading

    /// Read the current WindowServer displays plist as a dictionary.
    /// No elevated permissions are needed for reading.
    public func readCurrentPlist() -> [String: Any]? {
        guard let dict = NSDictionary(contentsOfFile: Self.plistPath) as? [String: Any] else {
            logger.warning("Could not read plist at \(Self.plistPath)")
            return nil
        }
        logger.debug("Successfully read WindowServer plist")
        return dict
    }

    /// Find the display entry location within the plist for a given display ID.
    ///
    /// The plist structure uses UUIDs to identify displays. This method converts the
    /// `CGDirectDisplayID` to its UUID via `CGDisplayCreateUUIDFromDisplayID` and searches
    /// through `DisplayAnyUserSets.Configs[n].DisplayConfig[m]` and
    /// `DisplaySets.Configs[n].DisplayConfig[m]` to find a matching entry.
    ///
    /// If UUID matching fails, falls back to finding the first display config entry
    /// that contains a `LinkDescription` key (only external displays have this key).
    ///
    /// - Returns: A `DisplayEntryLocation` if found, nil otherwise.
    public func findDisplayEntry(
        in plist: [String: Any],
        displayID: CGDirectDisplayID
    ) -> DisplayEntryLocation? {
        let targetUUID = displayUUIDString(for: displayID)
        logger.debug("Searching for display UUID=\(targetUUID ?? "nil") (displayID=\(displayID))")

        // Pass 1: Try UUID matching across all sections
        if let uuid = targetUUID {
            for sectionKey in Self.sectionKeys {
                if let location = findByUUID(uuid, in: plist, sectionKey: sectionKey) {
                    logger.info("Found display by UUID in \(sectionKey) configs[\(location.configsIndex)] displayConfig[\(location.displayConfigIndex)]")
                    return location
                }
            }
        }

        // Pass 2: Fallback — find first entry with LinkDescription (external display marker)
        logger.debug("UUID match failed, falling back to LinkDescription presence heuristic")
        for sectionKey in Self.sectionKeys {
            if let location = findByLinkDescriptionPresence(in: plist, sectionKey: sectionKey) {
                logger.info("Found display by LinkDescription presence in \(sectionKey) configs[\(location.configsIndex)] displayConfig[\(location.displayConfigIndex)]")
                return location
            }
        }

        logger.warning("Display not found in plist")
        return nil
    }

    /// Read the current `LinkDescription` for a display from the WindowServer plist.
    ///
    /// `LinkDescription` is a sibling of `CurrentInfo` and `UUID` within a display config
    /// entry, not nested inside `CurrentInfo`.
    public func readLinkDescription(for displayID: CGDirectDisplayID) -> LinkDescription? {
        guard let plist = readCurrentPlist() else {
            logger.error("Failed to read plist for LinkDescription")
            return nil
        }

        guard let location = findDisplayEntry(in: plist, displayID: displayID) else {
            logger.error("Display entry not found for LinkDescription")
            return nil
        }

        guard let displayConfig = resolveDisplayConfig(in: plist, at: location) else {
            logger.error("Could not resolve display config at location")
            return nil
        }

        // LinkDescription is a direct child of the display config entry, NOT inside CurrentInfo
        guard let linkDict = displayConfig["LinkDescription"] as? [String: Any] else {
            logger.warning("No LinkDescription found in display config entry")
            return nil
        }

        guard let pixelEncoding = linkDict["PixelEncoding"] as? Int,
              let range = linkDict["Range"] as? Int,
              let bitDepth = linkDict["BitDepth"] as? Int,
              let eotf = linkDict["EOTF"] as? Int else {
            logger.warning("LinkDescription has missing or unexpected fields")
            return nil
        }

        let desc = LinkDescription(
            pixelEncoding: pixelEncoding,
            range: range,
            bitDepth: bitDepth,
            eotf: eotf
        )
        logger.info("Read LinkDescription: encoding=\(pixelEncoding) range=\(range) depth=\(bitDepth) eotf=\(eotf)")
        return desc
    }

    // MARK: - Modification

    /// Build a modified copy of the plist with updated `LinkDescription` values for the given display.
    ///
    /// Updates the display entry in both `DisplayAnyUserSets` and `DisplaySets` if present.
    /// Returns nil if the display or expected structure cannot be found.
    public func buildModifiedPlist(
        original: [String: Any],
        displayID: CGDirectDisplayID,
        linkDescription: LinkDescription
    ) -> [String: Any]? {
        // Deep copy the plist to avoid mutating the original
        guard var copied = deepCopyPlist(original) else {
            logger.error("Failed to deep copy plist")
            return nil
        }

        let targetUUID = displayUUIDString(for: displayID)
        var updatedAtLeastOne = false

        // Update in every section where this display appears
        for sectionKey in Self.sectionKeys {
            let locations = findAllLocations(for: targetUUID, in: copied, sectionKey: sectionKey)

            for location in locations {
                if updateLinkDescription(in: &copied, at: location, with: linkDescription) {
                    updatedAtLeastOne = true
                    logger.debug("Updated LinkDescription in \(sectionKey) configs[\(location.configsIndex)] displayConfig[\(location.displayConfigIndex)]")
                }
            }
        }

        guard updatedAtLeastOne else {
            logger.error("Display not found in any section of the plist")
            return nil
        }

        logger.info("Built modified plist with encoding=\(linkDescription.pixelEncoding) range=\(linkDescription.range) depth=\(linkDescription.bitDepth)")
        return copied
    }

    // MARK: - Authorization

    /// Acquire administrator authorization, prompting the user if needed.
    /// If already authorized, returns the cached reference immediately.
    private func acquireAuthorization() throws -> AuthorizationRef {
        authLock.lock()
        defer { authLock.unlock() }

        if let existing = cachedAuthRef {
            return existing
        }

        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else {
            throw WindowServerPlistError.privilegeEscalationFailed(
                "AuthorizationCreate failed with status \(status)"
            )
        }

        // Request admin rights — this is what triggers the password dialog.
        // Use withCString / withUnsafeMutablePointer to satisfy pointer lifetime requirements.
        let rightName = kAuthorizationRightExecute
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]

        status = rightName.withCString { cName in
            var item = AuthorizationItem(
                name: cName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }

        guard status == errAuthorizationSuccess else {
            AuthorizationFree(auth, [])
            if status == errAuthorizationCanceled {
                throw WindowServerPlistError.privilegeEscalationFailed(
                    "User cancelled the authorization dialog"
                )
            }
            throw WindowServerPlistError.privilegeEscalationFailed(
                "AuthorizationCopyRights failed with status \(status)"
            )
        }

        cachedAuthRef = auth
        logger.info("Successfully acquired administrator authorization (cached for session)")
        return auth
    }

    /// Invalidate the cached authorization. The next write will prompt the user again.
    public func invalidateAuthorization() {
        authLock.lock()
        defer { authLock.unlock() }

        if let auth = cachedAuthRef {
            AuthorizationFree(auth, [.destroyRights])
            cachedAuthRef = nil
            logger.debug("Invalidated cached authorization")
        }
    }

    deinit {
        if let auth = cachedAuthRef {
            AuthorizationFree(auth, [])
        }
    }

    // MARK: - Writing

    /// Write the modified plist to the WindowServer path using administrator privileges.
    ///
    /// The plist is first written to a temporary file, then copied to the protected
    /// system path using a cached `AuthorizationRef`. The user is only prompted for
    /// their password once per app session; subsequent writes reuse the cached authorization.
    ///
    /// Uses `AuthorizationExecuteWithPrivileges` which is deprecated since macOS 10.7
    /// but remains functional on all current macOS versions. The modern replacement
    /// (SMAppService privileged helper) requires an XPC service bundle and entitlements,
    /// which is overkill for occasional file writes.
    public func writePlistWithPrivileges(_ plist: [String: Any]) async throws {
        let tempPath = NSTemporaryDirectory() + "chromaflow_ws_\(UUID().uuidString).plist"

        // Write to temp file
        let nsDict = plist as NSDictionary
        guard nsDict.write(toFile: tempPath, atomically: true) else {
            throw WindowServerPlistError.writeFailed("Failed to write temporary plist to \(tempPath)")
        }
        logger.debug("Wrote temporary plist to \(tempPath)")

        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            logger.debug("Cleaned up temporary plist")
        }

        // Acquire (or reuse cached) authorization
        let auth = try acquireAuthorization()

        // Execute the privileged copy using the cached authorization.
        // AuthorizationExecuteWithPrivileges is removed from Swift headers
        // but still exists in the Security framework binary. We load it via dlsym.
        try executePrivilegedCopy(auth: auth, source: tempPath, destination: Self.plistPath)

        // Wait a moment for the cp to complete
        try await Task.sleep(for: .milliseconds(100))

        logger.info("Successfully wrote WindowServer plist with administrator privileges")
    }

    // MARK: - Private Helpers — Privileged Execution

    /// Function signature for `AuthorizationExecuteWithPrivileges`.
    /// The function is removed from Swift headers on macOS 26+ but still exists in the
    /// Security framework binary. We load it via `dlsym` to avoid the compilation error.
    private typealias AuthExecFunc = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,       // pathToTool
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,  // arguments
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?  // communicationsPipe
    ) -> OSStatus

    /// Execute a privileged file copy using the cached `AuthorizationRef`.
    ///
    /// Loads `AuthorizationExecuteWithPrivileges` at runtime via `dlsym` since the
    /// function is still present in the Security framework dylib but is no longer
    /// exposed in Swift headers. This is the same technique used by Homebrew,
    /// Sparkle, and many other macOS apps.
    private func executePrivilegedCopy(auth: AuthorizationRef, source: String, destination: String) throws {
        // Load AuthorizationExecuteWithPrivileges from the Security framework at runtime
        guard let securityFramework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let funcPtr = dlsym(securityFramework, "AuthorizationExecuteWithPrivileges") else {
            throw WindowServerPlistError.privilegeEscalationFailed(
                "Failed to load AuthorizationExecuteWithPrivileges from Security framework"
            )
        }
        let authExec = unsafeBitCast(funcPtr, to: AuthExecFunc.self)

        let cpPath = "/bin/cp"

        // Build null-terminated C argument array
        let arg0 = strdup(source)!
        let arg1 = strdup(destination)!
        defer {
            free(arg0)
            free(arg1)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
        var pipe: UnsafeMutablePointer<FILE>?

        let status = argv.withUnsafeMutableBufferPointer { buffer in
            cpPath.withCString { toolPath in
                authExec(auth, toolPath, [], buffer.baseAddress!, &pipe)
            }
        }

        if let pipe = pipe {
            fclose(pipe)
        }

        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                throw WindowServerPlistError.privilegeEscalationFailed(
                    "User cancelled the authorization dialog"
                )
            }
            throw WindowServerPlistError.privilegeEscalationFailed(
                "Privileged file copy failed with status \(status)"
            )
        }
    }

    // MARK: - Private Helpers — UUID

    /// Get the UUID string for a display from CoreGraphics.
    ///
    /// Uses `CGDisplayCreateUUIDFromDisplayID` to obtain the system-assigned UUID
    /// that matches the UUID keys stored in the WindowServer plist.
    private func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID)
        guard let uuid = unmanaged?.takeUnretainedValue() else {
            logger.warning("CGDisplayCreateUUIDFromDisplayID returned nil for displayID=\(displayID)")
            return nil
        }
        guard let cfString = CFUUIDCreateString(kCFAllocatorDefault, uuid) else {
            logger.warning("CFUUIDCreateString returned nil for displayID=\(displayID)")
            return nil
        }
        return cfString as String
    }

    // MARK: - Private Helpers — Navigation

    /// Navigate to a specific display config entry in the plist.
    private func resolveDisplayConfig(
        in plist: [String: Any],
        at location: DisplayEntryLocation
    ) -> [String: Any]? {
        guard let section = plist[location.sectionKey] as? [String: Any],
              let configs = section["Configs"] as? [[String: Any]],
              location.configsIndex < configs.count else {
            return nil
        }

        let configGroup = configs[location.configsIndex]
        guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]],
              location.displayConfigIndex < displayConfigs.count else {
            return nil
        }

        return displayConfigs[location.displayConfigIndex]
    }

    /// Search a plist section for a display config matching the given UUID.
    private func findByUUID(
        _ uuid: String,
        in plist: [String: Any],
        sectionKey: String
    ) -> DisplayEntryLocation? {
        guard let section = plist[sectionKey] as? [String: Any],
              let configs = section["Configs"] as? [[String: Any]] else {
            return nil
        }

        for (configsIndex, configGroup) in configs.enumerated() {
            guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]] else {
                continue
            }

            for (dcIndex, displayConfig) in displayConfigs.enumerated() {
                if let entryUUID = displayConfig["UUID"] as? String,
                   entryUUID.caseInsensitiveCompare(uuid) == .orderedSame {
                    return DisplayEntryLocation(
                        sectionKey: sectionKey,
                        configsIndex: configsIndex,
                        displayConfigIndex: dcIndex
                    )
                }
            }
        }

        return nil
    }

    /// Fallback search: find the first display config entry that has a `LinkDescription` key.
    /// Only external displays have `LinkDescription`; built-in displays do not.
    private func findByLinkDescriptionPresence(
        in plist: [String: Any],
        sectionKey: String
    ) -> DisplayEntryLocation? {
        guard let section = plist[sectionKey] as? [String: Any],
              let configs = section["Configs"] as? [[String: Any]] else {
            return nil
        }

        for (configsIndex, configGroup) in configs.enumerated() {
            guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]] else {
                continue
            }

            for (dcIndex, displayConfig) in displayConfigs.enumerated() {
                if displayConfig["LinkDescription"] != nil {
                    return DisplayEntryLocation(
                        sectionKey: sectionKey,
                        configsIndex: configsIndex,
                        displayConfigIndex: dcIndex
                    )
                }
            }
        }

        return nil
    }

    /// Find all display config locations matching a UUID (or falling back to LinkDescription presence)
    /// within a specific section.
    private func findAllLocations(
        for uuid: String?,
        in plist: [String: Any],
        sectionKey: String
    ) -> [DisplayEntryLocation] {
        var results: [DisplayEntryLocation] = []

        guard let section = plist[sectionKey] as? [String: Any],
              let configs = section["Configs"] as? [[String: Any]] else {
            return results
        }

        for (configsIndex, configGroup) in configs.enumerated() {
            guard let displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]] else {
                continue
            }

            for (dcIndex, displayConfig) in displayConfigs.enumerated() {
                var matches = false

                if let uuid = uuid,
                   let entryUUID = displayConfig["UUID"] as? String,
                   entryUUID.caseInsensitiveCompare(uuid) == .orderedSame {
                    matches = true
                } else if uuid == nil, displayConfig["LinkDescription"] != nil {
                    // Fallback: match by LinkDescription presence
                    matches = true
                }

                if matches {
                    results.append(DisplayEntryLocation(
                        sectionKey: sectionKey,
                        configsIndex: configsIndex,
                        displayConfigIndex: dcIndex
                    ))
                }
            }
        }

        return results
    }

    /// Update the `LinkDescription` at a specific location in the plist.
    /// Returns true if successful.
    @discardableResult
    private func updateLinkDescription(
        in plist: inout [String: Any],
        at location: DisplayEntryLocation,
        with linkDescription: LinkDescription
    ) -> Bool {
        guard var section = plist[location.sectionKey] as? [String: Any],
              var configs = section["Configs"] as? [[String: Any]],
              location.configsIndex < configs.count else {
            return false
        }

        var configGroup = configs[location.configsIndex]
        guard var displayConfigs = configGroup["DisplayConfig"] as? [[String: Any]],
              location.displayConfigIndex < displayConfigs.count else {
            return false
        }

        var displayConfig = displayConfigs[location.displayConfigIndex]

        // Get existing LinkDescription or create a new one
        var linkDict = (displayConfig["LinkDescription"] as? [String: Any]) ?? [:]

        // Update the values
        linkDict["PixelEncoding"] = linkDescription.pixelEncoding
        linkDict["Range"] = linkDescription.range
        linkDict["BitDepth"] = linkDescription.bitDepth
        linkDict["EOTF"] = linkDescription.eotf

        // Reassemble the nested structure
        displayConfig["LinkDescription"] = linkDict
        displayConfigs[location.displayConfigIndex] = displayConfig
        configGroup["DisplayConfig"] = displayConfigs
        configs[location.configsIndex] = configGroup
        section["Configs"] = configs
        plist[location.sectionKey] = section

        return true
    }

    // MARK: - Private Helpers — Deep Copy

    /// Deep copy a plist dictionary using PropertyListSerialization round-trip.
    private func deepCopyPlist(_ dict: [String: Any]) -> [String: Any]? {
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict,
                format: .binary,
                options: 0
            )
            let result = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: nil
            )
            return result as? [String: Any]
        } catch {
            logger.error("Deep copy failed: \(error.localizedDescription)")
            return nil
        }
    }
}
