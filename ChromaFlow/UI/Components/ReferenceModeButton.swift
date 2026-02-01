//
//  ReferenceModeButton.swift
//  ChromaFlow
//
//  Created by Gwon iHyeon on 2026/02/01.
//

import SwiftUI

/// Button component for toggling Reference Mode lock
struct ReferenceModeButton: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button {
            Task {
                await appState.toggleReferenceMode()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: lockIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .symbolEffect(.bounce, value: appState.isReferenceModeActive)

                Text(buttonText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(backgroundView)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(helpText)
        .disabled(shouldDisableButton)
        .sheet(isPresented: .constant(appState.showReferenceModeUnlockDialog)) {
            ReferenceModeUnlockView()
        }
    }

    // MARK: - Computed Properties

    private var lockIcon: String {
        appState.isReferenceModeActive ? "lock.fill" : "lock.open"
    }

    private var buttonText: String {
        appState.isReferenceModeActive ? "Locked" : "Lock"
    }

    private var iconColor: Color {
        if appState.isReferenceModeActive {
            return .orange
        }
        return isHovering ? .blue : .secondary
    }

    private var textColor: Color {
        if appState.isReferenceModeActive {
            return .orange
        }
        return isHovering ? .primary : .secondary
    }

    private var backgroundView: some ShapeStyle {
        if appState.isReferenceModeActive {
            return LinearGradient(
                colors: [.orange.opacity(0.15), .orange.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isHovering {
            return LinearGradient(
                colors: [.blue.opacity(0.1), .blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        if appState.isReferenceModeActive {
            return .orange.opacity(0.5)
        }
        return isHovering ? .blue.opacity(0.3) : .secondary.opacity(0.2)
    }

    private var helpText: String {
        if appState.isReferenceModeActive {
            return "Reference Mode is locked. Click to unlock with authentication."
        } else if shouldDisableButton {
            return "Select a display to lock its color profile"
        } else {
            return "Lock current color profile to prevent accidental changes"
        }
    }

    private var shouldDisableButton: Bool {
        appState.selectedDisplayID == nil && !appState.isReferenceModeActive
    }

    private func colorForColorSpace(_ colorSpace: ColorProfile.ColorSpace) -> Color {
        switch colorSpace {
        case .sRGB:
            return .gray
        case .adobeRGB:
            return .purple
        case .displayP3:
            return .blue
        case .rec709:
            return .orange
        case .rec2020:
            return .red
        case .custom:
            return .pink
        }
    }
}

/// Sheet view for unlocking Reference Mode
struct ReferenceModeUnlockView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var isUnlocking = false
    @State private var unlockError: String?

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, value: isUnlocking)

            // Title
            Text("Unlock Reference Mode")
                .font(.title2.bold())

            // Description
            VStack(spacing: 8) {
                if let profile = appState.referenceProfile {
                    Text("Currently locked profile:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Circle()
                            .fill(colorForColorSpace(profile.colorSpace))
                            .frame(width: 12, height: 12)

                        Text(profile.name)
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.medium)
                    }
                }

                Text("Authentication required to unlock and modify color profiles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Error message
            if let error = unlockError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Button {
                    Task {
                        await performUnlock()
                    }
                } label: {
                    HStack {
                        if isUnlocking {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(.circular)
                        }
                        Text(isUnlocking ? "Authenticating..." : "Unlock")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUnlocking)
                .keyboardShortcut(.return)
            }
        }
        .padding(32)
        .frame(width: 420)
        .interactiveDismissDisabled(isUnlocking)
    }

    private func performUnlock() async {
        isUnlocking = true
        unlockError = nil

        do {
            try await Task.sleep(nanoseconds: 500_000_000) // Small delay for UX
            await appState.unlockReferenceMode()
            dismiss()
        } catch {
            withAnimation(.easeOut(duration: 0.3)) {
                unlockError = error.localizedDescription
            }

            // Clear error after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation {
                    unlockError = nil
                }
            }
        }

        isUnlocking = false
    }

    private func colorForColorSpace(_ colorSpace: ColorProfile.ColorSpace) -> Color {
        switch colorSpace {
        case .sRGB:
            return .gray
        case .adobeRGB:
            return .purple
        case .displayP3:
            return .blue
        case .rec709:
            return .orange
        case .rec2020:
            return .red
        case .custom:
            return .pink
        }
    }
}

// MARK: - Preview

#Preview("Reference Mode Button - Unlocked") {
    ReferenceModeButton()
        .environment(AppState())
        .padding()
}

#Preview("Reference Mode Button - Locked") {
    let appState = AppState()
    appState.isReferenceModeActive = true
    appState.referenceProfile = ColorProfile(colorSpace: .displayP3)

    return ReferenceModeButton()
        .environment(appState)
        .padding()
}

#Preview("Unlock Dialog") {
    let appState = AppState()
    appState.isReferenceModeActive = true
    appState.referenceProfile = ColorProfile(colorSpace: .displayP3)

    return ReferenceModeUnlockView()
        .environment(appState)
}