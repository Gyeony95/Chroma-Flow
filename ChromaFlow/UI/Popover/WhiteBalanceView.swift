import SwiftUI

struct WhiteBalanceView: View {
    @Environment(AppState.self) private var appState

    @State private var temperature: Double = 6500
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastHapticValue: Double?

    var body: some View {
        VStack(spacing: 12) {
            // Temperature slider
            VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(temperatureColor)
                        .frame(width: 20)
                        .breathing(intensity: 0.05, duration: 2.0)
                    Text("White Balance")
                        .font(LiquidUITheme.Typography.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(temperature))K")
                        .font(LiquidUITheme.Typography.monoFont)
                        .foregroundStyle(temperatureColor)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                // Temperature label hints
                HStack {
                    Text("Warm")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.6))
                    Spacer()
                    Text("D65")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Spacer()
                    Text("Cool")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue.opacity(0.6))
                }

                // Color temperature slider
                WhiteBalanceSlider(
                    value: $temperature,
                    in: 3000...7500,
                    step: 50,
                    onEditingChanged: { editing in
                        if !editing {
                            handleTemperatureChange(temperature)
                        }
                    }
                )
                .onChange(of: temperature) { _, newValue in
                    handleTemperatureChange(newValue)
                }
                .accessibilityLabel("Color Temperature")
                .accessibilityValue("\(Int(temperature)) Kelvin")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        temperature = min(7500, temperature + 50)
                    case .decrement:
                        temperature = max(3000, temperature - 50)
                    @unknown default:
                        break
                    }
                }

                // Illuminant indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(temperatureColor)
                        .frame(width: 6, height: 6)
                    Text(illuminantName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appState.isWhiteBalanceActive {
                        Button(action: {
                            Task {
                                await resetTemperature()
                            }
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9))
                                Text("Reset")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(LiquidUITheme.Colors.interactive)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            temperature = appState.whiteBalanceTemperature
        }
        .onChange(of: appState.selectedDisplayID) { _, _ in
            temperature = appState.whiteBalanceTemperature
        }
    }

    // MARK: - Computed Properties

    private var temperatureColor: Color {
        if temperature < 5000 {
            return .orange
        } else if temperature < 6000 {
            return .yellow
        } else if temperature <= 6800 {
            return Color(red: 0.7, green: 0.8, blue: 1.0)
        } else {
            return .blue
        }
    }

    private var illuminantName: String {
        WhiteBalanceController.getIlluminantName(for: temperature)
    }

    // MARK: - Actions

    private func handleTemperatureChange(_ newValue: Double) {
        triggerHapticIfNeeded(for: newValue)

        debounceTask?.cancel()

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms debounce

            guard !Task.isCancelled else { return }

            await appState.setWhiteBalanceTemperature(newValue)
        }
    }

    private func resetTemperature() async {
        withAnimation(LiquidUITheme.Animation.elastic) {
            temperature = 6500
        }
        await appState.resetWhiteBalance()
    }

    private func triggerHapticIfNeeded(for value: Double) {
        // Haptic at D65 (6500K) midpoint and boundaries
        let hapticPoints: [Double] = [3000, 5000, 6500, 7500]
        let closest = hapticPoints.min(by: { abs($0 - value) < abs($1 - value) })

        guard let point = closest, abs(value - point) < 30 else {
            lastHapticValue = nil
            return
        }

        guard lastHapticValue != point else { return }
        lastHapticValue = point

        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }
}

// MARK: - White Balance Slider (Gradient Track)

struct WhiteBalanceSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var thumbScale: CGFloat = 1.0
    @State private var trackScale: CGFloat = 1.0

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 3000...7500,
        step: Double = 50,
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
                // Temperature gradient track
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [
                            Color.orange,
                            Color.yellow,
                            Color.white,
                            Color(red: 0.8, green: 0.9, blue: 1.0),
                            Color.blue.opacity(0.7)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(height: 6)
                    .scaleEffect(y: trackScale)
                    .opacity(0.6)

                // D65 marker (6500K reference point)
                let d65Position = CGFloat((6500 - range.lowerBound) / (range.upperBound - range.lowerBound))
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 1, height: 10)
                    .offset(x: geometry.size.width * d65Position)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .fill(thumbColor)
                            .frame(width: 10, height: 10)
                    )
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

                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .levelChange,
                            performanceTime: .now
                        )
                    }
            )
        }
        .frame(height: 20)
    }

    private var normalizedValue: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var thumbColor: Color {
        if value < 5000 {
            return .orange
        } else if value < 6000 {
            return .yellow
        } else if value <= 6800 {
            return Color(red: 0.8, green: 0.9, blue: 1.0)
        } else {
            return .blue.opacity(0.7)
        }
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    WhiteBalanceView()
        .environment(appState)
        .frame(width: 300)
}
