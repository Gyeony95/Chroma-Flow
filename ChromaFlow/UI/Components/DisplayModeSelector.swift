//
//  DisplayModeSelector.swift
//  ChromaFlow
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI

// Import DisplayModeController types
import CoreGraphics

// MARK: - Main Component

/// Premium display mode selector with liquid UI animations
struct DisplayModeSelector: View {
    @Binding var selectedBitDepth: Int
    @Binding var selectedRange: DisplayModeController.RGBRange
    @Binding var selectedEncoding: DisplayModeController.ColorEncoding
    let availableModes: [DisplayModeController.DisplayMode]
    let onModeChange: (Int, DisplayModeController.RGBRange, DisplayModeController.ColorEncoding) -> Void

    @State private var showAdvanced: Bool = false
    @State private var isChanging: Bool = false
    @State private var changeDebounceTask: Task<Void, Never>?

    // Available options based on availableModes
    private var availableBitDepths: [Int] {
        Array(Set(availableModes.map { $0.bitDepth })).sorted()
    }

    private var availableRanges: [DisplayModeController.RGBRange] {
        Array(Set(availableModes.map { $0.range }))
    }

    private var availableEncodings: [DisplayModeController.ColorEncoding] {
        Array(Set(availableModes.map { $0.colorEncoding }))
    }

    var body: some View {
        VStack(spacing: LiquidUITheme.Spacing.medium) {
            // Header
            header

            // RGB Format Section
            bitDepthSection

            Divider()
                .padding(.vertical, LiquidUITheme.Spacing.tiny)

            // RGB Range Section
            rangeSection

            // Advanced Section Toggle
            advancedToggle

            // Color Encoding Section (Collapsible)
            if showAdvanced {
                Divider()
                    .padding(.vertical, LiquidUITheme.Spacing.tiny)
                    .transition(.opacity)

                encodingSection
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(LiquidUITheme.Spacing.medium)
        .frame(maxWidth: 300)
        .onChange(of: selectedBitDepth) { _, _ in scheduleChange() }
        .onChange(of: selectedRange) { _, _ in scheduleChange() }
        .onChange(of: selectedEncoding) { _, _ in scheduleChange() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: LiquidUITheme.Spacing.small) {
            Image(systemName: "tv.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .breathing(intensity: 0.08, duration: 2.5)

            Text("Display Mode")
                .font(LiquidUITheme.Typography.titleFont)
                .foregroundStyle(.primary)

            Spacer()

            if isChanging {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(.circular)
            }
        }
    }

    // MARK: - Bit Depth Section

    private var bitDepthSection: some View {
        VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
            sectionHeader(
                title: "RGB Format",
                icon: "sparkles"
            )

            HStack(spacing: LiquidUITheme.Spacing.small) {
                ForEach(availableBitDepths, id: \.self) { bitDepth in
                    BitDepthButton(
                        bitDepth: bitDepth,
                        isSelected: selectedBitDepth == bitDepth,
                        isAvailable: true,
                        isChanging: isChanging
                    ) {
                        withAnimation(LiquidUITheme.Animation.elastic) {
                            selectedBitDepth = bitDepth
                        }
                        hapticFeedback()
                    }
                }
            }
        }
    }

    // MARK: - Range Section

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
            sectionHeader(
                title: "RGB Range",
                icon: "arrow.up.left.and.arrow.down.right"
            )

            HStack(spacing: LiquidUITheme.Spacing.small) {
                ForEach(availableRanges, id: \.self) { range in
                    RangeButton(
                        range: range,
                        isSelected: selectedRange == range,
                        isChanging: isChanging
                    ) {
                        withAnimation(LiquidUITheme.Animation.elastic) {
                            selectedRange = range
                        }
                        hapticFeedback()
                    }
                }
            }
        }
    }

    // MARK: - Advanced Toggle

    private var advancedToggle: some View {
        Button {
            withAnimation(LiquidUITheme.Animation.elastic) {
                showAdvanced.toggle()
            }
            hapticFeedback(.alignment)
        } label: {
            HStack(spacing: LiquidUITheme.Spacing.small) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))

                Text("Advanced")
                    .font(LiquidUITheme.Typography.bodyFont.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Color Encoding")
                    .font(LiquidUITheme.Typography.captionFont)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Encoding Section

    private var encodingSection: some View {
        VStack(alignment: .leading, spacing: LiquidUITheme.Spacing.small) {
            sectionHeader(
                title: "Color Encoding",
                icon: "waveform",
                showInfo: true,
                infoText: "Color encoding affects how color information is transmitted. RGB 4:4:4 provides the best quality for desktop use."
            )

            VStack(spacing: LiquidUITheme.Spacing.small) {
                ForEach(availableEncodings, id: \.self) { encoding in
                    EncodingButton(
                        encoding: encoding,
                        isSelected: selectedEncoding == encoding,
                        isChanging: isChanging
                    ) {
                        withAnimation(LiquidUITheme.Animation.elastic) {
                            selectedEncoding = encoding
                        }
                        hapticFeedback()
                    }
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String, showInfo: Bool = false, infoText: String = "") -> some View {
        HStack(spacing: LiquidUITheme.Spacing.tiny) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(LiquidUITheme.Typography.captionFont.weight(.medium))
                .foregroundStyle(.secondary)

            if showInfo {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(infoText)
            }
        }
    }

    // MARK: - Methods

    private func scheduleChange() {
        // Cancel pending change
        changeDebounceTask?.cancel()

        // Debounce the change by 500ms
        changeDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                isChanging = true
                onModeChange(selectedBitDepth, selectedRange, selectedEncoding)

                // Reset changing state after a delay
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await MainActor.run {
                        isChanging = false
                    }
                }
            }
        }
    }

