import SwiftUI

struct PopoverContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isVisible = false

    var body: some View {
        @Bindable var bindableAppState = appState
        ZStack {
            // Liquid glass background
            LiquidGlass(intensity: 1.2)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if appState.showConflictWarning {
                    ConflictWarningBanner(message: appState.conflictMessage ?? "")
                        .transition(.asymmetric(
                            insertion: .push(from: .top).combined(with: .opacity),
                            removal: .push(from: .bottom).combined(with: .opacity)
                        ))
                }

                // Display selector with depth
                DisplaySelectorView()
                    .liquidDepth(.elevated)
                    .padding(.horizontal, LiquidUITheme.Spacing.medium)
                    .padding(.top, LiquidUITheme.Spacing.medium)

                // Organic separator
                LiquidDivider(opacity: 0.05, blurRadius: 12)
                    .padding(.vertical, LiquidUITheme.Spacing.small)

                // Profile switcher with card depth
                ProfileSwitcherView()
                    .liquidDepth(.card)
                    .padding(.horizontal, LiquidUITheme.Spacing.medium)

                // Organic separator
                LiquidDivider(opacity: 0.05, blurRadius: 12)
                    .padding(.vertical, LiquidUITheme.Spacing.small)

                // White Balance control (shown for all displays)
                WhiteBalanceView()
                    .liquidDepth(.card)
                    .padding(.horizontal, LiquidUITheme.Spacing.medium)

                // Organic separator
                LiquidDivider(opacity: 0.05, blurRadius: 12)
                    .padding(.vertical, LiquidUITheme.Spacing.small)

                // Display Mode Selector (only shown for external displays)
                if appState.selectedDisplayID != nil,
                   let display = appState.displays.first(where: { $0.id == appState.selectedDisplayID }),
                   !display.isBuiltIn,
                   !appState.availableDisplayModes.isEmpty {

                    DisplayModeSelector(
                        selectedBitDepth: $bindableAppState.selectedBitDepth,
                        selectedRange: $bindableAppState.selectedRGBRange,
                        selectedEncoding: $bindableAppState.selectedColorEncoding,
                        availableModes: appState.availableDisplayModes
                    ) { bitDepth, range, encoding in
                        Task {
                            await appState.setDisplayMode(bitDepth: bitDepth, range: range, encoding: encoding)
                        }
                    }
                    .liquidDepth(.card)
                    .padding(.horizontal, LiquidUITheme.Spacing.medium)

                    // Organic separator
                    LiquidDivider(opacity: 0.05, blurRadius: 12)
                        .padding(.vertical, LiquidUITheme.Spacing.small)
                }

                // Color mode selector (shown for all external displays)
                if appState.selectedDisplayID != nil,
                   let display = appState.displays.first(where: { $0.id == appState.selectedDisplayID }),
                   !display.isBuiltIn {

                    VStack(spacing: LiquidUITheme.Spacing.small) {
                        // DDC status indicator (only shown after detection completes)
                        if let caps = display.ddcCapabilities, caps.supportsColorTemperature {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("DDC Supported")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, LiquidUITheme.Spacing.medium)
                        }

                        ColorModeSelector()
                            .liquidDepth(.card)
                            .padding(.horizontal, LiquidUITheme.Spacing.medium)
                    }

                    // Organic separator
                    LiquidDivider(opacity: 0.05, blurRadius: 12)
                        .padding(.vertical, LiquidUITheme.Spacing.small)
                }

                // Brightness/Contrast sliders
                BrightnessContrastSliders()
                    .liquidDepth(.card)

                // Organic separator
                LiquidDivider(opacity: 0.05, blurRadius: 12)
                    .padding(.vertical, LiquidUITheme.Spacing.small)

                // Revert button with elastic animation
                Button(String(localized: "Revert to Previous")) {
                    // TODO: Implement revert
                }
                .buttonStyle(LiquidButtonStyle())
                .padding(LiquidUITheme.Spacing.medium)
                .accessibilityLabel(String(localized: "Revert to Previous"))
                .accessibilityHint("Restores the previous color profile")
                }
            }
            .frame(width: 320)
        }
        .clipShape(RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.large))
        .liquidShadow(radius: 24, y: 12)
        .scaleEffect(isVisible ? 1 : 0.95)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(LiquidUITheme.Animation.elastic) {
                isVisible = true
            }
            // Refresh displays when popover opens
            Task {
                await appState.loadConnectedDisplays()
            }
        }
        .overlay(
            // Toast notification overlay
            ToastOverlay()
        )
    }
}

struct ConflictWarningBanner: View {
    let message: String
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: LiquidUITheme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .breathing(intensity: 0.1)

            Text(message)
                .font(LiquidUITheme.Typography.captionFont)
                .foregroundStyle(.orange)

            Spacer()
        }
        .padding(LiquidUITheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                .fill(.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                        .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
                )
        )
        .liquidDepth(.card)
        .elasticButton(intensity: 0.5)
    }
}

// Custom button style for Liquid UI
struct LiquidButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LiquidUITheme.Typography.bodyFont)
            .foregroundColor(LiquidUITheme.Colors.interactive)
            .padding(.horizontal, LiquidUITheme.Spacing.large)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                    .fill(LiquidUITheme.Colors.interactive.opacity(configuration.isPressed ? 0.2 : (isHovered ? 0.15 : 0.1)))
                    .overlay(
                        RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                            .strokeBorder(
                                LiquidUITheme.Colors.interactive.opacity(configuration.isPressed ? 0.4 : 0.2),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(LiquidUITheme.Animation.snappy, value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(LiquidUITheme.Animation.gentle) {
                    isHovered = hovering
                }
            }
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    PopoverContentView()
        .environment(appState)
        .onAppear {
            appState.displays = [
                DisplayDevice(
                    id: 1,
                    name: "Built-in Display",
                    manufacturer: "Apple",
                    model: "MacBook Pro",
                    serialNumber: nil,
                    connectionType: .builtIn,
                    isBuiltIn: true,
                    maxBrightness: 1.0,
                    ddcCapabilities: nil
                )
            ]
            appState.selectedDisplayID = 1
            appState.showConflictWarning = true
            appState.conflictMessage = "Night Shift is active"
        }
}
