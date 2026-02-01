import Foundation
import AppKit

/// Detects system-level conflicts that may interfere with ChromaFlow's display control.
///
/// This detector identifies:
/// - macOS Night Shift (via private CoreBrightness framework when available)
/// - macOS True Tone (via private CoreBrightness framework when available)
/// - Competing display control applications (MonitorControl, BetterDisplay, Lunar, f.lux)
///
/// All private API access uses dynamic loading with graceful fallbacks to prevent crashes.
@MainActor
final class SystemConflictDetector {

    // MARK: - Private API Detection State

    /// Indicates whether Night Shift detection is available
    private var nightShiftDetectionAvailable: Bool = false

    /// Indicates whether True Tone detection is available
    private var trueToneDetectionAvailable: Bool = false

    // MARK: - Dynamic Loading Handles

    private var coreBrightnessHandle: UnsafeMutableRawPointer?
    private var blueLightClient: AnyObject?

    // MARK: - Known Competing Applications

    private let competingAppBundleIDs = [
        "com.MonitorControl.MonitorControl",
        "com.waydabber.BetterDisplay",
        "fyi.lunar.Lunar",
        "org.herf.Flux"
    ]

    // MARK: - Initialization

    init() {
        setupPrivateAPIAccess()
    }

    deinit {
        // Cleanup without async context - deinit can't be async
        blueLightClient = nil
        if let handle = coreBrightnessHandle {
            dlclose(handle)
            coreBrightnessHandle = nil
        }
    }

    // MARK: - Private API Setup

    /// Attempts to dynamically load CoreBrightness framework for Night Shift and True Tone detection.
    /// Only attempts this if the feature flag is enabled.
    private func setupPrivateAPIAccess() {
        guard FeatureFlags.nightShiftDetection else {
            return
        }

        // Try to load CoreBrightness framework
        let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            // Framework not available - graceful fallback
            return
        }

        coreBrightnessHandle = handle

        // Try to get CBBlueLightClient class
        if let blueLightClientClass = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
            // Try to instantiate the client
            if let client = blueLightClientClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() {
                if let initializedClient = client.perform(NSSelectorFromString("init"))?.takeUnretainedValue() {
                    blueLightClient = initializedClient
                    nightShiftDetectionAvailable = true
                    trueToneDetectionAvailable = true
                }
            }
        }
    }

    /// Cleanup dynamic loading resources
    private func cleanup() {
        blueLightClient = nil

        if let handle = coreBrightnessHandle {
            dlclose(handle)
            coreBrightnessHandle = nil
        }
    }

    // MARK: - Night Shift Detection

    /// Checks if macOS Night Shift is currently active.
    ///
    /// - Returns: Tri-state enum: enabled, disabled, or unknown (if API unavailable)
    func detectNightShift() -> DetectionState {
        guard FeatureFlags.nightShiftDetection, nightShiftDetectionAvailable else {
            return .unknown
        }

        guard let client = blueLightClient else {
            return .unknown
        }

        // Try to call getBlueLightStatus:
        // The method signature is: - (BOOL)getBlueLightStatus:(struct { BOOL enabled; ... } *)arg1;
        // We'll use a simpler approach - check if the strength is > 0

        let selector = NSSelectorFromString("getStrength:")
        guard client.responds(to: selector) else {
            return .unknown
        }

        var strength: Float = 0.0
        withUnsafeMutablePointer(to: &strength) { ptr in
            _ = client.perform(selector, with: ptr)
        }

        // If strength > 0, Night Shift is likely enabled
        return strength > 0.0 ? .enabled : .disabled
    }

    // MARK: - True Tone Detection

    /// Checks if macOS True Tone is currently active.
    ///
    /// - Returns: Tri-state enum: enabled, disabled, or unknown (if API unavailable)
    func detectTrueTone() -> DetectionState {
        guard FeatureFlags.nightShiftDetection, trueToneDetectionAvailable else {
            return .unknown
        }

        // True Tone detection requires different APIs from CoreBrightness
        // For now, return unknown as a safe fallback
        // This can be extended with proper True Tone detection if needed
        return .unknown
    }

    // MARK: - Competing App Detection

    /// Detects if any competing display control applications are currently running.
    ///
    /// - Returns: Array of bundle identifiers for detected competing apps
    func detectCompetingApps() -> [String] {
        let runningApps = NSWorkspace.shared.runningApplications

        return competingAppBundleIDs.filter { bundleID in
            runningApps.contains { app in
                app.bundleIdentifier == bundleID
            }
        }
    }

    // MARK: - Comprehensive Conflict Detection

    /// Performs comprehensive conflict detection and returns a report.
    ///
    /// - Returns: ConflictReport containing all detected conflicts
    func detectConflicts() -> ConflictReport {
        let nightShiftState = detectNightShift()
        let trueToneState = detectTrueTone()
        let competingApps = detectCompetingApps()

        return ConflictReport(
            nightShift: nightShiftState,
            trueTone: trueToneState,
            competingApps: competingApps
        )
    }
}

// MARK: - Detection Types

/// Represents the detection state of a system feature
enum DetectionState {
    /// Feature is confirmed to be enabled
    case enabled

    /// Feature is confirmed to be disabled
    case disabled

    /// Feature state cannot be determined (API unavailable or error)
    case unknown
}

/// Report of all detected system conflicts
struct ConflictReport {
    /// Night Shift detection state
    let nightShift: DetectionState

    /// True Tone detection state
    let trueTone: DetectionState

    /// List of bundle IDs for detected competing apps
    let competingApps: [String]

    /// Returns true if any conflicts were detected
    var hasConflicts: Bool {
        nightShift == .enabled ||
        trueTone == .enabled ||
        !competingApps.isEmpty
    }

    /// Generates a user-friendly conflict message
    var conflictMessage: String? {
        guard hasConflicts else { return nil }

        var messages: [String] = []

        if nightShift == .enabled {
            messages.append("Night Shift is active")
        }

        if trueTone == .enabled {
            messages.append("True Tone is active")
        }

        if !competingApps.isEmpty {
            let appNames = competingApps.compactMap { bundleID -> String? in
                switch bundleID {
                case "com.MonitorControl.MonitorControl":
                    return "MonitorControl"
                case "com.waydabber.BetterDisplay":
                    return "BetterDisplay"
                case "fyi.lunar.Lunar":
                    return "Lunar"
                case "org.herf.Flux":
                    return "f.lux"
                default:
                    return nil
                }
            }

            if !appNames.isEmpty {
                messages.append("Competing apps detected: \(appNames.joined(separator: ", "))")
            }
        }

        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }
}
