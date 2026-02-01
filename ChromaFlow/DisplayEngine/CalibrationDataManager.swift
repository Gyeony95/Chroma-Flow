//
//  CalibrationDataManager.swift
//  ChromaFlow
//
//  Hardware calibration data management
//  Handles ICC profiles, measurement data, and display-specific calibration
//

import Foundation
import CoreGraphics
import ColorSync

// MARK: - Calibration Data Structures

/// Display gamut coverage metrics
public struct GamutCoverage: Codable {
    public let sRGB: Double      // Percentage of sRGB coverage
    public let displayP3: Double // Percentage of Display P3 coverage
    public let adobeRGB: Double   // Percentage of Adobe RGB coverage
    public let rec2020: Double    // Percentage of Rec.2020 coverage

    public init(sRGB: Double = 100.0, displayP3: Double = 0.0, adobeRGB: Double = 0.0, rec2020: Double = 0.0) {
        self.sRGB = sRGB
        self.displayP3 = displayP3
        self.adobeRGB = adobeRGB
        self.rec2020 = rec2020
    }
}

/// Individual color patch measurement
public struct ColorPatch: Codable {
    public let patchID: String
    public let targetLab: LabColor
    public let measuredLab: LabColor
    public let deltaE: Double
    public let rgb: (r: UInt8, g: UInt8, b: UInt8)

    enum CodingKeys: String, CodingKey {
        case patchID, targetLab, measuredLab, deltaE, rgbR, rgbG, rgbB
    }

    public init(patchID: String, targetLab: LabColor, measuredLab: LabColor, rgb: (r: UInt8, g: UInt8, b: UInt8)) {
        self.patchID = patchID
        self.targetLab = targetLab
        self.measuredLab = measuredLab
        self.deltaE = DeltaECalculator.calculateDeltaE2000(lab1: targetLab, lab2: measuredLab)
        self.rgb = rgb
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        patchID = try container.decode(String.self, forKey: .patchID)
        targetLab = try container.decode(LabColor.self, forKey: .targetLab)
        measuredLab = try container.decode(LabColor.self, forKey: .measuredLab)
        deltaE = try container.decode(Double.self, forKey: .deltaE)
        let r = try container.decode(UInt8.self, forKey: .rgbR)
        let g = try container.decode(UInt8.self, forKey: .rgbG)
        let b = try container.decode(UInt8.self, forKey: .rgbB)
        rgb = (r: r, g: g, b: b)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(patchID, forKey: .patchID)
        try container.encode(targetLab, forKey: .targetLab)
        try container.encode(measuredLab, forKey: .measuredLab)
        try container.encode(deltaE, forKey: .deltaE)
        try container.encode(rgb.r, forKey: .rgbR)
        try container.encode(rgb.g, forKey: .rgbG)
        try container.encode(rgb.b, forKey: .rgbB)
    }
}

/// Display calibration profile
public struct CalibrationProfile: Codable {
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let date: Date
    public let whitePoint: CIExyY           // CIE xyY white point
    public let gamut: GamutCoverage
    public let colorPatchMeasurements: [ColorPatch]
    public let correctionMatrix: [[Double]] // 3x3 RGB correction matrix
    public let averageDeltaE: Double
    public let maxDeltaE: Double
    public let percentile95DeltaE: Double
    public let luminance: Double            // cd/m²
    public let contrast: Double             // Contrast ratio
    public let blackLevel: Double           // Black level luminance

    /// CIE xyY color representation
    public struct CIExyY: Codable {
        public let x: Double
        public let y: Double
        public let Y: Double  // Luminance

        public init(x: Double, y: Double, Y: Double) {
            self.x = x
            self.y = y
            self.Y = Y
        }
    }

    public init(
        displayID: CGDirectDisplayID,
        displayName: String,
        date: Date = Date(),
        whitePoint: CIExyY,
        gamut: GamutCoverage,
        colorPatchMeasurements: [ColorPatch],
        correctionMatrix: [[Double]],
        luminance: Double,
        contrast: Double,
        blackLevel: Double
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.date = date
        self.whitePoint = whitePoint
        self.gamut = gamut
        self.colorPatchMeasurements = colorPatchMeasurements
        self.correctionMatrix = correctionMatrix
        self.luminance = luminance
        self.contrast = contrast
        self.blackLevel = blackLevel

        // Calculate Delta-E statistics
        let patches = colorPatchMeasurements.map { ($0.targetLab, $0.measuredLab) }
        let stats = DeltaECalculator.deltaEStatistics(patches: patches)
        self.averageDeltaE = stats.average
        self.maxDeltaE = stats.max
        self.percentile95DeltaE = stats.percentile95
    }
}

