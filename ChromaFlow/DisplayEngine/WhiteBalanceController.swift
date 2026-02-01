//
//  WhiteBalanceController.swift
//  ChromaFlow
//
//  Maps ambient light sensor data to color temperature and applies smooth transitions.
//  Supports D50 (5000K), D65 (6500K), D75 (7500K) illuminant standards.
//

import Foundation
import CoreGraphics

/// Controller for ambient light-based white balance adjustment
final class WhiteBalanceController: @unchecked Sendable {

    // MARK: - Properties

    /// Reference to gamma controller for applying temperature
    private let gammaController = GammaController()

    /// Current target temperature in Kelvin
    private var currentTemperature: Double = 6500

    /// Temperature transition duration (seconds)
    private let transitionDuration: TimeInterval = 1.0

    /// Minimum change threshold to trigger update (prevents jitter)
    private let temperatureThreshold: Double = 100

    /// Debounce timer to prevent rapid changes
    private var debounceTask: Task<Void, Never>?

    // MARK: - Temperature Mapping Constants

    /// Lux ranges for different lighting conditions
    private enum LuxRange {
        static let darkMax: Double = 100       // 0-100 lux: dark environment
        static let normalMax: Double = 500     // 100-500 lux: normal indoor
        // 500+ lux: bright environment
    }

    /// Temperature ranges in Kelvin
    private enum TemperatureRange {
        static let warmMin: Double = 3000      // Warm (D50-like)
        static let warmMax: Double = 4000
        static let neutralMin: Double = 5000   // Neutral
        static let neutralMax: Double = 6000   // D65 standard
        static let coolMin: Double = 6500      // Cool (D75-like)
        static let coolMax: Double = 7500
    }

    // MARK: - Public API

    /// Apply white balance based on ambient light level
    /// - Parameters:
    ///   - lux: Ambient light level in lux
    ///   - displayID: Target display ID
    ///   - smooth: Whether to apply smooth transition (default: true)
    func applyWhiteBalance(
        lux: Double,
        displayID: CGDirectDisplayID,
        smooth: Bool = true
    ) async {
        // Map lux to color temperature
        let targetTemperature = mapLuxToTemperature(lux: lux)

        // Check if change is significant enough
        guard abs(targetTemperature - currentTemperature) >= temperatureThreshold else {
            return
        }

        // Cancel any pending debounce task
        debounceTask?.cancel()

        if smooth {
            // Apply with smooth transition
            await applyTemperatureSmooth(
                from: currentTemperature,
                to: targetTemperature,
                displayID: displayID
            )
        } else {
            // Apply immediately
            gammaController.setColorTemperature(targetTemperature, for: displayID)
            currentTemperature = targetTemperature
        }
    }

    /// Apply white balance with debouncing to prevent rapid changes
    /// - Parameters:
    ///   - lux: Ambient light level in lux
    ///   - displayID: Target display ID
    ///   - debounceDelay: Delay before applying (default: 2 seconds)
    func applyWhiteBalanceDebounced(
        lux: Double,
        displayID: CGDirectDisplayID,
        debounceDelay: TimeInterval = 2.0
    ) {
        // Cancel previous debounce task
        debounceTask?.cancel()

        // Create new debounce task
        debounceTask = Task {
            // Wait for debounce delay
            try? await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))

            // Check if cancelled
            guard !Task.isCancelled else { return }

            // Apply white balance
            await applyWhiteBalance(lux: lux, displayID: displayID, smooth: true)
        }
    }

    /// Reset display to default white balance
    /// - Parameter displayID: Target display ID
    func reset(displayID: CGDirectDisplayID) {
        gammaController.resetGamma(for: displayID)
        currentTemperature = 6500
        debounceTask?.cancel()
    }

    /// Get current target temperature
    /// - Returns: Current temperature in Kelvin
    func getCurrentTemperature() -> Double {
        return currentTemperature
    }

    // MARK: - Private Methods

    /// Map lux value to color temperature using segmented linear interpolation
    /// - Parameter lux: Ambient light level in lux (0-100000)
    /// - Returns: Color temperature in Kelvin (3000-7500)
    private func mapLuxToTemperature(lux: Double) -> Double {
        switch lux {
        case 0...LuxRange.darkMax:
            // Dark environment: 0-100 lux → 3000-4000K (warm, D50-like)
            return linearInterpolate(
                value: lux,
                inMin: 0,
                inMax: LuxRange.darkMax,
                outMin: TemperatureRange.warmMin,
                outMax: TemperatureRange.warmMax
            )

        case LuxRange.darkMax...LuxRange.normalMax:
            // Normal indoor: 100-500 lux → 5000-6500K (neutral to D65)
            return linearInterpolate(
                value: lux,
                inMin: LuxRange.darkMax,
                inMax: LuxRange.normalMax,
                outMin: TemperatureRange.neutralMin,
                outMax: TemperatureRange.coolMin
            )

        default:
            // Bright environment: 500+ lux → 6500-7500K (cool, D75-like)
            // Cap at 10000 lux for mapping
            let cappedLux = min(lux, 10000)
            return linearInterpolate(
                value: cappedLux,
                inMin: LuxRange.normalMax,
                inMax: 10000,
                outMin: TemperatureRange.coolMin,
                outMax: TemperatureRange.coolMax
            )
        }
    }

    /// Linear interpolation helper
    private func linearInterpolate(
        value: Double,
        inMin: Double,
        inMax: Double,
        outMin: Double,
        outMax: Double
    ) -> Double {
        let normalized = (value - inMin) / (inMax - inMin)
        return outMin + normalized * (outMax - outMin)
    }

    /// Apply temperature with smooth transition using linear interpolation
    /// - Parameters:
    ///   - startTemperature: Starting temperature in Kelvin
    ///   - endTemperature: Target temperature in Kelvin
    ///   - displayID: Target display ID
    private func applyTemperatureSmooth(
        from startTemperature: Double,
        to endTemperature: Double,
        displayID: CGDirectDisplayID
    ) async {
        let steps = 20 // 20 steps over 1 second = 50ms per step
        let stepDelay: UInt64 = UInt64(transitionDuration / Double(steps) * 1_000_000_000)

        for step in 0...steps {
            // Check if task was cancelled
            guard !Task.isCancelled else {
                return
            }

            let progress = Double(step) / Double(steps)
            let temperature = startTemperature + (endTemperature - startTemperature) * progress

            gammaController.setColorTemperature(temperature, for: displayID)

            // Don't sleep on last step
            if step < steps {
                try? await Task.sleep(nanoseconds: stepDelay)
            }
        }

        currentTemperature = endTemperature
    }
}

// MARK: - Helper Extensions

extension WhiteBalanceController {
    /// Get illuminant standard name for a given temperature
    /// - Parameter temperature: Temperature in Kelvin
    /// - Returns: Human-readable illuminant name
    static func getIlluminantName(for temperature: Double) -> String {
        switch temperature {
        case 0..<4500:
            return "D50 (Warm)"
        case 4500..<6000:
            return "D55 (Neutral)"
        case 6000..<7000:
            return "D65 (Standard)"
        default:
            return "D75 (Cool)"
        }
    }

    /// Get recommended temperature for specific use cases
    enum UseCaseTemperature {
        static let photoEditing: Double = 5000      // D50 for print work
        static let videoEditing: Double = 6500      // D65 for broadcast
        static let generalUse: Double = 6500        // D65 standard
        static let reading: Double = 4000           // Warm for eye comfort
        static let outdoor: Double = 7500           // Cool for bright conditions
    }
}
