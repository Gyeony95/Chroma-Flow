//
//  ColorPreset.swift
//  ChromaFlow
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// Color temperature presets for external monitors based on VESA DDC/CI VCP standard.
///
/// This enum represents standardized color temperature presets as defined in the
/// VESA MCCS (Monitor Control Command Set) specification for VCP code 0x14.
///
/// VCP Code 0x14 controls the color preset/temperature setting of the display.
/// Each preset corresponds to a specific color temperature (measured in Kelvin)
/// that affects the warmth or coolness of the display's white point.
enum ColorPreset: String, Codable, Hashable, CaseIterable {
    /// Warm color temperature (~5000K)
    /// Produces a yellowish-orange tint, easier on the eyes in low-light conditions
    case warm

    /// Standard/Neutral color temperature (~6500K)
    /// Balanced white point, closest to natural daylight
    /// This is the most common default setting
    case standard

    /// Cool color temperature (~7500K-9300K)
    /// Produces a bluish tint, appears brighter and crisper
    case cool

    /// Display's native color space
    /// Uses the monitor's factory default color configuration
    case native

    /// sRGB color space
    /// Standard RGB color space for web and general computing
    case srgb

    /// User-defined custom preset
    /// Allows users to configure their own color temperature
    case custom

    // MARK: - VCP Mapping

    /// The VCP (Virtual Control Panel) value for this color preset.
    ///
    /// These values are defined in the VESA MCCS standard for VCP code 0x14.
    /// Reference: VESA MCCS Standard v2.2a, Section 8.14
    var vcpValue: UInt16 {
        switch self {
        case .srgb:     return 0x01  // sRGB standard color space
        case .native:   return 0x02  // Display's native/default setting
        case .warm:     return 0x04  // 5000K - Warm white point
        case .standard: return 0x05  // 6500K - Standard daylight white point
        case .cool:     return 0x08  // 9300K - Cool blue-ish white point
        case .custom:   return 0x0B  // User-defined preset slot 1
        }
    }

    // MARK: - Display Properties

    /// Human-readable name for the preset
    var displayName: String {
        switch self {
        case .warm:     return "Warm"
        case .standard: return "Standard"
        case .cool:     return "Cool"
        case .native:   return "Native"
        case .srgb:     return "sRGB"
        case .custom:   return "Custom"
        }
    }

    /// SF Symbol icon name representing this color preset
    var iconName: String {
        switch self {
        case .warm:     return "sun.max.fill"           // Warm/yellow tone
        case .standard: return "sun.horizon.fill"       // Balanced/neutral
        case .cool:     return "moon.stars.fill"        // Cool/blue tone
        case .native:   return "display"                // Display default
        case .srgb:     return "square.grid.3x3.fill"   // Standard color space
        case .custom:   return "slider.horizontal.3"    // User customizable
        }
    }

    /// Approximate color temperature in Kelvin (for informational purposes)
    var colorTemperatureK: Int? {
        switch self {
        case .warm:     return 5000
        case .standard: return 6500
        case .cool:     return 9300
        case .native, .srgb, .custom:
            return nil  // Not temperature-based
        }
    }

    /// Brief description of the preset's characteristics
    var description: String {
        switch self {
        case .warm:
            return "Warm tone, reduces blue light for comfortable evening viewing"
        case .standard:
            return "Balanced neutral white, closest to natural daylight"
        case .cool:
            return "Cool tone with enhanced blue, appears brighter and crisper"
        case .native:
            return "Monitor's factory default color configuration"
        case .srgb:
            return "Standard RGB color space for web and general use"
        case .custom:
            return "User-defined color temperature settings"
        }
    }

    // MARK: - Reverse Lookup

    /// Initialize a ColorPreset from a VCP value.
    ///
    /// - Parameter vcpValue: The VCP code 0x14 value received from the monitor
    /// - Returns: The corresponding ColorPreset, or nil if the value is unrecognized
    init?(vcpValue: UInt16) {
        guard let preset = Self.allCases.first(where: { $0.vcpValue == vcpValue }) else {
            return nil
        }
        self = preset
    }
}
