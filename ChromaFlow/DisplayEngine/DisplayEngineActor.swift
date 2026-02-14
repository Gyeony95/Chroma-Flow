import Foundation
import CoreGraphics
import os.log

/// Thread-safe actor that coordinates display detection, profile management, and device memory
actor DisplayEngineActor {

    // MARK: - Properties

    private let profileManager: ProfileManager
    private let displayDetector: DisplayDetector
    private let referenceModeManager: ReferenceModeManager
    private let virtualHDREngine: VirtualHDREngine?
    private let gammaController: GammaController
    private let calibrationDataManager: CalibrationDataManager
    private let colorCorrectionEngine: ColorCorrectionEngine
    private let ddcActor: DDCActor
    private let displayModeController: DisplayModeController
    private let logger = Logger(
        subsystem: "com.chromaflow.ChromaFlow",
        category: "DisplayEngine"
    )

    /// Track active profiles per display (in-memory cache)
    private var activeProfiles: [CGDirectDisplayID: ColorProfile] = [:]

    /// Track displays that are currently connected
    private var connectedDisplayIDs: Set<CGDirectDisplayID> = []

    // MARK: - Initialization

    init(profileManager: ProfileManager = ProfileManager(),
         displayDetector: DisplayDetector = DisplayDetector(),
         referenceModeManager: ReferenceModeManager? = nil,
         gammaController: GammaController? = nil,
         ddcActor: DDCActor = DDCActor()) {
        // Initialize simple properties first
        self.profileManager = profileManager
        self.displayDetector = displayDetector
        self.ddcActor = ddcActor

        // Initialize DisplayModeController on MainActor
        self.displayModeController = MainActor.assumeIsolated {
            DisplayModeController()
        }

        // Initialize or capture GammaController
        let localGammaController: GammaController
        if let controller = gammaController {
            localGammaController = controller
        } else {
            localGammaController = MainActor.assumeIsolated {
                GammaController()
            }
        }
        self.gammaController = localGammaController

        // Initialize ReferenceModeManager
        if let manager = referenceModeManager {
            self.referenceModeManager = manager
        } else {
            self.referenceModeManager = MainActor.assumeIsolated {
                ReferenceModeManager()
            }
        }

        // Initialize CalibrationDataManager
        self.calibrationDataManager = CalibrationDataManager()

        // Initialize VirtualHDREngine using local variable
        self.virtualHDREngine = MainActor.assumeIsolated {
            VirtualHDREngine(gammaController: localGammaController)
        }

        // Initialize ColorCorrectionEngine using local variable
        self.colorCorrectionEngine = ColorCorrectionEngine(gammaController: localGammaController)

        // Start monitoring display events in a detached task
        Task { [weak self] in
            await self?.monitorDisplayEvents()
        }
    }

    // MARK: - Public API

    /// Switch the color profile for a specific display
    /// - Parameters:
    ///   - profile: The color profile to activate
    ///   - displayID: The display identifier
    /// - Returns: Confirmation of the profile switch
    /// - Throws: ProfileManagerError if the switch fails or reference mode is locked
    func switchProfile(_ profile: ColorProfile, for displayID: CGDirectDisplayID) async throws -> ProfileSwitchConfirmation {
        // Check reference mode lock
        let canModify = await MainActor.run {
            referenceModeManager.canModifyProfile(for: displayID)
        }

        guard canModify else {
            logger.warning("Profile switch blocked - Reference Mode is active for display \(displayID)")
            throw ProfileManagerError.referenceModeActive
        }

        logger.info("Switching profile '\(profile.name)' for display \(displayID)")

        // Ensure display is connected
        guard let display = await findDisplayDevice(by: displayID) else {
            throw ProfileManagerError.displayDisconnected(displayID)
        }

        // Perform the profile switch via ProfileManager
        let confirmation = try await profileManager.switchProfile(profile, for: display)

        // Update in-memory cache
        activeProfiles[displayID] = profile

        // Persist to DeviceMemory for auto-restore
        await saveProfileToMemory(profile, for: display)

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.showProfileChanged(profile, for: display.name)
        }

        logger.info("Profile switched successfully: '\(profile.name)' on display \(displayID)")

        return confirmation
    }

    /// Get all currently connected displays
    /// - Returns: Array of connected display devices
    func connectedDisplays() async -> [DisplayDevice] {
        return await displayDetector.connectedDisplays()
    }

    /// Stream of display events (connect, disconnect, profile changes)
    var displayEvents: AsyncStream<DisplayEvent> {
        displayDetector.events
    }

    /// Get the currently active color profile for a display
    /// - Parameter displayID: The display identifier
    /// - Returns: The active color profile
    /// - Throws: ProfileManagerError if query fails
    func activeProfile(for displayID: CGDirectDisplayID) async throws -> ColorProfile {
        // Check cache first
        if let cached = activeProfiles[displayID] {
            return cached
        }

        // Query from ProfileManager
        guard let display = await findDisplayDevice(by: displayID) else {
            throw ProfileManagerError.displayDisconnected(displayID)
        }

        let profile = try await profileManager.activeProfile(for: display)

        // Update cache
        activeProfiles[displayID] = profile

        return profile
    }

    /// Apply a color profile to the primary display
    /// - Parameter profile: The color profile to apply
    /// - Throws: ProfileManagerError if application fails
    func applyColorProfile(_ profile: ColorProfile) async throws {
        // Get primary display (main display ID or first available)
        let mainDisplayID = CGMainDisplayID()
        let displays = await connectedDisplays()
        guard let primaryDisplay = displays.first(where: { $0.id == mainDisplayID }) ?? displays.first else {
            throw ProfileManagerError.noDisplay
        }

        // Switch profile
        _ = try await switchProfile(profile, for: primaryDisplay.id)
    }

    /// Get the current color space of the primary display
    /// - Returns: The current color space
    func getCurrentColorSpace() async -> ColorProfile.ColorSpace {
        do {
            let mainDisplayID = CGMainDisplayID()
            let displays = await connectedDisplays()
            guard let primaryDisplay = displays.first(where: { $0.id == mainDisplayID }) ?? displays.first else {
                return .sRGB // Default fallback
            }

            let profile = try await activeProfile(for: primaryDisplay.id)
            return profile.colorSpace
        } catch {
            logger.error("Failed to get current color space: \(error.localizedDescription)")
            return .sRGB // Default fallback
        }
    }

    /// Get available profiles for a display
    /// - Parameter displayID: The display identifier
    /// - Returns: Array of available color profiles
    func availableProfiles(for displayID: CGDirectDisplayID) async -> [ColorProfile] {
        guard let display = await findDisplayDevice(by: displayID) else {
            logger.warning("Cannot get available profiles - display \(displayID) not found")
            return []
        }

        return profileManager.availableProfiles(for: display)
    }

    // MARK: - Reference Mode Management

    /// Lock the current profile to prevent accidental changes
    /// - Parameters:
    ///   - displayID: The display to lock
    /// - Throws: ProfileManagerError if no profile is active
    func lockReferenceMode(for displayID: CGDirectDisplayID) async throws {
        let currentProfile = try await activeProfile(for: displayID)

        await MainActor.run {
            Task {
                await referenceModeManager.lock(profile: currentProfile, for: displayID)
            }
        }

        logger.info("Reference Mode locked for display \(displayID) with profile '\(currentProfile.name)'")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.showInfo(
                "Reference Mode Locked",
                subtitle: "Profile changes are now protected"
            )
        }
    }

    /// Unlock reference mode to allow profile changes
    /// - Throws: ReferenceModeError if authentication fails
    func unlockReferenceMode() async throws {
        await MainActor.run {
            Task {
                try await referenceModeManager.unlock()
            }
        }

        logger.info("Reference Mode unlocked successfully")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "Reference Mode Unlocked",
                subtitle: "Profile changes are now allowed",
                style: .success
            )
        }
    }

    /// Check if reference mode is currently locked
    /// - Returns: True if reference mode is active
    func isReferenceModeActive() async -> Bool {
        return await MainActor.run {
            referenceModeManager.isLocked
        }
    }

    /// Get the locked profile and display information
    /// - Returns: Tuple of locked profile and display ID, or nil if not locked
    func getReferenceModeInfo() async -> (profile: ColorProfile, displayID: CGDirectDisplayID)? {
        return await MainActor.run {
            guard referenceModeManager.isLocked,
                  let profile = referenceModeManager.lockedProfile,
                  let displayID = referenceModeManager.lockedDisplayID else {
                return nil
            }
            return (profile, displayID)
        }
    }

    // MARK: - Private Display Event Monitoring

    private func monitorDisplayEvents() async {
        for await event in displayDetector.events {
            await handleDisplayEvent(event)
        }
    }

    private func handleDisplayEvent(_ event: DisplayEvent) async {
        switch event {
        case .connected(let display):
            await handleDisplayConnected(display)

        case .disconnected(let displayID):
            await handleDisplayDisconnected(displayID)

        case .profileChanged(let displayID):
            await handleProfileChanged(displayID)
        }
    }

    private func handleDisplayConnected(_ display: DisplayDevice) async {
        logger.info("Display connected: \(display.name) (ID: \(display.id))")

        connectedDisplayIDs.insert(display.id)

        // Auto-restore last profile from DeviceMemory
        await restoreProfileFromMemory(for: display)
    }

    private func handleDisplayDisconnected(_ displayID: CGDirectDisplayID) async {
        logger.info("Display disconnected: \(displayID)")

        connectedDisplayIDs.remove(displayID)

        // Clean up state
        activeProfiles.removeValue(forKey: displayID)
    }

    private func handleProfileChanged(_ displayID: CGDirectDisplayID) async {
        logger.info("Profile changed externally for display \(displayID)")

        // Invalidate cache - next activeProfile() call will query fresh
        activeProfiles.removeValue(forKey: displayID)
    }

    // MARK: - DeviceMemory Integration

    @MainActor
    private func saveProfileToMemory(_ profile: ColorProfile, for display: DisplayDevice) async {
        let existingSettings = DeviceMemory.shared.restoreSettings(for: display)

        let updatedSettings = DeviceSettings(
            lastProfileID: profile.id,
            lastDDCBrightness: existingSettings?.lastDDCBrightness,
            lastDDCContrast: existingSettings?.lastDDCContrast,
            lastModified: Date()
        )

        DeviceMemory.shared.saveSettings(for: display, settings: updatedSettings)

        logger.debug("Saved profile \(profile.name) to DeviceMemory for display \(display.id)")
    }

    @MainActor
    private func restoreProfileFromMemory(for display: DisplayDevice) async {
        guard let settings = DeviceMemory.shared.restoreSettings(for: display),
              let lastProfileID = settings.lastProfileID else {
            logger.debug("No saved profile to restore for display \(display.id)")
            return
        }

        // Find the matching profile from available profiles
        let availableProfiles = profileManager.availableProfiles(for: display)

        guard let profileToRestore = availableProfiles.first(where: { $0.id == lastProfileID }) else {
            logger.warning("Saved profile ID \(lastProfileID) not found in available profiles")
            return
        }

        do {
            _ = try await profileManager.switchProfile(profileToRestore, for: display)

            // Update active profiles cache (actor-isolated property) - use Task to properly isolate
            await Task { @MainActor in
                await self.updateActiveProfile(displayID: display.id, profile: profileToRestore)
            }.value

            // Show toast notification for auto-restore
            await MainActor.run {
                ToastManager.shared.showInfo(
                    "Profile Restored",
                    subtitle: "\(profileToRestore.name) for \(display.name)"
                )
            }

            logger.info("Auto-restored profile '\(profileToRestore.name)' for display \(display.id)")
        } catch {
            logger.error("Failed to restore profile: \(error.localizedDescription)")

            // Show error toast
            await MainActor.run {
                ToastManager.shared.showError("Failed to restore profile")
            }
        }
    }

    /// Helper method to update active profile from MainActor context
    private func updateActiveProfile(displayID: CGDirectDisplayID, profile: ColorProfile) async {
        activeProfiles[displayID] = profile
    }

    // MARK: - Virtual HDR Management

    /// Enable Virtual HDR emulation for a display
    /// - Parameters:
    ///   - displayID: The display to enable HDR emulation for
    ///   - intensity: HDR intensity (0.0 to 1.0)
    ///   - localContrast: Local contrast enhancement (0.0 to 1.0)
    /// - Throws: VirtualHDRError if enabling fails
    func enableVirtualHDR(for displayID: CGDirectDisplayID, intensity: Double = 0.5, localContrast: Double = 0.3) async throws {
        guard let hdrEngine = virtualHDREngine else {
            throw VirtualHDRError.engineNotInitialized
        }

        // Check if display is connected
        guard await findDisplayDevice(by: displayID) != nil else {
            throw VirtualHDRError.displayNotFound(displayID)
        }

        // Enable HDR emulation on MainActor
        await MainActor.run {
            Task {
                try await hdrEngine.enableHDREmulation(intensity: intensity, for: displayID)
                hdrEngine.localContrastBoost = localContrast
            }
        }

        logger.info("Virtual HDR enabled for display \(displayID) with intensity \(intensity)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "Virtual HDR Enabled",
                subtitle: "Enhanced contrast and tone mapping active",
                style: .success
            )
        }
    }

    /// Disable Virtual HDR emulation
    /// - Parameter displayID: The display to disable HDR emulation for
    /// - Throws: VirtualHDRError if disabling fails
    func disableVirtualHDR(for displayID: CGDirectDisplayID) async throws {
        guard let hdrEngine = virtualHDREngine else {
            throw VirtualHDRError.engineNotInitialized
        }

        // Disable HDR emulation on MainActor
        try await MainActor.run {
            Task {
                try await hdrEngine.disableHDREmulation(for: displayID)
            }
        }

        logger.info("Virtual HDR disabled for display \(displayID)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.showInfo(
                "Virtual HDR Disabled",
                subtitle: "Returned to standard display mode"
            )
        }
    }

    /// Adjust Virtual HDR intensity
    /// - Parameters:
    ///   - intensity: New intensity value (0.0 to 1.0)
    ///   - displayID: The display to adjust
    /// - Throws: VirtualHDRError if adjustment fails
    func adjustVirtualHDRIntensity(_ intensity: Double, for displayID: CGDirectDisplayID) async throws {
        guard let hdrEngine = virtualHDREngine else {
            throw VirtualHDRError.engineNotInitialized
        }

        try await MainActor.run {
            Task {
                try await hdrEngine.adjustIntensity(intensity, for: displayID)
            }
        }

        logger.debug("Virtual HDR intensity adjusted to \(intensity) for display \(displayID)")
    }

    /// Apply Virtual HDR preset
    /// - Parameters:
    ///   - preset: The HDR preset to apply
    ///   - displayID: The display to apply the preset to
    /// - Throws: VirtualHDRError if application fails
    func applyVirtualHDRPreset(_ preset: VirtualHDREngine.HDRPreset, for displayID: CGDirectDisplayID) async throws {
        guard let hdrEngine = virtualHDREngine else {
            throw VirtualHDRError.engineNotInitialized
        }

        try await MainActor.run {
            Task {
                try await hdrEngine.applyPreset(preset, for: displayID)
            }
        }

        logger.info("Virtual HDR preset '\(String(describing: preset))' applied to display \(displayID)")
    }

    /// Get Virtual HDR status
    /// - Returns: Tuple containing enabled status and current settings
    func getVirtualHDRStatus() async -> (isEnabled: Bool, intensity: Double, localContrast: Double) {
        guard let hdrEngine = virtualHDREngine else {
            return (false, 0.0, 0.0)
        }

        return await MainActor.run {
            (hdrEngine.isEnabled, hdrEngine.intensity, hdrEngine.localContrastBoost)
        }
    }

    // MARK: - Delta-E Calibration Management

    /// Apply color calibration based on Delta-E measurements
    /// - Parameters:
    ///   - displayID: The display to calibrate
    ///   - intensity: Correction intensity (0.0 to 1.0)
    /// - Throws: CalibrationError if calibration fails
    func applyColorCalibration(for displayID: CGDirectDisplayID, intensity: Double = 0.8) async throws {
        // Load calibration profile for display
        guard let profile = try await calibrationDataManager.loadCalibration(for: displayID) else {
            throw CalibrationError.displayNotFound
        }

        // Apply correction via ColorCorrectionEngine
        try await colorCorrectionEngine.applyCorrection(profile, intensity: intensity, for: displayID)

        logger.info("Color calibration applied for display \(displayID) with average Delta-E: \(profile.averageDeltaE)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "Calibration Applied",
                subtitle: "Delta-E: \(String(format: "%.2f", profile.averageDeltaE))",
                style: .success
            )
        }
    }

    /// Remove color calibration from display
    /// - Parameter displayID: The display to remove calibration from
    /// - Throws: CorrectionError if removal fails
    func removeColorCalibration(for displayID: CGDirectDisplayID) async throws {
        try await colorCorrectionEngine.removeCorrection(for: displayID)

        logger.info("Color calibration removed for display \(displayID)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.showInfo(
                "Calibration Removed",
                subtitle: "Display returned to native colors"
            )
        }
    }

    /// Import calibration from ICC profile
    /// - Parameters:
    ///   - url: URL to the ICC profile file
    ///   - displayID: The display to apply calibration to
    /// - Returns: The imported calibration profile
    /// - Throws: CalibrationError if import fails
    func importICCCalibration(from url: URL, for displayID: CGDirectDisplayID) async throws -> CalibrationProfile {
        let profile = try await calibrationDataManager.importICCProfile(at: url, for: displayID)

        logger.info("ICC profile imported for display \(displayID): Average Delta-E = \(profile.averageDeltaE)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "ICC Profile Imported",
                subtitle: "Ready to apply calibration",
                style: .success
            )
        }

        return profile
    }

    /// Import calibration from measurement data
    /// - Parameters:
    ///   - url: URL to the measurement data file (X-Rite, CGATS, JSON)
    ///   - displayID: The display to apply calibration to
    /// - Returns: The imported calibration profile
    /// - Throws: CalibrationError if import fails
    func importMeasurementData(from url: URL, for displayID: CGDirectDisplayID) async throws -> CalibrationProfile {
        let fileExtension = url.pathExtension.lowercased()
        let profile: CalibrationProfile

        switch fileExtension {
        case "mxf", "txt", "cgats":
            // X-Rite or CGATS format
            profile = try await calibrationDataManager.importXRiteData(at: url, for: displayID)
        case "json":
            // Custom JSON format
            profile = try await calibrationDataManager.importJSONCalibration(at: url)
        default:
            throw CalibrationError.invalidDataFormat
        }

        logger.info("Measurement data imported for display \(displayID): Average Delta-E = \(profile.averageDeltaE)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "Calibration Data Imported",
                subtitle: "Delta-E: \(String(format: "%.2f", profile.averageDeltaE))",
                style: .success
            )
        }

        return profile
    }

    /// Get calibration status for a display
    /// - Parameter displayID: The display ID to check
    /// - Returns: Current calibration status
    func getCalibrationStatus(for displayID: CGDirectDisplayID) async -> CalibrationStatus {
        return await calibrationDataManager.getCalibrationStatus(for: displayID)
    }

    /// Update color correction intensity
    /// - Parameters:
    ///   - intensity: New intensity value (0.0 to 1.0)
    ///   - displayID: The display to update
    /// - Throws: CorrectionError if update fails
    func updateCorrectionIntensity(_ intensity: Double, for displayID: CGDirectDisplayID) async throws {
        try await colorCorrectionEngine.updateCorrectionIntensity(intensity, for: displayID)

        logger.debug("Color correction intensity updated to \(intensity) for display \(displayID)")
    }

    /// Apply content-aware color correction
    /// - Parameters:
    ///   - contentType: Type of content being displayed
    ///   - displayID: The display to apply correction to
    /// - Throws: CalibrationError or CorrectionError if application fails
    func applyContentAwareCorrection(contentType: ColorCorrectionEngine.ContentType, for displayID: CGDirectDisplayID) async throws {
        // Load calibration profile
        guard let profile = try await calibrationDataManager.loadCalibration(for: displayID) else {
            throw CalibrationError.displayNotFound
        }

        // Apply content-aware correction
        try await colorCorrectionEngine.applyContentAwareCorrection(profile, contentType: contentType, for: displayID)

        logger.info("Content-aware correction applied for \(String(describing: contentType)) on display \(displayID)")
    }

    /// Validate current color correction
    /// - Parameter displayID: The display to validate
    /// - Returns: Validation result with Delta-E metrics
    func validateColorCorrection(for displayID: CGDirectDisplayID) async -> ColorCorrectionEngine.ValidationResult {
        // Use standard ColorChecker patches for validation
        let testPatches = CalibrationDataManager.colorCheckerPatches().map { patch in
            (rgb: patch.rgb, targetLab: patch.lab)
        }

        return await colorCorrectionEngine.validateCorrection(for: displayID, testPatches: testPatches)
    }

    /// Get current correction state
    /// - Parameter displayID: The display to check
    /// - Returns: Current correction state information
    func getCorrectionState(for displayID: CGDirectDisplayID) async -> (
        isActive: Bool,
        intensity: Double?,
        averageDeltaE: Double?,
        profile: CalibrationProfile?
    ) {
        return await colorCorrectionEngine.getCorrectionState(for: displayID)
    }

    // MARK: - Display Mode Control

    /// Get available display modes for a display
    func availableDisplayModes(for displayID: CGDirectDisplayID) async -> [DisplayModeController.DisplayMode] {
        return await MainActor.run {
            displayModeController.availableModes(for: displayID)
        }
    }

    /// Get encoding variants (same timing, different encoding)
    func displayEncodingVariants(for displayID: CGDirectDisplayID) async -> [DisplayModeController.DisplayMode] {
        return await MainActor.run {
            displayModeController.encodingVariants(for: displayID, matchingCurrent: true)
        }
    }

    /// Get current display mode
    func currentDisplayMode(for displayID: CGDirectDisplayID) async -> DisplayModeController.DisplayMode? {
        return await MainActor.run {
            displayModeController.currentMode(for: displayID)
        }
    }

    /// Set display mode
    func setDisplayMode(_ mode: DisplayModeController.DisplayMode, for displayID: CGDirectDisplayID) async throws {
        try await MainActor.run {
            try displayModeController.setMode(mode, for: displayID)
        }

        logger.info("Display mode changed to: \(mode.description)")

        // Show toast notification
        await MainActor.run {
            ToastManager.shared.show(
                title: "Display Mode Changed",
                subtitle: mode.description,
                style: .success
            )
        }
    }

    /// Switch to 8-bit SDR RGB mode
    func setSDRMode(for displayID: CGDirectDisplayID) async throws {
        try await MainActor.run {
            try displayModeController.setSSDRMode(for: displayID)
        }

        logger.info("Switched to 8-bit SDR RGB mode for display \(displayID)")

        await MainActor.run {
            ToastManager.shared.show(
                title: "SDR Mode",
                subtitle: "8-bit RGB Full Range",
                style: .success
            )
        }
    }

    /// Switch to 10-bit HDR mode
    func setHDRMode(for displayID: CGDirectDisplayID) async throws {
        try await MainActor.run {
            try displayModeController.setHDRMode(for: displayID)
        }

        logger.info("Switched to 10-bit HDR mode for display \(displayID)")

        await MainActor.run {
            ToastManager.shared.show(
                title: "HDR Mode",
                subtitle: "10-bit RGB Limited Range",
                style: .success
            )
        }
    }

    /// Toggle between full and limited RGB range
    func toggleRGBRange(for displayID: CGDirectDisplayID) async throws {
        try await MainActor.run {
            try displayModeController.toggleRGBRange(for: displayID)
        }

        guard let newMode = await currentDisplayMode(for: displayID) else { return }

        logger.info("RGB range toggled to: \(newMode.range.description)")

        await MainActor.run {
            ToastManager.shared.show(
                title: "RGB Range",
                subtitle: newMode.range.description,
                style: .success
            )
        }
    }

    // MARK: - DDC Control

    /// Sets the display color preset mode via DDC/CI
    /// - Parameters:
    ///   - preset: The color preset to apply
    ///   - displayID: The target display
    /// - Throws: DDCActor.DDCError if communication fails or display doesn't support DDC
    func setColorPreset(_ preset: ColorPreset, for displayID: CGDirectDisplayID) async throws {
        // Ensure display is connected and supports DDC
        guard await findDisplayDevice(by: displayID) != nil else {
            throw DDCActor.DDCError.displayNotFound(displayID)
        }

        // Check if display has DDC capabilities
        let capabilities = await ddcActor.detectCapabilities(for: displayID)
        guard capabilities.supportsColorTemperature || !capabilities.supportedColorPresets.isEmpty else {
            throw DDCActor.DDCError.ddcNotSupported(displayID)
        }

        // Send DDC command via DDCActor
        try await ddcActor.setColorPreset(preset, for: displayID)

        logger.info("Color preset changed to \(preset.displayName) for display \(displayID)")

        // Show toast notification on main thread
        await MainActor.run {
            ToastManager.shared.show(
                title: "Color Mode",
                subtitle: preset.displayName,
                style: .success
            )
        }
    }

    /// Reads the current color preset from the display
    /// - Parameter displayID: The target display
    /// - Returns: The current color preset, or nil if unrecognized
    /// - Throws: DDCActor.DDCError if communication fails
    func readColorPreset(for displayID: CGDirectDisplayID) async throws -> ColorPreset? {
        let vcpValue = try await ddcActor.readColorPreset(for: displayID)
        return ColorPreset(vcpValue: vcpValue)
    }

    /// Reset DDC failure counts for all displays (used when popover opens)
    func resetDDCFailures() async {
        await ddcActor.resetAllFailures()
    }

    // MARK: - DDC Brightness/Contrast Control

    /// Reads current DDC brightness value (0.0 to 1.0)
    func readDDCBrightness(for displayID: CGDirectDisplayID) async throws -> Double {
        return try await ddcActor.readBrightness(for: displayID)
    }

    /// Reads current DDC contrast value (0.0 to 1.0)
    func readDDCContrast(for displayID: CGDirectDisplayID) async throws -> Double {
        return try await ddcActor.readContrast(for: displayID)
    }

    /// Sets DDC brightness (0.0 to 1.0)
    func setDDCBrightness(_ value: Double, for displayID: CGDirectDisplayID) async throws {
        try await ddcActor.setBrightness(value, for: displayID)
    }

    /// Sets DDC contrast (0.0 to 1.0)
    func setDDCContrast(_ value: Double, for displayID: CGDirectDisplayID) async throws {
        try await ddcActor.setContrast(value, for: displayID)
    }

    /// Detects DDC capabilities for a display and returns updated DisplayDevice
    /// - Parameter displayID: The display to detect capabilities for
    /// - Returns: Updated DisplayDevice with detected capabilities, or nil if display not found
    func detectAndUpdateDDCCapabilities(for displayID: CGDirectDisplayID) async -> DisplayDevice? {
        print("[DisplayEngine] detectAndUpdateDDCCapabilities called for display \(displayID)")

        // Get display device
        guard var device = await findDisplayDevice(by: displayID) else {
            print("[DisplayEngine] Display \(displayID) not found")
            return nil
        }

        print("[DisplayEngine] Found device: \(device.name), isBuiltIn: \(device.isBuiltIn)")

        // Skip built-in displays (they don't support DDC)
        if device.isBuiltIn {
            print("[DisplayEngine] Skipping built-in display")
            return device
        }

        print("[DisplayEngine] Calling ddcActor.detectCapabilities for display \(displayID)")

        // Detect capabilities via DDCActor
        let capabilities = await ddcActor.detectCapabilities(for: displayID)

        print("[DisplayEngine] Received capabilities: brightness=\(capabilities.supportsBrightness), contrast=\(capabilities.supportsContrast), colorTemp=\(capabilities.supportsColorTemperature)")

        // Update device with detected capabilities
        device.ddcCapabilities = capabilities

        logger.info("Detected DDC capabilities for \(device.name): brightness=\(capabilities.supportsBrightness), contrast=\(capabilities.supportsContrast), colorTemp=\(capabilities.supportsColorTemperature)")

        return device
    }

    // MARK: - Private Helpers

    private func findDisplayDevice(by displayID: CGDirectDisplayID) async -> DisplayDevice? {
        let displays = await displayDetector.connectedDisplays()
        return displays.first { $0.id == displayID }
    }
}

// MARK: - Virtual HDR Errors

enum VirtualHDRError: LocalizedError {
    case engineNotInitialized
    case displayNotFound(CGDirectDisplayID)
    case invalidIntensity(Double)
    case gammaControllerUnavailable

    var errorDescription: String? {
        switch self {
        case .engineNotInitialized:
            return "Virtual HDR engine is not initialized"
        case .displayNotFound(let displayID):
            return "Display \(displayID) not found"
        case .invalidIntensity(let intensity):
            return "Invalid intensity value: \(intensity). Must be between 0.0 and 1.0"
        case .gammaControllerUnavailable:
            return "Gamma controller is not available"
        }
    }
}
