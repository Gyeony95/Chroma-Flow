//
//  DeltaECalculator.swift
//  ChromaFlow
//
//  Delta-E 2000 (CIEDE2000) color difference calculator
//  Provides professional-grade perceptual color difference calculations
//

import Foundation
import simd

// MARK: - Color Space Structures

/// Lab color space representation
public struct LabColor: Codable, Equatable {
    public let L: Double  // Lightness (0-100)
    public let a: Double  // Green-Red (-128 to 127)
    public let b: Double  // Blue-Yellow (-128 to 127)

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// XYZ color space representation
public struct XYZColor: Codable, Equatable {
    public let X: Double
    public let Y: Double
    public let Z: Double

    public init(X: Double, Y: Double, Z: Double) {
        self.X = X
        self.Y = Y
        self.Z = Z
    }
}

/// Standard illuminants for color space conversions
public enum WhitePoint: String, Codable {
    case D50 = "D50"  // Graphic arts standard
    case D65 = "D65"  // sRGB, Rec.709 standard
    case D75 = "D75"  // North sky daylight

    var tristimulus: (X: Double, Y: Double, Z: Double) {
        switch self {
        case .D50:
            return (X: 96.422, Y: 100.000, Z: 82.521)
        case .D65:
            return (X: 95.047, Y: 100.000, Z: 108.883)
        case .D75:
            return (X: 94.972, Y: 100.000, Z: 122.638)
        }
    }
}

// MARK: - Delta-E Calculator

/// Professional color difference calculator implementing CIEDE2000
public struct DeltaECalculator {

    // MARK: - Delta-E 2000 (CIEDE2000) Implementation

    /// Calculate Delta-E 2000 between two Lab colors
    /// - Parameters:
    ///   - lab1: First Lab color
    ///   - lab2: Second Lab color
    ///   - kL: Lightness weighting factor (default 1.0)
    ///   - kC: Chroma weighting factor (default 1.0)
    ///   - kH: Hue weighting factor (default 1.0)
    /// - Returns: Delta-E value (0 = identical, <1 = imperceptible, >10 = significant)
    public static func calculateDeltaE2000(
        lab1: LabColor,
        lab2: LabColor,
        kL: Double = 1.0,
        kC: Double = 1.0,
        kH: Double = 1.0
    ) -> Double {
        // Convert to radians helper
        let deg2rad = { (deg: Double) -> Double in deg * .pi / 180.0 }
        let rad2deg = { (rad: Double) -> Double in rad * 180.0 / .pi }

        // Calculate C* (chroma) for each color
        let C1_star = sqrt(lab1.a * lab1.a + lab1.b * lab1.b)
        let C2_star = sqrt(lab2.a * lab2.a + lab2.b * lab2.b)

        // Calculate mean C*
        let C_star_mean = (C1_star + C2_star) / 2.0

        // Calculate G factor
        let C_star_mean_7 = pow(C_star_mean, 7.0)
        let G = 0.5 * (1.0 - sqrt(C_star_mean_7 / (C_star_mean_7 + pow(25.0, 7.0))))

        // Calculate a' (adjusted a*)
        let a1_prime = lab1.a * (1.0 + G)
        let a2_prime = lab2.a * (1.0 + G)

        // Calculate C' (adjusted chroma)
        let C1_prime = sqrt(a1_prime * a1_prime + lab1.b * lab1.b)
        let C2_prime = sqrt(a2_prime * a2_prime + lab2.b * lab2.b)

        // Calculate h' (hue angle)
        let h1_prime = atan2(lab1.b, a1_prime)
        let h2_prime = atan2(lab2.b, a2_prime)

        // Calculate ΔL', ΔC', ΔH'
        let deltaL_prime = lab2.L - lab1.L
        let deltaC_prime = C2_prime - C1_prime

        var deltah_prime = h2_prime - h1_prime
        if deltah_prime > .pi { deltah_prime -= 2.0 * .pi }
        if deltah_prime < -.pi { deltah_prime += 2.0 * .pi }

        let deltaH_prime = 2.0 * sqrt(C1_prime * C2_prime) * sin(deltah_prime / 2.0)

        // Calculate mean values
        let L_prime_mean = (lab1.L + lab2.L) / 2.0
        let C_prime_mean = (C1_prime + C2_prime) / 2.0

        var h_prime_mean = (h1_prime + h2_prime) / 2.0
        if abs(h1_prime - h2_prime) > .pi {
            h_prime_mean += .pi
        }

        // Calculate T
        let h_prime_mean_deg = rad2deg(h_prime_mean)
        let T = 1.0 - 0.17 * cos(deg2rad(h_prime_mean_deg - 30.0))
                + 0.24 * cos(deg2rad(2.0 * h_prime_mean_deg))
                + 0.32 * cos(deg2rad(3.0 * h_prime_mean_deg + 6.0))
                - 0.20 * cos(deg2rad(4.0 * h_prime_mean_deg - 63.0))

        // Calculate SL, SC, SH
        let L_prime_mean_minus_50_squared = pow(L_prime_mean - 50.0, 2.0)
        let SL = 1.0 + (0.015 * L_prime_mean_minus_50_squared) / sqrt(20.0 + L_prime_mean_minus_50_squared)
        let SC = 1.0 + 0.045 * C_prime_mean
        let SH = 1.0 + 0.015 * C_prime_mean * T

        // Calculate RT
        let deltaTheta = deg2rad(30.0 * exp(-pow((h_prime_mean_deg - 275.0) / 25.0, 2.0)))
        let C_prime_mean_7 = pow(C_prime_mean, 7.0)
        let RC = 2.0 * sqrt(C_prime_mean_7 / (C_prime_mean_7 + pow(25.0, 7.0)))
        let RT = -RC * sin(2.0 * deltaTheta)

        // Calculate final Delta-E 2000
        let deltaL_component = deltaL_prime / (kL * SL)
        let deltaC_component = deltaC_prime / (kC * SC)
        let deltaH_component = deltaH_prime / (kH * SH)

        let deltaE = sqrt(
            pow(deltaL_component, 2.0) +
            pow(deltaC_component, 2.0) +
            pow(deltaH_component, 2.0) +
            RT * deltaC_component * deltaH_component
        )

        return deltaE
    }

