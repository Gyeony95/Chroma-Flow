import Foundation
import CoreGraphics
import DDCKit

/// Serialized DDC/CI hardware communication actor
///
/// Enforces strict timing requirements for DDC/CI protocol:
/// - Minimum 50ms delay between commands
/// - Serial execution per display
/// - Automatic failure handling and recovery
actor DDCActor {
    // MARK: - Types

    enum DDCError: Error, LocalizedError {
        case displayNotFound(CGDirectDisplayID)
        case ddcNotSupported(CGDirectDisplayID)
        case ddcDisabled(CGDirectDisplayID)
        case i2cCommunicationFailed(underlying: Error)
        case invalidValue(expected: String)
        case consecutiveFailures(count: Int)

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "Display \(id) not found"
            case .ddcNotSupported(let id):
                return "DDC/CI not supported on display \(id)"
            case .ddcDisabled(let id):
                return "DDC/CI disabled on display \(id) due to repeated failures"
            case .i2cCommunicationFailed(let error):
                return "I2C communication failed: \(error.localizedDescription)"
            case .invalidValue(let expected):
                return "Invalid value: \(expected)"
            case .consecutiveFailures(let count):
                return "DDC disabled after \(count) consecutive failures"
            }
        }
    }

    private struct CommandQueue {
        var pending: [(priority: Int, block: () async throws -> Void)] = []

        mutating func enqueue(priority: Int = 0, _ block: @escaping () async throws -> Void) {
            pending.append((priority, block))
            pending.sort { $0.priority > $1.priority }
        }

        mutating func dequeue() -> (() async throws -> Void)? {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst().block
        }
    }

    private struct DisplayState {
        var lastCommandTime: Date?
        var consecutiveFailures: Int = 0
        var isDDCDisabled: Bool = false
        var cachedCapabilities: DDCCapabilities?
        var adapter: Arm64DDCAdapter?
        var saveWorkItem: Task<Void, Never>?
    }

    // MARK: - Properties

    /// Minimum delay between DDC/CI commands (hardware requirement)
    private let minimumCommandDelay: TimeInterval = 0.05 // 50ms

    /// Maximum consecutive failures before disabling DDC
    private let maxConsecutiveFailures = 3

    /// Debounce interval for DDC persistence (500ms)
    private let persistenceDebounceInterval: TimeInterval = 0.5

    /// Per-display state tracking
    private var displayStates: [CGDirectDisplayID: DisplayState] = [:]

    /// Command queue for coordinating requests
    private var commandQueue = CommandQueue()

    // MARK: - Public API

    /// Sets display brightness (0.0 to 1.0)
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID, device: DisplayDevice? = nil) async throws {
        guard value >= 0.0 && value <= 1.0 else {
            throw DDCError.invalidValue(expected: "0.0-1.0")
        }

        try await executeCommand(for: displayID) { adapter in
            try await adapter.setBrightness(value)
        }

        // Persist to DeviceMemory after successful write (debounced)
        if let device = device {
            schedulePersistence(for: displayID) {
                await DeviceMemory.shared.saveDDCBrightness(value, for: device)
            }
        }
    }

    /// Sets display contrast (0.0 to 1.0)
    func setContrast(_ value: Double, for displayID: CGDirectDisplayID, device: DisplayDevice? = nil) async throws {
        guard value >= 0.0 && value <= 1.0 else {
            throw DDCError.invalidValue(expected: "0.0-1.0")
        }

        try await executeCommand(for: displayID) { adapter in
            try await adapter.setContrast(value)
        }

        // Persist to DeviceMemory after successful write (debounced)
        if let device = device {
            schedulePersistence(for: displayID) {
                await DeviceMemory.shared.saveDDCContrast(value, for: device)
            }
        }
    }

    /// Reads current brightness value (0.0 to 1.0)
    func readBrightness(for displayID: CGDirectDisplayID) async throws -> Double {
        try await executeCommand(for: displayID) { adapter in
            let (current, max) = try await adapter.readVCP(.brightness)
            return Double(current) / Double(max)
        }
    }

    /// Reads current contrast value (0.0 to 1.0)
    func readContrast(for displayID: CGDirectDisplayID) async throws -> Double {
        try await executeCommand(for: displayID) { adapter in
            let (current, max) = try await adapter.readVCP(.contrast)
            return Double(current) / Double(max)
        }
    }

    /// Detects DDC/CI capabilities for a display
    func detectCapabilities(for displayID: CGDirectDisplayID) async -> DDCCapabilities {
        // Check cache first
        if let cached = displayStates[displayID]?.cachedCapabilities {
            return cached
        }

        do {
            let adapter = try await getOrCreateAdapter(for: displayID)
            let capabilities = await adapter.capabilities

            // Cache for future use
            if displayStates[displayID] != nil {
                displayStates[displayID]?.cachedCapabilities = capabilities
            }

            return capabilities
        } catch {
            // Return empty capabilities on failure
            return DDCCapabilities(
                supportsBrightness: false,
                supportsContrast: false,
                supportsColorTemperature: false,
                supportsInputSource: false,
                supportedColorPresets: [],
                maxBrightness: 100,
                maxContrast: 100,
                rawCapabilityString: nil
            )
        }
    }

    /// Resets failure count for a display (for testing/recovery)
    func resetFailures(for displayID: CGDirectDisplayID) {
        displayStates[displayID]?.consecutiveFailures = 0
        displayStates[displayID]?.isDDCDisabled = false
    }

    /// Restore last-known DDC settings from DeviceMemory on display connect
    func restoreSettings(for device: DisplayDevice, from deviceMemory: DeviceMemory) async {
        let displayID = device.id

        // Restore brightness if available
        if let brightness = await deviceMemory.loadDDCBrightness(for: device) {
            do {
                try await setBrightness(brightness, for: displayID)
                print("✓ Restored brightness \(Int(brightness * 100))% for display \(displayID)")
            } catch {
                print("⚠️ Failed to restore brightness for display \(displayID): \(error)")
            }
        }

        // Restore contrast if available
        if let contrast = await deviceMemory.loadDDCContrast(for: device) {
            do {
                try await setContrast(contrast, for: displayID)
                print("✓ Restored contrast \(Int(contrast * 100))% for display \(displayID)")
            } catch {
                print("⚠️ Failed to restore contrast for display \(displayID): \(error)")
            }
        }
    }

    // MARK: - Private Implementation

    private func executeCommand<T>(
        for displayID: CGDirectDisplayID,
        operation: (Arm64DDCAdapter) async throws -> T
    ) async throws -> T {
        // Check if DDC is disabled
        if displayStates[displayID]?.isDDCDisabled == true {
            throw DDCError.ddcDisabled(displayID)
        }

        // Enforce minimum delay
        try await enforceMinimumDelay(for: displayID)

        // Get or create adapter
        let adapter = try await getOrCreateAdapter(for: displayID)

        do {
            // Execute operation
            let result = try await operation(adapter)

            // Update timestamp
            updateLastCommandTime(for: displayID)

            // Reset failure count on success
            displayStates[displayID]?.consecutiveFailures = 0

            return result
        } catch {
            // Track failure
            await handleFailure(for: displayID, error: error)
            throw error
        }
    }

    private func enforceMinimumDelay(for displayID: CGDirectDisplayID) async throws {
        guard let lastTime = displayStates[displayID]?.lastCommandTime else {
            return // First command, no delay needed
        }

        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed < minimumCommandDelay {
            let delay = minimumCommandDelay - elapsed
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func updateLastCommandTime(for displayID: CGDirectDisplayID) {
        if displayStates[displayID] != nil {
            displayStates[displayID]?.lastCommandTime = Date()
        } else {
            displayStates[displayID] = DisplayState(lastCommandTime: Date())
        }
    }

    private func getOrCreateAdapter(for displayID: CGDirectDisplayID) async throws -> Arm64DDCAdapter {
        // Return existing adapter if available
        if let existing = displayStates[displayID]?.adapter {
            return existing
        }

        // Create new adapter
        let adapter = try Arm64DDCAdapter(displayID: displayID)

        // Store in state
        if displayStates[displayID] != nil {
            displayStates[displayID]?.adapter = adapter
        } else {
            displayStates[displayID] = DisplayState(adapter: adapter)
        }

        return adapter
    }

    private func handleFailure(for displayID: CGDirectDisplayID, error: Error) async {
        guard var state = displayStates[displayID] else { return }

        state.consecutiveFailures += 1

        if state.consecutiveFailures >= maxConsecutiveFailures {
            state.isDDCDisabled = true
            print("⚠️ DDC/CI disabled for display \(displayID) after \(state.consecutiveFailures) consecutive failures")
        }

        displayStates[displayID] = state
    }

    /// Schedule debounced persistence to reduce disk writes
    private func schedulePersistence(for displayID: CGDirectDisplayID, operation: @escaping () async -> Void) {
        // Cancel any pending save for this display
        displayStates[displayID]?.saveWorkItem?.cancel()

        // Schedule new save after debounce interval
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(persistenceDebounceInterval * 1_000_000_000))

            guard !Task.isCancelled else { return }
            await operation()
        }

        // Store task for potential cancellation
        if displayStates[displayID] != nil {
            displayStates[displayID]?.saveWorkItem = task
        }
    }
}
