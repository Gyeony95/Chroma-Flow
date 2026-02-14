// I2CTransport.swift
// DDCKit - I2C Transport Layer for DDC/CI Communication
//
// Forked and adapted from MonitorControl's Arm64DDC.swift (MIT License)
// https://github.com/MonitorControl/MonitorControl
//
// Provides ARM64 (Apple Silicon) I2C transport using undocumented
// IOAVService APIs loaded dynamically via dlopen/dlsym.

import Foundation
import IOKit

// MARK: - Errors

/// Errors that can occur during I2C transport operations.
public enum I2CTransportError: Error, Sendable, CustomStringConvertible {
    /// The IOAVService symbols could not be loaded (unsupported system).
    case unsupported
    /// The I2C write operation failed with the given IOReturn code.
    case writeFailed(Int32)
    /// The I2C read operation failed with the given IOReturn code.
    case readFailed(Int32)
    /// The io_service_t handle is invalid or zero.
    case invalidService
    /// The IOAVService could not be created for the given service.
    case serviceCreationFailed
    /// The requested data length is invalid.
    case invalidLength

    public var description: String {
        switch self {
        case .unsupported:
            return "I2C transport is not supported on this system (IOAVService symbols not found)"
        case .writeFailed(let code):
            return "I2C write failed with IOReturn code: \(code)"
        case .readFailed(let code):
            return "I2C read failed with IOReturn code: \(code)"
        case .invalidService:
            return "Invalid io_service_t handle"
        case .serviceCreationFailed:
            return "Failed to create IOAVService from io_service_t"
        case .invalidLength:
            return "Invalid data length for I2C operation"
        }
    }
}

// MARK: - I2CTransport Protocol

/// Protocol defining low-level I2C read/write operations for DDC communication.
public protocol I2CTransport: Sendable {
    /// Write data to an I2C device at the specified address.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - address: The 7-bit I2C slave address (typically `0x37` for DDC).
    ///   - data: The raw bytes to write.
    /// - Throws: `I2CTransportError` on failure.
    func write(service: io_service_t, address: UInt8, data: [UInt8]) throws

    /// Read data from an I2C device at the specified address.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - address: The 7-bit I2C slave address (typically `0x37` for DDC).
    ///   - length: The number of bytes to read.
    /// - Returns: The raw bytes read from the device.
    /// - Throws: `I2CTransportError` on failure.
    func read(service: io_service_t, address: UInt8, length: Int) throws -> [UInt8]
}

// MARK: - IOAVService Dynamic Loading

/// Opaque type representing an IOAVService reference.
/// This is an undocumented Apple type used for DisplayPort I2C access.
private typealias IOAVServiceRef = UnsafeMutableRawPointer

/// Function signature for `IOAVServiceCreateWithService`.
/// Creates an IOAVService from an existing io_service_t.
///
/// Parameters: allocator (CFAllocator), service (io_service_t)
/// Returns: IOAVServiceRef or nil
private typealias IOAVServiceCreateWithServiceFunc = @convention(c) (
    CFAllocator?, io_service_t
) -> IOAVServiceRef?

/// Function signature for `IOAVServiceWriteI2C`.
///
/// Parameters: service, chipAddress, dataAddress, inputBuffer, inputBufferSize
/// Returns: IOReturn (kern_return_t)
private typealias IOAVServiceWriteI2CFunc = @convention(c) (
    IOAVServiceRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32
) -> Int32

/// Function signature for `IOAVServiceReadI2CFunc`.
///
/// Parameters: service, chipAddress, dataAddress, outputBuffer, outputBufferSize
/// Returns: IOReturn (kern_return_t)
private typealias IOAVServiceReadI2CFunc = @convention(c) (
    IOAVServiceRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32
) -> Int32

/// Container for dynamically loaded IOAVService symbols.
/// Loads once and caches the function pointers for the lifetime of the process.
private final class IOAVSymbols: @unchecked Sendable {
    static let shared = IOAVSymbols()

    let createWithService: IOAVServiceCreateWithServiceFunc?
    let writeI2C: IOAVServiceWriteI2CFunc?
    let readI2C: IOAVServiceReadI2CFunc?

    /// Whether all required symbols were successfully loaded.
    var isAvailable: Bool {
        createWithService != nil && writeI2C != nil && readI2C != nil
    }

    private init() {
        // IOKit framework path on macOS
        let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"

        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            self.createWithService = nil
            self.writeI2C = nil
            self.readI2C = nil
            return
        }

