import SwiftUI
import AppKit

// MARK: - Elastic Button Modifier
/// Adds elastic press animation to any view
struct ElasticButtonModifier: ViewModifier {
    @State private var isPressed = false
    @State private var scale: CGFloat = 1.0
    @State private var rotation: Double = 0

    let hapticEnabled: Bool
    let intensity: CGFloat

    init(hapticEnabled: Bool = true, intensity: CGFloat = 1.0) {
        self.hapticEnabled = hapticEnabled
        self.intensity = intensity
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .onLongPressGesture(
                minimumDuration: 0,
                maximumDistance: .infinity,
                pressing: { pressing in
                    withAnimation(LiquidUITheme.Animation.elastic) {
                        isPressed = pressing
                        if pressing {
                            scale = 0.95 * (2.0 - intensity)
                            rotation = Double.random(in: -0.5...0.5) * intensity
                            if hapticEnabled {
                                NSHapticFeedbackManager.defaultPerformer.perform(
                                    .alignment,
                                    performanceTime: .now
                                )
                            }
                        } else {
                            scale = 1.0
                            rotation = 0
                        }
                    }
                },
                perform: {}
            )
    }
}

// MARK: - Elastic Slider Modifier
/// Adds squash and stretch effect to slider thumb
struct ElasticSliderModifier: ViewModifier {
    @Binding var value: Double
    @State private var isDragging = false
    @State private var velocity: CGFloat = 0
    @State private var lastValue: Double = 0
    @State private var scaleX: CGFloat = 1.0
    @State private var scaleY: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY)
            .onChange(of: value) { oldValue, newValue in
                let delta = newValue - oldValue
                velocity = CGFloat(delta) * 10

                withAnimation(LiquidUITheme.Animation.snappy) {
                    // Squash and stretch based on velocity
                    if abs(velocity) > 0.1 {
                        scaleX = 1.0 + min(abs(velocity) * 0.15, 0.3)
                        scaleY = 1.0 - min(abs(velocity) * 0.1, 0.2)
                    }
                }

                // Reset after animation
                withAnimation(LiquidUITheme.Animation.elastic.delay(0.1)) {
                    scaleX = 1.0
                    scaleY = 1.0
                }
            }
            .onLongPressGesture(
                minimumDuration: 0,
                maximumDistance: .infinity,
                pressing: { pressing in
                    isDragging = pressing
                    if pressing {
                        withAnimation(LiquidUITheme.Animation.snappy) {
                            scaleX = 1.1
                            scaleY = 0.95
                        }
                    } else {
                        withAnimation(LiquidUITheme.Animation.elastic) {
                            scaleX = 1.0
                            scaleY = 1.0
                        }
                    }
                },
                perform: {}
            )
    }
}

// MARK: - Liquid Hover Modifier
/// Adds fluid hover effect with depth
struct LiquidHoverModifier: ViewModifier {
    @State private var isHovered = false
    @State private var hoverScale: CGFloat = 1.0
    @State private var shadowRadius: CGFloat = 8
    @State private var yOffset: CGFloat = 0

    let enableDepth: Bool

    init(enableDepth: Bool = true) {
        self.enableDepth = enableDepth
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(hoverScale)
            .offset(y: yOffset)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.15 : 0.08),
                radius: shadowRadius,
                x: 0,
                y: isHovered ? 6 : 2
            )
            .onHover { hovering in
                withAnimation(LiquidUITheme.Animation.elastic) {
                    isHovered = hovering
                    hoverScale = hovering ? 1.02 : 1.0
                    shadowRadius = hovering ? 12 : 8
                    yOffset = hovering && enableDepth ? -2 : 0
                }
            }
    }
}

// MARK: - Ripple Effect Modifier
/// Creates a ripple effect on tap
struct RippleEffectModifier: ViewModifier {
    @State private var ripples: [Ripple] = []

