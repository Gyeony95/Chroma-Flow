import SwiftUI
import AppKit

// MARK: - Liquid UI Theme
/// Central theme manager for the Liquid UI design system
public struct LiquidUITheme {

    // MARK: - Color System
    public struct Colors {
        /// Dynamic colors that adapt to light/dark mode
        static let primary = Color("AccentColor", bundle: .main)
        static let glass = Color(nsColor: .controlBackgroundColor).opacity(0.3)
        static let glassOverlay = Color(nsColor: .labelColor).opacity(0.02)

        /// Semantic colors
        static let interactive = Color.accentColor
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red

        /// Adaptive tint colors based on background
        static func adaptiveTint(for backgroundColor: Color) -> Color {
            // This would sample the background and return an appropriate tint
            return primary
        }
    }

    // MARK: - Typography
    public struct Typography {
        static let displayFont = Font.custom("SF Pro Display", size: 24).weight(.semibold)
        static let titleFont = Font.custom("SF Pro Display", size: 16).weight(.medium)
        static let bodyFont = Font.custom("SF Pro Text", size: 13)
        static let captionFont = Font.custom("SF Pro Text", size: 11)
        static let monoFont = Font.custom("SF Mono", size: 12)
    }

    // MARK: - Spacing
    public struct Spacing {
        public static let micro: CGFloat = 2
        public static let tiny: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xlarge: CGFloat = 24
        public static let xxlarge: CGFloat = 32
    }

    // MARK: - Animation Presets
    public struct Animation {
        /// Ultra-smooth spring for primary interactions
        static let elastic = SwiftUI.Animation.spring(
            response: 0.35,
            dampingFraction: 0.72,
            blendDuration: 0.2
        )

        /// Snappy spring for quick feedback
        static let snappy = SwiftUI.Animation.spring(
            response: 0.25,
            dampingFraction: 0.85,
            blendDuration: 0.1
        )

        /// Gentle spring for subtle movements
        static let gentle = SwiftUI.Animation.spring(
            response: 0.45,
            dampingFraction: 0.9,
            blendDuration: 0.3
        )

        /// Bouncy spring for playful interactions
        static let bouncy = SwiftUI.Animation.spring(
            response: 0.4,
            dampingFraction: 0.6,
            blendDuration: 0.25
        )

        /// Check if reduce motion is enabled
        static var shouldReduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Get appropriate animation based on accessibility settings
        static func adaptive(_ animation: SwiftUI.Animation) -> SwiftUI.Animation {
            shouldReduceMotion ? .easeInOut(duration: 0.2) : animation
        }
    }

    // MARK: - Shadow Presets
    public struct Shadows {
        /// Subtle elevation for flat elements
        static let subtle = Shadow(
            color: Color.black.opacity(0.08),
            radius: 4,
            x: 0,
            y: 2
        )

        /// Medium elevation for cards and buttons
        static let medium = Shadow(
            color: Color.black.opacity(0.12),
            radius: 8,
            x: 0,
            y: 4
        )

        /// Deep elevation for popovers and modals
        static let deep = Shadow(
            color: Color.black.opacity(0.16),
            radius: 16,
            x: 0,
            y: 8
        )

        /// Dramatic elevation for hero elements
        static let dramatic = Shadow(
            color: Color.black.opacity(0.2),
            radius: 24,
            x: 0,
            y: 12
        )

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Corner Radius
    public struct CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let xlarge: CGFloat = 20
    }

    // MARK: - Blur Radius
    public struct Blur {
        static let light: CGFloat = 8
        static let medium: CGFloat = 16
        static let heavy: CGFloat = 32
        static let ultraHeavy: CGFloat = 64
    }
}

// MARK: - Theme Protocol Conformance
public struct LiquidTheme: UIThemeProviding {
    public func popoverMaterial() -> some View {
        LiquidGlassMaterial()
    }

    public func interactionSpring() -> SwiftUI.Animation {
        LiquidUITheme.Animation.elastic
    }

    public var supportsAdaptiveGlass: Bool { true }
}

// MARK: - Custom Glass Material
struct LiquidGlassMaterial: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var backgroundColor: Color = .clear

    var body: some View {
        ZStack {
            // Base glass layer
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    // Adaptive color overlay
                    LinearGradient(
                        colors: [
                            backgroundColor.opacity(0.05),
                            backgroundColor.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // Noise texture for depth
                    NoiseOverlay()
                )
        }
        .onAppear {
            updateBackgroundColor()
        }
    }

    private func updateBackgroundColor() {
        // Sample the desktop/window background color
        // This is a simplified version - in production, you'd sample the actual background
        backgroundColor = colorScheme == .dark ? Color.blue : Color.indigo
    }
}

// MARK: - Noise Overlay
struct NoiseOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Create subtle noise pattern
                for _ in 0..<500 {
                    let x = CGFloat.random(in: 0...size.width)
                    let y = CGFloat.random(in: 0...size.height)
                    let opacity = Double.random(in: 0.02...0.05)

                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(.white.opacity(opacity))
                    )
                }
            }
            .allowsHitTesting(false)
            .blendMode(.overlay)
        }
    }
}