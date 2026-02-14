import SwiftUI
import Observation
import CoreGraphics
import AppKit

@Observable
@MainActor
final class AppState {
    // Display engine
    let displayEngine: DisplayEngineActor

    // Display state
    var displays: [DisplayDevice] = []
    var activeProfiles: [CGDirectDisplayID: ColorProfile] = [:]
    var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            guard let newDisplayID = selectedDisplayID, newDisplayID != oldValue else { return }
            guard displays.contains(where: { $0.id == newDisplayID }) else { return }

            // Load display modes and profile when selection changes
            Task {
                // Load active profile
                do {
                    currentProfile = try await displayEngine.activeProfile(for: newDisplayID)
                } catch {
                    currentProfile = nil
                }

                // Load display modes for external displays
                if let display = displays.first(where: { $0.id == newDisplayID }), !display.isBuiltIn {
                    await loadDisplayModes(for: newDisplayID)
                } else {
                    // Clear display modes for built-in displays
                    availableDisplayModes = []
                    currentDisplayMode = nil
                }

                // Re-apply white balance for the newly selected display
                if isWhiteBalanceActive {
                    await displayEngine.setColorTemperature(whiteBalanceTemperature, for: newDisplayID)
                }
            }
        }
    }
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

    // Guard against concurrent loadConnectedDisplays calls
    private var isLoadingDisplays = false

    // Display change observer
    private nonisolated(unsafe) var displayChangeObserver: NSObjectProtocol?

    // Solar schedule properties
    var isSolarScheduleEnabled: Bool = false
    var currentSolarPhase: SolarPhase?
    var blueLightFilterStrength: Double = 0.0
    var solarScheduleEngine: SolarScheduleEngine?

    // White Balance properties
    var whiteBalanceTemperature: Double = 6500 {
        didSet {
            guard whiteBalanceTemperature != oldValue else { return }
            UserDefaults.standard.set(whiteBalanceTemperature, forKey: "ChromaFlow.whiteBalanceTemperature")
        }
    }
    var isWhiteBalanceActive: Bool = false

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

    // Display Mode properties
    var currentDisplayMode: DisplayModeController.DisplayMode?
    var availableDisplayModes: [DisplayModeController.DisplayMode] = []
    var selectedBitDepth: Int = 8
    var selectedRGBRange: DisplayModeController.RGBRange = .full
    var selectedColorEncoding: DisplayModeController.ColorEncoding = .rgb

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

        // Restore white balance temperature
        let savedTemp = UserDefaults.standard.double(forKey: "ChromaFlow.whiteBalanceTemperature")
        if savedTemp >= 3000 && savedTemp <= 7500 {
            whiteBalanceTemperature = savedTemp
        }

        // Observe display configuration changes (HDMI connect/disconnect)
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Small delay for OS to fully register the display
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.loadConnectedDisplays()
            }
        }
    }

    deinit {
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Display Management

    /// Load and populate connected displays
    func loadConnectedDisplays() async {
        guard !isLoadingDisplays else { return }
        isLoadingDisplays = true
        defer { isLoadingDisplays = false }

        print("[AppState] Starting loadConnectedDisplays()")

        // Get displays immediately without DDC detection (fast)
        let connectedDisplays = await displayEngine.connectedDisplays()
        displays = connectedDisplays

        print("[AppState] Found \(connectedDisplays.count) displays:")
        for display in connectedDisplays {
            print("[AppState]   - \(display.name) (ID: \(display.id), Built-in: \(display.isBuiltIn))")
        }

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

            // Load display modes for external displays
            if let display = connectedDisplays.first(where: { $0.id == displayID }), !display.isBuiltIn {
                await loadDisplayModes(for: displayID)
            }

            // Re-apply white balance if active (gamma tables reset on display reconnect)
            if isWhiteBalanceActive {
                await displayEngine.setColorTemperature(whiteBalanceTemperature, for: displayID)
            }
        }

        // Detect DDC capabilities asynchronously in background (non-blocking)
        let externalDisplays = connectedDisplays.filter { !$0.isBuiltIn }
        print("[AppState] Detecting DDC for \(externalDisplays.count) external displays...")

        Task.detached { [weak self] in
            print("[AppState] DDC detection task started")
            if let self = self {
                await self.displayEngine.resetDDCFailures()
            }
            for display in externalDisplays {
                print("[AppState] Detecting DDC for display \(display.id)...")
                if let updated = await self?.displayEngine.detectAndUpdateDDCCapabilities(for: display.id) {
                    print("[AppState] DDC detection completed for display \(display.id)")
                    await MainActor.run {
                        if let self = self,
                           let index = self.displays.firstIndex(where: { $0.id == updated.id }) {
                            self.displays[index] = updated
                            print("[AppState] Updated display \(display.id) with DDC capabilities")
                        }
                    }
                } else {
                    print("[AppState] DDC detection returned nil for display \(display.id)")
                }
            }
            print("[AppState] DDC detection task finished")
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

    // MARK: - White Balance Methods

    /// Set white balance color temperature
    func setWhiteBalanceTemperature(_ temperature: Double) async {
        guard let displayID = selectedDisplayID else { return }

        let clamped = min(max(temperature, 3000), 7500)
        whiteBalanceTemperature = clamped
        isWhiteBalanceActive = (clamped != 6500)

        await displayEngine.setColorTemperature(clamped, for: displayID)
    }

    /// Reset white balance to default D65 (6500K)
    func resetWhiteBalance() async {
        guard let displayID = selectedDisplayID else { return }

        whiteBalanceTemperature = 6500
        isWhiteBalanceActive = false

        await displayEngine.resetWhiteBalance(for: displayID)
    }

    // MARK: - Display Mode Methods

    /// Load available display modes for the selected display
    func loadDisplayModes(for displayID: CGDirectDisplayID) async {
        availableDisplayModes = await displayEngine.displayEncodingVariants(for: displayID)
        currentDisplayMode = await displayEngine.currentDisplayMode(for: displayID)

        if let current = currentDisplayMode {
            selectedBitDepth = current.bitDepth
            selectedRGBRange = current.range
            selectedColorEncoding = current.colorEncoding
        }
    }

    /// Set a new display mode with the specified parameters
    func setDisplayMode(bitDepth: Int, range: DisplayModeController.RGBRange, encoding: DisplayModeController.ColorEncoding) async {
        guard let displayID = selectedDisplayID else { return }

        // Find matching mode
        let matchingMode = availableDisplayModes.first { mode in
            mode.bitDepth == bitDepth &&
            mode.range == range &&
            mode.colorEncoding == encoding
        }

        guard let mode = matchingMode else {
            ToastManager.shared.showError("Display mode not available")
            return
        }

        do {
            try await displayEngine.setDisplayMode(mode, for: displayID)
            currentDisplayMode = mode
        } catch {
            ToastManager.shared.showError("Failed to change display mode: \(error.localizedDescription)")
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
