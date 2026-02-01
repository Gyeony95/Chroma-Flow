import SwiftUI
import Observation
import CoreGraphics

@Observable
@MainActor
final class AppState {
    // Display engine
    let displayEngine: DisplayEngineActor

    // Display state
    var displays: [DisplayDevice] = []
    var activeProfiles: [CGDirectDisplayID: ColorProfile] = [:]
    var selectedDisplayID: CGDirectDisplayID?
    var currentProfile: ColorProfile?

    // DDC state
    var ddcValues: [CGDirectDisplayID: DDCValues] = [:]

    // System conflict detection
    var isNightShiftActive: Bool = false
    var isTrueToneActive: Bool = false

    // UI state
    var showConflictWarning: Bool = false
    var conflictMessage: String?

    // App-aware color space properties
    var isAppAwareEnabled: Bool = false
    var currentAppBundleID: String?
    var currentAppName: String?
    var appProfileMappings: [String: ColorProfile.ColorSpace] = [:]

    // Ambient Sync properties
    var isAmbientSyncEnabled: Bool = false
    var currentLux: Double?
    var targetColorTemperature: Int?

    // Automation engine (initialized later)
    var automationEngine: AutomationEngine?

    // Solar schedule properties
    var isSolarScheduleEnabled: Bool = false
    var currentSolarPhase: SolarPhase?
    var blueLightFilterStrength: Double = 0.0
    var solarScheduleEngine: SolarScheduleEngine?

    // Virtual HDR Emulation properties
    var isVirtualHDREnabled: Bool = false
    var hdrIntensity: Double = 0.5 // 0.0 to 1.0
    var hdrLocalContrast: Double = 0.3 // 0.0 to 1.0
    var virtualHDREngine: VirtualHDREngine?
    var hdrPreset: VirtualHDREngine.HDRPreset = .balanced

    // Reference Mode properties
    let referenceModeManager: ReferenceModeManager
    var isReferenceModeActive: Bool = false
    var referenceProfile: ColorProfile?
    var referenceDisplayID: CGDirectDisplayID?
    var showReferenceModeUnlockDialog: Bool = false

    // Delta-E Calibration properties
    var colorCorrectionEnabled: Bool = false
    var correctionIntensity: Double = 0.8 // 0.0 to 1.0
    var displayCalibrationStatus: [CGDirectDisplayID: CalibrationStatus] = [:]
    var activeCalibrationProfiles: [CGDirectDisplayID: CalibrationProfile] = [:]
    var contentAwareMode: ColorCorrectionEngine.ContentType = .photo

    init() {
        // Initialize ReferenceModeManager
        self.referenceModeManager = ReferenceModeManager()

        // Initialize DisplayEngineActor with the shared ReferenceModeManager
        self.displayEngine = DisplayEngineActor(
            referenceModeManager: referenceModeManager
        )

        // Initialize with empty state
        // AutomationEngine will be initialized after DisplayEngine is available

        // Observe reference mode changes
        Task {
            await observeReferenceModeChanges()
        }

        // Load connected displays on initialization
        Task {
            await loadConnectedDisplays()
        }
    }

    // MARK: - Display Management

    /// Load and populate connected displays
    func loadConnectedDisplays() async {
        let connectedDisplays = await displayEngine.connectedDisplays()
        displays = connectedDisplays

        // Set selected display to first available if not already set
        if selectedDisplayID == nil, let firstDisplay = connectedDisplays.first {
            selectedDisplayID = firstDisplay.id
        }

        // Try to load active profile for selected display
        if let displayID = selectedDisplayID {
            do {
                currentProfile = try await displayEngine.activeProfile(for: displayID)
            } catch {
                // Failed to get active profile, leave as nil
            }
        }
    }

    // MARK: - Reference Mode Methods

    /// Toggle reference mode lock
    func toggleReferenceMode() async {
        if isReferenceModeActive {
            // Show unlock dialog
            showReferenceModeUnlockDialog = true
        } else {
            // Lock current profile
            await lockReferenceMode()
        }
    }

    /// Lock the current profile for the selected display
    private func lockReferenceMode() async {
        guard let displayID = selectedDisplayID else { return }

        do {
            try await displayEngine.lockReferenceMode(for: displayID)

            // Update local state
            isReferenceModeActive = true
            referenceProfile = currentProfile
            referenceDisplayID = displayID
        } catch {
            // Show error toast
            ToastManager.shared.showError("Failed to lock Reference Mode: \(error.localizedDescription)")
        }
    }

