//
//  ReferenceModeManager.swift
//  ChromaFlow
//
//  Created by Gwon iHyeon on 2026/02/01.
//

import Foundation
import LocalAuthentication
import SwiftUI

/// Error types for Reference Mode operations
enum ReferenceModeError: LocalizedError {
    case authenticationFailed
    case authenticationCancelled
    case authenticationNotAvailable
    case noProfileLocked
    case maxAttemptsReached

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication failed. Please try again."
        case .authenticationCancelled:
            return "Authentication was cancelled."
        case .authenticationNotAvailable:
            return "Biometric authentication is not available."
        case .noProfileLocked:
            return "No profile is currently locked."
        case .maxAttemptsReached:
            return "Maximum unlock attempts reached. Please restart the app."
        }
    }
}

/// Manages the Reference Mode lock state for preventing accidental profile changes
@MainActor
final class ReferenceModeManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isLocked: Bool = false
    @Published var lockedProfile: ColorProfile?
    @Published var lockedDisplayID: CGDirectDisplayID?
    @Published var failedUnlockAttempts: Int = 0

    // MARK: - Private Properties

    private let maxUnlockAttempts = 3
    private let keychainKey = "com.chromaflow.referenceModeState"
    private let laContext = LAContext()

    // MARK: - Initialization

    init() {
        loadLockState()
    }

    // MARK: - Public Methods

    /// Lock the current profile for a specific display
    func lock(profile: ColorProfile, for displayID: CGDirectDisplayID) async {
        self.lockedProfile = profile
        self.lockedDisplayID = displayID
        self.isLocked = true
        self.failedUnlockAttempts = 0

        // Save to Keychain for persistence
        saveLockState()

        // Log the lock action
        print("[ReferenceModeManager] Locked profile '\(profile.name)' for display \(displayID)")
    }

    /// Unlock the reference mode with authentication
    func unlock() async throws {
        guard isLocked else {
            throw ReferenceModeError.noProfileLocked
        }

        guard failedUnlockAttempts < maxUnlockAttempts else {
            throw ReferenceModeError.maxAttemptsReached
        }

        do {
            let authenticated = try await authenticateUser()

            if authenticated {
                self.isLocked = false
                self.lockedProfile = nil
                self.lockedDisplayID = nil
                self.failedUnlockAttempts = 0

                // Clear from Keychain
                clearLockState()

                print("[ReferenceModeManager] Successfully unlocked reference mode")
            } else {
                failedUnlockAttempts += 1
                throw ReferenceModeError.authenticationFailed
            }
        } catch {
            failedUnlockAttempts += 1
            throw error
        }
    }

    /// Check if profile modifications are allowed for a display
    func canModifyProfile(for displayID: CGDirectDisplayID) -> Bool {
        guard isLocked, let lockedDisplayID = lockedDisplayID else {
            return true
        }

        // Lock only applies to the specific display
        return displayID != lockedDisplayID
    }

    /// Force unlock without authentication (for emergency use)
    func forceUnlock() {
        self.isLocked = false
        self.lockedProfile = nil
        self.lockedDisplayID = nil
        self.failedUnlockAttempts = 0
        clearLockState()

        print("[ReferenceModeManager] Force unlocked reference mode")
    }

    // MARK: - Private Methods

    /// Authenticate user with biometrics or device passcode
    private func authenticateUser() async throws -> Bool {
        let context = LAContext()
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error = error {
                print("[ReferenceModeManager] Authentication not available: \(error.localizedDescription)")
            }
            throw ReferenceModeError.authenticationNotAvailable
        }

        // Set properties for better UX
        context.localizedCancelTitle = "Cancel Unlock"
        context.localizedFallbackTitle = "Enter Passcode"

        do {
            // Evaluate authentication policy
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Reference Mode to modify color profiles"
            )

            return success
        } catch let laError as LAError {
            print("[ReferenceModeManager] Authentication error: \(laError.localizedDescription)")

            switch laError.code {
            case .userCancel, .systemCancel:
                throw ReferenceModeError.authenticationCancelled
            case .userFallback:
                // User chose to enter passcode
                return try await authenticateWithPasscode(context: context)
            default:
                throw ReferenceModeError.authenticationFailed
            }
        } catch {
            throw ReferenceModeError.authenticationFailed
        }
    }

    /// Fallback authentication with device passcode
    private func authenticateWithPasscode(context: LAContext) async throws -> Bool {
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Enter your device passcode to unlock Reference Mode"
            )
            return success
        } catch {
            throw ReferenceModeError.authenticationFailed
        }
    }

    // MARK: - Persistence

    /// Save lock state to Keychain
    private func saveLockState() {
        guard isLocked, let profile = lockedProfile, let displayID = lockedDisplayID else {
            return
        }

        let lockState = ReferenceLockState(
            isLocked: isLocked,
            profileID: profile.id,
            profileName: profile.name,
            displayID: displayID,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(lockState) {
            KeychainHelper.save(data, forKey: keychainKey)
        }
    }

    /// Load lock state from Keychain
    private func loadLockState() {
        guard let data = KeychainHelper.load(forKey: keychainKey),
              let lockState = try? JSONDecoder().decode(ReferenceLockState.self, from: data) else {
            return
        }

        // Only restore if locked within the last 24 hours
        let timeInterval = Date().timeIntervalSince(lockState.timestamp)
        if timeInterval < 86400 { // 24 hours
            self.isLocked = lockState.isLocked
            self.lockedDisplayID = lockState.displayID

            // Note: We'll need to restore the profile from ProfileStore
            // This will be done in AppState integration
            print("[ReferenceModeManager] Restored lock state from Keychain")
        } else {
            // Clear expired lock state
            clearLockState()
        }
    }

    /// Clear lock state from Keychain
    private func clearLockState() {
        KeychainHelper.delete(forKey: keychainKey)
    }
}

// MARK: - Supporting Types

/// Structure for persisting lock state
struct ReferenceLockState: Codable {
    let isLocked: Bool
    let profileID: UUID
    let profileName: String
    let displayID: CGDirectDisplayID
    let timestamp: Date
}

// MARK: - Keychain Helper

/// Simple Keychain wrapper for secure storage
enum KeychainHelper {
    static func save(_ data: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete any existing item
        SecItemDelete(query as CFDictionary)

        // Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainHelper] Failed to save data: \(status)")
        }
    }

    static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        }

        return nil
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}