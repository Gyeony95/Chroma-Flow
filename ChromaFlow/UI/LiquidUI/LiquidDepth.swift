import SwiftUI

// MARK: - Organic Depth System
/// Provides layered depth without hard dividers
public struct LiquidDepth {

    // MARK: - Depth Levels
    public enum Level: Int, CaseIterable {
        case background = 0
        case card = 1
        case elevated = 2
        case floating = 3
        case modal = 4

        var shadowStyle: ShadowStyle {
            switch self {
            case .background:
                return ShadowStyle(
                    color: .black.opacity(0.04),
                    radius: 2,
                    x: 0,
                    y: 1,
                    blur: 4
                )
            case .card:
                return ShadowStyle(
                    color: .black.opacity(0.08),
                    radius: 6,
                    x: 0,
                    y: 2,
                    blur: 8
                )
            case .elevated:
                return ShadowStyle(
                    color: .black.opacity(0.12),
                    radius: 12,
                    x: 0,
                    y: 4,
                    blur: 16
                )
            case .floating:
                return ShadowStyle(
                    color: .black.opacity(0.16),
                    radius: 20,
                    x: 0,
                    y: 8,
                    blur: 24
                )
            case .modal:
                return ShadowStyle(
                    color: .black.opacity(0.24),
                    radius: 32,
                    x: 0,
                    y: 16,
                    blur: 48
                )
            }
        }

        var zIndex: Double {
            Double(self.rawValue)
        }

        var scale: CGFloat {
            switch self {
            case .background: return 1.0
            case .card: return 1.0
            case .elevated: return 1.01
            case .floating: return 1.02
            case .modal: return 1.03
            }
        }
    }

    // MARK: - Shadow Style
    public struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
        let blur: CGFloat
    }
}

// MARK: - Depth Modifier
struct DepthModifier: ViewModifier {
    let level: LiquidDepth.Level
    let animated: Bool
    @State private var currentLevel: LiquidDepth.Level

    init(level: LiquidDepth.Level, animated: Bool = true) {
        self.level = level
        self.animated = animated
        self._currentLevel = State(initialValue: level)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(currentLevel.scale)
            .background(
                DepthShadowView(shadowStyle: currentLevel.shadowStyle)
            )
            .zIndex(currentLevel.zIndex)
            .onChange(of: level) { _, newLevel in
                if animated {
                    withAnimation(LiquidUITheme.Animation.elastic) {
                        currentLevel = newLevel
                    }
                } else {
                    currentLevel = newLevel
                }
            }
    }
}

// MARK: - Multiple Shadow Layers
struct DepthShadowView: View {
    let shadowStyle: LiquidDepth.ShadowStyle

    var body: some View {
        ZStack {
            // Layer 1: Ambient shadow (soft, wide)
            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                .fill(Color.clear)
                .shadow(
                    color: shadowStyle.color.opacity(0.5),
                    radius: shadowStyle.radius * 2,
                    x: 0,
                    y: shadowStyle.y * 0.5
                )

            // Layer 2: Key shadow (sharp, directional)
            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                .fill(Color.clear)
                .shadow(
                    color: shadowStyle.color,
                    radius: shadowStyle.radius,
                    x: shadowStyle.x,
                    y: shadowStyle.y
                )

            // Layer 3: Contact shadow (very sharp, close)
            RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                .fill(Color.clear)
                .shadow(
                    color: shadowStyle.color.opacity(1.5),
                    radius: shadowStyle.radius * 0.25,
                    x: 0,
                    y: shadowStyle.y * 0.25
                )
        }
        .blur(radius: shadowStyle.blur * 0.1)
    }
}

// MARK: - Layered Container
/// Container that automatically manages depth for child views
public struct LiquidLayeredContainer<Content: View>: View {
    let content: Content
    let spacing: CGFloat

    public init(
        spacing: CGFloat = LiquidUITheme.Spacing.medium,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            DepthGradient()
        )
    }
}

// MARK: - Depth Gradient
/// Subtle gradient that enhances depth perception
struct DepthGradient: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                Color.primary.opacity(colorScheme == .dark ? 0.02 : 0.01),
                Color.clear,
                Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(colorScheme == .dark ? .plusLighter : .multiply)
    }
}

// MARK: - Organic Divider
/// Soft depth-based separator without hard lines
public struct LiquidDivider: View {
    let opacity: Double
    let blurRadius: CGFloat

    public init(
        opacity: Double = 0.1,
        blurRadius: CGFloat = 8
    ) {
        self.opacity = opacity
        self.blurRadius = blurRadius
    }

    public var body: some View {
        ZStack {
            // Top highlight
            LinearGradient(
                colors: [
                    Color.white.opacity(opacity),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 1)
            .blur(radius: blurRadius)
            .offset(y: -1)

            // Bottom shadow
            LinearGradient(
                colors: [
                    Color.black.opacity(opacity * 2),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 2)
            .blur(radius: blurRadius)
            .offset(y: 1)
        }
        .frame(height: 1)
    }
}

// MARK: - Floating Card
/// Card component with organic depth
public struct LiquidCard<Content: View>: View {
    let content: Content
    let depth: LiquidDepth.Level
    let padding: CGFloat

    public init(
        depth: LiquidDepth.Level = .card,
        padding: CGFloat = LiquidUITheme.Spacing.medium,
        @ViewBuilder content: () -> Content
    ) {
        self.depth = depth
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: LiquidUITheme.CornerRadius.medium)
                    .fill(.regularMaterial)
            )
            .liquidDepth(depth)
    }
}

// MARK: - View Extensions
extension View {
    /// Apply organic depth to any view
    public func liquidDepth(_ level: LiquidDepth.Level, animated: Bool = true) -> some View {
        modifier(DepthModifier(level: level, animated: animated))
    }

    /// Apply layered shadows for depth
    public func liquidShadow(
        color: Color = .black,
        opacity: Double = 0.1,
        radius: CGFloat = 10,
        x: CGFloat = 0,
        y: CGFloat = 5
    ) -> some View {
        self
            .shadow(color: color.opacity(opacity * 0.5), radius: radius * 2, x: 0, y: y * 0.5)
            .shadow(color: color.opacity(opacity), radius: radius, x: x, y: y)
            .shadow(color: color.opacity(opacity * 1.5), radius: radius * 0.25, x: 0, y: y * 0.25)
    }

    /// Remove all Dividers and replace with organic depth
    public func organicSeparators() -> some View {
        self.environment(\.defaultMinListRowHeight, 0)
    }
}