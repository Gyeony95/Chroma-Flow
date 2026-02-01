//
//  DisplayModeControllerTests.swift
//  ChromaFlow
//
//  Test file for DisplayModeController functionality
//

import Foundation
import CoreGraphics

@MainActor
func testDisplayModeController() async {
    print("\n=== DisplayModeController Test ===\n")

    let controller = DisplayModeController()

    // Get main display
    let mainDisplay = CGMainDisplayID()
    print("Testing with main display: \(mainDisplay)")

    // Test 1: Get current mode
    print("\n1. Current Display Mode:")
    if let currentMode = controller.currentMode(for: mainDisplay) {
        print("   \(currentMode.description)")
        print("   Resolution: \(currentMode.resolution.description)")
        print("   Refresh Rate: \(currentMode.refreshRate) Hz")
        print("   Bit Depth: \(currentMode.bitDepth)-bit")
        print("   Color Encoding: \(currentMode.colorEncoding.description)")
        print("   RGB Range: \(currentMode.range.description)")
    } else {
        print("   Failed to get current mode")
    }

    // Test 2: List all available modes
    print("\n2. All Available Modes:")
    let allModes = controller.availableModes(for: mainDisplay)
    print("   Found \(allModes.count) total modes")

    // Group by resolution for easier viewing
    let modesByResolution = Dictionary(grouping: allModes) { $0.resolution }
    for (resolution, modes) in modesByResolution.sorted(by: { $0.key.width > $1.key.width }) {
        print("\n   \(resolution.description):")
        for mode in modes.prefix(5) {  // Show first 5 modes per resolution
            print("      - \(mode.description)")
        }
        if modes.count > 5 {
            print("      ... and \(modes.count - 5) more")
        }
    }

    // Test 3: Get encoding variants (modes with same timing)
    print("\n3. Encoding Variants (same resolution/refresh):")
    let variants = controller.encodingVariants(for: mainDisplay, matchingCurrent: true)
    print("   Found \(variants.count) encoding variants")
    for variant in variants {
        print("   - \(variant.description)")
    }

    // Test 4: Enhanced mode detection with IOKit
    print("\n4. Enhanced Mode Detection (with IOKit):")
    if let enhancedMode = controller.currentModeEnhanced(for: mainDisplay) {
        print("   \(enhancedMode.description)")
        if let pixelEncoding = enhancedMode.pixelEncoding {
            print("   Raw Pixel Encoding: \(pixelEncoding)")
        }
    }

    // Test 5: Display capabilities
    print("\n5. Display Capabilities:")
    let capabilities = controller.displayCapabilities(for: mainDisplay)
    print(capabilities.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))

    // Test 6: Find specific modes
    print("\n6. Finding Specific Modes:")

    // Try to find 8-bit RGB Full range
    if let sdrMode = controller.findMode(
        for: mainDisplay,
        bitDepth: 8,
        colorEncoding: .rgb,
        range: .full,
        matchCurrentTiming: true
    ) {
        print("   8-bit RGB Full: \(sdrMode.description)")
    } else {
        print("   8-bit RGB Full: Not found")
    }

    // Try to find 10-bit mode
    if let hdrMode = controller.findMode(
        for: mainDisplay,
        bitDepth: 10,
        matchCurrentTiming: true
    ) {
        print("   10-bit mode: \(hdrMode.description)")
    } else {
        print("   10-bit mode: Not found")
    }

    // Test 7: Mode switching (dry run - don't actually switch)
    print("\n7. Mode Switching (dry run):")
    if variants.count > 1 {
        let targetMode = variants[1]  // Get second variant
        print("   Would switch to: \(targetMode.description)")
        print("   Command: try controller.setMode(targetMode, for: mainDisplay)")
        print("   (Not executing to avoid changing display settings)")
    } else {
        print("   No alternative modes available for switching")
    }

    print("\n=== Test Complete ===\n")
}

// Run the test
// To run: await testDisplayModeController()
// This can be called from your app's initialization or a test target