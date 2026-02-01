//
//  AutomationEngine.swift
//  ChromaFlow
//
//  Created on 2026-02-01
//

import Foundation
import SwiftUI
import Observation

/// Coordinates automatic color profile switching based on active applications
@Observable
final class AutomationEngine: @unchecked Sendable {

    // MARK: - Properties

    /// Reference to the app state
    @MainActor
    private let appState: AppState

    /// Reference to the display engine
    @MainActor
    private let displayEngine: DisplayEngineActor

    /// Reference to the app activity monitor
    private let appMonitor = AppActivityMonitor.shared

    /// Reference to the app profile mapping
    private let profileMapping = AppProfileMapping.shared

    /// Ambient light sensor for automatic white balance
    private let ambientSensor = AmbientLightSensor()

    /// White balance controller for temperature adjustment
    private let whiteBalanceController = WhiteBalanceController()

    /// Solar schedule engine for blue light filtering
    private var solarScheduleEngine: SolarScheduleEngine?

    /// Task for ambient light monitoring
    private var ambientMonitorTask: Task<Void, Never>?

    /// Whether automation is currently enabled
    @MainActor
    private(set) var isEnabled = false

    /// Whether ambient sync is currently enabled
    @MainActor
    private(set) var isAmbientSyncEnabled = false

    /// Whether solar schedule is currently enabled
    @MainActor
    private(set) var isSolarScheduleEnabled = false

    /// The previous color space before automatic switch
    @MainActor
    private var previousColorSpace: ColorProfile.ColorSpace?

    /// The bundle ID that triggered the current color space
    @MainActor
    private var currentTriggerBundleID: String?

    /// History of recent switches for debugging
    @MainActor
    private(set) var switchHistory: [(date: Date, app: String, colorSpace: ColorProfile.ColorSpace)] = []

    /// Maximum number of history entries to keep
    private let maxHistoryEntries = 50

    // MARK: - Initialization

    init(appState: AppState, displayEngine: DisplayEngineActor) {
        self.appState = appState
        self.displayEngine = displayEngine
    }

    // MARK: - Public Methods

    /// Start the automation engine
    @MainActor
    func start() {
        guard !isEnabled else { return }

        isEnabled = true

        // Set up app change callback
        appMonitor.onAppChanged = { [weak self] bundleID, appName in
            Task { @MainActor [weak self] in
                await self?.handleAppChange(bundleID: bundleID, appName: appName)
            }
        }

        // Start monitoring
        appMonitor.startMonitoring()

        // Handle current app immediately
        if let currentBundleID = appMonitor.getFrontmostAppBundleID(),
           let currentAppName = appMonitor.getFrontmostAppName() {
            Task {
                await handleAppChange(bundleID: currentBundleID, appName: currentAppName)
            }
        }
    }

    /// Stop the automation engine
    @MainActor
    func stop() {
        guard isEnabled else { return }

        isEnabled = false

        // Stop monitoring
        appMonitor.stopMonitoring()
        appMonitor.onAppChanged = nil

        // Stop ambient sync if enabled
        if isAmbientSyncEnabled {
            stopAmbientSync()
        }

        // Restore previous color space if we had switched
        if let previousColorSpace = previousColorSpace,
           currentTriggerBundleID != nil {
            Task {
                await restoreColorSpace(to: previousColorSpace)
            }
        }

        // Clear state
        previousColorSpace = nil
        currentTriggerBundleID = nil
    }

    /// Toggle automation on/off
    @MainActor
    func toggle() {
        if isEnabled {
            stop()
        } else {
            start()
        }
    }

    /// Clear switch history
    @MainActor
    func clearHistory() {
        switchHistory.removeAll()
    }

    /// Get a description of the last switch
    @MainActor
    func getLastSwitchDescription() -> String? {
        guard let lastSwitch = switchHistory.first else { return nil }
        return "\(lastSwitch.app) → \(lastSwitch.colorSpace)"
    }

    // MARK: - Private Methods