/// Calibration status for a display
public enum CalibrationStatus: Codable {
    case notCalibrated
    case calibrated(profile: CalibrationProfile)
    case expired(profile: CalibrationProfile, daysOld: Int)
    case loading
    case error(String)

    enum CodingKeys: String, CodingKey {
        case type, profile, daysOld, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "notCalibrated":
            self = .notCalibrated
        case "calibrated":
            let profile = try container.decode(CalibrationProfile.self, forKey: .profile)
            self = .calibrated(profile: profile)
        case "expired":
            let profile = try container.decode(CalibrationProfile.self, forKey: .profile)
            let daysOld = try container.decode(Int.self, forKey: .daysOld)
            self = .expired(profile: profile, daysOld: daysOld)
        case "loading":
            self = .loading
        case "error":
            let error = try container.decode(String.self, forKey: .error)
            self = .error(error)
        default:
            self = .notCalibrated
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .notCalibrated:
            try container.encode("notCalibrated", forKey: .type)
        case .calibrated(let profile):
            try container.encode("calibrated", forKey: .type)
            try container.encode(profile, forKey: .profile)
        case .expired(let profile, let daysOld):
            try container.encode("expired", forKey: .type)
            try container.encode(profile, forKey: .profile)
            try container.encode(daysOld, forKey: .daysOld)
        case .loading:
            try container.encode("loading", forKey: .type)
        case .error(let error):
            try container.encode("error", forKey: .type)
            try container.encode(error, forKey: .error)
        }
    }
}

// MARK: - Calibration Data Manager

