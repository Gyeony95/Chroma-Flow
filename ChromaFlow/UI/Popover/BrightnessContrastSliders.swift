import SwiftUI
import CoreGraphics
import AppKit

struct BrightnessContrastSliders: View {
    @Environment(AppState.self) private var appState

    @State private var brightness: Double = 50.0
    @State private var contrast: Double = 50.0
    @State private var isLoading: Bool = true
    @State private var isDDCSupported: Bool = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastHapticValue: Double?

    // Shared DDCActor instance (static to avoid recreation on view updates)
    private static let ddcActor = DDCActor()
    private var ddcActor: DDCActor { Self.ddcActor }

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if !isDDCSupported {
                Text("DDC Not Supported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                // Brightness slider with elastic animation
                VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
                    HStack {
                        Image(systemName: "sun.max.fill")
                            .foregroundStyle(LiquidUITheme.Colors.interactive)
                            .frame(width: 20)
                            .breathing(intensity: 0.05, duration: 2.0)
                        Text("Brightness")
                            .font(LiquidUITheme.Typography.captionFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(brightness))%")
                            .font(LiquidUITheme.Typography.monoFont)
                            .foregroundStyle(LiquidUITheme.Colors.interactive)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    LiquidSlider(
                        value: $brightness,
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing {
                                handleBrightnessChange(brightness)
                            }
                        }
                    )
                    .onChange(of: brightness) { _, newValue in
                        handleBrightnessChange(newValue)
                    }
                    .accessibilityLabel("Brightness")
                    .accessibilityValue("\(Int(brightness))%")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            brightness = min(100, brightness + 1)
                        case .decrement:
                            brightness = max(0, brightness - 1)
                        @unknown default:
                            break
                        }
                    }
                }

                // Contrast slider with elastic animation
                VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(LiquidUITheme.Colors.interactive)
                            .frame(width: 20)
                            .breathing(intensity: 0.05, duration: 2.0)
                        Text("Contrast")
                            .font(LiquidUITheme.Typography.captionFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(contrast))%")
                            .font(LiquidUITheme.Typography.monoFont)
                            .foregroundStyle(LiquidUITheme.Colors.interactive)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    LiquidSlider(
                        value: $contrast,
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing {
                                handleContrastChange(contrast)
                            }
                        }
                    )
                    .onChange(of: contrast) { _, newValue in
                        handleContrastChange(newValue)
                    }
                    .accessibilityLabel("Contrast")
                    .accessibilityValue("\(Int(contrast))%")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            contrast = min(100, contrast + 1)
                        case .decrement:
                            contrast = max(0, contrast - 1)
                        @unknown default:
                            break
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task {
            await loadInitialValues()
        }
        .onChange(of: appState.selectedDisplayID) { _, _ in
            Task {
                await loadInitialValues()
            }
        }
    }

    // MARK: - Private Methods

    private func loadInitialValues() async {
        isLoading = true

        guard let displayID = appState.selectedDisplayID else {
            isLoading = false
            isDDCSupported = false
            return
        }

        // Check if display supports DDC
        guard let display = appState.displays.first(where: { $0.id == displayID }),
              !display.isBuiltIn,
              display.ddcCapabilities?.supportsBrightness == true else {
            isLoading = false
            isDDCSupported = false
            return
        }

        isDDCSupported = true

        // Read current hardware values
        do {
            async let brightnessValue = ddcActor.readBrightness(for: displayID)
            async let contrastValue = ddcActor.readContrast(for: displayID)

            let (b, c) = try await (brightnessValue, contrastValue)

            // Convert 0.0-1.0 to 0-100
            brightness = b * 100.0
            contrast = c * 100.0

        } catch {
            // Fallback to cached values if read fails
            if let cachedValues = appState.ddcValues[displayID] {
                brightness = cachedValues.brightness * 100.0
                contrast = cachedValues.contrast * 100.0
            }
        }

        isLoading = false
    }

    private func handleBrightnessChange(_ newValue: Double) {
        // Haptic feedback at boundaries
        triggerHapticIfNeeded(for: newValue)

        // Cancel existing debounce task
        debounceTask?.cancel()

        // Create new debounced task (16ms = ~60Hz)
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 16_000_000) // 16ms

            guard !Task.isCancelled else { return }

            await applyBrightness(newValue)
        }
    }

    private func handleContrastChange(_ newValue: Double) {
        // Haptic feedback at boundaries
        triggerHapticIfNeeded(for: newValue)

        // Cancel existing debounce task
        debounceTask?.cancel()

        // Create new debounced task (16ms = ~60Hz)
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 16_000_000) // 16ms

            guard !Task.isCancelled else { return }

            await applyContrast(newValue)
        }
    }

    private func applyBrightness(_ value: Double) async {
        guard let displayID = appState.selectedDisplayID else { return }

        // Convert 0-100 to 0.0-1.0
        let normalizedValue = value / 100.0

        // Fire-and-forget DDC command
        Task.detached {
            try? await ddcActor.setBrightness(normalizedValue, for: displayID)
        }

        // Update cached value immediately for responsiveness
        await MainActor.run {
            var currentValues = appState.ddcValues[displayID] ?? DDCValues()
            currentValues.brightness = normalizedValue
            appState.ddcValues[displayID] = currentValues
        }
    }

    private func applyContrast(_ value: Double) async {
        guard let displayID = appState.selectedDisplayID else { return }

        // Convert 0-100 to 0.0-1.0
        let normalizedValue = value / 100.0

        // Fire-and-forget DDC command
        Task.detached {
            try? await ddcActor.setContrast(normalizedValue, for: displayID)
        }

        // Update cached value immediately for responsiveness
        await MainActor.run {
            var currentValues = appState.ddcValues[displayID] ?? DDCValues()
            currentValues.contrast = normalizedValue
            appState.ddcValues[displayID] = currentValues
        }
    }

    private func triggerHapticIfNeeded(for value: Double) {
        // Only trigger at exact boundaries
        guard value == 0.0 || value == 100.0 else {
            lastHapticValue = nil
            return
        }

        // Prevent repeated haptics at same boundary
        guard lastHapticValue != value else { return }
        lastHapticValue = value

        // Trigger haptic feedback
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    BrightnessContrastSliders()
        .environment(appState)
        .frame(width: 300)
        .onAppear {
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
                        supportsColorTemperature: false,
                        supportsInputSource: false,
                        supportedColorPresets: [],
                        maxBrightness: 100,
                        maxContrast: 100,
                        rawCapabilityString: nil
                    )
                )
            ]
            appState.selectedDisplayID = 1
            appState.ddcValues[1] = DDCValues(brightness: 0.75, contrast: 0.60)
        }
}