    @MainActor
    private func handleAppChange(bundleID: String?, appName: String?) async {
        // Update app state
        appState.currentAppBundleID = bundleID
        appState.currentAppName = appName

        // Check if we should switch color space
        guard let bundleID = bundleID,
              let targetColorSpace = profileMapping.getColorSpace(for: bundleID) else {
            // No mapping for this app, restore previous if needed
            if currentTriggerBundleID != nil,
               let previousColorSpace = previousColorSpace {
                await restoreColorSpace(to: previousColorSpace)
                currentTriggerBundleID = nil
            }
            return
        }

        // Get current color space
        let currentColorSpace = await displayEngine.getCurrentColorSpace()

        // Skip if already in the target color space
        guard currentColorSpace != targetColorSpace else {
            print("Already in \(targetColorSpace) for \(appName ?? bundleID)")
            return
        }

        // Store previous color space if this is the first automatic switch
        if currentTriggerBundleID == nil {
            previousColorSpace = currentColorSpace
        }

        // Switch to target color space
        await switchColorSpace(to: targetColorSpace, for: appName ?? bundleID)

        // Update trigger
        currentTriggerBundleID = bundleID
    }

    @MainActor
    private func switchColorSpace(to colorSpace: ColorProfile.ColorSpace, for appName: String) async {
        print("Switching to \(colorSpace) for \(appName)")

        // Create and apply color profile
        let profile = ColorProfile(colorSpace: colorSpace)
        try? await displayEngine.applyColorProfile(profile)

        // Update app state
        appState.currentProfile = profile

        // Add to history
        addToHistory(app: appName, colorSpace: colorSpace)

        // Show toast notification
        await showToastNotification(for: colorSpace, appName: appName)
    }

    @MainActor
    private func restoreColorSpace(to colorSpace: ColorProfile.ColorSpace) async {
        print("Restoring color space to \(colorSpace)")

        // Create and apply color profile
        let profile = ColorProfile(colorSpace: colorSpace)
        try? await displayEngine.applyColorProfile(profile)

        // Update app state
        appState.currentProfile = profile

        // Show toast notification
        await showToastNotification(for: colorSpace, appName: "Default")
    }

    @MainActor
    private func addToHistory(app: String, colorSpace: ColorProfile.ColorSpace) {
        // Add new entry at the beginning
        switchHistory.insert((date: Date(), app: app, colorSpace: colorSpace), at: 0)

        // Trim history if needed
        if switchHistory.count > maxHistoryEntries {
            switchHistory = Array(switchHistory.prefix(maxHistoryEntries))
        }
    }

    @MainActor
    private func showToastNotification(for colorSpace: ColorProfile.ColorSpace, appName: String) async {
        // Get color space display name
        let colorSpaceName: String
        switch colorSpace {
        case .sRGB:
            colorSpaceName = "sRGB"
        case .displayP3:
            colorSpaceName = "Display P3"
        case .adobeRGB:
            colorSpaceName = "Adobe RGB"
        case .rec709:
            colorSpaceName = "Rec.709"
        case .rec2020:
            colorSpaceName = "Rec.2020"
        case .custom:
            colorSpaceName = "Custom"
        }

        // Create toast message
        let message = "\(colorSpaceName) Activated (\(appName))"

        // Show toast (this will be integrated with ToastManager when UI is added)
        appState.showToast(message: message, type: .info)
    }
}

// MARK: - Statistics

extension AutomationEngine {
    /// Get statistics about automatic switches
    @MainActor
    func getStatistics() -> AutomationStatistics {
        var appSwitchCounts: [String: Int] = [:]
        var colorSpaceUsage: [ColorProfile.ColorSpace: TimeInterval] = [:]

        // Count switches per app
        for entry in switchHistory {
            appSwitchCounts[entry.app, default: 0] += 1
        }

        // Calculate time spent in each color space (simplified)
        // In a real implementation, this would track actual durations
        for i in 0..<switchHistory.count {
            let entry = switchHistory[i]
            let duration: TimeInterval

            if i == 0 {
                // Current session
                duration = Date().timeIntervalSince(entry.date)
            } else {
                // Historical session
                duration = switchHistory[i - 1].date.timeIntervalSince(entry.date)
            }

            colorSpaceUsage[entry.colorSpace, default: 0] += duration
        }

        return AutomationStatistics(
            totalSwitches: switchHistory.count,
            appSwitchCounts: appSwitchCounts,
            colorSpaceUsage: colorSpaceUsage,
            mostUsedApp: appSwitchCounts.max(by: { $0.value < $1.value })?.key,
            mostUsedColorSpace: colorSpaceUsage.max(by: { $0.value < $1.value })?.key
        )
    }
}

