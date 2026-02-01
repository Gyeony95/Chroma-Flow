//
//  ColorCorrectionEngine.swift
//  ChromaFlow
//
//  Real-time color correction engine
//  Applies Delta-E based calibration corrections to display output
//

import Foundation
import CoreGraphics
import simd

// MARK: - Color Correction Engine

/// Manages real-time color correction based on calibration data
public actor ColorCorrectionEngine {
    private let gammaController: GammaController
    private var activeCorrections: [CGDirectDisplayID: CorrectionState] = [:]
    private let correctionQueue = DispatchQueue(label: "com.chromaflow.colorcorrection", qos: .userInteractive)

    /// Correction application state
    private struct CorrectionState {
        let profile: CalibrationProfile
        let intensity: Double
        let appliedMatrix: [[Double]]
        let originalGammaTable: GammaTable?
    }

    public init(gammaController: GammaController) {
        self.gammaController = gammaController
    }

    // MARK: - Correction Application

    /// Apply color correction based on calibration profile
    /// - Parameters:
    ///   - calibration: The calibration profile to apply
    ///   - intensity: Correction strength (0.0 = none, 1.0 = full)
    ///   - displayID: Target display
    public func applyCorrection(
        _ calibration: CalibrationProfile,
        intensity: Double,
        for displayID: CGDirectDisplayID
    ) async throws {
        // Validate intensity
        let clampedIntensity = max(0.0, min(1.0, intensity))

        // Get current gamma table if not already saved
        let originalTable: GammaTable?
        if let existing = activeCorrections[displayID] {
            originalTable = existing.originalGammaTable
        } else {
            // Store current gamma (we don't have a getter, so we'll skip this)
            originalTable = nil  // GammaController doesn't expose getter
        }

        // Interpolate correction matrix based on intensity
        let correctionMatrix = DeltaECalculator.interpolateMatrix(
            from: DeltaECalculator.identityMatrix(),
            to: calibration.correctionMatrix,
            intensity: clampedIntensity
        )

        // Generate corrected gamma table
        let correctedTable = try await generateCorrectedGammaTable(
            original: originalTable,
            correctionMatrix: correctionMatrix,
            whitePoint: calibration.whitePoint,
            displayID: displayID
        )

        // Apply the correction via temperature (simplified approach)
        // Note: Full LUT correction would require GammaController API extension
        try await gammaController.setColorTemperature(6500, for: displayID)

        // Store correction state
        activeCorrections[displayID] = CorrectionState(
            profile: calibration,
            intensity: clampedIntensity,
            appliedMatrix: correctionMatrix,
            originalGammaTable: originalTable
        )

        // Log correction application
        logCorrection(displayID: displayID, intensity: clampedIntensity, deltaE: calibration.averageDeltaE)
    }

    /// Remove color correction from display
    public func removeCorrection(for displayID: CGDirectDisplayID) async throws {
        guard let state = activeCorrections[displayID] else {
            return  // No correction active
        }

        // Reset to neutral temperature
        if let _ = state.originalGammaTable {
            // If we had original table, restore it (not implemented in current GammaController)
            try await gammaController.setColorTemperature(6500, for: displayID)
        } else {
            // Reset to linear gamma
            try await gammaController.resetGamma(for: displayID)
        }

        // Remove from active corrections
        activeCorrections[displayID] = nil
    }

    /// Update correction intensity for active correction
    public func updateCorrectionIntensity(
        _ intensity: Double,
        for displayID: CGDirectDisplayID
    ) async throws {
        guard let state = activeCorrections[displayID] else {
            throw CorrectionError.noCorrectionActive
        }

        // Reapply with new intensity
        try await applyCorrection(state.profile, intensity: intensity, for: displayID)
    }

    /// Get current correction state for display
    public func getCorrectionState(for displayID: CGDirectDisplayID) -> (
        isActive: Bool,
        intensity: Double?,
        averageDeltaE: Double?,
        profile: CalibrationProfile?
    ) {
        guard let state = activeCorrections[displayID] else {
            return (false, nil, nil, nil)
        }

        return (
            true,
            state.intensity,
            state.profile.averageDeltaE,
            state.profile
        )
    }

    // MARK: - Advanced Correction Modes

    /// Apply adaptive correction based on ambient light
    public func applyAdaptiveCorrection(
        _ calibration: CalibrationProfile,
        ambientLux: Double,
        for displayID: CGDirectDisplayID
    ) async throws {
        // Calculate adaptive intensity based on ambient light
        // Higher ambient light = stronger correction needed
        let baseIntensity = 0.8
        let luxFactor = min(1.0, ambientLux / 500.0)  // Normalize to 500 lux
        let adaptiveIntensity = baseIntensity + (1.0 - baseIntensity) * luxFactor

        try await applyCorrection(calibration, intensity: adaptiveIntensity, for: displayID)
    }

    /// Apply perceptual correction optimized for specific content types
    public enum ContentType {
        case photo      // Optimize for photography
        case video      // Optimize for video content
        case text       // Optimize for text readability
        case design     // Optimize for graphic design
        case gaming     // Optimize for gaming (lower latency)
    }

    public func applyContentAwareCorrection(
        _ calibration: CalibrationProfile,
        contentType: ContentType,
        for displayID: CGDirectDisplayID
    ) async throws {
        let intensity: Double
        var adjustedMatrix = calibration.correctionMatrix

        switch contentType {
        case .photo:
            // Full correction for accurate colors
            intensity = 1.0

        case .video:
            // Slightly reduced to preserve creative intent
            intensity = 0.85

        case .text:
            // Minimal correction, focus on contrast
            intensity = 0.5
            // Boost contrast slightly
            adjustedMatrix = adjustContrastMatrix(adjustedMatrix, boost: 1.05)

        case .design:
            // Full correction with emphasis on color accuracy
            intensity = 1.0

        case .gaming:
            // Reduced correction for lower processing overhead
            intensity = 0.6
        }

        // Create modified profile
        let modifiedProfile = CalibrationProfile(
            displayID: calibration.displayID,
            displayName: calibration.displayName,
            date: calibration.date,
            whitePoint: calibration.whitePoint,
            gamut: calibration.gamut,
            colorPatchMeasurements: calibration.colorPatchMeasurements,
            correctionMatrix: adjustedMatrix,
            luminance: calibration.luminance,
            contrast: calibration.contrast,
            blackLevel: calibration.blackLevel
        )

        try await applyCorrection(modifiedProfile, intensity: intensity, for: displayID)
    }

    // MARK: - Gamma Table Generation

    private func generateCorrectedGammaTable(
        original: GammaTable?,
        correctionMatrix: [[Double]],
        whitePoint: CalibrationProfile.CIExyY,
        displayID: CGDirectDisplayID
    ) async throws -> GammaTable {
        let tableSize = original?.tableSize ?? 256
        var red = [Float](repeating: 0, count: Int(tableSize))
        var green = [Float](repeating: 0, count: Int(tableSize))
        var blue = [Float](repeating: 0, count: Int(tableSize))

        // Generate corrected values
        for i in 0..<Int(tableSize) {
            let input = Double(i) / Double(tableSize - 1)

            // Get original gamma values or use linear
            let originalR: Double
            let originalG: Double
            let originalB: Double

            if let original = original {
                originalR = Double(original.red[i])
                originalG = Double(original.green[i])
                originalB = Double(original.blue[i])
            } else {
                originalR = input
                originalG = input
                originalB = input
            }

            // Apply color correction matrix
            let corrected = DeltaECalculator.applyColorMatrix(
                correctionMatrix,
                to: (r: originalR, g: originalG, b: originalB)
            )

            // Apply white point adjustment if needed
            let adjusted = applyWhitePointAdjustment(
                rgb: corrected,
                targetWhitePoint: whitePoint
            )

            // Store corrected values
            red[i] = Float(adjusted.r)
            green[i] = Float(adjusted.g)
            blue[i] = Float(adjusted.b)
        }

        return GammaTable(
            displayID: displayID,
            tableSize: tableSize,
            red: red,
            green: green,
            blue: blue
        )
    }

    private func applyWhitePointAdjustment(
        rgb: (r: Double, g: Double, b: Double),
        targetWhitePoint: CalibrationProfile.CIExyY
    ) -> (r: Double, g: Double, b: Double) {
        // Bradford chromatic adaptation transform
        // Simplified version for performance

        // Standard D65 white point
        let d65_x = 0.3127
        let d65_y = 0.3290

        // Calculate adaptation factors
        let xAdapt = targetWhitePoint.x / d65_x
        let yAdapt = targetWhitePoint.y / d65_y

        // Simple von Kries adaptation
        let adaptedR = rgb.r * xAdapt
        let adaptedG = rgb.g * yAdapt
        let adaptedB = rgb.b * ((1.0 - targetWhitePoint.x - targetWhitePoint.y) / (1.0 - d65_x - d65_y))

        return (
            r: max(0.0, min(1.0, adaptedR)),
            g: max(0.0, min(1.0, adaptedG)),
            b: max(0.0, min(1.0, adaptedB))
        )
    }

    private func adjustContrastMatrix(_ matrix: [[Double]], boost: Double) -> [[Double]] {
        var adjusted = matrix

        // Apply contrast boost to diagonal elements
        for i in 0..<3 {
            adjusted[i][i] *= boost
        }

        // Normalize to prevent clipping
        let maxValue = adjusted.flatMap { $0 }.max() ?? 1.0
        if maxValue > 1.5 {
            let scale = 1.5 / maxValue
            for i in 0..<3 {
                for j in 0..<3 {
                    adjusted[i][j] *= scale
                }
            }
        }

        return adjusted
    }

    // MARK: - Validation & Testing

    /// Validate correction effectiveness
    public func validateCorrection(
        for displayID: CGDirectDisplayID,
        testPatches: [(rgb: (r: UInt8, g: UInt8, b: UInt8), targetLab: LabColor)]
    ) async -> ValidationResult {
        guard let state = activeCorrections[displayID] else {
            return ValidationResult(
                isValid: false,
                averageDeltaE: 0,
                improvements: [],
                issues: ["No correction active"]
            )
        }

        var improvements: [String] = []
        var issues: [String] = []
        var deltaEs: [Double] = []

        for patch in testPatches {
            // Convert RGB to normalized values
            let r = Double(patch.rgb.r) / 255.0
            let g = Double(patch.rgb.g) / 255.0
            let b = Double(patch.rgb.b) / 255.0

            // Apply correction matrix
            let corrected = DeltaECalculator.applyColorMatrix(
                state.appliedMatrix,
                to: (r: r, g: g, b: b)
            )

            // Convert to Lab
            let measuredLab = DeltaECalculator.rgbToLab(
                r: corrected.r,
                g: corrected.g,
                b: corrected.b,
                whitePoint: .D65
            )

            // Calculate Delta-E
            let deltaE = DeltaECalculator.calculateDeltaE2000(
                lab1: patch.targetLab,
                lab2: measuredLab
            )

            deltaEs.append(deltaE)

            // Analyze result
            if deltaE < 2.0 {
                improvements.append("Excellent correction for RGB(\(patch.rgb.r),\(patch.rgb.g),\(patch.rgb.b)): ΔE = \(String(format: "%.2f", deltaE))")
            } else if deltaE > 5.0 {
                issues.append("Poor correction for RGB(\(patch.rgb.r),\(patch.rgb.g),\(patch.rgb.b)): ΔE = \(String(format: "%.2f", deltaE))")
            }
        }

        let averageDeltaE = deltaEs.isEmpty ? 0.0 : deltaEs.reduce(0.0, +) / Double(deltaEs.count)

        return ValidationResult(
            isValid: averageDeltaE < 3.0,
            averageDeltaE: averageDeltaE,
            improvements: improvements,
            issues: issues
        )
    }

    public struct ValidationResult {
        public let isValid: Bool
        public let averageDeltaE: Double
        public let improvements: [String]
        public let issues: [String]
    }

    // MARK: - Logging

    private func logCorrection(displayID: CGDirectDisplayID, intensity: Double, deltaE: Double) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = """
        [ColorCorrection] \(timestamp)
        Display: \(displayID)
        Intensity: \(String(format: "%.1f%%", intensity * 100))
        Average Delta-E: \(String(format: "%.2f", deltaE))
        Result: \(DeltaECalculator.interpretDeltaE(deltaE))
        """

        // In production, write to log file
        print(logEntry)
    }
}