    private func hapticFeedback(_ type: NSHapticFeedbackManager.FeedbackPattern = .levelChange) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            type,
            performanceTime: .now
        )
    }
}

// MARK: - Bit Depth Button

struct BitDepthButton: View {
    let bitDepth: Int
    let isSelected: Bool
    let isAvailable: Bool
    let isChanging: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    private var displayName: String {
        "\(bitDepth)-bit \(bitDepth >= 10 ? "HDR" : "SDR")"
    }

    private var iconName: String {
        bitDepth >= 10 ? "sparkles" : "display"
    }

    private var description: String {
        bitDepth >= 10 ? "High dynamic range with \(pow(2.0, Double(bitDepth * 3)) / 1_000_000) million colors" :
                        "Standard dynamic range with \(pow(2.0, Double(bitDepth * 3)) / 1_000_000) million colors"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: LiquidUITheme.Spacing.tiny) {
                ZStack {
                    // Glow for selected state
                    if isSelected {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        glowColor.opacity(0.3),
                                        glowColor.opacity(0.1),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 25
                                )
                            )
                            .frame(width: 50, height: 50)
                            .scaleEffect(isPressed ? 0.9 : 1.0)
                    }

                    // Icon
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24, height: 24)
                }
                .frame(height: 32)

                // Label
                VStack(spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textColor)

                    if bitDepth >= 10 && isAvailable {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.green)
                            Text("Available")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .padding(.horizontal, LiquidUITheme.Spacing.tiny)
            .background(backgroundGradient)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium))
            .scaleEffect(scaleEffect)
            .opacity(isAvailable ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || isChanging)
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
        .help(description)
    }

    private var iconColor: Color {
        if !isAvailable { return .secondary.opacity(0.3) }
        if isSelected { return glowColor }
        if isHovered { return glowColor.opacity(0.8) }
        return .secondary.opacity(0.6)
    }

    private var textColor: Color {
        if !isAvailable { return .secondary.opacity(0.3) }
        if isSelected { return .primary }
        if isHovered { return .primary.opacity(0.9) }
        return .secondary
    }

    private var glowColor: Color {
        bitDepth >= 10 ? .purple : .blue
    }

    private var backgroundGradient: some ShapeStyle {
        if isSelected {
            return LinearGradient(
                colors: [
                    glowColor.opacity(0.15),
                    glowColor.opacity(0.08),
                    glowColor.opacity(0.05)
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
        if !isAvailable { return .secondary.opacity(0.1) }
        if isSelected { return glowColor.opacity(0.4) }
        if isHovered { return .secondary.opacity(0.3) }
        return .secondary.opacity(0.15)
    }

    private var scaleEffect: CGFloat {
        if isPressed { return 0.94 }
        if isHovered && !isSelected { return 1.03 }
        return 1.0
    }
}

// MARK: - Range Button

struct RangeButton: View {
    let range: DisplayModeController.RGBRange
    let isSelected: Bool
    let isChanging: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    private var displayName: String {
        switch range {
        case .full: return "Full Range"
        case .limited: return "Limited Range"
        case .auto: return "Auto"
        }
    }

    private var rangeDescription: String {
        switch range {
        case .full: return "0-255"
        case .limited: return "16-235"
        case .auto: return "Auto"
        }
    }

    private var iconName: String {
        switch range {
        case .full: return "arrow.up.left.and.arrow.down.right"
        case .limited: return "arrow.down.right.and.arrow.up.left"
        case .auto: return "gear"
        }
    }

    private var detailedInfo: String {
        switch range {
        case .full:
            return "Uses the complete color range (0-255). Best for computer displays and ensures maximum contrast and color accuracy."
        case .limited:
            return "Uses limited color range (16-235). Designed for TV compatibility where 16 represents black and 235 represents white."
        case .auto:
            return "Automatically selects the appropriate range based on the display and content type."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: LiquidUITheme.Spacing.tiny) {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.cyan.opacity(0.3),
                                        Color.cyan.opacity(0.1),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 25
                                )
                            )
                            .frame(width: 50, height: 50)
                            .scaleEffect(isPressed ? 0.9 : 1.0)
                    }

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24, height: 24)
                }
                .frame(height: 32)

                VStack(spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textColor)

                    Text(rangeDescription)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .padding(.horizontal, LiquidUITheme.Spacing.tiny)
            .background(backgroundGradient)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium))
            .scaleEffect(scaleEffect)
        }
        .buttonStyle(.plain)
        .disabled(isChanging)
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
        .help(detailedInfo)
    }

    private var iconColor: Color {
        if isSelected { return .cyan }
        if isHovered { return .cyan.opacity(0.8) }
        return .secondary.opacity(0.6)
    }

    private var textColor: Color {
        if isSelected { return .primary }
        if isHovered { return .primary.opacity(0.9) }
        return .secondary
    }

    private var backgroundGradient: some ShapeStyle {
        if isSelected {
            return LinearGradient(
                colors: [
                    Color.cyan.opacity(0.15),
                    Color.cyan.opacity(0.08),
                    Color.cyan.opacity(0.05)
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
        if isSelected { return .cyan.opacity(0.4) }
        if isHovered { return .secondary.opacity(0.3) }
        return .secondary.opacity(0.15)
    }

    private var scaleEffect: CGFloat {
        if isPressed { return 0.94 }
        if isHovered && !isSelected { return 1.03 }
        return 1.0
    }
}

// MARK: - Encoding Button

struct EncodingButton: View {
    let encoding: DisplayModeController.ColorEncoding
    let isSelected: Bool
    let isChanging: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    private var displayName: String {
        encoding.description
    }

    private var iconName: String {
        switch encoding {
        case .rgb: return "square.grid.3x3.fill"
        case .ycbcr444: return "waveform"
        case .ycbcr422: return "waveform.badge.minus"
        case .ycbcr420: return "waveform.badge.minus"
        }
    }

    private var shortDescription: String {
        switch encoding {
        case .rgb: return "Full color resolution"
        case .ycbcr444: return "Video, no subsampling"
        case .ycbcr422: return "Video, chroma subsampled"
        case .ycbcr420: return "Video, highly compressed"
        }
    }

    private var detailedInfo: String {
        switch encoding {
        case .rgb:
            return "RGB with full color resolution for each pixel. Best for text and detailed graphics. No compression."
        case .ycbcr444:
            return "Luma and chroma at full resolution. Video-optimized encoding with no color subsampling."
        case .ycbcr422:
            return "Chroma subsampled horizontally. Reduces bandwidth while maintaining good video quality. Half the color resolution."
        case .ycbcr420:
            return "Chroma subsampled both horizontally and vertically. Most compressed format, suitable for video streaming."
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: LiquidUITheme.Spacing.small) {
                // Icon
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.green.opacity(0.2),
                                        Color.green.opacity(0.05)
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 20
                                )
                            )
                            .frame(width: 40, height: 40)
                    }

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 32)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textColor)

                    Text(shortDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer()

                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, LiquidUITheme.Spacing.small)
            .padding(.horizontal, LiquidUITheme.Spacing.small)
            .background(backgroundGradient)
            .overlay(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium))
            .scaleEffect(scaleEffect)
        }
        .buttonStyle(.plain)
        .disabled(isChanging)
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
        .help(detailedInfo)
    }

    private var iconColor: Color {
        if isSelected { return .green }
        if isHovered { return .green.opacity(0.8) }
        return .secondary.opacity(0.6)
    }

    private var textColor: Color {
        if isSelected { return .primary }
        if isHovered { return .primary.opacity(0.9) }
        return .secondary
    }

    private var backgroundGradient: some ShapeStyle {
        if isSelected {
            return LinearGradient(
                colors: [
                    Color.green.opacity(0.12),
                    Color.green.opacity(0.06),
                    Color.green.opacity(0.03)
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
        if isSelected { return .green.opacity(0.4) }
        if isHovered { return .secondary.opacity(0.3) }
        return .secondary.opacity(0.15)
    }

    private var scaleEffect: CGFloat {
        if isPressed { return 0.97 }
        if isHovered && !isSelected { return 1.015 }
        return 1.0
    }
}

// MARK: - Previews

#Preview("Bit Depth Buttons") {
    HStack(spacing: 12) {
        BitDepthButton(
            bitDepth: 8,
            isSelected: true,
            isAvailable: true,
            isChanging: false
        ) {
            print("8-bit selected")
        }

        BitDepthButton(
            bitDepth: 10,
            isSelected: false,
            isAvailable: true,
            isChanging: false
        ) {
            print("10-bit selected")
        }
    }
    .frame(width: 300)
    .padding()
}

#Preview("Range Buttons") {
    HStack(spacing: 12) {
        RangeButton(
            range: .full,
            isSelected: true,
            isChanging: false
        ) {
            print("Full range selected")
        }

        RangeButton(
            range: .limited,
            isSelected: false,
            isChanging: false
        ) {
            print("Limited range selected")
        }
    }
    .frame(width: 300)
    .padding()
}

#Preview("Encoding Buttons") {
    VStack(spacing: 8) {
        EncodingButton(
            encoding: .rgb,
            isSelected: true,
            isChanging: false
        ) {
            print("RGB selected")
        }

        EncodingButton(
            encoding: .ycbcr444,
            isSelected: false,
            isChanging: false
        ) {
            print("YCbCr 4:4:4 selected")
        }

        EncodingButton(
            encoding: .ycbcr422,
            isSelected: false,
            isChanging: false
        ) {
            print("YCbCr 4:2:2 selected")
        }
    }
    .frame(width: 300)
    .padding()
}