    // MARK: - Color Space Conversions

    /// Convert RGB (0-1 range) to Lab color space
    public static func rgbToLab(r: Double, g: Double, b: Double, whitePoint: WhitePoint = .D65) -> LabColor {
        let xyz = rgbToXYZ(r: r, g: g, b: b)
        return xyzToLab(xyz: xyz, whitePoint: whitePoint)
    }

    /// Convert Lab to RGB (0-1 range)
    public static func labToRGB(lab: LabColor, whitePoint: WhitePoint = .D65) -> (r: Double, g: Double, b: Double) {
        let xyz = labToXYZ(lab: lab, whitePoint: whitePoint)
        return xyzToRGB(xyz: xyz)
    }

    /// Convert RGB to XYZ (using sRGB primaries)
    private static func rgbToXYZ(r: Double, g: Double, b: Double) -> XYZColor {
        // Apply gamma correction (sRGB)
        let gammaCorrect = { (channel: Double) -> Double in
            if channel <= 0.04045 {
                return channel / 12.92
            } else {
                return pow((channel + 0.055) / 1.055, 2.4)
            }
        }

        let rLinear = gammaCorrect(r)
        let gLinear = gammaCorrect(g)
        let bLinear = gammaCorrect(b)

        // sRGB to XYZ matrix (D65 illuminant)
        let X = rLinear * 0.4124564 + gLinear * 0.3575761 + bLinear * 0.1804375
        let Y = rLinear * 0.2126729 + gLinear * 0.7151522 + bLinear * 0.0721750
        let Z = rLinear * 0.0193339 + gLinear * 0.1191920 + bLinear * 0.9503041

        return XYZColor(X: X * 100.0, Y: Y * 100.0, Z: Z * 100.0)
    }

    /// Convert XYZ to RGB (using sRGB primaries)
    private static func xyzToRGB(xyz: XYZColor) -> (r: Double, g: Double, b: Double) {
        // Normalize XYZ values
        let X = xyz.X / 100.0
        let Y = xyz.Y / 100.0
        let Z = xyz.Z / 100.0

        // XYZ to sRGB matrix (D65 illuminant)
        var r = X *  3.2404542 + Y * -1.5371385 + Z * -0.4985314
        var g = X * -0.9692660 + Y *  1.8760108 + Z *  0.0415560
        var b = X *  0.0556434 + Y * -0.2040259 + Z *  1.0572252

        // Apply inverse gamma correction (sRGB)
        let inverseGamma = { (channel: Double) -> Double in
            if channel <= 0.0031308 {
                return channel * 12.92
            } else {
                return 1.055 * pow(channel, 1.0 / 2.4) - 0.055
            }
        }

        r = inverseGamma(r)
        g = inverseGamma(g)
        b = inverseGamma(b)

        // Clamp to [0, 1]
        r = max(0.0, min(1.0, r))
        g = max(0.0, min(1.0, g))
        b = max(0.0, min(1.0, b))

        return (r: r, g: g, b: b)
    }

    /// Convert XYZ to Lab
    private static func xyzToLab(xyz: XYZColor, whitePoint: WhitePoint) -> LabColor {
        let white = whitePoint.tristimulus

        // Normalize by white point
        let xn = xyz.X / white.X
        let yn = xyz.Y / white.Y
        let zn = xyz.Z / white.Z

        // Apply Lab conversion function
        let f = { (t: Double) -> Double in
            let delta = 6.0 / 29.0
            if t > pow(delta, 3.0) {
                return pow(t, 1.0 / 3.0)
            } else {
                return t / (3.0 * delta * delta) + 4.0 / 29.0
            }
        }

        let fx = f(xn)
        let fy = f(yn)
        let fz = f(zn)

        let L = 116.0 * fy - 16.0
        let a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)

