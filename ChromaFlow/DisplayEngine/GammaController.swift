//
//  GammaController.swift
//  ChromaFlow
//
//  Real-time gamma/LUT controller using CoreGraphics.
//  Provides < 1ms gamma updates for slider-based color temperature adjustment.
//

import CoreGraphics
import Foundation

// MARK: - Gamma Table

/// Represents a complete gamma correction table for a display
public struct GammaTable {
    public let displayID: CGDirectDisplayID
    public let tableSize: UInt32
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]

    public init(displayID: CGDirectDisplayID, tableSize: UInt32, red: [Float], green: [Float], blue: [Float]) {
        self.displayID = displayID
        self.tableSize = tableSize
        self.red = red
        self.green = green
        self.blue = blue
    }
}

// MARK: - Gamma Controller

/// Controller for real-time display gamma manipulation
public final class GammaController {
    // MARK: - Properties

    /// Standard gamma table size (256 entries for 8-bit precision)
    private static let gammaTableSize: UInt32 = 256

    // MARK: - Public API

    /// Set custom gamma tables for a display
    /// - Parameters:
    ///   - red: Red channel gamma curve (256 values, 0.0-1.0)
    ///   - green: Green channel gamma curve (256 values, 0.0-1.0)
    ///   - blue: Blue channel gamma curve (256 values, 0.0-1.0)
    ///   - displayID: Target display ID
    /// - Returns: True if gamma was set successfully
    @discardableResult
    func setGamma(
        red: [Float],
        green: [Float],
        blue: [Float],
        for displayID: CGDirectDisplayID
    ) -> Bool {
        guard red.count == Self.gammaTableSize,
              green.count == Self.gammaTableSize,
              blue.count == Self.gammaTableSize else {
            print("GammaController: Invalid gamma table size (expected \(Self.gammaTableSize))")
            return false
        }

        // CoreGraphics expects values in range [0.0, 1.0]
        let redClamped = red.map { min(max($0, 0.0), 1.0) }
        let greenClamped = green.map { min(max($0, 0.0), 1.0) }
        let blueClamped = blue.map { min(max($0, 0.0), 1.0) }

        // Apply gamma table (synchronous, < 1ms)
        let error = CGSetDisplayTransferByTable(
            displayID,
            Self.gammaTableSize,
            redClamped,
            greenClamped,
            blueClamped
        )

        if error != .success {
            print("GammaController: Failed to set gamma (error: \(error.rawValue))")
            return false
        }

        return true
    }

    /// Adjust color temperature by manipulating gamma curves
    /// - Parameters:
    ///   - temperature: Temperature in Kelvin (1000-10000, 6500 = neutral)
    ///   - displayID: Target display ID
    /// - Returns: True if temperature was applied successfully
    @discardableResult
    func setColorTemperature(_ temperature: Double, for displayID: CGDirectDisplayID) -> Bool {
        let tables = generateTemperatureGammaTables(temperature: temperature)
        return setGamma(red: tables.red, green: tables.green, blue: tables.blue, for: displayID)
    }

    /// Apply blue light filter with custom strength
    /// - Parameters:
    ///   - strength: Filter strength (0.0 = no filter, 1.0 = maximum filter)
    ///   - displayID: Target display ID
    /// - Returns: True if filter was applied successfully
    @discardableResult
    func setBlueLightFilter(strength: Double, for displayID: CGDirectDisplayID) -> Bool {
        let tables = generateBlueLightFilterTables(strength: strength)
        return setGamma(red: tables.red, green: tables.green, blue: tables.blue, for: displayID)
    }

    /// Reset display gamma to ICC profile defaults
    /// - Parameter displayID: Target display ID
    @discardableResult
    func resetGamma(for displayID: CGDirectDisplayID) -> Bool {
        // CGDisplayRestoreColorSyncSettings() returns void
        CGDisplayRestoreColorSyncSettings()
        return true
    }

    // MARK: - Private Helpers

    /// Generate gamma tables for color temperature adjustment
    /// - Parameter temperature: Temperature in Kelvin
    /// - Returns: RGB gamma tables
    private func generateTemperatureGammaTables(
        temperature: Double
    ) -> (red: [Float], green: [Float], blue: [Float]) {
        let kelvin = min(max(temperature, 1000), 10000)
        let neutral: Double = 6500

        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()

        for i in 0..<Int(Self.gammaTableSize) {
            let normalized = Float(i) / Float(Self.gammaTableSize - 1)

            // Calculate color temperature adjustment
            let redMultiplier: Float
            let blueMultiplier: Float

            if kelvin < neutral {
                // Warm: boost red, reduce blue
                let warmFactor = Float((neutral - kelvin) / neutral)
                redMultiplier = 1.0 + (warmFactor * 0.3)
                blueMultiplier = 1.0 - (warmFactor * 0.3)
            } else {
                // Cool: boost blue, reduce red
                let coolFactor = Float((kelvin - neutral) / neutral)
                redMultiplier = 1.0 - (coolFactor * 0.2)
                blueMultiplier = 1.0 + (coolFactor * 0.3)
            }

            red.append(min(normalized * redMultiplier, 1.0))
            green.append(normalized) // Green remains neutral
            blue.append(min(normalized * blueMultiplier, 1.0))
        }

        return (red, green, blue)
    }

    /// Generate gamma tables for blue light filtering
    /// - Parameter strength: Filter strength (0.0 = no filter, 1.0 = maximum filter)
    /// - Returns: RGB gamma tables
    private func generateBlueLightFilterTables(
        strength: Double
    ) -> (red: [Float], green: [Float], blue: [Float]) {
        let clampedStrength = min(max(strength, 0.0), 1.0)

        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()

        // Maximum blue reduction: 50% at full strength
        let maxBlueReduction: Float = 0.5
        let blueReduction = Float(clampedStrength) * maxBlueReduction

        // Slight warm tint by boosting red
        let redBoost = Float(clampedStrength) * 0.1

        // Contrast adjustment (90% at full strength)
        let minContrast: Float = 0.9
        let contrast = 1.0 - (Float(clampedStrength) * (1.0 - minContrast))

        for i in 0..<Int(Self.gammaTableSize) {
            let normalized = Float(i) / Float(Self.gammaTableSize - 1)

            // Apply contrast curve
            let adjusted = pow(normalized, 1.0 / contrast)

            // Apply channel-specific adjustments
            red.append(min(adjusted * (1.0 + redBoost), 1.0))
            green.append(adjusted)
            blue.append(adjusted * (1.0 - blueReduction))
        }

        return (red, green, blue)
    }
}
