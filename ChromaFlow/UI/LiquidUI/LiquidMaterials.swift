import SwiftUI
import AppKit

// MARK: - Adaptive Glass View
/// High-resolution adaptive glass material that responds to background colors
struct AdaptiveGlassView: NSViewRepresentable {
    let blurRadius: CGFloat
    let saturationBoost: CGFloat
    let tintColor: Color?

    init(
        blurRadius: CGFloat = 32,
        saturationBoost: CGFloat = 1.2,
        tintColor: Color? = nil
    ) {
        self.blurRadius = blurRadius
        self.saturationBoost = saturationBoost
        self.tintColor = tintColor
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true

        // Add custom Core Image filters for enhanced blur
        if let layer = view.layer {
            layer.backgroundFilters = createBackgroundFilters()
            layer.compositingFilter = createCompositingFilter()
        }

        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Update filters if needed
        if let layer = nsView.layer {
            layer.backgroundFilters = createBackgroundFilters()
        }
    }

    private func createBackgroundFilters() -> [Any] {
        var filters: [Any] = []

        // Gaussian blur
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            filters.append(blurFilter)
        }

        // Saturation adjustment
        if let saturationFilter = CIFilter(name: "CIColorControls") {
            saturationFilter.setValue(saturationBoost, forKey: kCIInputSaturationKey)
            filters.append(saturationFilter)
        }

        return filters
    }

    private func createCompositingFilter() -> CIFilter? {
        // Add color dodge blend mode for luminosity
        return CIFilter(name: "CIColorDodgeBlendMode")
    }
}

