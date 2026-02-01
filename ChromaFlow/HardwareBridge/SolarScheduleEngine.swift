//
//  SolarScheduleEngine.swift
//  ChromaFlow
//
//  Automated blue light filtering based on solar schedule.
//  Applies liquid transitions for smooth day/night cycle adaptation.
//

import Foundation
import CoreGraphics
import CoreLocation
import Observation

/// Configuration for solar schedule behavior
struct SolarScheduleConfig: Sendable {
    /// Update interval for checking solar phase (seconds)
    let updateInterval: TimeInterval = 300 // 5 minutes

    /// Transition duration for smooth changes (seconds)
    let transitionDuration: TimeInterval = 600 // 10 minutes

    /// Maximum blue light filter strength (0.0 - 1.0)
    let maxBlueLightReduction: Double = 0.5 // 50% reduction

    /// Contrast adjustment during night mode
    let nightContrast: Double = 0.9 // 90% of original

    /// Whether to reduce brightness during night mode
    let adjustBrightness: Bool = false

    /// Night mode brightness multiplier (if adjustBrightness is true)
    let nightBrightness: Double = 0.85 // 85% of original
}

/// Solar schedule engine for automated blue light filtering
@Observable
@MainActor
final class SolarScheduleEngine: @unchecked Sendable {

    // MARK: - Properties

    /// Solar calculator for sunrise/sunset times
    private let solarCalculator = SolarCalculator()

    /// Gamma controller for display adjustments
    private let gammaController = GammaController()

    /// Configuration
    private let config = SolarScheduleConfig()

    /// Timer for periodic updates
    private var updateTimer: Timer?

    /// Whether the engine is currently active
    private(set) var isActive = false

    /// Current solar phase
    private(set) var currentPhase: SolarPhase?

    /// Current blue light filter strength (0.0 - 1.0)
    private(set) var blueLightFilterStrength: Double = 0.0

    /// Target blue light filter strength during transition
    private var targetFilterStrength: Double = 0.0

    /// Transition start time
    private var transitionStartTime: Date?

    /// Transition start strength
    private var transitionStartStrength: Double = 0.0

    /// Display ID to control
    private var displayID: CGDirectDisplayID?

    /// Callback for state changes
    var onStateChanged: ((SolarPhase, Double) -> Void)?

    // MARK: - Public API