    struct Ripple: Identifiable {
        let id = UUID()
        let position: CGPoint
        let startTime: Date
    }

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    ZStack {
                        ForEach(ripples) { ripple in
                            RippleView(
                                position: ripple.position,
                                startTime: ripple.startTime,
                                maxRadius: min(geometry.size.width, geometry.size.height)
                            )
                        }
                    }
                    .allowsHitTesting(false)
                }
            )
            .onTapGesture { location in
                let newRipple = Ripple(position: location, startTime: Date())
                ripples.append(newRipple)

                // Remove ripple after animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: {
                    ripples.removeAll { $0.id == newRipple.id }
                })
            }
    }
}

struct RippleView: View {
    let position: CGPoint
    let startTime: Date
    let maxRadius: CGFloat

    @State private var scale: CGFloat = 0
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .fill(LiquidUITheme.Colors.interactive.opacity(opacity))
            .frame(width: maxRadius * 2, height: maxRadius * 2)
            .scaleEffect(scale)
            .position(position)
            .onAppear {
                withAnimation(LiquidUITheme.Animation.gentle) {
                    scale = 1
                    opacity = 0
                }
            }
    }
}

// MARK: - Parallax Modifier
/// Adds parallax depth effect based on mouse position
struct ParallaxModifier: ViewModifier {
    @State private var mouseLocation: CGPoint = .zero
    @State private var xOffset: CGFloat = 0
    @State private var yOffset: CGFloat = 0

    let intensity: CGFloat
    let inverted: Bool

    init(intensity: CGFloat = 10, inverted: Bool = false) {
        self.intensity = intensity
        self.inverted = inverted
    }

    func body(content: Content) -> some View {
        content
            .offset(x: xOffset, y: yOffset)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    withAnimation(LiquidUITheme.Animation.gentle) {
                        let factor: CGFloat = inverted ? -1 : 1
                        xOffset = (location.x - mouseLocation.x) * 0.05 * intensity * factor
                        yOffset = (location.y - mouseLocation.y) * 0.05 * intensity * factor
                        mouseLocation = location
                    }
                case .ended:
                    withAnimation(LiquidUITheme.Animation.elastic) {
                        xOffset = 0
                        yOffset = 0
                    }
                }
            }
    }
}

// MARK: - Breathing Animation Modifier
/// Adds a subtle breathing/pulsing animation
struct BreathingModifier: ViewModifier {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0

    let intensity: CGFloat
    let duration: Double

    init(intensity: CGFloat = 0.05, duration: Double = 3.0) {
        self.intensity = intensity
        self.duration = duration
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    Animation.easeInOut(duration: duration)
                        .repeatForever(autoreverses: true)
                ) {
                    scale = 1.0 + intensity
                    opacity = 0.9
                }
            }
    }
}

// MARK: - View Extensions
extension View {
    /// Apply elastic button animation
    func elasticButton(haptic: Bool = true, intensity: CGFloat = 1.0) -> some View {
        modifier(ElasticButtonModifier(hapticEnabled: haptic, intensity: intensity))
    }

    /// Apply elastic slider animation
    func elasticSlider(value: Binding<Double>) -> some View {
        modifier(ElasticSliderModifier(value: value))
    }

    /// Apply liquid hover effect
    func liquidHover(enableDepth: Bool = true) -> some View {
        modifier(LiquidHoverModifier(enableDepth: enableDepth))
    }

    /// Apply ripple effect on tap
    func rippleEffect() -> some View {
        modifier(RippleEffectModifier())
    }

    /// Apply parallax depth effect
    func parallax(intensity: CGFloat = 10, inverted: Bool = false) -> some View {
        modifier(ParallaxModifier(intensity: intensity, inverted: inverted))
    }

    /// Apply breathing animation
    func breathing(intensity: CGFloat = 0.05, duration: Double = 3.0) -> some View {
        modifier(BreathingModifier(intensity: intensity, duration: duration))
    }
}