import SwiftUI

struct ProfileSwitcherView: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredProfile: UUID? = nil
    @State private var selectedAnimation: Bool = false
    @State private var showLockWarning: Bool = false

    let profiles: [ColorProfile] = [
        ColorProfile(
            id: UUID(),
            name: "sRGB",
            colorSpace: .sRGB,
            iccProfileURL: nil,
            isCustom: false,
            whitePoint: nil,
            gamut: nil
        ),
        ColorProfile(
            id: UUID(),
            name: "Display P3",
            colorSpace: .displayP3,
            iccProfileURL: nil,
            isCustom: false,
            whitePoint: nil,
            gamut: nil
        ),
        ColorProfile(
            id: UUID(),
            name: "Adobe RGB",
            colorSpace: .adobeRGB,
            iccProfileURL: nil,
            isCustom: false,
            whitePoint: nil,
            gamut: nil
        ),
        ColorProfile(
            id: UUID(),
            name: "Rec. 709",
            colorSpace: .rec709,
            iccProfileURL: nil,
            isCustom: false,
            whitePoint: nil,
            gamut: nil
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.tiny) {
            // Reference Mode Lock Indicator
            if appState.isReferenceModeActive {
                HStack(spacing: LiquidUITheme.Spacing.small) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text("Reference Mode Active")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Spacer()

                    Button("Unlock") {
                        Task {
                            await appState.toggleReferenceMode()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, LiquidUITheme.Spacing.medium)
                .padding(.vertical, LiquidUITheme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                        .fill(.orange.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.bottom, LiquidUITheme.Spacing.tiny)
            }

            ForEach(profiles) { profile in
                LiquidProfileButton(
                    profile: profile,
                    isActive: isActive(profile),
                    isHovered: hoveredProfile == profile.id,
                    isLocked: appState.isReferenceModeActive
                ) {
                    // Check if Reference Mode is active
                    if appState.isReferenceModeActive {
                        // Show lock warning
                        showLockWarning = true

                        // Haptic feedback for denied action
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment,
                            performanceTime: .now
                        )

                        // Auto-hide warning after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
                            showLockWarning = false
                        })
                    }

                    Task {
                        guard let displayID = appState.selectedDisplayID else { return }
                        do {
                            _ = try await appState.displayEngine.switchProfile(profile, for: displayID)
                        } catch ProfileManagerError.referenceModeActive {
                            // Show reference mode warning
                            showLockWarning = true
                        } catch {
                            // Error is already logged by DisplayEngineActor
                            // Toast notification will be shown by ToastManager
                        }
                    }

                    withAnimation(LiquidUITheme.Animation.bouncy) {
                        selectedAnimation = true
                    }

                    // Haptic feedback
                    NSHapticFeedbackManager.defaultPerformer.perform(
                        .levelChange,
                        performanceTime: .now
                    )

                    // Reset animation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                        selectedAnimation = false
                    })
                }
                .onHover { hovering in
                    withAnimation(LiquidUITheme.Animation.snappy) {
                        hoveredProfile = hovering ? profile.id : nil
                    }
                }
                .rippleEffect()
                .disabled(appState.isReferenceModeActive)
                .opacity(appState.isReferenceModeActive ? 0.6 : 1.0)
            }

            // Lock warning message
            if showLockWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Text("Unlock Reference Mode to change profiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, LiquidUITheme.Spacing.medium)
                .padding(.vertical, LiquidUITheme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                        .fill(.orange.opacity(0.05))
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(LiquidUITheme.Spacing.small)
    }

    private func isActive(_ profile: ColorProfile) -> Bool {
        guard let selectedID = appState.selectedDisplayID else { return false }
        return appState.activeProfiles[selectedID]?.id == profile.id
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    ProfileSwitcherView()
        .environment(appState)
        .frame(width: 300)
        .onAppear {
            appState.selectedDisplayID = 1
        }
}

// MARK: - Liquid Profile Button
struct LiquidProfileButton: View {
    let profile: ColorProfile
    let isActive: Bool
    let isHovered: Bool
    var isLocked: Bool = false
    let action: () -> Void

    @State private var iconScale: CGFloat = 1.0
    @State private var iconRotation: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: LiquidUITheme.Spacing.medium) {
                // Color space indicator
                ZStack {
                    Circle()
                        .fill(profileGradient)
                        .frame(width: 8, height: 8)
                        .scaleEffect(isActive ? 1.2 : 1.0)
                        .animation(LiquidUITheme.Animation.elastic, value: isActive)

                    if isActive {
                        Circle()
                            .strokeBorder(LiquidUITheme.Colors.interactive, lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 20, height: 20)

                // Profile name
                Text(profile.name)
                    .font(isActive ? LiquidUITheme.Typography.bodyFont.weight(.medium) : LiquidUITheme.Typography.bodyFont)
                    .foregroundColor(isActive ? LiquidUITheme.Colors.interactive : .primary)

                Spacer()

                // Active indicator with elastic animation or lock icon
                if isLocked && isActive {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.5).combined(with: .opacity),
                                removal: .scale(scale: 0.5).combined(with: .opacity)
                            )
                        )
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(LiquidUITheme.Colors.interactive)
                        .scaleEffect(iconScale)
                        .rotationEffect(.degrees(iconRotation))
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.5).combined(with: .opacity),
                                removal: .scale(scale: 0.5).combined(with: .opacity)
                            )
                        )
                        .onAppear {
                            withAnimation(LiquidUITheme.Animation.bouncy) {
                                iconScale = 1.1
                                iconRotation = 360
                            }
                            withAnimation(LiquidUITheme.Animation.elastic.delay(0.2)) {
                                iconScale = 1.0
                            }
                        }
                }
            }
            .padding(.horizontal, LiquidUITheme.Spacing.medium)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                            .strokeBorder(
                                isActive ? LiquidUITheme.Colors.interactive.opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .liquidDepth(isHovered ? .elevated : .card)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(LiquidUITheme.Animation.snappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.name)
        .accessibilityValue(isActive ? "Active" : "Inactive")
    }

    private var profileGradient: LinearGradient {
        let colors: [Color] = {
            switch profile.colorSpace {
            case .sRGB:
                return [.red, .green, .blue]
            case .displayP3:
                return [.pink, .purple, .blue]
            case .adobeRGB:
                return [.orange, .red, .purple]
            case .rec709:
                return [.cyan, .green, .yellow]
            default:
                return [.gray, .gray]
            }
        }()

        return LinearGradient(
            colors: colors.map { $0.opacity(0.8) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var backgroundFill: Color {
        if isActive {
            return LiquidUITheme.Colors.interactive.opacity(0.1)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
        }
    }
}
