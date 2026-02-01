import Foundation

struct FeatureFlags {
    @FeatureFlag("builtInBrightness", defaultValue: false)
    static var builtInBrightness: Bool

    @FeatureFlag("nightShiftDetection", defaultValue: false)
    static var nightShiftDetection: Bool

    @FeatureFlag("ioKitAmbientLight", defaultValue: false)
    static var ioKitAmbientLight: Bool
}

@propertyWrapper
struct FeatureFlag {
    let key: String
    let defaultValue: Bool

    init(_ key: String, defaultValue: Bool) {
        self.key = "FeatureFlag.\(key)"
        self.defaultValue = defaultValue
    }

    var wrappedValue: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
