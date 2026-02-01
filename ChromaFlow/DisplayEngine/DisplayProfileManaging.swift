import Foundation
import CoreGraphics

protocol DisplayProfileManaging: Sendable {
    func availableProfiles(for display: DisplayDevice) -> [ColorProfile]
    func activeProfile(for display: DisplayDevice) async throws -> ColorProfile
    func switchProfile(_ profile: ColorProfile, for display: DisplayDevice) async throws -> ProfileSwitchConfirmation
    func lockProfile(_ profile: ColorProfile, for display: DisplayDevice) async
    func unlockProfile(for display: DisplayDevice) async
}

struct ProfileSwitchConfirmation: Sendable {
    let displayID: CGDirectDisplayID
    let profile: ColorProfile
    let timestamp: Date
}