    /// Start the solar schedule engine
    func start(for displayID: CGDirectDisplayID) {
        guard !isActive else { return }

        self.displayID = displayID
        isActive = true

        // Request location permission if not already granted
        if !solarCalculator.isLocationAuthorized {
            solarCalculator.requestLocationPermission()
        }

        // Start timer for periodic updates
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: config.updateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSolarState()
            }
        }

        // Trigger immediate update
        updateSolarState()

        print("SolarScheduleEngine: Started for display \(displayID)")
    }

    /// Stop the solar schedule engine
    func stop() {
        guard isActive else { return }

        isActive = false

        // Stop timer
        updateTimer?.invalidate()
        updateTimer = nil

        // Reset gamma to default
        if let displayID = displayID {
            gammaController.resetGamma(for: displayID)
        }

        // Clear state
        currentPhase = nil
        blueLightFilterStrength = 0.0
        targetFilterStrength = 0.0
        transitionStartTime = nil
        displayID = nil

        print("SolarScheduleEngine: Stopped")
    }

    /// Manually set filter strength (overrides automatic schedule)
    func setFilterStrength(_ strength: Double) {
        guard let displayID = displayID else { return }

        blueLightFilterStrength = max(0.0, min(1.0, strength))
        targetFilterStrength = blueLightFilterStrength
        transitionStartTime = nil

        applyBlueLightFilter(strength: blueLightFilterStrength, to: displayID)
    }

    /// Get current solar times
    func getCurrentSolarTimes() -> SolarTimes {
        return solarCalculator.calculateSolarTimes()
    }

    // MARK: - Private Methods

    private func updateSolarState() {
        guard isActive, let displayID = displayID else { return }

        // Get current solar phase
        let newPhase = solarCalculator.getCurrentPhase()

        // Check if phase changed
        if newPhase != currentPhase {
            print("SolarScheduleEngine: Phase changed from \(String(describing: currentPhase)) to \(newPhase)")
            currentPhase = newPhase
            startTransition(to: newPhase)
        }

        // Update transition if in progress
        if transitionStartTime != nil {
            updateTransition(for: displayID)
        }

        // Notify state change
        onStateChanged?(newPhase, blueLightFilterStrength)
    }

    private func startTransition(to phase: SolarPhase) {
        // Calculate target filter strength based on phase
        let newTargetStrength: Double

        switch phase {
        case .daytime:
            // No filtering during day
            newTargetStrength = 0.0

        case .dawn:
            // Gradually reduce filtering during dawn
            let progress = solarCalculator.getPhaseProgress()
            newTargetStrength = config.maxBlueLightReduction * (1.0 - progress)

        case .twilight:
            // Gradually increase filtering during twilight
            let progress = solarCalculator.getPhaseProgress()
            newTargetStrength = config.maxBlueLightReduction * progress

        case .night:
            // Maximum filtering at night
            newTargetStrength = config.maxBlueLightReduction
        }

        // Start smooth transition
        transitionStartTime = Date()
        transitionStartStrength = blueLightFilterStrength
        targetFilterStrength = newTargetStrength

        print("SolarScheduleEngine: Starting transition from \(blueLightFilterStrength) to \(newTargetStrength)")
    }

    private func updateTransition(for displayID: CGDirectDisplayID) {
        guard let startTime = transitionStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(1.0, elapsed / config.transitionDuration)

        // Linear interpolation (could be enhanced with easing functions)
        let newStrength = transitionStartStrength + (targetFilterStrength - transitionStartStrength) * progress

        // Apply new strength
        blueLightFilterStrength = newStrength
        applyBlueLightFilter(strength: newStrength, to: displayID)

        // Clear transition state if complete
        if progress >= 1.0 {
            transitionStartTime = nil
            print("SolarScheduleEngine: Transition complete at strength \(newStrength)")
        }
    }

    private func applyBlueLightFilter(strength: Double, to displayID: CGDirectDisplayID) {
        // Generate gamma tables with reduced blue channel
        let tables = generateBlueLightFilterTables(strength: strength)

        // Apply gamma tables
        let success = gammaController.setGamma(
            red: tables.red,
            green: tables.green,
            blue: tables.blue,
            for: displayID
        )

        if !success {
            print("SolarScheduleEngine: Failed to apply blue light filter")
        }
    }

    /// Generate gamma tables with blue light reduction
    /// - Parameter strength: Filter strength (0.0 = no filter, 1.0 = maximum filter)
    /// - Returns: RGB gamma tables
    private func generateBlueLightFilterTables(
        strength: Double
    ) -> (red: [Float], green: [Float], blue: [Float]) {
        let tableSize = 256
        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()

        // Calculate channel multipliers
        // At maximum strength (1.0):
        // - Blue channel: 50% reduction
        // - Red channel: slight boost for warmth
        // - Green channel: neutral
        let blueReduction = Float(strength * config.maxBlueLightReduction)
        let redBoost = Float(strength * 0.1) // Slight warm tint
        let contrast = Float(1.0 - (strength * (1.0 - config.nightContrast)))

        for i in 0..<tableSize {
            let normalized = Float(i) / Float(tableSize - 1)

            // Apply contrast curve (simple power function)
            let adjusted = pow(normalized, 1.0 / contrast)

            // Apply channel-specific adjustments
            red.append(min(adjusted * (1.0 + redBoost), 1.0))
            green.append(adjusted)
            blue.append(adjusted * (1.0 - blueReduction))
        }

        return (red, green, blue)
    }
}

// MARK: - Solar Schedule Statistics

extension SolarScheduleEngine {
    /// Get statistics about the current solar schedule
    func getStatistics() -> SolarScheduleStatistics {
        let times = solarCalculator.calculateSolarTimes()
        let phase = currentPhase ?? solarCalculator.getCurrentPhase()
        let progress = solarCalculator.getPhaseProgress()

        return SolarScheduleStatistics(
            currentPhase: phase,
            phaseProgress: progress,
            blueLightFilterStrength: blueLightFilterStrength,
            sunrise: times.sunrise,
            sunset: times.sunset,
            dawnStart: times.dawnStart,
            twilightEnd: times.twilightEnd,
            location: solarCalculator.currentLocation.coordinate,
            isLocationAuthorized: solarCalculator.isLocationAuthorized
        )
    }
}

/// Statistics about solar schedule state
struct SolarScheduleStatistics: Sendable {
    let currentPhase: SolarPhase
    let phaseProgress: Double
    let blueLightFilterStrength: Double
    let sunrise: Date
    let sunset: Date
    let dawnStart: Date
    let twilightEnd: Date
    let location: CLLocationCoordinate2D
    let isLocationAuthorized: Bool

    /// Get a user-friendly description of the current phase
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

    /// Get a formatted time range for the current phase
    var phaseTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        switch currentPhase {
        case .daytime:
            return "\(formatter.string(from: sunrise)) - \(formatter.string(from: sunset))"
        case .dawn:
            return "\(formatter.string(from: dawnStart)) - \(formatter.string(from: sunrise))"
        case .twilight:
            return "\(formatter.string(from: sunset)) - \(formatter.string(from: twilightEnd))"
        case .night:
            return "\(formatter.string(from: twilightEnd)) - \(formatter.string(from: dawnStart))"
        }
    }
}
