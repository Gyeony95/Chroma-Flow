import Foundation

/// Storage and management for custom user color profiles
@MainActor
final class ProfileStore: Sendable {
    static let shared = ProfileStore()

    private let storageDirectory: URL
    private let profileCache: ProfileCache

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        storageDirectory = appSupport
            .appendingPathComponent("ChromaFlow")
            .appendingPathComponent("profiles")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        profileCache = ProfileCache(directory: storageDirectory)
        loadBuiltInProfiles()
    }

    // MARK: - Public API

    /// List all profiles (built-in + custom)
    func listProfiles() -> [ColorProfile] {
        profileCache.listAll()
    }

    /// List only custom profiles
    func listCustomProfiles() -> [ColorProfile] {
        profileCache.listAll().filter { $0.isCustom }
    }

    /// Get a profile by ID
    func getProfile(id: UUID) -> ColorProfile? {
        profileCache.get(id: id)
    }

    /// Add a custom profile
    func addProfile(_ profile: ColorProfile) throws {
        guard profile.isCustom else {
            throw ProfileStoreError.cannotModifyBuiltIn
        }

        profileCache.add(profile)
        try persist(profile)
    }

    /// Update an existing custom profile
    func updateProfile(_ profile: ColorProfile) throws {
        guard profile.isCustom else {
            throw ProfileStoreError.cannotModifyBuiltIn
        }

        guard profileCache.get(id: profile.id) != nil else {
            throw ProfileStoreError.profileNotFound
        }

        profileCache.update(profile)
        try persist(profile)
    }

    /// Remove a custom profile
    func removeProfile(id: UUID) throws {
        guard let profile = profileCache.get(id: id) else {
            throw ProfileStoreError.profileNotFound
        }

        guard profile.isCustom else {
            throw ProfileStoreError.cannotModifyBuiltIn
        }

        profileCache.remove(id: id)
        try deleteFile(for: id)
    }

    // MARK: - Private Helpers

    private func loadBuiltInProfiles() {
        let builtInProfiles = [
            ColorProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "sRGB",
                colorSpace: .sRGB,
                iccProfileURL: nil,
                isCustom: false,
                whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 1.0),
                gamut: nil
            ),
            ColorProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Display P3",
                colorSpace: .displayP3,
                iccProfileURL: nil,
                isCustom: false,
                whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 1.0),
                gamut: nil
            ),
            ColorProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Adobe RGB",
                colorSpace: .adobeRGB,
                iccProfileURL: nil,
                isCustom: false,
                whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 1.0),
                gamut: nil
            ),
            ColorProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                name: "Rec. 709",
                colorSpace: .rec709,
                iccProfileURL: nil,
                isCustom: false,
                whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 1.0),
                gamut: nil
            ),
            ColorProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                name: "Rec. 2020",
                colorSpace: .rec2020,
                iccProfileURL: nil,
                isCustom: false,
                whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 1.0),
                gamut: nil
            )
        ]

        for profile in builtInProfiles {
            profileCache.add(profile)
        }

        // Load custom profiles from disk
        loadCustomProfiles()
    }

    private func loadCustomProfiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for fileURL in files where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let profile = try JSONDecoder().decode(ColorProfile.self, from: data)
                profileCache.add(profile)
            } catch {
                // Corrupt JSON - skip and continue
                print("⚠️ ProfileStore: Failed to load profile from \(fileURL.lastPathComponent): \(error)")
            }
        }
    }

    private func persist(_ profile: ColorProfile) throws {
        let fileURL = storageDirectory.appendingPathComponent("\(profile.id.uuidString).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(profile)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ProfileStoreError.persistenceFailed(error)
        }
    }

    private func deleteFile(for id: UUID) throws {
        let fileURL = storageDirectory.appendingPathComponent("\(id.uuidString).json")

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw ProfileStoreError.deleteFailed(error)
        }
    }
}

// MARK: - ProfileCache

/// Thread-safe in-memory cache for profiles
private final class ProfileCache: Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.chromaflow.profilecache", attributes: .concurrent)
    private var profiles: [UUID: ColorProfile] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func add(_ profile: ColorProfile) {
        queue.async(flags: .barrier) {
            self.profiles[profile.id] = profile
        }
    }

    func update(_ profile: ColorProfile) {
        queue.async(flags: .barrier) {
            self.profiles[profile.id] = profile
        }
    }

    func remove(id: UUID) {
        queue.async(flags: .barrier) {
            self.profiles.removeValue(forKey: id)
        }
    }

    func get(id: UUID) -> ColorProfile? {
        queue.sync {
            profiles[id]
        }
    }

    func listAll() -> [ColorProfile] {
        queue.sync {
            Array(profiles.values).sorted { $0.name < $1.name }
        }
    }
}

// MARK: - ProfileStoreError

enum ProfileStoreError: LocalizedError {
    case profileNotFound
    case cannotModifyBuiltIn
    case persistenceFailed(Error)
    case deleteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "Profile not found"
        case .cannotModifyBuiltIn:
            return "Cannot modify built-in profiles"
        case .persistenceFailed(let error):
            return "Failed to save profile: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete profile: \(error.localizedDescription)"
        }
    }
}
