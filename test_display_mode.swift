#!/usr/bin/env swift

import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics

// Inline DisplayModeController for testing
@MainActor
final class TestRunner {

    static func main() async {
        print("\n=== Display Mode Controller Test ===\n")

        // Get main display
        let mainDisplay = CGMainDisplayID()
        print("Main Display ID: \(mainDisplay)")

        // Test basic CoreGraphics mode enumeration
        print("\n1. CoreGraphics Display Modes:")
        if let modes = CGDisplayCopyAllDisplayModes(mainDisplay, nil) as? [CGDisplayMode] {
            print("   Found \(modes.count) modes")

            // Show first few modes
            for (index, mode) in modes.prefix(5).enumerated() {
                let width = mode.pixelWidth
                let height = mode.pixelHeight
                let refresh = mode.refreshRate
                print("   Mode \(index): \(width)x\(height) @ \(refresh)Hz")
            }
        }

        // Test current mode
        print("\n2. Current Display Mode:")
        if let currentMode = CGDisplayCopyDisplayMode(mainDisplay) {
            print("   Resolution: \(currentMode.pixelWidth)x\(currentMode.pixelHeight)")
            print("   Refresh Rate: \(currentMode.refreshRate) Hz")
            print("   Is Usable for Desktop: \(currentMode.isUsableForDesktopGUI())")
        }

        // Test IOKit integration
        print("\n3. IOKit Display Info:")
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

        if result == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }

                // Try to get some properties
                if let vendorID = getProperty(service, key: "DisplayVendorID") {
                    print("   Vendor ID: \(vendorID)")
                }
                if let productID = getProperty(service, key: "DisplayProductID") {
                    print("   Product ID: \(productID)")
                }

                // Check for HDR support
                if let hdrSupported = getProperty(service, key: "HDRSupported") {
                    print("   HDR Supported: \(hdrSupported)")
                }

                break // Just show first display
            }
        }

        print("\n=== Test Complete ===\n")
    }

    static func getProperty(_ service: io_service_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}

// Run the test
await TestRunner.main()