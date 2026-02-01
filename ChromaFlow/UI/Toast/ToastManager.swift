//
//  ToastManager.swift
//  ChromaFlow
//
//  Created on 2026-02-01.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    private(set) var currentToast: ToastNotification?
    private var toastQueue: [ToastNotification] = []
    private var isDisplaying = false

    private init() {}

    func show(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        style: ToastStyle = .info,
        duration: TimeInterval = 3.0
    ) {
        let toast = ToastNotification(
            title: title,
            subtitle: subtitle,
            icon: icon,
            style: style,
            duration: duration
        )

        if isDisplaying {
            toastQueue.append(toast)
        } else {
            displayToast(toast)
        }
    }

    func showProfileChanged(_ profile: ColorProfile, for appName: String? = nil) {
        let subtitle: String
        if let appName = appName {
            subtitle = "Activated for \(appName)"
        } else {
            subtitle = "Color profile switched"
        }

        show(
            title: "\(profile.name) Activated",
            subtitle: subtitle,
            icon: "paintpalette.fill",
            style: .success
        )
    }

    func showError(_ message: String) {
        show(
            title: "Error",
            subtitle: message,
            style: .error
        )
    }

    func showInfo(_ title: String, subtitle: String? = nil) {
        show(
            title: title,
            subtitle: subtitle,
            style: .info
        )
    }

    func showWarning(_ title: String, subtitle: String? = nil) {
        show(
            title: title,
            subtitle: subtitle,
            style: .warning
        )
    }

    func dismiss() {
        currentToast = nil
        isDisplaying = false

        // Process next toast in queue
        if !toastQueue.isEmpty {
            let nextToast = toastQueue.removeFirst()
            // Add slight delay before showing next toast
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                displayToast(nextToast)
            }
        }
    }

    private func displayToast(_ toast: ToastNotification) {
        isDisplaying = true
        currentToast = toast

        // Auto-dismiss after duration + animation time
        Task {
            try? await Task.sleep(for: .seconds(toast.duration + 0.3))
            if currentToast?.id == toast.id {
                dismiss()
            }
        }
    }
}
