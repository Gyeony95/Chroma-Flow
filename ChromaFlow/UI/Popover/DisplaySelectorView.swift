import SwiftUI
import CoreGraphics

struct DisplaySelectorView: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: LiquidUITheme.Spacing.medium) {
            // Icon with breathing animation
            ZStack {
                Circle()
                    .fill(LiquidUITheme.Colors.interactive.opacity(0.1))
                    .frame(width: 32, height: 32)

                Image(systemName: "display")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LiquidUITheme.Colors.interactive)
                    .breathing(intensity: 0.05, duration: 3.0)
            }
            .liquidDepth(.card)

            // Custom dropdown selector
            LiquidPicker(
                selection: Binding(
                    get: { appState.selectedDisplayID ?? appState.displays.first?.id },
                    set: { appState.selectedDisplayID = $0 }
                ),
                label: selectedDisplayName
            ) {
                ForEach(appState.displays) { display in
                    LiquidPickerItem(
                        icon: displayIcon(for: display),
                        title: display.name,
                        subtitle: display.connectionType.description,
                        value: display.id as CGDirectDisplayID?,
                        action: { newValue in
                            appState.selectedDisplayID = newValue
                        }
                    )
                }
            }
            .accessibilityLabel("Select display")
            .accessibilityValue(selectedDisplayName)
        }
        .padding(LiquidUITheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                )
        )
        .liquidHover(enableDepth: true)
    }

    private var selectedDisplayName: String {
        guard let selectedID = appState.selectedDisplayID,
              let display = appState.displays.first(where: { $0.id == selectedID }) else {
            return "No display selected"
        }
        return display.name
    }

    private func displayIcon(for display: DisplayDevice) -> String {
        if display.isBuiltIn {
            return "laptopcomputer"
        }

        switch display.connectionType {
        case .thunderbolt, .usbC:
            return "cable.connector"
        case .displayPort:
            return "display"
        case .hdmi:
            return "display.2"
        default:
            return "display"
        }
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    DisplaySelectorView()
        .environment(appState)
        .frame(width: 300)
        .onAppear {
            appState.displays = [
                DisplayDevice(
                    id: 1,
                    name: "Built-in Retina Display",
                    manufacturer: "Apple",
                    model: "MacBook Pro",
                    serialNumber: nil,
                    connectionType: .builtIn,
                    isBuiltIn: true,
                    maxBrightness: 1.0,
                    ddcCapabilities: nil
                ),
                DisplayDevice(
                    id: 2,
                    name: "LG UltraFine 5K",
                    manufacturer: "LG",
                    model: "27MD5KL",
                    serialNumber: "123456",
                    connectionType: .thunderbolt,
                    isBuiltIn: false,
                    maxBrightness: 1.0,
                    ddcCapabilities: nil
                )
            ]
            appState.selectedDisplayID = 1
        }
}

// MARK: - Connection Type Extension
extension DisplayDevice.ConnectionType {
    var description: String {
        switch self {
        case .builtIn:
            return "Built-in Display"
        case .thunderbolt:
            return "Thunderbolt"
        case .displayPort:
            return "DisplayPort"
        case .hdmi:
            return "HDMI"
        case .usbC:
            return "USB-C"
        case .unknown:
            return "External"
        }
    }
}

// MARK: - Liquid Picker Components
struct LiquidPicker<Content: View, Value: Hashable>: View {
    @Binding var selection: Value?
    let label: String
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack {
                Text(label)
                    .font(LiquidUITheme.Typography.bodyFont)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(LiquidUITheme.Animation.snappy, value: isExpanded)
            }
            .padding(.horizontal, LiquidUITheme.Spacing.medium)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.small)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .onTapGesture {
            withAnimation(LiquidUITheme.Animation.snappy) {
                isExpanded.toggle()
            }
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange,
                performanceTime: .now
            )
        }
        .elasticButton(intensity: 0.5)
    }
}

struct LiquidPickerItem<Value: Hashable>: View {
    let icon: String
    let title: String
    let subtitle: String
    let value: Value?
    let action: (Value?) -> Void

    var body: some View {
        Button {
            action(value)
        } label: {
            HStack(spacing: LiquidUITheme.Spacing.medium) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(LiquidUITheme.Colors.interactive)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LiquidUITheme.Typography.bodyFont)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(LiquidUITheme.Typography.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
}
