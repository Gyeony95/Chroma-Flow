//
//  TestAppAware.swift
//  ChromaFlow
//
//  Created on 2026-02-01
//  Test file for App-Aware Color Space feature
//

import Foundation
import SwiftUI

/// Test harness for App-Aware Color Space functionality
@MainActor
struct TestAppAware {

    static func runTests() async {
        print("🧪 Starting App-Aware Color Space Tests...")
        print("=" * 50)

        // Initialize components
        let appState = AppState()
        let displayEngine = DisplayEngineActor()
        let automationEngine = AutomationEngine(appState: appState, displayEngine: displayEngine)

        // Store automation engine in app state
        appState.automationEngine = automationEngine

        // Test 1: App Activity Monitor
        await testAppActivityMonitor()

        // Test 2: Profile Mapping
        await testProfileMapping()

        // Test 3: Automation Engine
        await testAutomationEngine(appState: appState, automationEngine: automationEngine)

        print("=" * 50)
        print("✅ App-Aware Color Space Tests Complete!")
    }

    // MARK: - Test App Activity Monitor

    static func testAppActivityMonitor() async {
        print("\n📱 Testing App Activity Monitor...")

        let monitor = AppActivityMonitor.shared

        // Start monitoring
        monitor.startMonitoring()

        // Get current app
        if let bundleID = monitor.getFrontmostAppBundleID(),
           let appName = monitor.getFrontmostAppName() {
            print("  ✓ Current app: \(appName) (\(bundleID))")
        } else {
            print("  ⚠️ Could not detect current app")
        }

        // List all running apps
        let runningApps = monitor.getAllRunningApps()
        print("  ✓ Running apps: \(runningApps.count)")
        for app in runningApps.prefix(5) {
            print("    - \(app.name): \(app.bundleID)")
        }

        // Test app change callback
        var callbackFired = false
        monitor.onAppChanged = { bundleID, appName in
            print("  ✓ App changed to: \(appName ?? "Unknown") (\(bundleID ?? "Unknown"))")
            callbackFired = true
        }

        // Wait a moment for potential app changes
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Stop monitoring
        monitor.stopMonitoring()

        print("  ✓ App Activity Monitor test complete")
    }

    // MARK: - Test Profile Mapping

    static func testProfileMapping() async {
        print("\n🎨 Testing Profile Mapping...")

        let mapping = AppProfileMapping.shared

        // Test default mappings
        let allMappings = mapping.getAllMappings()
        print("  ✓ Total mappings: \(allMappings.count)")

        // Test specific app mappings
        let testApps = [
            "com.apple.FinalCutPro",
            "com.adobe.Photoshop",
            "com.apple.Safari",
            "com.figma.Desktop"
        ]

        for bundleID in testApps {
            if let colorSpace = mapping.getColorSpace(for: bundleID) {
                print("  ✓ \(bundleID) → \(colorSpace)")
            }
        }

        // Test custom mapping
        mapping.setMapping(
            bundleID: "com.test.app",
            appName: "Test App",
            colorSpace: .displayP3
        )

        if let customSpace = mapping.getColorSpace(for: "com.test.app") {
            print("  ✓ Custom mapping works: Test App → \(customSpace)")
        }

        // Test toggle
        mapping.toggleMapping(bundleID: "com.test.app")
        if mapping.getColorSpace(for: "com.test.app") == nil {
            print("  ✓ Toggle disable works")
        }

        mapping.toggleMapping(bundleID: "com.test.app")
        if mapping.getColorSpace(for: "com.test.app") != nil {
            print("  ✓ Toggle enable works")
        }

        // Clean up
        mapping.removeMapping(bundleID: "com.test.app")

        print("  ✓ Profile Mapping test complete")
    }

    // MARK: - Test Automation Engine

    static func testAutomationEngine(appState: AppState, automationEngine: AutomationEngine) async {
        print("\n⚙️ Testing Automation Engine...")

        // Enable app-aware mode
        appState.isAppAwareEnabled = true
        print("  ✓ App-aware mode enabled")

        // Start automation
        automationEngine.start()
        print("  ✓ Automation engine started")

        // Check current state
        if automationEngine.isEnabled {
            print("  ✓ Engine is running")
        }

        // Simulate app change by checking current app
        if let currentBundleID = AppActivityMonitor.shared.getFrontmostAppBundleID(),
           let currentAppName = AppActivityMonitor.shared.getFrontmostAppName() {
            print("  ✓ Current app detected: \(currentAppName)")

            // Check if mapping exists
            if let targetColorSpace = AppProfileMapping.shared.getColorSpace(for: currentBundleID) {
                print("  ✓ App has mapping to: \(targetColorSpace)")
            } else {
                print("  ℹ️ No mapping for current app")
            }
        }

        // Get statistics
        let stats = automationEngine.getStatistics()
        print("  ✓ Statistics:")
        print("    - Total switches: \(stats.totalSwitches)")
        print("    - Most used app: \(stats.mostUsedApp ?? "None")")
        print("    - Most used color space: \(stats.mostUsedColorSpace?.rawValue ?? "None")")

        // Wait for potential automatic switch
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Check history
        if let lastSwitch = automationEngine.getLastSwitchDescription() {
            print("  ✓ Last switch: \(lastSwitch)")
        }

        // Stop automation
        automationEngine.stop()
        print("  ✓ Automation engine stopped")

        print("  ✓ Automation Engine test complete")
    }
}

// Extension to make String multiplication work
extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}