// MARK: - Liquid Glass Material
/// Premium glass material with dynamic color sampling
public struct LiquidGlass: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var sampledColor: Color = .clear
    @State private var luminosity: Double = 0.5

    let intensity: Double
    let tintColor: Color?
    let autoSample: Bool

    public init(
        intensity: Double = 1.0,
        tintColor: Color? = nil,
        autoSample: Bool = true
    ) {
        self.intensity = intensity
        self.tintColor = tintColor
        self.autoSample = autoSample
    }

    public var body: some View {
        ZStack {
            // Base adaptive glass layer
            AdaptiveGlassView(
                blurRadius: 32 * intensity,
                saturationBoost: 1.2,
                tintColor: tintColor
            )
            .allowsHitTesting(false)

            // Gradient overlay for depth
            LinearGradient(
                colors: [
                    sampledColor.opacity(0.08 * intensity),
                    sampledColor.opacity(0.03 * intensity),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Radial gradient for center glow
            RadialGradient(
                colors: [
                    Color.white.opacity(0.05 * luminosity),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 200
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)

            // Noise texture overlay
            NoiseTexture(opacity: 0.03 * intensity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
        .onAppear {
            if autoSample {
                startColorSampling()
            }
        }
    }

    private func startColorSampling() {
        // Sample desktop wallpaper color
        Task {
            if let screen = NSScreen.main {
                let desktopImage = NSWorkspace.shared.desktopImageURL(for: screen)
                if let url = desktopImage,
                   let image = NSImage(contentsOf: url) {
                    sampledColor = dominantColor(from: image) ?? LiquidUITheme.Colors.primary
                    luminosity = calculateLuminosity(of: sampledColor)
                }
            }
        }
    }

    private func dominantColor(from image: NSImage) -> Color? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        var redTotal: CGFloat = 0
        var greenTotal: CGFloat = 0
        var blueTotal: CGFloat = 0
        let sampleSize = 10
        var sampleCount = 0

        for x in stride(from: 0, to: Int(bitmap.pixelsWide), by: sampleSize) {
            for y in stride(from: 0, to: Int(bitmap.pixelsHigh), by: sampleSize) {
                if let color = bitmap.colorAt(x: x, y: y) {
                    redTotal += color.redComponent
                    greenTotal += color.greenComponent
                    blueTotal += color.blueComponent
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return nil }

        return Color(
            red: redTotal / CGFloat(sampleCount),
            green: greenTotal / CGFloat(sampleCount),
            blue: blueTotal / CGFloat(sampleCount)
        )
    }

    private func calculateLuminosity(of color: Color) -> Double {
        let nsColor = NSColor(color)
        let brightness = nsColor.brightnessComponent
        return Double(brightness)
    }
}

// MARK: - Noise Texture
/// Procedural noise texture for organic feel
struct NoiseTexture: View {
    let opacity: Double
    @State private var phase: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            // Generate noise pattern
            let noiseSize: CGFloat = 2
            let cols = Int(size.width / noiseSize)
            let rows = Int(size.height / noiseSize)

            for x in 0..<cols {
                for y in 0..<rows {
                    let noise = perlinNoise(
                        x: CGFloat(x) * 0.1 + phase,
                        y: CGFloat(y) * 0.1
                    )
                    let alpha = (noise + 1) * 0.5 * opacity

                    context.fill(
                        Path(CGRect(
                            x: CGFloat(x) * noiseSize,
                            y: CGFloat(y) * noiseSize,
                            width: noiseSize,
                            height: noiseSize
                        )),
                        with: .color(.white.opacity(alpha))
                    )
                }
            }
        }
        .onAppear {
            // Subtle animation for living texture
            withAnimation(
                Animation.linear(duration: 20)
                    .repeatForever(autoreverses: false)
            ) {
                phase = 10
            }
        }
    }

    // Simplified Perlin noise implementation
    private func perlinNoise(x: CGFloat, y: CGFloat) -> CGFloat {
        let xi = Int(floor(x))
        let yi = Int(floor(y))
        let xf = x - floor(x)
        let yf = y - floor(y)

        let u = fade(xf)
        let v = fade(yf)

        let aa = grad(hash(xi, yi), xf, yf)
        let ab = grad(hash(xi, yi + 1), xf, yf - 1)
        let ba = grad(hash(xi + 1, yi), xf - 1, yf)
        let bb = grad(hash(xi + 1, yi + 1), xf - 1, yf - 1)

        let x1 = lerp(aa, ba, u)
        let x2 = lerp(ab, bb, u)

        return lerp(x1, x2, v)
    }

    private func fade(_ t: CGFloat) -> CGFloat {
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        return a + t * (b - a)
    }

    private func grad(_ hash: Int, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let h = hash & 3
        let u = h < 2 ? x : y
        let v = h < 2 ? y : x
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    private func hash(_ x: Int, _ y: Int) -> Int {
        var h = (x * 374761393 + y * 668265263) & 0x7FFFFFFF
        h = (h ^ (h >> 13)) * 1274126177
        return h & 0x7FFFFFFF
    }
}

// MARK: - Gradient Mesh Background
/// Animated gradient mesh for dynamic backgrounds
@available(macOS 15.0, *)
public struct GradientMesh: View {
    @State private var topLeading = Color.blue.opacity(0.3)
    @State private var topTrailing = Color.purple.opacity(0.3)
    @State private var bottomLeading = Color.mint.opacity(0.3)
    @State private var bottomTrailing = Color.pink.opacity(0.3)
    @State private var rotation: Double = 0

    let animated: Bool

    public init(animated: Bool = true) {
        self.animated = animated
    }

    public var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: [
                topLeading, Color.clear, topTrailing,
                Color.clear, Color.white.opacity(0.1), Color.clear,
                bottomLeading, Color.clear, bottomTrailing
            ]
        )
        .rotationEffect(.degrees(rotation))
        .blur(radius: 40)
        .onAppear {
            guard animated else { return }
            withAnimation(
                Animation.easeInOut(duration: 10)
                    .repeatForever(autoreverses: true)
            ) {
                topLeading = Color.mint.opacity(0.3)
                topTrailing = Color.blue.opacity(0.3)
                bottomLeading = Color.pink.opacity(0.3)
                bottomTrailing = Color.purple.opacity(0.3)
                rotation = 180
            }
        }
    }
}

// MARK: - View Extensions
extension View {
    /// Apply liquid glass background
    public func liquidGlassBackground(
        intensity: Double = 1.0,
        tintColor: Color? = nil
    ) -> some View {
        background(
            LiquidGlass(
                intensity: intensity,
                tintColor: tintColor
            )
        )
    }

    /// Apply gradient mesh background
    @available(macOS 15.0, *)
    public func gradientMeshBackground(animated: Bool = true) -> some View {
        background(
            GradientMesh(animated: animated)
                .ignoresSafeArea()
        )
    }
}