// MARK: - Supporting Types

struct AutomationStatistics {
    let totalSwitches: Int
    let appSwitchCounts: [String: Int]
    let colorSpaceUsage: [ColorProfile.ColorSpace: TimeInterval]
    let mostUsedApp: String?
    let mostUsedColorSpace: ColorProfile.ColorSpace?
}

// MARK: - AppState Extension

extension AppState {
    /// Show a toast notification (placeholder - will be properly integrated with UI)
    func showToast(message: String, type: ToastType) {
        // This will be implemented when the UI components are added
        print("Toast: \(type) - \(message)")
    }

    enum ToastType {
        case info
        case success
        case warning
        case error
    }
}

// MARK: - Ambient Sync

extension AutomationEngine {
    /// Start ambient light-based white balance adjustment
    @MainActor
    func startAmbientSync() {
        guard !isAmbientSyncEnabled else {
            print("AmbientSync: Already enabled")
            return
        }

        guard FeatureFlags.ioKitAmbientLight else {
            print("AmbientSync: Feature flag disabled")
            appState.showToast(message: "Ambient Sync not available on this Mac", type: .warning)
            return
        }

        // Start sensor monitoring
        guard let luxStream = ambientSensor.startMonitoring() else {
            print("AmbientSync: Failed to start sensor (not available)")
            appState.showToast(message: "Ambient light sensor not available", type: .error)
            return
        }

        isAmbientSyncEnabled = true

        // Get primary display
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID? else {
            print("AmbientSync: No display found")
            stopAmbientSync()
            return
        }

        // Start monitoring task
        ambientMonitorTask = Task { [weak self] in
            guard let self = self else { return }

            for await lux in luxStream {
                // Check if still enabled
                guard await self.isAmbientSyncEnabled else {
                    break
                }

                // Update app state
                await MainActor.run {
                    self.appState.currentLux = lux
                }

                // Apply white balance with debouncing
                self.whiteBalanceController.applyWhiteBalanceDebounced(
                    lux: lux,
                    displayID: displayID,
                    debounceDelay: 2.0
                )

                // Update target temperature in app state
                let targetTemp = await self.whiteBalanceController.getCurrentTemperature()
                await MainActor.run {
                    self.appState.targetColorTemperature = Int(targetTemp)
                }
            }
        }

        appState.showToast(message: "Ambient Sync enabled", type: .success)
        print("AmbientSync: Started monitoring")
    }

    /// Stop ambient light-based white balance adjustment
    @MainActor
    func stopAmbientSync() {
        guard isAmbientSyncEnabled else {
            return
        }

        isAmbientSyncEnabled = false

        // Cancel monitoring task
        ambientMonitorTask?.cancel()
        ambientMonitorTask = nil

        // Stop sensor
        ambientSensor.stopMonitoring()

        // Reset white balance to default
        if let displayID = CGMainDisplayID() as CGDirectDisplayID? {
            whiteBalanceController.reset(displayID: displayID)
        }

        // Clear app state
        appState.currentLux = nil
        appState.targetColorTemperature = nil

        appState.showToast(message: "Ambient Sync disabled", type: .info)
        print("AmbientSync: Stopped monitoring")
    }

    /// Toggle ambient sync on/off
    @MainActor
    func toggleAmbientSync() {
        if isAmbientSyncEnabled {
            stopAmbientSync()
        } else {
            startAmbientSync()
        }
    }