        return LabColor(L: L, a: a, b: b)
    }

    /// Convert Lab to XYZ
    private static func labToXYZ(lab: LabColor, whitePoint: WhitePoint) -> XYZColor {
        let white = whitePoint.tristimulus

        let fy = (lab.L + 16.0) / 116.0
        let fx = lab.a / 500.0 + fy
        let fz = fy - lab.b / 200.0

        // Apply inverse Lab conversion function
        let finv = { (t: Double) -> Double in
            let delta = 6.0 / 29.0
            if t > delta {
                return pow(t, 3.0)
            } else {
                return 3.0 * delta * delta * (t - 4.0 / 29.0)
            }
        }

        let xn = finv(fx)
        let yn = finv(fy)
        let zn = finv(fz)

        let X = xn * white.X
        let Y = yn * white.Y
        let Z = zn * white.Z

        return XYZColor(X: X, Y: Y, Z: Z)
    }

    // MARK: - Utility Functions

    /// Interpret Delta-E value as perceptual difference
    public static func interpretDeltaE(_ deltaE: Double) -> String {
        switch deltaE {
        case 0..<1:
            return "Imperceptible (ΔE < 1)"
        case 1..<2:
            return "Very slight difference (ΔE 1-2)"
        case 2..<3.5:
            return "Noticeable to trained eye (ΔE 2-3.5)"
        case 3.5..<5:
            return "Noticeable difference (ΔE 3.5-5)"
        case 5..<10:
            return "Clear difference (ΔE 5-10)"
        default:
            return "Significant difference (ΔE > 10)"
        }
    }

    /// Calculate average Delta-E for a set of color patches
    public static func averageDeltaE(patches: [(target: LabColor, measured: LabColor)]) -> Double {
        guard !patches.isEmpty else { return 0.0 }

        let totalDeltaE = patches.reduce(0.0) { sum, patch in
            sum + calculateDeltaE2000(lab1: patch.target, lab2: patch.measured)
        }

        return totalDeltaE / Double(patches.count)
    }

    /// Calculate Delta-E statistics for color patches
    public static func deltaEStatistics(patches: [(target: LabColor, measured: LabColor)]) -> (
        average: Double,
        max: Double,
        min: Double,
        percentile95: Double
    ) {
        guard !patches.isEmpty else {
            return (average: 0, max: 0, min: 0, percentile95: 0)
        }

        let deltaEs = patches.map { patch in
            calculateDeltaE2000(lab1: patch.target, lab2: patch.measured)
        }.sorted()

        let average = deltaEs.reduce(0.0, +) / Double(deltaEs.count)
        let max = deltaEs.last ?? 0.0
        let min = deltaEs.first ?? 0.0

        // Calculate 95th percentile
        let index95 = Int(Double(deltaEs.count) * 0.95)
        let percentile95 = deltaEs[Swift.min(index95, deltaEs.count - 1)]

        return (average: average, max: max, min: min, percentile95: percentile95)
    }
}

// MARK: - Color Matrix Operations

extension DeltaECalculator {

    /// Apply 3x3 color correction matrix to RGB values
    public static func applyColorMatrix(_ matrix: [[Double]], to rgb: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        guard matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }) else {
            return rgb  // Return unchanged if matrix is invalid
        }

        let r = matrix[0][0] * rgb.r + matrix[0][1] * rgb.g + matrix[0][2] * rgb.b
        let g = matrix[1][0] * rgb.r + matrix[1][1] * rgb.g + matrix[1][2] * rgb.b
        let b = matrix[2][0] * rgb.r + matrix[2][1] * rgb.g + matrix[2][2] * rgb.b

        // Clamp to valid range
        return (
            r: max(0.0, min(1.0, r)),
            g: max(0.0, min(1.0, g)),
            b: max(0.0, min(1.0, b))
        )
    }

    /// Generate identity matrix (no correction)
    public static func identityMatrix() -> [[Double]] {
        return [
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, 0.0, 1.0]
        ]
    }

    /// Interpolate between identity and correction matrix
    public static func interpolateMatrix(
        from identity: [[Double]] = identityMatrix(),
        to correction: [[Double]],
        intensity: Double
    ) -> [[Double]] {
        guard intensity >= 0.0 && intensity <= 1.0 else {
            return intensity <= 0.0 ? identity : correction
        }

        var result = [[Double]]()
        for i in 0..<3 {
            var row = [Double]()
            for j in 0..<3 {
                let value = identity[i][j] + (correction[i][j] - identity[i][j]) * intensity
                row.append(value)
            }
            result.append(row)
        }

        return result
    }
}