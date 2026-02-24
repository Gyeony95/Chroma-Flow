import Foundation
import CoreGraphics

/// Per-monitor settings storage with auto-save and restore functionality
@MainActor
final class DeviceMemory: Sendable {
    static let shared = DeviceMemory()

    private let storageDirectory: URL
    private let debounceInterval: TimeInterval = 0.5
    private var saveWorkItem: DispatchWorkItem?

    private let deviceSettings: DeviceSettingsStore

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        storageDirectory = appSupport
            .appendingPathComponent("ChromaFlow")
            .appendingPathComponent("devices")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        deviceSettings = DeviceSettingsStore(directory: storageDirectory)
    }

    // MARK: - Public API

    /// Save settings for a display device
    func saveSettings(for device: DisplayDevice, settings: DeviceSettings) {
        let deviceID = deviceIdentifier(for: device)
        deviceSettings.save(settings, for: deviceID)
        scheduleSave(for: deviceID, settings: settings)
    }

    /// Restore settings for a display device
    func restoreSettings(for device: DisplayDevice) -> DeviceSettings? {
        let deviceID = deviceIdentifier(for: device)
        return deviceSettings.load(for: deviceID)
    }

    /// Remove settings for a display device
    func removeSettings(for device: DisplayDevice) {
        let deviceID = deviceIdentifier(for: device)
        deviceSettings.remove(for: deviceID)
    }

    /// List all stored device identifiers
    func listStoredDevices() -> [String] {
        deviceSettings.listAll()
    }

    // MARK: - DDC Persistence

    /// Save DDC brightness value (0.0 to 1.0) for a display device
    func saveDDCBrightness(_ value: Double, for device: DisplayDevice) {
        let deviceID = deviceIdentifier(for: device)
        var settings = deviceSettings.load(for: deviceID) ?? DeviceSettings()
        settings.lastDDCBrightness = Int(value * 100) // Store as 0-100 integer
        settings.lastModified = Date()
        deviceSettings.save(settings, for: deviceID)
        scheduleSave(for: deviceID, settings: settings)
    }

    /// Save DDC contrast value (0.0 to 1.0) for a display device
    func saveDDCContrast(_ value: Double, for device: DisplayDevice) {
        let deviceID = deviceIdentifier(for: device)
        var settings = deviceSettings.load(for: deviceID) ?? DeviceSettings()
        settings.lastDDCContrast = Int(value * 100) // Store as 0-100 integer
        settings.lastModified = Date()
        deviceSettings.save(settings, for: deviceID)
        scheduleSave(for: deviceID, settings: settings)
    }

    /// Load DDC brightness value (0.0 to 1.0) for a display device
    func loadDDCBrightness(for device: DisplayDevice) -> Double? {
        let deviceID = deviceIdentifier(for: device)
        guard let settings = deviceSettings.load(for: deviceID),
              let brightness = settings.lastDDCBrightness else {
            return nil
        }
        return Double(brightness) / 100.0 // Convert from 0-100 integer to 0.0-1.0
    }

    /// Load DDC contrast value (0.0 to 1.0) for a display device
    func loadDDCContrast(for device: DisplayDevice) -> Double? {
        let deviceID = deviceIdentifier(for: device)
        guard let settings = deviceSettings.load(for: deviceID),
              let contrast = settings.lastDDCContrast else {
            return nil
        }
        return Double(contrast) / 100.0 // Convert from 0-100 integer to 0.0-1.0
    }

    // MARK: - Connection Mode Persistence

    /// Save preferred connection color mode for a display device
    func saveConnectionMode(_ mode: ConnectionColorMode, for device: DisplayDevice) {
        let deviceID = deviceIdentifier(for: device)
        var settings = deviceSettings.load(for: deviceID) ?? DeviceSettings()
        settings.preferredPixelEncoding = mode.pixelEncoding.rawValue
        settings.preferredBitsPerComponent = mode.bitsPerComponent.rawValue
        settings.preferredColorRange = mode.colorRange.rawValue
        settings.preferredDynamicRange = mode.dynamicRange.rawValue
        settings.lastModified = Date()
        deviceSettings.save(settings, for: deviceID)
        scheduleSave(for: deviceID, settings: settings)
    }

    /// Load preferred connection color mode for a display device
    func loadConnectionMode(for device: DisplayDevice) -> ConnectionColorMode? {
        let deviceID = deviceIdentifier(for: device)
        guard let settings = deviceSettings.load(for: deviceID),
              let encodingRaw = settings.preferredPixelEncoding,
              let bpcRaw = settings.preferredBitsPerComponent,
              let rangeRaw = settings.preferredColorRange,
              let dynamicRaw = settings.preferredDynamicRange,
              let encoding = PixelEncoding(rawValue: encodingRaw),
              let bpc = BitsPerComponent(rawValue: bpcRaw),
              let range = ColorRange(rawValue: rangeRaw),
              let dynamic = DynamicRange(rawValue: dynamicRaw) else {
            return nil
        }
        return ConnectionColorMode(
            pixelEncoding: encoding,
            bitsPerComponent: bpc,
            colorRange: range,
            dynamicRange: dynamic
        )
    }

    // MARK: - Private Helpers

    /// Generate stable device identifier from EDID serial or manufacturer+model hash
    private func deviceIdentifier(for device: DisplayDevice) -> String {
        if let serial = device.serialNumber, !serial.isEmpty {
            return "serial_\(serial)"
        }

        // Fallback: hash of manufacturer + model
        let combined = "\(device.manufacturer)_\(device.model)"
        return "hash_\(combined.hashValue)"
    }

    /// Debounced save to avoid excessive disk writes
    private func scheduleSave(for deviceID: String, settings: DeviceSettings) {
        saveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.deviceSettings.persist(settings, for: deviceID)
        }

        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}