    /// Get current ambient sync status
    @MainActor
    func getAmbientSyncStatus() -> AmbientSyncStatus {
        return AmbientSyncStatus(
            isEnabled: isAmbientSyncEnabled,
            currentLux: appState.currentLux,
            targetTemperature: appState.targetColorTemperature
        )
    }
}

// MARK: - Ambient Sync Types

struct AmbientSyncStatus {
    let isEnabled: Bool
    let currentLux: Double?
    let targetTemperature: Int?

    var temperatureName: String? {
        guard let temp = targetTemperature else { return nil }
        return WhiteBalanceController.getIlluminantName(for: Double(temp))
    }
}

// MARK: - Solar Schedule

extension AutomationEngine {
    /// Start solar schedule-based blue light filtering
    @MainActor
    func startSolarSchedule() {
        guard !isSolarScheduleEnabled else {
            print("SolarSchedule: Already enabled")
            return
        }

        // Get primary display
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID? else {
            print("SolarSchedule: No display found")
            appState.showToast(message: "No display found for Solar Schedule", type: .error)
            return
        }

        // Initialize solar schedule engine if needed
        if solarScheduleEngine == nil {
            solarScheduleEngine = SolarScheduleEngine()
        }

        // Set up state change callback
        solarScheduleEngine?.onStateChanged = { [weak self] phase, strength in
            Task { @MainActor [weak self] in
                self?.appState.currentSolarPhase = phase
                self?.appState.blueLightFilterStrength = strength
            }
        }

        // Start the engine
        solarScheduleEngine?.start(for: displayID)
        isSolarScheduleEnabled = true
        appState.isSolarScheduleEnabled = true

        // Store engine reference in app state
        appState.solarScheduleEngine = solarScheduleEngine

        appState.showToast(message: "Solar Schedule enabled", type: .success)
        print("SolarSchedule: Started for display \(displayID)")
    }

    /// Stop solar schedule-based blue light filtering
    @MainActor
    func stopSolarSchedule() {
        guard isSolarScheduleEnabled else {
            return
        }

        // Stop the engine
        solarScheduleEngine?.stop()
        isSolarScheduleEnabled = false
        appState.isSolarScheduleEnabled = false

        // Clear app state
        appState.currentSolarPhase = nil
        appState.blueLightFilterStrength = 0.0

        appState.showToast(message: "Solar Schedule disabled", type: .info)
        print("SolarSchedule: Stopped")
    }

    /// Toggle solar schedule on/off
    @MainActor
    func toggleSolarSchedule() {
        if isSolarScheduleEnabled {
            stopSolarSchedule()
        } else {
            startSolarSchedule()
        }
    }

    /// Get current solar schedule status
    @MainActor
    func getSolarScheduleStatus() -> SolarScheduleStatus? {
        guard isSolarScheduleEnabled, let engine = solarScheduleEngine else {
            return nil
        }

        let stats = engine.getStatistics()
        return SolarScheduleStatus(
            isEnabled: isSolarScheduleEnabled,
            currentPhase: stats.currentPhase,
            phaseProgress: stats.phaseProgress,
            blueLightFilterStrength: stats.blueLightFilterStrength,
            sunrise: stats.sunrise,
            sunset: stats.sunset,
            isLocationAuthorized: stats.isLocationAuthorized
        )
    }
}

// MARK: - Solar Schedule Types

struct SolarScheduleStatus {
    let isEnabled: Bool
    let currentPhase: SolarPhase
    let phaseProgress: Double
    let blueLightFilterStrength: Double
    let sunrise: Date
    let sunset: Date
    let isLocationAuthorized: Bool

    var phaseDescription: String {
        switch currentPhase {
        case .daytime:
            return "☀️ Daytime"
        case .dawn:
            return "🌄 Dawn"
        case .twilight:
            return "🌅 Twilight"
        case .night:
            return "🌙 Night"
        }
    }

    var filterPercentage: String {
        return String(format: "%.0f%%", blueLightFilterStrength * 100)
    }
}