// MARK: - Liquid Slider Component
struct LiquidSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var thumbScale: CGFloat = 1.0
    @State private var trackScale: CGFloat = 1.0

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...100,
        step: Double = 1,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 6)
                    .scaleEffect(y: trackScale)

                // Filled track
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [
                            LiquidUITheme.Colors.interactive.opacity(0.8),
                            LiquidUITheme.Colors.interactive
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geometry.size.width * normalizedValue, height: 6)
                    .scaleEffect(y: trackScale)
                    .animation(LiquidUITheme.Animation.snappy, value: value)

                // Thumb
                Circle()
                    .fill(LiquidUITheme.Colors.interactive)
                    .frame(width: 16, height: 16)
                    .scaleEffect(thumbScale)
                    .liquidShadow(radius: 8, y: 2)
                    .offset(x: geometry.size.width * normalizedValue - 8)
                    .animation(isDragging ? nil : LiquidUITheme.Animation.elastic, value: value)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            withAnimation(LiquidUITheme.Animation.snappy) {
                                isDragging = true
                                thumbScale = 1.3
                                trackScale = 1.2
                            }
                            onEditingChanged(true)

                            // Haptic feedback on start
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment,
                                performanceTime: .now
                            )
                        }

                        let newValue = gesture.location.x / geometry.size.width
                        let clampedValue = min(max(newValue, 0), 1)
                        let mappedValue = range.lowerBound + (range.upperBound - range.lowerBound) * clampedValue
                        let steppedValue = round(mappedValue / step) * step
                        value = min(max(steppedValue, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        withAnimation(LiquidUITheme.Animation.elastic) {
                            isDragging = false
                            thumbScale = 1.0
                            trackScale = 1.0
                        }
                        onEditingChanged(false)

                        // Haptic feedback on end
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .levelChange,
                            performanceTime: .now
                        )
                    }
            )
        }
    }

    private var normalizedValue: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