    /// Unlock reference mode with authentication
    func unlockReferenceMode() async {
        do {
            try await displayEngine.unlockReferenceMode()

            // Update local state
            isReferenceModeActive = false
            referenceProfile = nil
            referenceDisplayID = nil
            showReferenceModeUnlockDialog = false
        } catch {
            // Show error toast
            ToastManager.shared.showError("Failed to unlock: \(error.localizedDescription)")
        }
    }

    /// Observe reference mode state changes
    private func observeReferenceModeChanges() async {
        for await _ in Timer.publish(every: 1, on: .main, in: .common).autoconnect().values {
            let isActive = await displayEngine.isReferenceModeActive()
            if isActive != isReferenceModeActive {
                isReferenceModeActive = isActive

                if isActive {
                    // Get locked info
                    if let info = await displayEngine.getReferenceModeInfo() {
                        referenceProfile = info.profile
                        referenceDisplayID = info.displayID
                    }
                } else {
                    referenceProfile = nil
                    referenceDisplayID = nil
                }
            }
        }
    }

    // MARK: - Delta-E Calibration Methods

    /// Apply color calibration to selected display
    func applyColorCalibration() async {
        guard let displayID = selectedDisplayID else { return }

        do {
            try await displayEngine.applyColorCalibration(for: displayID, intensity: correctionIntensity)
            colorCorrectionEnabled = true

            // Update calibration status
            displayCalibrationStatus[displayID] = await displayEngine.getCalibrationStatus(for: displayID)
        } catch {
            ToastManager.shared.showError("Failed to apply calibration: \(error.localizedDescription)")
        }
    }

    /// Remove color calibration from selected display
    func removeColorCalibration() async {
        guard let displayID = selectedDisplayID else { return }

        do {
            try await displayEngine.removeColorCalibration(for: displayID)
            colorCorrectionEnabled = false
        } catch {
            ToastManager.shared.showError("Failed to remove calibration: \(error.localizedDescription)")
        }
    }

    /// Import ICC calibration profile
    func importICCProfile(from url: URL) async {
        guard let displayID = selectedDisplayID else { return }

        do {
            let profile = try await displayEngine.importICCCalibration(from: url, for: displayID)
            activeCalibrationProfiles[displayID] = profile
            displayCalibrationStatus[displayID] = .calibrated(profile: profile)
        } catch {
            ToastManager.shared.showError("Failed to import ICC profile: \(error.localizedDescription)")
        }
    }

    /// Import measurement data
    func importMeasurementData(from url: URL) async {
        guard let displayID = selectedDisplayID else { return }

        do {
            let profile = try await displayEngine.importMeasurementData(from: url, for: displayID)
            activeCalibrationProfiles[displayID] = profile
            displayCalibrationStatus[displayID] = .calibrated(profile: profile)
        } catch {
            ToastManager.shared.showError("Failed to import measurement data: \(error.localizedDescription)")
        }
    }

    /// Update correction intensity
    func updateCorrectionIntensity(_ intensity: Double) async {
        guard let displayID = selectedDisplayID, colorCorrectionEnabled else { return }

        correctionIntensity = intensity

        do {
            try await displayEngine.updateCorrectionIntensity(intensity, for: displayID)
        } catch {
            ToastManager.shared.showError("Failed to update correction intensity: \(error.localizedDescription)")
        }
    }

    /// Apply content-aware correction
    func applyContentAwareCorrection(_ contentType: ColorCorrectionEngine.ContentType) async {
        guard let displayID = selectedDisplayID else { return }

        contentAwareMode = contentType

        do {
            try await displayEngine.applyContentAwareCorrection(contentType: contentType, for: displayID)
            colorCorrectionEnabled = true
        } catch {
            ToastManager.shared.showError("Failed to apply content-aware correction: \(error.localizedDescription)")
        }
    }

    /// Validate current color correction
    func validateColorCorrection() async -> ColorCorrectionEngine.ValidationResult? {
        guard let displayID = selectedDisplayID else { return nil }

        return await displayEngine.validateColorCorrection(for: displayID)
    }

    /// Refresh calibration status for all displays
    func refreshCalibrationStatus() async {
        for display in displays {
            displayCalibrationStatus[display.id] = await displayEngine.getCalibrationStatus(for: display.id)
        }
    }
}

struct DDCValues: Sendable {
    var brightness: Double  // 0.0-1.0
    var contrast: Double    // 0.0-1.0

    init(brightness: Double = 0.5, contrast: Double = 0.5) {
        self.brightness = brightness
        self.contrast = contrast
    }
}
