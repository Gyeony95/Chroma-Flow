import Foundation
import CoreGraphics
import IOKit

final class DisplayDetector: DisplayDetecting, @unchecked Sendable {

    // MARK: - Properties

    private let eventContinuation: AsyncStream<DisplayEvent>.Continuation
    let events: AsyncStream<DisplayEvent>

    private var isMonitoring = false
    private let queue = DispatchQueue(label: "com.chromaflow.display-detector", qos: .userInitiated)
    private var registeredCallback: CGDisplayReconfigurationCallBack?

    // MARK: - Initialization

    init() {
        var continuation: AsyncStream<DisplayEvent>.Continuation!
        self.events = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation

        startMonitoring()
    }

    deinit {
        stopMonitoring()
        eventContinuation.finish()
    }

    // MARK: - DisplayDetecting

    func connectedDisplays() async -> [DisplayDevice] {
        return await withCheckedContinuation { continuation in
            queue.async {
                let displays = self.detectDisplays()
                continuation.resume(returning: displays)
            }
        }
    }

    // MARK: - Private Methods

    private func startMonitoring() {
        guard !isMonitoring else { return }

        print("[DisplayDetector] Starting display monitoring")

        // Register for display reconfiguration callbacks
        let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let detector = Unmanaged<DisplayDetector>.fromOpaque(userInfo).takeUnretainedValue()
            detector.handleDisplayReconfiguration(displayID: displayID, flags: flags)
        }

        // Store callback for later removal
        registeredCallback = callback

        // Use Unmanaged to pass self as userInfo
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        CGDisplayRegisterReconfigurationCallback(callback, selfPointer)
        isMonitoring = true
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }

        print("[DisplayDetector] Stopping display monitoring")

        // Properly unregister the callback to prevent crashes
        if let callback = registeredCallback {
            let selfPointer = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(callback, selfPointer)
            registeredCallback = nil
        }

        isMonitoring = false
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if flags.contains(.addFlag) {
                // Display connected
                if let device = self.createDisplayDevice(for: displayID) {
                    self.eventContinuation.yield(.connected(device))
                }
            } else if flags.contains(.removeFlag) {
                // Display disconnected
                self.eventContinuation.yield(.disconnected(displayID))
            } else if flags.contains(.setModeFlag) {
                // Display configuration changed
                self.eventContinuation.yield(.profileChanged(displayID))
            }
        }
    }

    private func detectDisplays() -> [DisplayDevice] {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        // Get online displays (includes sleeping/inactive displays)
        // CGGetActiveDisplayList only returns fully active displays, missing external monitors in some states
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &displayCount) == .success else {
            print("[DisplayDetector] Failed to get online display list")
            return []
        }

        print("[DisplayDetector] CGGetOnlineDisplayList returned \(displayCount) displays")

        // Build DisplayDevice for each display
        let devices = displays.prefix(Int(displayCount)).compactMap { displayID in
            createDisplayDevice(for: displayID)
        }

        print("[DisplayDetector] Successfully created \(devices.count) DisplayDevice objects")
        return devices
    }

    private func createDisplayDevice(for displayID: CGDirectDisplayID) -> DisplayDevice? {
        // Parse EDID for display information
        let edidInfo = EDIDParser.parseEDID(for: displayID)

        let name = edidInfo?.model ?? "Unknown Display"
        let manufacturer = edidInfo?.manufacturer ?? "Unknown"
        let model = edidInfo?.model ?? "Unknown Model"
        let serialNumber = edidInfo?.serialNumber

        // Check if built-in display
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

        // Detect connection type
        let connectionType = detectConnectionType(for: displayID, isBuiltIn: isBuiltIn)

        // Get max brightness (only for built-in displays typically)
        let maxBrightness = isBuiltIn ? 1.0 : nil

        // DDC capabilities will be probed by DDCController later
        let ddcCapabilities: DDCCapabilities? = nil

        return DisplayDevice(
            id: displayID,
            name: name,
            manufacturer: manufacturer,
            model: model,
            serialNumber: serialNumber,
            connectionType: connectionType,
            isBuiltIn: isBuiltIn,
            maxBrightness: maxBrightness,
            ddcCapabilities: ddcCapabilities
        )
    }

    private func detectConnectionType(for displayID: CGDirectDisplayID, isBuiltIn: Bool) -> DisplayDevice.ConnectionType {
        if isBuiltIn {
            return .builtIn
        }

        // Try to determine connection type via IOKit service traversal
        var servicePort: io_service_t = 0
        var iter: io_iterator_t = 0

        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return .unknown
        }

        defer { IOObjectRelease(iter) }

        while true {
            servicePort = IOIteratorNext(iter)
            if servicePort == 0 { break }

            defer { IOObjectRelease(servicePort) }

            // Try to get connection type from IOKit properties
            if let transportType = getIOKitProperty(servicePort, key: "IODisplayConnectorType") as? String {
                IOObjectRelease(servicePort)

                // Map transport type to ConnectionType
                switch transportType.lowercased() {
                case let t where t.contains("hdmi"):
                    return .hdmi
                case let t where t.contains("displayport"), let t where t.contains("dp"):
                    return .displayPort
                case let t where t.contains("usb-c"), let t where t.contains("usbc"):
                    return .usbC
                case let t where t.contains("thunderbolt"):
                    return .thunderbolt
                default:
                    return .unknown
                }
            }
        }

        // Fallback: Check for Thunderbolt/USB-C based on common patterns
        if let locationInTree = getIOKitProperty(servicePort, key: "IODisplayLocation") as? String {
            if locationInTree.contains("Thunderbolt") {
                return .thunderbolt
            } else if locationInTree.contains("USB") {
                return .usbC
            }
        }

        return .unknown
    }

    private func getIOKitProperty(_ service: io_service_t, key: String) -> Any? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        return property.takeRetainedValue()
    }
}
