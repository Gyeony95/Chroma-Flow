//
//  AppProfileMapping.swift
//  ChromaFlow
//
//  Created on 2026-02-01
//

import Foundation
import SwiftUI

/// Manages application-to-color-profile mappings
@Observable
final class AppProfileMapping: @unchecked Sendable {

    // MARK: - Types

    struct AppMapping: Codable, Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let appName: String
        var colorSpace: ColorProfile.ColorSpace
        var isEnabled: Bool = true
        var isCustom: Bool = false
    }

    // MARK: - Properties

    /// Default mappings for common professional applications
    private static let defaultMappings: [String: (name: String, colorSpace: ColorProfile.ColorSpace)] = [
        // Video Editing
        "com.apple.FinalCutPro": ("Final Cut Pro", .rec2020),
        "com.apple.iMovieApp": ("iMovie", .displayP3),
        "com.blackmagic-design.DaVinciResolve": ("DaVinci Resolve", .rec2020),
        "com.adobe.PremierePro": ("Premiere Pro", .rec2020),

        // Photo Editing
        "com.adobe.Photoshop": ("Photoshop", .adobeRGB),
        "com.adobe.Lightroom": ("Lightroom", .adobeRGB),
        "com.adobe.LightroomCC": ("Lightroom CC", .adobeRGB),
        "com.pixelmator.Pixelmator": ("Pixelmator", .displayP3),
        "com.pixelmatorteam.pixelmator.x": ("Pixelmator Pro", .displayP3),
        "com.seriflabs.affinityphoto2": ("Affinity Photo", .displayP3),
        "com.phaseone.captureone": ("Capture One", .adobeRGB),

        // Design
        "com.figma.Desktop": ("Figma", .displayP3),
        "com.bohemiancoding.sketch3": ("Sketch", .displayP3),
        "com.adobe.Illustrator": ("Illustrator", .adobeRGB),
        "com.adobe.InDesign": ("InDesign", .adobeRGB),
        "com.adobe.AfterEffects": ("After Effects", .rec2020),
        "com.seriflabs.affinitydesigner2": ("Affinity Designer", .displayP3),

        // Web Browsers (sRGB for web content)
        "com.apple.Safari": ("Safari", .sRGB),
        "com.google.Chrome": ("Chrome", .sRGB),
        "org.mozilla.firefox": ("Firefox", .sRGB),
        "com.microsoft.edgemac": ("Edge", .sRGB),
        "com.brave.Browser": ("Brave", .sRGB),

        // Development
        "com.apple.dt.Xcode": ("Xcode", .displayP3),
        "com.microsoft.VSCode": ("VS Code", .sRGB),
        "com.sublimetext.4": ("Sublime Text", .sRGB),
        "com.jetbrains.intellij": ("IntelliJ IDEA", .sRGB),

        // 3D & CAD
        "com.autodesk.maya": ("Maya", .adobeRGB),
        "com.maxon.cinema4d": ("Cinema 4D", .adobeRGB),
        "com.blender.Blender": ("Blender", .displayP3),
        "com.autodesk.AutoCAD": ("AutoCAD", .sRGB),

        // Gaming (HDR where supported)
        "com.apple.Arcade": ("Apple Arcade", .displayP3),

        // Media Players
        "com.apple.QuickTimePlayerX": ("QuickTime Player", .rec709),
        "org.videolan.vlc": ("VLC", .rec709),
        "com.apple.TV": ("Apple TV", .rec2020),
        "com.netflix.Netflix": ("Netflix", .rec2020),

        // Office & Productivity
        "com.microsoft.Word": ("Microsoft Word", .sRGB),
        "com.microsoft.Excel": ("Microsoft Excel", .sRGB),
        "com.microsoft.Powerpoint": ("Microsoft PowerPoint", .sRGB),
        "com.apple.Keynote": ("Keynote", .displayP3),
        "com.apple.Pages": ("Pages", .sRGB),
        "com.apple.Numbers": ("Numbers", .sRGB),

        // Communication
        "com.tinyspeck.slackmacgap": ("Slack", .sRGB),
        "com.hnc.Discord": ("Discord", .sRGB),
        "us.zoom.xos": ("Zoom", .sRGB),
        "com.microsoft.teams2": ("Microsoft Teams", .sRGB)
    ]

    /// All mappings (default + custom)
    @MainActor
    private(set) var mappings: [String: AppMapping] = [:]

    /// Path to the mappings file
    private var mappingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let chromaFlowDir = appSupport.appendingPathComponent("ChromaFlow", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: chromaFlowDir, withIntermediateDirectories: true)

        return chromaFlowDir.appendingPathComponent("app-mappings.json")
    }

    // MARK: - Singleton

    static let shared = AppProfileMapping()

    private init() {
        Task { @MainActor in
            loadMappings()
        }
    }

    // MARK: - Public Methods

    /// Get the color space for a given app bundle ID
    @MainActor
    func getColorSpace(for bundleID: String?) -> ColorProfile.ColorSpace? {
        guard let bundleID = bundleID,
              let mapping = mappings[bundleID],
              mapping.isEnabled else {
            return nil
        }
        return mapping.colorSpace
    }

    /// Add or update a custom mapping
    @MainActor
    func setMapping(bundleID: String, appName: String, colorSpace: ColorProfile.ColorSpace) {
        let mapping = AppMapping(
            bundleID: bundleID,
            appName: appName,
            colorSpace: colorSpace,
            isEnabled: true,
            isCustom: true
        )
        mappings[bundleID] = mapping
        saveMappings()
    }

    /// Remove a custom mapping
    @MainActor
    func removeMapping(bundleID: String) {
        // Only remove if it's a custom mapping
        if mappings[bundleID]?.isCustom == true {
            mappings.removeValue(forKey: bundleID)
            saveMappings()
        } else if var mapping = mappings[bundleID] {
            // For default mappings, just disable them
            mapping.isEnabled = false
            mappings[bundleID] = mapping
            saveMappings()
        }
    }

    /// Toggle a mapping on/off
    @MainActor
    func toggleMapping(bundleID: String) {
        guard var mapping = mappings[bundleID] else { return }
        mapping.isEnabled.toggle()
        mappings[bundleID] = mapping
        saveMappings()
    }

    /// Reset to default mappings
    @MainActor
    func resetToDefaults() {
        mappings.removeAll()

        // Add all default mappings
        for (bundleID, (name, colorSpace)) in Self.defaultMappings {
            mappings[bundleID] = AppMapping(
                bundleID: bundleID,
                appName: name,
                colorSpace: colorSpace,
                isEnabled: true,
                isCustom: false
            )
        }

        saveMappings()
    }

    /// Get all mappings sorted by app name
    @MainActor
    func getAllMappings() -> [AppMapping] {
        return Array(mappings.values).sorted { $0.appName < $1.appName }
    }

    /// Get enabled mappings only
    @MainActor
    func getEnabledMappings() -> [AppMapping] {
        return mappings.values.filter { $0.isEnabled }.sorted { $0.appName < $1.appName }
    }

    // MARK: - Private Methods

    @MainActor
    private func loadMappings() {
        // Try to load from file first
        if let data = try? Data(contentsOf: mappingsFileURL),
           let loadedMappings = try? JSONDecoder().decode([String: AppMapping].self, from: data) {
            mappings = loadedMappings
        } else {
            // Initialize with defaults on first run
            resetToDefaults()
        }
    }

    @MainActor
    private func saveMappings() {
        do {
            let data = try JSONEncoder().encode(mappings)
            try data.write(to: mappingsFileURL)
        } catch {
            print("Failed to save app mappings: \(error)")
        }
    }

    /// Check if app has a mapping (enabled or disabled)
    @MainActor
    func hasMapping(for bundleID: String) -> Bool {
        return mappings[bundleID] != nil
    }

    /// Update the color space for an existing mapping
    @MainActor
    func updateColorSpace(for bundleID: String, to colorSpace: ColorProfile.ColorSpace) {
        guard var mapping = mappings[bundleID] else { return }
        mapping.colorSpace = colorSpace
        mappings[bundleID] = mapping
        saveMappings()
    }
}

// MARK: - View Extensions

extension AppProfileMapping {
    /// Get a user-friendly description of the color space
    static func colorSpaceDescription(_ colorSpace: ColorProfile.ColorSpace) -> String {
        switch colorSpace {
        case .sRGB:
            return "Standard RGB - Web & General Use"
        case .displayP3:
            return "Display P3 - Modern Apple Displays"
        case .adobeRGB:
            return "Adobe RGB - Photography & Print"
        case .rec709:
            return "Rec.709 - HD Video Standard"
        case .rec2020:
            return "Rec.2020 - HDR & Wide Gamut Video"
        case .custom:
            return "Custom ICC Profile"
        }
    }

    /// Get an icon for the color space
    static func colorSpaceIcon(_ colorSpace: ColorProfile.ColorSpace) -> String {
        switch colorSpace {
        case .sRGB:
            return "globe"
        case .displayP3:
            return "display"
        case .adobeRGB:
            return "camera.fill"
        case .rec709:
            return "tv"
        case .rec2020:
            return "4k.tv.fill"
        case .custom:
            return "doc.badge.gearshape"
        }
    }
}