/// Manages display calibration profiles and measurement data
public actor CalibrationDataManager {
    private var calibrationData: [CGDirectDisplayID: CalibrationProfile] = [:]
    private let calibrationDirectory: URL
    private let maxCalibrationAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    public init() {
        // Initialize calibration directory in Application Support
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.calibrationDirectory = appSupportURL.appendingPathComponent("ChromaFlow/Calibration")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: calibrationDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Profile Management

    /// Load calibration profile for a display
    public func loadCalibration(for displayID: CGDirectDisplayID) async throws -> CalibrationProfile? {
        // Check memory cache first
        if let cached = calibrationData[displayID] {
            return cached
        }

        // Load from disk
        let profileURL = calibrationDirectory.appendingPathComponent("display_\(displayID).json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: profileURL)
        let profile = try JSONDecoder().decode(CalibrationProfile.self, from: data)

        // Cache in memory
        calibrationData[displayID] = profile

        return profile
    }

    /// Save calibration profile for a display
    public func saveCalibration(_ profile: CalibrationProfile, for displayID: CGDirectDisplayID) async throws {
        // Update memory cache
        calibrationData[displayID] = profile

        // Save to disk
        let profileURL = calibrationDirectory.appendingPathComponent("display_\(displayID).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(profile)
        try data.write(to: profileURL)
    }

    /// Remove calibration for a display
    public func removeCalibration(for displayID: CGDirectDisplayID) async throws {
        calibrationData[displayID] = nil

        let profileURL = calibrationDirectory.appendingPathComponent("display_\(displayID).json")
        try? FileManager.default.removeItem(at: profileURL)
    }

    /// Get calibration status for a display
    public func getCalibrationStatus(for displayID: CGDirectDisplayID) async -> CalibrationStatus {
        guard let profile = try? await loadCalibration(for: displayID) else {
            return .notCalibrated
        }

        // Check if calibration is expired (>30 days old)
        let age = Date().timeIntervalSince(profile.date)
        let daysOld = Int(age / (24 * 60 * 60))

        if age > maxCalibrationAge {
            return .expired(profile: profile, daysOld: daysOld)
        }

        return .calibrated(profile: profile)
    }

    // MARK: - Import Functions

    /// Import calibration from ICC profile
    public func importICCProfile(at url: URL, for displayID: CGDirectDisplayID) async throws -> CalibrationProfile {
        // Read ICC profile data
        let iccData = try Data(contentsOf: url)

        // Create ColorSync profile
        guard let colorProfile = ColorSyncProfileCreate(iccData as CFData, nil)?.takeRetainedValue() else {
            throw CalibrationError.invalidICCProfile
        }

        // Extract profile information
        let profileData = try extractICCProfileData(colorProfile, displayID: displayID)

        // Save the calibration
        try await saveCalibration(profileData, for: displayID)

        return profileData
    }

    /// Import calibration from X-Rite i1Profiler format
    public func importXRiteData(at url: URL, for displayID: CGDirectDisplayID) async throws -> CalibrationProfile {
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? ""

        // Parse X-Rite measurement data (CGATS format)
        let profile = try parseXRiteData(content, displayID: displayID)

        // Save the calibration
        try await saveCalibration(profile, for: displayID)

        return profile
    }

    /// Import calibration from JSON format
    public func importJSONCalibration(at url: URL) async throws -> CalibrationProfile {
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(CalibrationProfile.self, from: data)

        // Save the calibration
        try await saveCalibration(profile, for: profile.displayID)

        return profile
    }

    // MARK: - ColorChecker Patches

    /// Generate standard X-Rite ColorChecker patches (24 patches)
    public static func colorCheckerPatches() -> [(name: String, lab: LabColor, rgb: (r: UInt8, g: UInt8, b: UInt8))] {
        return [
            // Row 1
            ("Dark Skin", LabColor(L: 37.54, a: 14.37, b: 14.92), (115, 82, 69)),
            ("Light Skin", LabColor(L: 64.66, a: 19.27, b: 17.50), (194, 150, 130)),
            ("Blue Sky", LabColor(L: 49.32, a: -3.82, b: -22.54), (98, 122, 157)),
            ("Foliage", LabColor(L: 43.46, a: -12.74, b: 22.72), (87, 108, 67)),
            ("Blue Flower", LabColor(L: 54.94, a: 9.61, b: -25.79), (133, 128, 177)),
            ("Bluish Green", LabColor(L: 70.48, a: -32.26, b: -0.37), (103, 189, 170)),

            // Row 2
            ("Orange", LabColor(L: 62.73, a: 35.83, b: 56.50), (214, 126, 44)),
            ("Purplish Blue", LabColor(L: 39.43, a: 10.75, b: -45.17), (80, 91, 167)),
            ("Moderate Red", LabColor(L: 50.57, a: 47.70, b: 16.93), (193, 90, 99)),
            ("Purple", LabColor(L: 30.10, a: 22.54, b: -20.87), (94, 60, 108)),
            ("Yellow Green", LabColor(L: 71.77, a: -24.13, b: 58.19), (157, 188, 64)),
            ("Orange Yellow", LabColor(L: 71.51, a: 18.24, b: 67.37), (224, 163, 46)),

            // Row 3
            ("Blue", LabColor(L: 28.37, a: 15.42, b: -49.80), (56, 61, 150)),
            ("Green", LabColor(L: 54.38, a: -39.72, b: 32.27), (70, 148, 73)),
            ("Red", LabColor(L: 42.43, a: 51.05, b: 28.62), (175, 54, 60)),
            ("Yellow", LabColor(L: 81.29, a: 4.39, b: 80.45), (231, 199, 31)),
            ("Magenta", LabColor(L: 50.63, a: 49.37, b: -13.29), (187, 86, 150)),
            ("Cyan", LabColor(L: 49.57, a: -30.41, b: -28.32), (8, 133, 161)),

            // Row 4 (Grayscale)
            ("White", LabColor(L: 96.54, a: -0.43, b: 1.19), (243, 243, 243)),
            ("Neutral 8", LabColor(L: 81.26, a: -0.64, b: 0.34), (200, 200, 200)),
            ("Neutral 6.5", LabColor(L: 66.77, a: -0.73, b: 0.50), (160, 160, 160)),
            ("Neutral 5", LabColor(L: 50.87, a: -0.15, b: 0.27), (122, 122, 121)),
            ("Neutral 3.5", LabColor(L: 35.66, a: -0.42, b: 1.23), (85, 85, 85)),
            ("Black", LabColor(L: 20.46, a: 0.08, b: -0.97), (52, 52, 52))
        ]
    }

    // MARK: - Private Helpers

    private func extractICCProfileData(_ colorProfile: ColorSyncProfile, displayID: CGDirectDisplayID) throws -> CalibrationProfile {
        // Get profile description
        let displayName: String
        if let descriptionRef = ColorSyncProfileCopyDescriptionString(colorProfile) {
            displayName = descriptionRef.takeRetainedValue() as String
        } else {
            displayName = "Unknown Display"
        }

        // Extract white point (default to D65 if not found)
        let whitePoint = CalibrationProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100.0)

        // Generate synthetic color patches based on profile
        let patches = Self.colorCheckerPatches().map { patch in
            // For now, use ideal values (would need actual measurements)
            ColorPatch(
                patchID: patch.name,
                targetLab: patch.lab,
                measuredLab: patch.lab,  // Would be replaced with actual measurements
                rgb: patch.rgb
            )
        }

        // Default correction matrix (identity)
        let correctionMatrix = DeltaECalculator.identityMatrix()

        return CalibrationProfile(
            displayID: displayID,
            displayName: displayName,
            whitePoint: whitePoint,
            gamut: GamutCoverage(),
            colorPatchMeasurements: patches,
            correctionMatrix: correctionMatrix,
            luminance: 120.0,  // Default values
            contrast: 1000.0,
            blackLevel: 0.12
        )
    }

    private func parseXRiteData(_ content: String, displayID: CGDirectDisplayID) throws -> CalibrationProfile {
        // Parse CGATS format (simplified parser)
        var patches: [ColorPatch] = []
        let lines = content.components(separatedBy: .newlines)

        var inDataSection = false
        for line in lines {
            if line.hasPrefix("BEGIN_DATA") {
                inDataSection = true
                continue
            }
            if line.hasPrefix("END_DATA") {
                break
            }

            if inDataSection {
                // Parse measurement data lines
                let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if components.count >= 7 {
                    // Expected format: SAMPLE_ID RGB_R RGB_G RGB_B LAB_L LAB_A LAB_B
                    if let r = UInt8(components[1]),
                       let g = UInt8(components[2]),
                       let b = UInt8(components[3]),
                       let L = Double(components[4]),
                       let a = Double(components[5]),
                       let labB = Double(components[6]) {

                        let measured = LabColor(L: L, a: a, b: labB)

                        // Find matching ColorChecker patch
                        let checkerPatches = Self.colorCheckerPatches()
                        if let matchingPatch = checkerPatches.first(where: {
                            abs(Int($0.rgb.r) - Int(r)) < 10 &&
                            abs(Int($0.rgb.g) - Int(g)) < 10 &&
                            abs(Int($0.rgb.b) - Int(b)) < 10
                        }) {
                            patches.append(ColorPatch(
                                patchID: matchingPatch.name,
                                targetLab: matchingPatch.lab,
                                measuredLab: measured,
                                rgb: (r, g, b)
                            ))
                        }
                    }
                }
            }
        }

        guard !patches.isEmpty else {
            throw CalibrationError.invalidDataFormat
        }

        // Calculate correction matrix from measurements
        let correctionMatrix = calculateCorrectionMatrix(from: patches)

        return CalibrationProfile(
            displayID: displayID,
            displayName: "Calibrated Display",
            whitePoint: CalibrationProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100.0),
            gamut: GamutCoverage(),
            colorPatchMeasurements: patches,
            correctionMatrix: correctionMatrix,
            luminance: 120.0,
            contrast: 1000.0,
            blackLevel: 0.12
        )
    }

    private func calculateCorrectionMatrix(from patches: [ColorPatch]) -> [[Double]] {
        // Simplified matrix calculation
        // In production, would use least squares fitting or similar optimization
        var matrix = DeltaECalculator.identityMatrix()

        // Calculate average color shift for primary colors
        let redPatches = patches.filter { $0.rgb.r > 200 && $0.rgb.g < 100 && $0.rgb.b < 100 }
        let greenPatches = patches.filter { $0.rgb.g > 200 && $0.rgb.r < 100 && $0.rgb.b < 100 }
        let bluePatches = patches.filter { $0.rgb.b > 200 && $0.rgb.r < 100 && $0.rgb.g < 100 }

        // Apply corrections based on measurements
        if !redPatches.isEmpty {
            let avgDeltaE = redPatches.map { $0.deltaE }.reduce(0.0, +) / Double(redPatches.count)
            if avgDeltaE > 2.0 {
                matrix[0][0] *= 1.0 + (avgDeltaE - 2.0) * 0.01  // Small adjustment
            }
        }

        if !greenPatches.isEmpty {
            let avgDeltaE = greenPatches.map { $0.deltaE }.reduce(0.0, +) / Double(greenPatches.count)
            if avgDeltaE > 2.0 {
                matrix[1][1] *= 1.0 + (avgDeltaE - 2.0) * 0.01
            }
        }

        if !bluePatches.isEmpty {
            let avgDeltaE = bluePatches.map { $0.deltaE }.reduce(0.0, +) / Double(bluePatches.count)
            if avgDeltaE > 2.0 {
                matrix[2][2] *= 1.0 + (avgDeltaE - 2.0) * 0.01
            }
        }

        return matrix
    }
}

// MARK: - Errors

public enum CalibrationError: LocalizedError {
    case invalidICCProfile
    case invalidDataFormat
    case measurementDataMissing
    case displayNotFound
    case calibrationExpired

    public var errorDescription: String? {
        switch self {
        case .invalidICCProfile:
            return "Invalid ICC profile format"
        case .invalidDataFormat:
            return "Invalid calibration data format"
        case .measurementDataMissing:
            return "Measurement data is missing or incomplete"
        case .displayNotFound:
            return "Display not found"
        case .calibrationExpired:
            return "Calibration data has expired"
        }
    }
}