// MARK: - DeviceSettings

/// Settings stored per display device
struct DeviceSettings: Codable, Sendable {
    var lastProfileID: UUID?
    var lastDDCBrightness: Int?
    var lastDDCContrast: Int?
    var lastModified: Date
    var preferredPixelEncoding: Int?      // ConnectionColorMode.PixelEncoding raw value
    var preferredBitsPerComponent: Int?   // BitsPerComponent raw value
    var preferredColorRange: Int?         // ColorRange raw value
    var preferredDynamicRange: Int?       // DynamicRange raw value

    init(
        lastProfileID: UUID? = nil,
        lastDDCBrightness: Int? = nil,
        lastDDCContrast: Int? = nil,
        lastModified: Date = Date(),
        preferredPixelEncoding: Int? = nil,
        preferredBitsPerComponent: Int? = nil,
        preferredColorRange: Int? = nil,
        preferredDynamicRange: Int? = nil
    ) {
        self.lastProfileID = lastProfileID
        self.lastDDCBrightness = lastDDCBrightness
        self.lastDDCContrast = lastDDCContrast
        self.lastModified = lastModified
        self.preferredPixelEncoding = preferredPixelEncoding
        self.preferredBitsPerComponent = preferredBitsPerComponent
        self.preferredColorRange = preferredColorRange
        self.preferredDynamicRange = preferredDynamicRange
    }
}

// MARK: - DeviceSettingsStore

/// Thread-safe storage for device settings
private final class DeviceSettingsStore: Sendable {
    private let directory: URL
    private let cache: NSCache<NSString, CacheEntry>
    private let queue = DispatchQueue(label: "com.chromaflow.devicesettings", attributes: .concurrent)

    init(directory: URL) {
        self.directory = directory
        self.cache = NSCache()
        self.cache.countLimit = 50 // Limit cache size
    }

    func save(_ settings: DeviceSettings, for deviceID: String) {
        let entry = CacheEntry(settings: settings)
        cache.setObject(entry, forKey: deviceID as NSString)
    }

    func load(for deviceID: String) -> DeviceSettings? {
        // Check cache first
        if let cached = cache.object(forKey: deviceID as NSString) {
            return cached.settings
        }

        // Load from disk
        let fileURL = directory.appendingPathComponent("\(deviceID).json")

        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else {
                return nil
            }

            do {
                let settings = try JSONDecoder().decode(DeviceSettings.self, from: data)
                // Cache the loaded settings
                let entry = CacheEntry(settings: settings)
                cache.setObject(entry, forKey: deviceID as NSString)
                return settings
            } catch {
                // Corrupt JSON - return nil for graceful fallback
                print("⚠️ DeviceMemory: Failed to decode settings for \(deviceID): \(error)")
                return nil
            }
        }
    }

    func persist(_ settings: DeviceSettings, for deviceID: String) {
        let fileURL = directory.appendingPathComponent("\(deviceID).json")

        queue.async(flags: .barrier) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(settings)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("⚠️ DeviceMemory: Failed to persist settings for \(deviceID): \(error)")
            }
        }
    }

    func remove(for deviceID: String) {
        cache.removeObject(forKey: deviceID as NSString)

        let fileURL = directory.appendingPathComponent("\(deviceID).json")
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func listAll() -> [String] {
        queue.sync {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            return contents
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
    }
}

// MARK: - CacheEntry

private final class CacheEntry: NSObject, Sendable {
    let settings: DeviceSettings

    init(settings: DeviceSettings) {
        self.settings = settings
        super.init()
    }
}
