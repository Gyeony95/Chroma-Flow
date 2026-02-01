//
//  VirtualHDREngine.swift
//  ChromaFlow
//
//  Virtual HDR Emulation Engine - Provides HDR-like visual experience on SDR monitors
//  through advanced tone mapping and local contrast enhancement
//

import Foundation
import Cocoa
import simd

/// Virtual HDR Engine that simulates high dynamic range on SDR displays
@MainActor
final class VirtualHDREngine: ObservableObject {

    // MARK: - Properties

    @Published var isEnabled: Bool = false
    @Published var intensity: Double = 0.5 // 0.0 to 1.0
    @Published var localContrastBoost: Double = 0.3 // 0.0 to 1.0

    private let gammaController: GammaController
    private var cachedLUTs: [String: (red: [Float], green: [Float], blue: [Float])] = [:]

    // PQ (Perceptual Quantizer) constants
    private let pqM1: Double = 0.1593017578125
    private let pqM2: Double = 78.84375
    private let pqC1: Double = 0.8359375
    private let pqC2: Double = 18.8515625
    private let pqC3: Double = 18.6875

    // ACES Filmic Tone Mapping constants
    private let acesA: Double = 2.51
    private let acesB: Double = 0.03
    private let acesC: Double = 2.43
    private let acesD: Double = 0.59
    private let acesE: Double = 0.14

    // Performance monitoring
    private var lastUpdateTime: Date = Date()
    private var updateDuration: TimeInterval = 0

    // MARK: - Initialization

    init(gammaController: GammaController) {
        self.gammaController = gammaController
    }

    // MARK: - Public Methods

    /// Enable HDR emulation for a specific display
    func enableHDREmulation(intensity: Double = 0.5, for displayID: CGDirectDisplayID) async throws {
        guard !isEnabled else { return }

        self.intensity = max(0, min(1, intensity))
        self.isEnabled = true

        try await applyHDREmulation(to: displayID)
    }

    /// Disable HDR emulation and restore original gamma
    func disableHDREmulation(for displayID: CGDirectDisplayID) async throws {
        guard isEnabled else { return }

        // Restore display to default ICC profile gamma
        gammaController.resetGamma(for: displayID)

        isEnabled = false
    }

    /// Adjust HDR emulation intensity
    func adjustIntensity(_ intensity: Double, for displayID: CGDirectDisplayID) async throws {
        guard isEnabled else { return }

        self.intensity = max(0, min(1, intensity))
        try await applyHDREmulation(to: displayID)
    }

    /// Adjust local contrast enhancement
    func adjustLocalContrast(_ boost: Double, for displayID: CGDirectDisplayID) async throws {
        guard isEnabled else { return }

        self.localContrastBoost = max(0, min(1, boost))
        try await applyHDREmulation(to: displayID)
    }

    // MARK: - Private Methods

    /// Apply HDR emulation to display
    private func applyHDREmulation(to displayID: CGDirectDisplayID) async throws {
        let startTime = Date()

        // Generate or retrieve cached LUT
        let lutKey = "\(displayID)_\(intensity)_\(localContrastBoost)"
        let (red, green, blue): ([CGGammaValue], [CGGammaValue], [CGGammaValue])

        if let cached = cachedLUTs[lutKey] {
            (red, green, blue) = cached
        } else {
            (red, green, blue) = generateHDRLUT(for: displayID)

            // Cache the LUT (limit cache size)
            if cachedLUTs.count > 20 {
                cachedLUTs.removeAll()
            }
            cachedLUTs[lutKey] = (red, green, blue)
        }

        // Apply the HDR LUT
        try await gammaController.setGamma(
            red: red,
            green: green,
            blue: blue,
            for: displayID
        )

        updateDuration = Date().timeIntervalSince(startTime)
    }

    /// Generate HDR Look-Up Table
    private func generateHDRLUT(for displayID: CGDirectDisplayID) -> (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
        let tableSize = 256
        var red = [CGGammaValue](repeating: 0, count: tableSize)
        var green = [CGGammaValue](repeating: 0, count: tableSize)
        var blue = [CGGammaValue](repeating: 0, count: tableSize)

        // Use linear gamma as base (standard sRGB)
        let original = (
            red: (0..<tableSize).map { Float($0) / Float(tableSize - 1) },
            green: (0..<tableSize).map { Float($0) / Float(tableSize - 1) },
            blue: (0..<tableSize).map { Float($0) / Float(tableSize - 1) }
        )

        for i in 0..<tableSize {
            let normalizedInput = Double(i) / Double(tableSize - 1)

            // Apply original gamma first
            let originalRed = Double(original.red[min(i, original.red.count - 1)])
            let originalGreen = Double(original.green[min(i, original.green.count - 1)])
            let originalBlue = Double(original.blue[min(i, original.blue.count - 1)])

            // Apply HDR tone mapping
            let hdrRed = applyHDRToneMapping(originalRed)
            let hdrGreen = applyHDRToneMapping(originalGreen)
            let hdrBlue = applyHDRToneMapping(originalBlue)

            // Apply local contrast enhancement
            let enhancedRed = applyLocalContrastEnhancement(hdrRed, original: originalRed)
            let enhancedGreen = applyLocalContrastEnhancement(hdrGreen, original: originalGreen)
            let enhancedBlue = applyLocalContrastEnhancement(hdrBlue, original: originalBlue)

            // Mix with original based on intensity
            red[i] = CGGammaValue(mix(originalRed, enhancedRed, by: intensity))
            green[i] = CGGammaValue(mix(originalGreen, enhancedGreen, by: intensity))
            blue[i] = CGGammaValue(mix(originalBlue, enhancedBlue, by: intensity))
        }

        return (red, green, blue)
    }