        // Load IOAVServiceCreateWithService
        if let sym = dlsym(handle, "IOAVServiceCreateWithService") {
            self.createWithService = unsafeBitCast(sym, to: IOAVServiceCreateWithServiceFunc.self)
        } else {
            self.createWithService = nil
        }

        // Load IOAVServiceWriteI2C
        if let sym = dlsym(handle, "IOAVServiceWriteI2C") {
            self.writeI2C = unsafeBitCast(sym, to: IOAVServiceWriteI2CFunc.self)
        } else {
            self.writeI2C = nil
        }

        // Load IOAVServiceReadI2C
        if let sym = dlsym(handle, "IOAVServiceReadI2C") {
            self.readI2C = unsafeBitCast(sym, to: IOAVServiceReadI2CFunc.self)
        } else {
            self.readI2C = nil
        }

        // Note: we intentionally do NOT dlclose(handle) because the symbols
        // must remain valid for the process lifetime.
    }
}

// MARK: - ARM64 I2C Transport

/// ARM64 (Apple Silicon) I2C transport implementation using IOAVService APIs.
///
/// This implementation supports M1, M2, M3, and M4 Apple Silicon chips.
/// It dynamically loads the undocumented `IOAVServiceWriteI2C` and
/// `IOAVServiceReadI2C` symbols from the IOKit framework at runtime.
///
/// If the symbols are not available (e.g., on Intel Macs or unsupported
/// macOS versions), all operations throw `I2CTransportError.unsupported`.
public final class ARM64I2CTransport: I2CTransport, @unchecked Sendable {

    /// DDC data address used as the register/offset for I2C operations.
    public static let ddcDataAddress: UInt8 = 0x51

    /// Cache of IOAVServiceRef instances keyed by io_service_t.
    /// Access is serialized via `lock`.
    private var serviceCache: [io_service_t: IOAVServiceRef] = [:]
    private let lock = NSLock()

    public init() {}

    /// Check whether this transport is available on the current system.
    public var isAvailable: Bool {
        IOAVSymbols.shared.isAvailable
    }

    public func write(service: io_service_t, address: UInt8, data: [UInt8]) throws {
        guard IOAVSymbols.shared.isAvailable else {
            throw I2CTransportError.unsupported
        }
        guard service != 0 else {
            throw I2CTransportError.invalidService
        }
        guard !data.isEmpty else {
            throw I2CTransportError.invalidLength
        }

        let avService = try getOrCreateAVService(for: service)

        var buffer = data
        let result = IOAVSymbols.shared.writeI2C!(
            avService,
            UInt32(address),
            UInt32(Self.ddcDataAddress),
            &buffer,
            UInt32(buffer.count)
        )

        guard result == 0 else { // KERN_SUCCESS == 0
            throw I2CTransportError.writeFailed(result)
        }
    }

    public func read(service: io_service_t, address: UInt8, length: Int) throws -> [UInt8] {
        guard IOAVSymbols.shared.isAvailable else {
            throw I2CTransportError.unsupported
        }
        guard service != 0 else {
            throw I2CTransportError.invalidService
        }
        guard length > 0 else {
            throw I2CTransportError.invalidLength
        }

        let avService = try getOrCreateAVService(for: service)

        var buffer = [UInt8](repeating: 0, count: length)
        let result = IOAVSymbols.shared.readI2C!(
            avService,
            UInt32(address),
            UInt32(Self.ddcDataAddress),
            &buffer,
            UInt32(buffer.count)
        )

        guard result == 0 else { // KERN_SUCCESS == 0
            throw I2CTransportError.readFailed(result)
        }

        return buffer
    }

    /// Invalidate cached IOAVService for a given service handle.
    /// Call this when a display is disconnected.
    public func invalidateService(_ service: io_service_t) {
        lock.lock()
        defer { lock.unlock() }
        serviceCache.removeValue(forKey: service)
    }

    /// Clear all cached IOAVService instances.
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        serviceCache.removeAll()
    }

    // MARK: - Private

    private func getOrCreateAVService(for service: io_service_t) throws -> IOAVServiceRef {
        lock.lock()
        defer { lock.unlock() }

        if let cached = serviceCache[service] {
            return cached
        }

        guard let createFn = IOAVSymbols.shared.createWithService else {
            throw I2CTransportError.unsupported
        }

        guard let avService = createFn(nil, service) else {
            throw I2CTransportError.serviceCreationFailed
        }

        serviceCache[service] = avService
        return avService
    }
}
