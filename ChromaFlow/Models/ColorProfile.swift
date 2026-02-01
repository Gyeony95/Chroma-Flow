import Foundation

struct ColorProfile: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let colorSpace: ColorSpace
    let iccProfileURL: URL?
    let isCustom: Bool
    let whitePoint: CIExyY?
    let gamut: GamutCoverage?

    enum ColorSpace: String, Codable, Sendable, CaseIterable {
        case sRGB
        case displayP3
        case adobeRGB
        case rec709
        case rec2020
        case custom
    }

    struct CIExyY: Codable, Sendable {
        let x: Double
        let y: Double
        let Y: Double
    }

    struct GamutCoverage: Codable, Sendable {
        let percentage: Double
        let targetColorSpace: ColorSpace
    }

    // MARK: - Initializers

    /// Full memberwise initializer
    init(
        id: UUID,
        name: String,
        colorSpace: ColorSpace,
        iccProfileURL: URL?,
        isCustom: Bool,
        whitePoint: CIExyY?,
        gamut: GamutCoverage?
    ) {
        self.id = id
        self.name = name
        self.colorSpace = colorSpace
        self.iccProfileURL = iccProfileURL
        self.isCustom = isCustom
        self.whitePoint = whitePoint
        self.gamut = gamut
    }

    /// Create a simple color profile from a color space
    init(colorSpace: ColorSpace, name: String? = nil) {
        self.id = UUID()
        self.name = name ?? colorSpace.rawValue
        self.colorSpace = colorSpace
        self.iccProfileURL = nil
        self.isCustom = false
        self.whitePoint = nil
        self.gamut = nil
    }
}