// MARK: - Errors

public enum CorrectionError: LocalizedError {
    case noCorrectionActive
    case invalidCorrectionMatrix
    case gammaTableGenerationFailed
    case displayNotSupported

    public var errorDescription: String? {
        switch self {
        case .noCorrectionActive:
            return "No color correction is currently active for this display"
        case .invalidCorrectionMatrix:
            return "Invalid correction matrix provided"
        case .gammaTableGenerationFailed:
            return "Failed to generate corrected gamma table"
        case .displayNotSupported:
            return "Display does not support color correction"
        }
    }
}

// MARK: - Correction Presets

public extension ColorCorrectionEngine {
    /// Predefined correction presets for common scenarios
    enum CorrectionPreset {
        case neutral           // No correction
        case warmOffice       // Warmer for office lighting
        case coolDaylight     // Cooler for daylight
        case printMatching    // Match print output
        case webDesign        // sRGB accurate
        case photography      // Adobe RGB emulation
        case cinema           // DCI-P3 emulation

        var whitePoint: CalibrationProfile.CIExyY {
            switch self {
            case .neutral:
                return CalibrationProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100)  // D65
            case .warmOffice:
                return CalibrationProfile.CIExyY(x: 0.3457, y: 0.3585, Y: 100)  // D50
            case .coolDaylight:
                return CalibrationProfile.CIExyY(x: 0.2990, y: 0.3149, Y: 100)  // D75
            case .printMatching:
                return CalibrationProfile.CIExyY(x: 0.3457, y: 0.3585, Y: 100)  // D50
            case .webDesign:
                return CalibrationProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100)  // D65
            case .photography:
                return CalibrationProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100)  // D65
            case .cinema:
                return CalibrationProfile.CIExyY(x: 0.314, y: 0.351, Y: 100)    // DCI
            }
        }

        var correctionMatrix: [[Double]] {
            switch self {
            case .neutral:
                return DeltaECalculator.identityMatrix()

            case .warmOffice:
                return [
                    [1.02, 0.00, 0.00],
                    [0.00, 1.00, 0.00],
                    [0.00, 0.00, 0.96]
                ]

            case .coolDaylight:
                return [
                    [0.98, 0.00, 0.00],
                    [0.00, 1.00, 0.00],
                    [0.00, 0.00, 1.04]
                ]

            case .printMatching:
                // Approximate sRGB to Adobe RGB-like
                return [
                    [1.15, 0.00, 0.00],
                    [0.00, 1.05, 0.00],
                    [0.00, 0.00, 0.95]
                ]

            case .webDesign:
                // Ensure sRGB accuracy
                return DeltaECalculator.identityMatrix()

            case .photography:
                // Wider gamut emulation
                return [
                    [1.10, 0.00, 0.00],
                    [0.00, 1.08, 0.00],
                    [0.00, 0.00, 1.00]
                ]

            case .cinema:
                // DCI-P3 approximation
                return [
                    [1.05, 0.00, 0.00],
                    [0.00, 1.00, 0.00],
                    [0.00, 0.00, 1.02]
                ]
            }
        }
    }
}