    /// Apply HDR tone mapping using ACES Filmic and PQ curves
    private func applyHDRToneMapping(_ input: Double) -> Double {
        // First apply ACES Filmic tone mapping
        let aces = acesFilmicToneMapping(input * 2.0) // Boost input range

        // Then apply partial PQ curve for perceptual enhancement
        let pq = pqEOTF(aces)

        // Blend between ACES and PQ based on intensity
        return mix(aces, pq, by: intensity * 0.5)
    }

    /// ACES Filmic Tone Mapping
    private func acesFilmicToneMapping(_ x: Double) -> Double {
        let numerator = x * (acesA * x + acesB)
        let denominator = x * (acesC * x + acesD) + acesE
        return min(1.0, numerator / denominator)
    }

    /// PQ Electro-Optical Transfer Function (simplified)
    private func pqEOTF(_ input: Double) -> Double {
        guard input > 0 else { return 0 }

        let Lm1 = pow(input, pqM1)
        let numerator = pqC1 + pqC2 * Lm1
        let denominator = 1 + pqC3 * Lm1

        guard denominator > 0 else { return input }

        let output = pow(numerator / denominator, pqM2)

        // Normalize to 0-1 range (assuming 10000 nits max)
        return min(1.0, output / 10000.0)
    }

    /// Apply local contrast enhancement
    private func applyLocalContrastEnhancement(_ value: Double, original: Double) -> Double {
        // Identify region (shadow, midtone, highlight)
        let shadowThreshold = 0.25
        let highlightThreshold = 0.75

        var enhanced = value

        if original < shadowThreshold {
            // Shadow detail enhancement (lift)
            let shadowBoost = localContrastBoost * 0.1
            enhanced = value + shadowBoost * (1.0 - value)
        } else if original > highlightThreshold {
            // Highlight boost
            let highlightBoost = localContrastBoost * 0.2
            enhanced = value + highlightBoost * (1.0 - value)
        } else {
            // Midtone contrast
            let midPoint = 0.5
            let contrast = 1.0 + localContrastBoost
            enhanced = (value - midPoint) * contrast + midPoint
        }

        // Apply S-curve for enhanced contrast
        enhanced = applySCurve(enhanced, strength: localContrastBoost * 0.5)

        return max(0, min(1, enhanced))
    }

    /// Apply S-curve for contrast enhancement
    private func applySCurve(_ value: Double, strength: Double) -> Double {
        guard strength > 0 else { return value }

        // Sigmoid function for S-curve
        let k = 5.0 * strength // Curve steepness
        let midPoint = 0.5

        let sigmoid = 1.0 / (1.0 + exp(-k * (value - midPoint)))

        // Normalize to maintain 0 and 1 endpoints
        let sigmoidMin = 1.0 / (1.0 + exp(k * midPoint))
        let sigmoidMax = 1.0 / (1.0 + exp(-k * midPoint))

        return (sigmoid - sigmoidMin) / (sigmoidMax - sigmoidMin)
    }

    /// Linear interpolation helper
    private func mix(_ a: Double, _ b: Double, by t: Double) -> Double {
        return a * (1 - t) + b * t
    }

    // MARK: - Performance Monitoring

    /// Get current performance metrics
    func getPerformanceMetrics() -> (updateTime: TimeInterval, cacheSize: Int) {
        return (updateDuration, cachedLUTs.count)
    }

    /// Clear LUT cache
    func clearCache() {
        cachedLUTs.removeAll()
    }

    // MARK: - Presets

    enum HDRPreset {
        case subtle
        case balanced
        case vivid
        case cinematic
        case gaming

        var intensity: Double {
            switch self {
            case .subtle: return 0.3
            case .balanced: return 0.5
            case .vivid: return 0.7
            case .cinematic: return 0.6
            case .gaming: return 0.8
            }
        }

        var localContrast: Double {
            switch self {
            case .subtle: return 0.2
            case .balanced: return 0.3
            case .vivid: return 0.5
            case .cinematic: return 0.4
            case .gaming: return 0.6
            }
        }
    }

    /// Apply HDR preset
    func applyPreset(_ preset: HDRPreset, for displayID: CGDirectDisplayID) async throws {
        self.intensity = preset.intensity
        self.localContrastBoost = preset.localContrast

        if isEnabled {
            try await applyHDREmulation(to: displayID)
        }
    }
}

// MARK: - HDR Metadata

struct HDRMetadata {
    let maxContentLightLevel: Double // Max nits
    let maxFrameAverageLightLevel: Double // Average nits
    let minMasteringLuminance: Double
    let maxMasteringLuminance: Double
    let colorPrimaries: ColorPrimaries

    enum ColorPrimaries {
        case rec709  // SDR
        case rec2020 // HDR
        case p3      // Display P3
    }
}

// MARK: - Extensions

extension VirtualHDREngine {
    /// Analyze current display capabilities
    func analyzeDisplayCapabilities(for displayID: CGDirectDisplayID) -> DisplayCapabilities {
        // Get display color space
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        let isWideGamut = colorSpace.name == CGColorSpace.displayP3

        // Estimate peak brightness (this is approximate)
        let estimatedPeakNits: Double = isWideGamut ? 500 : 400

        return DisplayCapabilities(
            supportsTrueHDR: false,
            estimatedPeakNits: estimatedPeakNits,
            colorGamut: isWideGamut ? .p3 : .sRGB,
            bitDepth: 8 // Most SDR displays
        )
    }

    struct DisplayCapabilities {
        let supportsTrueHDR: Bool
        let estimatedPeakNits: Double
        let colorGamut: ColorGamut
        let bitDepth: Int

        enum ColorGamut {
            case sRGB
            case p3
            case adobeRGB
            case rec2020
        }
    }
}