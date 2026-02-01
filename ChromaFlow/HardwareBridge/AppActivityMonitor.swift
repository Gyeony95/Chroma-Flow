//
//  AppActivityMonitor.swift
//  ChromaFlow
//
//  Created on 2026-02-01
//

import Foundation
import AppKit
import Observation

/// Monitors active application changes and publishes events
@Observable
final class AppActivityMonitor: @unchecked Sendable {

    // MARK: - Properties

    /// The currently active application's bundle identifier
    @MainActor
    private(set) var currentAppBundleID: String?

    /// The currently active application's name
    @MainActor
    private(set) var currentAppName: String?

    /// Whether monitoring is active
    @MainActor
    private(set) var isMonitoring = false

    /// Notification observers
    private var notificationObservers: [NSObjectProtocol] = []

    /// Serial queue for thread-safe operations
    private let queue = DispatchQueue(label: "com.chromaflow.appmonitor", qos: .userInteractive)

    /// Debounce timer for app switching
    private var debounceTimer: Timer?

    /// Callback for app change events
    var onAppChanged: ((String?, String?) -> Void)?

    // MARK: - Singleton

    static let shared = AppActivityMonitor()

    private init() {}

    // MARK: - Public Methods

    /// Start monitoring active application changes
    @MainActor
    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true

        // Get current active app
        updateCurrentApp()

        // Register for notifications
        let center = NSWorkspace.shared.notificationCenter

        // Monitor active app changes
        let activeAppObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActiveAppChange(notification)
        }

        // Monitor app launches
        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppLaunch(notification)
        }

        // Monitor app terminations
        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppTermination(notification)
        }

        notificationObservers = [activeAppObserver, launchObserver, terminateObserver]
    }

    /// Stop monitoring active application changes
    @MainActor
    func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false

        // Remove observers
        notificationObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        notificationObservers.removeAll()

        // Cancel debounce timer
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    /// Get the bundle ID of the frontmost application
    @MainActor
    func getFrontmostAppBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Get the name of the frontmost application
    @MainActor
    func getFrontmostAppName() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Private Methods

    @MainActor
    private func updateCurrentApp() {
        let app = NSWorkspace.shared.frontmostApplication
        currentAppBundleID = app?.bundleIdentifier
        currentAppName = app?.localizedName
    }

    @MainActor
    private func handleActiveAppChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        let newBundleID = app.bundleIdentifier
        let newAppName = app.localizedName

        // Check if the app actually changed
        guard newBundleID != currentAppBundleID else { return }

        // Cancel existing debounce timer
        debounceTimer?.invalidate()

        // Debounce rapid app switches (0.3 seconds)
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processAppChange(bundleID: newBundleID, appName: newAppName)
            }
        }
    }

    @MainActor
    private func processAppChange(bundleID: String?, appName: String?) {
        // Update current app
        let previousBundleID = currentAppBundleID
        currentAppBundleID = bundleID
        currentAppName = appName

        // Log the change
        print("App changed from \(previousBundleID ?? "none") to \(bundleID ?? "none")")

        // Notify callback
        onAppChanged?(bundleID, appName)
    }

    @MainActor
    private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        // Log app launch
        print("App launched: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "Unknown"))")
    }

    @MainActor
    private func handleAppTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        // Log app termination
        print("App terminated: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "Unknown"))")

        // If the terminated app was the current app, update to the new frontmost
        if app.bundleIdentifier == currentAppBundleID {
            updateCurrentApp()
            onAppChanged?(currentAppBundleID, currentAppName)
        }
    }
}

// MARK: - Extensions

extension AppActivityMonitor {
    /// Get a list of all running applications with their bundle IDs
    @MainActor
    func getAllRunningApps() -> [(name: String, bundleID: String)] {
        let apps = NSWorkspace.shared.runningApplications
        return apps.compactMap { app in
            guard let name = app.localizedName,
                  let bundleID = app.bundleIdentifier else {
                return nil
            }
            return (name: name, bundleID: bundleID)
        }
    }

    /// Check if a specific app is running
    @MainActor
    func isAppRunning(bundleID: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleID
        }
    }
}