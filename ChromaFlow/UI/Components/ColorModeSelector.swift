//
//  ColorModeSelector.swift
//  ChromaFlow
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI

/// Premium color mode selector with liquid UI animations
struct ColorModeSelector: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPreset: ColorPreset = .standard
    @State private var isChanging: Bool = false
    @State private var isDDCSupported: Bool = false
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: LiquidUITheme.Spacing.medium) {
            // Header
            HStack(spacing: LiquidUITheme.Spacing.small) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .breathing(intensity: 0.08, duration: 2.5)

                Text("Color Mode")
                    .font(LiquidUITheme.Typography.titleFont)
                    .foregroundStyle(.primary)

                Spacer()

                if isChanging {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(.circular)
                }
            }

            // Button Grid or Loading/Error State
            if isLoading {
                loadingView
            } else if !isDDCSupported {
                unsupportedView
            } else {
                colorPresetGrid
            }
        }
        .padding(LiquidUITheme.Spacing.medium)
        .task {
            await loadInitialState()
        }
        .onChange(of: appState.selectedDisplayID) { _, _ in
            Task {
                await loadInitialState()
            }
        }
        .onChange(of: appState.displays.first(where: { $0.id == appState.selectedDisplayID })?.ddcCapabilities?.supportsColorTemperature) { _, newValue in
            if let supported = newValue {
                // DDC detection completed - update state
                withAnimation(LiquidUITheme.Animation.snappy) {
                    isDDCSupported = supported
                }
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Checking DDC support...")
                .font(LiquidUITheme.Typography.captionFont)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, LiquidUITheme.Spacing.large)
    }

    private var unsupportedView: some View {
        VStack(spacing: LiquidUITheme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .breathing(intensity: 0.1, duration: 2.0)

            Text("DDC Not Supported")
                .font(LiquidUITheme.Typography.bodyFont.weight(.medium))
                .foregroundStyle(.primary)

            Text("This display doesn't support hardware color temperature control via DDC/CI.")
                .font(LiquidUITheme.Typography.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, LiquidUITheme.Spacing.large)
        .frame(maxWidth: .infinity)
    }

    private var colorPresetGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: LiquidUITheme.Spacing.small),
                GridItem(.flexible(), spacing: LiquidUITheme.Spacing.small),
                GridItem(.flexible(), spacing: LiquidUITheme.Spacing.small)
            ],
            spacing: LiquidUITheme.Spacing.small
        ) {
            ForEach(relevantPresets, id: \.self) { preset in
                ColorModeButton(
                    preset: preset,
                    isSelected: selectedPreset == preset,
                    isChanging: isChanging,
                    isDisabled: !isDDCSupported
                ) {
                    Task {
                        await changeColorMode(to: preset)
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var relevantPresets: [ColorPreset] {
        // Filter to only show presets that make sense for color temperature control
        [.warm, .standard, .cool, .native, .srgb]
    }

    // MARK: - Methods

    private func loadInitialState() async {
        isLoading = true
        errorMessage = nil

        guard let displayID = appState.selectedDisplayID else {
            isLoading = false
            isDDCSupported = false
            return
        }

        // Check if display is external (built-in displays never support DDC)
        guard let display = appState.displays.first(where: { $0.id == displayID }),
              !display.isBuiltIn else {
            isLoading = false
            isDDCSupported = false
            return
        }

        // If DDC capabilities are already known, use them
        if let caps = display.ddcCapabilities {
            isDDCSupported = caps.supportsColorTemperature || !caps.supportedColorPresets.isEmpty
            if !isDDCSupported {
                isLoading = false
                return
            }
        } else {
            // DDC capabilities not yet detected - optimistically assume supported for external displays
            // The actual DDC command will fail gracefully if not supported
            isDDCSupported = true
        }

        // Try to read current color preset
        do {
            if let currentPreset = try await appState.displayEngine.readColorPreset(for: displayID) {
                withAnimation(LiquidUITheme.Animation.elastic) {
                    selectedPreset = currentPreset
                }
            }
        } catch {
            // Failed to read current preset - this is OK, we'll still show the buttons
            // and let the user try. The error will be shown on button press if DDC truly isn't supported.
            selectedPreset = .standard
        }

        isLoading = false
    }

    private func changeColorMode(to preset: ColorPreset) async {
        guard let displayID = appState.selectedDisplayID else { return }
        guard !isChanging else { return } // Prevent multiple simultaneous changes

        // Start changing animation
        withAnimation(LiquidUITheme.Animation.snappy) {
            isChanging = true
            errorMessage = nil
        }

        // Haptic feedback
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )

        do {
            // Apply the color preset via DisplayEngine
            try await appState.displayEngine.setColorPreset(preset, for: displayID)

            // Update selected state with smooth animation
            withAnimation(LiquidUITheme.Animation.elastic) {
                selectedPreset = preset
                isChanging = false
            }

            // Success haptic
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange,
                performanceTime: .now
            )

        } catch {
            // Handle error
            withAnimation(LiquidUITheme.Animation.snappy) {
                isChanging = false
                errorMessage = error.localizedDescription
            }

            // If DDC failed, mark as unsupported so UI updates
            if let ddcError = error as? DDCActor.DDCError {
                switch ddcError {
                case .ddcNotSupported, .ddcDisabled:
                    withAnimation(LiquidUITheme.Animation.snappy) {
                        isDDCSupported = false
                    }
                default:
                    break
                }
            }

            // Show error toast
            await MainActor.run {
                ToastManager.shared.showError("Failed to change color mode: \(error.localizedDescription)")
            }

            // Error haptic
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
    }
}

// MARK: - Color Mode Button

struct ColorModeButton: View {
    let preset: ColorPreset
    let isSelected: Bool
    let isChanging: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: LiquidUITheme.Spacing.tiny) {
                // Icon with glow effect
                ZStack {
                    // Glow background for selected state
                    if isSelected {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        iconColor.opacity(0.3),
                                        iconColor.opacity(0.1),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 25
                                )
                            )
                            .frame(width: 50, height: 50)
                            .scaleEffect(isPressed ? 0.9 : 1.0)
                            .opacity(isPressed ? 0.7 : 1.0)
                    }

                    // Icon
                    Image(systemName: preset.iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24, height: 24)
                }
                .frame(height: 36)

                // Label with temperature (if applicable)
                VStack(spacing: 2) {
                    Text(preset.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textColor)

                    if let tempK = preset.colorTemperatureK {
                        Text("\(tempK)K")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .padding(.horizontal, LiquidUITheme.Spacing.tiny)
            .background(backgroundView)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium))
            .scaleEffect(scaleEffect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isChanging)
        .onHover { hovering in
            withAnimation(LiquidUITheme.Animation.snappy) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(LiquidUITheme.Animation.snappy) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(LiquidUITheme.Animation.elastic) {
                        isPressed = false
                    }
                }
        )
        .help(helpText)
    }

    // MARK: - Computed Properties

    private var iconColor: Color {
        if isDisabled {
            return .secondary.opacity(0.3)
        }
        if isSelected {
            return colorForPreset(preset)
        }
        if isHovered {
            return colorForPreset(preset).opacity(0.8)
        }
        return .secondary.opacity(0.6)
    }

    private var textColor: Color {
        if isDisabled {
            return .secondary.opacity(0.3)
        }
        if isSelected {
            return .primary
        }
        if isHovered {
            return .primary.opacity(0.9)
        }
        return .secondary
    }

    private var backgroundView: some ShapeStyle {
        if isSelected {
            return LinearGradient(
                colors: [
                    colorForPreset(preset).opacity(0.15),
                    colorForPreset(preset).opacity(0.08),
                    colorForPreset(preset).opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isHovered {
            return LinearGradient(
                colors: [
                    Color.primary.opacity(0.05),
                    Color.primary.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        if isDisabled {
            return .secondary.opacity(0.1)
        }
        if isSelected {
            return colorForPreset(preset).opacity(0.4)
        }
        if isHovered {
            return .secondary.opacity(0.3)
        }
        return .secondary.opacity(0.15)
    }

    private var scaleEffect: CGFloat {
        if isPressed {
            return 0.94
        }
        if isHovered && !isSelected {
            return 1.03
        }
        return 1.0
    }

    private var helpText: String {
        if isDisabled {
            return "Display does not support this color mode"
        }
        return preset.description
    }

    private func colorForPreset(_ preset: ColorPreset) -> Color {
        switch preset {
        case .warm:
            return .orange
        case .standard:
            return .cyan
        case .cool:
            return .blue
        case .native:
            return .purple
        case .srgb:
            return .green
        case .custom:
            return .pink
        }
    }
}

// MARK: - Shadow Extension

extension View {
    func liquidShadow(radius: CGFloat = 8, y: CGFloat = 2) -> some View {
        self.shadow(
            color: Color.black.opacity(0.12),
            radius: radius,
            x: 0,
            y: y
        )
    }
}

// MARK: - Preview

#Preview("Color Mode Selector - Supported") {
    ColorModeSelector()
        .environment({
            let appState = AppState()
            appState.displays = [
                DisplayDevice(
                    id: 1,
                    name: "External Display",
                    manufacturer: "Dell",
                    model: "U2720Q",
                    serialNumber: "ABC123",
                    connectionType: .displayPort,
                    isBuiltIn: false,
                    maxBrightness: 1.0,
                    ddcCapabilities: DDCCapabilities(
                        supportsBrightness: true,
                        supportsContrast: true,
                        supportsColorTemperature: true,
                        supportsInputSource: false,
                        supportedColorPresets: [0x04, 0x05, 0x08],
                        maxBrightness: 100,
                        maxContrast: 100,
                        rawCapabilityString: nil
                    )
                )
            ]
            appState.selectedDisplayID = 1
            return appState
        }())
        .frame(width: 320)
        .padding()
}

#Preview("Color Mode Selector - Not Supported") {
    ColorModeSelector()
        .environment({
            let appState = AppState()
            appState.displays = [
                DisplayDevice(
                    id: 1,
                    name: "Built-in Display",
                    manufacturer: "Apple",
                    model: "MacBook Pro",
                    serialNumber: "ABC123",
                    connectionType: .builtIn,
                    isBuiltIn: true,
                    maxBrightness: 1.0,
                    ddcCapabilities: nil
                )
            ]
            appState.selectedDisplayID = 1
            return appState
        }())
        .frame(width: 320)
        .padding()
}

#Preview("Color Mode Button - Selected") {
    ColorModeButton(
        preset: .warm,
        isSelected: true,
        isChanging: false,
        isDisabled: false
    ) {
        print("Warm selected")
    }
    .frame(width: 100)
    .padding()
}

#Preview("Color Mode Button - Hover") {
    ColorModeButton(
        preset: .cool,
        isSelected: false,
        isChanging: false,
        isDisabled: false
    ) {
        print("Cool selected")
    }
    .frame(width: 100)
    .padding()
}
