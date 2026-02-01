import Foundation

enum ColorSpaceDefinitions {
    static func profileURL(for colorSpace: ColorProfile.ColorSpace) -> URL? {
        switch colorSpace {
        case .sRGB:
            return URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
        case .displayP3:
            return URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc")
        case .adobeRGB:
            // Adobe RGB may need to be bundled
            return Bundle.main.url(forResource: "ChromaFlow-AdobeRGB", withExtension: "icc", subdirectory: "Profiles")
        case .rec709:
            return Bundle.main.url(forResource: "ChromaFlow-Rec709", withExtension: "icc", subdirectory: "Profiles")
        case .rec2020:
            return nil  // Not implemented in MVP
        case .custom:
            return nil  // Custom profiles from user directory
        }
    }

    static func defaultProfile(for colorSpace: ColorProfile.ColorSpace) -> ColorProfile {
        ColorProfile(
            id: profileID(for: colorSpace),
            name: localizedName(for: colorSpace),
            colorSpace: colorSpace,
            iccProfileURL: profileURL(for: colorSpace),
            isCustom: false,
            whitePoint: nil,
            gamut: nil
        )
    }

    private static func profileID(for colorSpace: ColorProfile.ColorSpace) -> UUID {
        switch colorSpace {
        case .sRGB: return Constants.sRGBProfileID
        case .displayP3: return Constants.displayP3ProfileID
        case .adobeRGB: return Constants.adobeRGBProfileID
        case .rec709: return Constants.rec709ProfileID
        case .rec2020, .custom: return UUID()
        }
    }

    private static func localizedName(for colorSpace: ColorProfile.ColorSpace) -> String {
        switch colorSpace {
        case .sRGB: return String(localized: "sRGB")
        case .displayP3: return String(localized: "Display P3")
        case .adobeRGB: return String(localized: "Adobe RGB")
        case .rec709: return String(localized: "Rec. 709")
        case .rec2020: return String(localized: "Rec. 2020")
        case .custom: return String(localized: "Custom")
        }
    }
}
