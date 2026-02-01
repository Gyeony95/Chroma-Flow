// DDCInterface.swift
// DDCKit - DDC/CI Protocol Interface
//
// Implements DDC/CI (Display Data Channel Command Interface) protocol framing
// on top of the I2C transport layer. Handles packet construction, checksum
// calculation, VCP reply parsing, and retry logic with exponential backoff.
//
// DDC/CI specification reference: VESA MCCS Standard Version 2.2a
// Adapted from MonitorControl's Arm64DDC.swift (MIT License)

import Foundation
import IOKit

// MARK: - DDC Constants

/// Standard DDC/CI protocol constants.
public enum DDCConstants {
    /// 7-bit I2C slave address for DDC devices (monitors).
    public static let slaveAddress: UInt8 = 0x37

    /// DDC data address byte (source address in DDC packets).
    public static let dataAddress: UInt8 = 0x51

    /// Host address: slave address shifted left by 1 (write mode).
    /// Used as the checksum seed for outgoing packets.
    public static let hostAddress: UInt8 = 0x6E // 0x37 << 1

    /// Reply address seed for validating incoming checksums.
    /// XOR of dataAddress and hostAddress: 0x51 ^ 0x6E = 0x3F
    /// MonitorControl uses 0x50 as the seed for reply checksum calculation.
    public static let replyChecksumSeed: UInt8 = 0x50

    /// DDC/CI VCP Get command opcode.
    public static let vcpGetOpcode: UInt8 = 0x01

    /// DDC/CI VCP Set command opcode.
    public static let vcpSetOpcode: UInt8 = 0x03

    /// DDC/CI VCP Reply opcode (in response to Get).
    public static let vcpReplyOpcode: UInt8 = 0x02

    /// Expected length of a VCP Get reply (11 bytes including length header).
    public static let vcpReplyLength: Int = 11

    /// Default command timeout in seconds.
    public static let defaultTimeout: TimeInterval = 0.2 // 200ms

    /// Default number of retry attempts.
    public static let defaultRetryCount: Int = 3

    /// Default write sleep time in microseconds (between write cycles).
    public static let defaultWriteSleep: UInt32 = 10_000 // 10ms

    /// Default read sleep time in microseconds (after write, before read).
    public static let defaultReadSleep: UInt32 = 50_000 // 50ms

    /// Default retry sleep time in microseconds.
    public static let defaultRetrySleep: UInt32 = 20_000 // 20ms

    /// Default number of write cycles per attempt.
    public static let defaultWriteCycles: Int = 2
}

// MARK: - DDC Errors

/// Errors specific to DDC/CI protocol operations.
public enum DDCError: Error, Sendable, CustomStringConvertible {
    /// All retry attempts were exhausted without success.
    case retriesExhausted(attempts: Int, lastError: String)
    /// The VCP reply checksum does not match.
    case checksumMismatch(expected: UInt8, actual: UInt8)
    /// The VCP reply has an unexpected format or length.
    case invalidReply(reason: String)
    /// The VCP command was not supported by the display.
    case vcpNotSupported(code: UInt8)
    /// The operation timed out.
    case timeout
    /// The I2C transport is not available.
    case transportUnavailable

    public var description: String {
        switch self {
        case .retriesExhausted(let attempts, let lastError):
            return "DDC operation failed after \(attempts) attempts. Last error: \(lastError)"
        case .checksumMismatch(let expected, let actual):
            return "DDC checksum mismatch: expected 0x\(String(expected, radix: 16)), got 0x\(String(actual, radix: 16))"
        case .invalidReply(let reason):
            return "Invalid DDC reply: \(reason)"
        case .vcpNotSupported(let code):
            return "VCP code 0x\(String(code, radix: 16)) not supported by display"
        case .timeout:
            return "DDC operation timed out"
        case .transportUnavailable:
            return "I2C transport is not available on this system"
        }
    }
}

// MARK: - VCP Reply

/// Parsed VCP (Virtual Control Panel) reply from a DDC/CI Get command.
public struct VCPReply: Sendable, Equatable {
    /// The VCP feature code this reply is for.
    public let vcpCode: UInt8
    /// Result code from the display (0 = no error).
    public let resultCode: UInt8
    /// VCP type code (0 = set parameter, 1 = momentary).
    public let typeCode: UInt8
    /// Maximum value for this VCP feature.
    public let maxValue: UInt16
    /// Current value for this VCP feature.
    public let currentValue: UInt16

    public init(vcpCode: UInt8, resultCode: UInt8, typeCode: UInt8, maxValue: UInt16, currentValue: UInt16) {
        self.vcpCode = vcpCode
        self.resultCode = resultCode
        self.typeCode = typeCode
        self.maxValue = maxValue
        self.currentValue = currentValue
    }
}

// MARK: - DDCInterface

/// High-level DDC/CI interface that handles protocol framing, checksum
/// calculation, and retry logic on top of an I2C transport.
///
/// Usage:
/// ```swift
/// let transport = ARM64I2CTransport()
/// let ddc = DDCInterface(transport: transport)
///
/// // Read brightness
/// let reply = try ddc.readVCP(service: displayService, code: .brightness)
/// print("Brightness: \(reply.currentValue)/\(reply.maxValue)")
///
/// // Set brightness to 50
/// try ddc.writeVCP(service: displayService, code: .brightness, value: 50)
/// ```
public final class DDCInterface: @unchecked Sendable {

    private let transport: I2CTransport
    private let lock = NSLock()

    /// Configuration for retry behavior.
    public struct RetryConfig: Sendable {
        /// Number of retry attempts (not counting the initial attempt).
        public let retryCount: Int
        /// Base delay between retries. Each retry doubles the delay (exponential backoff).
        public let baseDelay: TimeInterval
        /// Number of write cycles per attempt.
        public let writeCycles: Int
        /// Sleep time between write and read in microseconds.
        public let readSleep: UInt32
        /// Sleep time between write cycles in microseconds.
        public let writeSleep: UInt32

        public static let `default` = RetryConfig(
            retryCount: DDCConstants.defaultRetryCount,
            baseDelay: TimeInterval(DDCConstants.defaultRetrySleep) / 1_000_000.0,
            writeCycles: DDCConstants.defaultWriteCycles,
            readSleep: DDCConstants.defaultReadSleep,
            writeSleep: DDCConstants.defaultWriteSleep
        )

        public init(
            retryCount: Int = DDCConstants.defaultRetryCount,
            baseDelay: TimeInterval = TimeInterval(DDCConstants.defaultRetrySleep) / 1_000_000.0,
            writeCycles: Int = DDCConstants.defaultWriteCycles,
            readSleep: UInt32 = DDCConstants.defaultReadSleep,
            writeSleep: UInt32 = DDCConstants.defaultWriteSleep
        ) {
            self.retryCount = retryCount
            self.baseDelay = baseDelay
            self.writeCycles = writeCycles
            self.readSleep = readSleep
            self.writeSleep = writeSleep
        }
    }

    public let config: RetryConfig

    /// Initialize a DDCInterface with the given I2C transport and retry configuration.
    ///
    /// - Parameters:
    ///   - transport: The I2C transport implementation to use.
    ///   - config: Retry configuration. Defaults to `RetryConfig.default`.
    public init(transport: I2CTransport, config: RetryConfig = .default) {
        self.transport = transport
        self.config = config
    }

    // MARK: - Public API

    /// Read a VCP feature value from a display.
    ///
    /// Sends a DDC/CI VCP Get command and parses the reply.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - code: The VCP feature code to read.
    /// - Returns: The parsed VCP reply containing current and maximum values.
    /// - Throws: `DDCError` or `I2CTransportError` on failure.
    public func readVCP(service: io_service_t, code: VCPCode) throws -> VCPReply {
        try readVCP(service: service, rawCode: code.rawValue)
    }

    /// Read a VCP feature value using a raw VCP code byte.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - rawCode: The raw VCP code byte.
    /// - Returns: The parsed VCP reply.
    /// - Throws: `DDCError` or `I2CTransportError` on failure.
    public func readVCP(service: io_service_t, rawCode: UInt8) throws -> VCPReply {
        let sendPayload: [UInt8] = [DDCConstants.vcpGetOpcode, rawCode]
        let packet = buildWritePacket(payload: sendPayload)

        var lastError: String = "unknown"

        for attempt in 0...config.retryCount {
            if attempt > 0 {
                // Exponential backoff: baseDelay * 2^(attempt-1)
                let delay = config.baseDelay * pow(2.0, Double(attempt - 1))
                usleep(UInt32(delay * 1_000_000))
            }

            do {
                // Perform write cycles
                for cycle in 0..<config.writeCycles {
                    try transport.write(
                        service: service,
                        address: DDCConstants.slaveAddress,
                        data: packet
                    )
                    if cycle < config.writeCycles - 1 {
                        usleep(config.writeSleep)
                    }
                }

                // Wait before reading
                usleep(config.readSleep)

                // Read reply
                let reply = try transport.read(
                    service: service,
                    address: DDCConstants.slaveAddress,
                    length: DDCConstants.vcpReplyLength
                )

                // Parse and validate
                return try parseVCPReply(reply)

            } catch let error as DDCError {
                lastError = error.description
                continue
            } catch let error as I2CTransportError {
                lastError = error.description
                continue
            } catch {
                lastError = error.localizedDescription
                continue
            }
        }

        throw DDCError.retriesExhausted(
            attempts: config.retryCount + 1,
            lastError: lastError
        )
    }

    /// Write a VCP feature value to a display.
    ///
    /// Sends a DDC/CI VCP Set command.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - code: The VCP feature code to set.
    ///   - value: The value to set (0-65535).
    /// - Throws: `DDCError` or `I2CTransportError` on failure.
    public func writeVCP(service: io_service_t, code: VCPCode, value: UInt16) throws {
        try writeVCP(service: service, rawCode: code.rawValue, value: value)
    }

    /// Write a VCP feature value using a raw VCP code byte.
    ///
    /// - Parameters:
    ///   - service: The IOKit service handle for the display.
    ///   - rawCode: The raw VCP code byte.
    ///   - value: The value to set.
    /// - Throws: `DDCError` or `I2CTransportError` on failure.
    public func writeVCP(service: io_service_t, rawCode: UInt8, value: UInt16) throws {
        let sendPayload: [UInt8] = [
            DDCConstants.vcpSetOpcode,
            rawCode,
            UInt8(value >> 8),      // Value high byte
            UInt8(value & 0xFF)     // Value low byte
        ]
        let packet = buildWritePacket(payload: sendPayload)

        var lastError: String = "unknown"

        for attempt in 0...config.retryCount {
            if attempt > 0 {
                let delay = config.baseDelay * pow(2.0, Double(attempt - 1))
                usleep(UInt32(delay * 1_000_000))
            }

            do {
                for cycle in 0..<config.writeCycles {
                    try transport.write(
                        service: service,
                        address: DDCConstants.slaveAddress,
                        data: packet
                    )
                    if cycle < config.writeCycles - 1 {
                        usleep(config.writeSleep)
                    }
                }
                return // Success
            } catch let error as I2CTransportError {
                lastError = error.description
                continue
            } catch {
                lastError = error.localizedDescription
                continue
            }
        }

        throw DDCError.retriesExhausted(
            attempts: config.retryCount + 1,
            lastError: lastError
        )
    }

    // MARK: - Packet Construction

    /// Build a DDC/CI write packet from a command payload.
    ///
    /// DDC/CI write packet format:
    /// ```
    /// [0x80 | (payload_length + 1), payload_length, ...payload, checksum]
    /// ```
    ///
    /// The checksum is XOR of all bytes with the host address (0x6E) as seed.
    ///
    /// - Parameter payload: The command bytes (e.g., `[opcode, vcp_code, ...]`).
    /// - Returns: The complete packet ready for I2C transmission.
    public func buildWritePacket(payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8]()
        packet.reserveCapacity(payload.count + 3)

        // Byte 0: 0x80 OR'd with (payload length + 1)
        packet.append(0x80 | UInt8(payload.count + 1))
        // Byte 1: payload length
        packet.append(UInt8(payload.count))
        // Bytes 2..n-1: payload
        packet.append(contentsOf: payload)
        // Byte n: checksum placeholder
        packet.append(0x00)

        // Calculate checksum: XOR all packet bytes with host address seed
        let checksumValue = Self.checksum(
            seed: DDCConstants.hostAddress,
            data: packet,
            start: 0,
            end: packet.count - 2
        )
        packet[packet.count - 1] = checksumValue

        return packet
    }

    /// Parse a VCP reply from raw I2C read data.
    ///
    /// Expected VCP reply format (11 bytes):
    /// ```
    /// [0] - Source address marker
    /// [1] - Length byte (0x80 | length)
    /// [2] - Result code
    /// [3] - VCP opcode (should be 0x02)
    /// [4] - VCP type code
    /// [5] - VCP feature code
    /// [6] - Max value high byte
    /// [7] - Max value low byte
    /// [8] - Current value high byte
    /// [9] - Current value low byte
    /// [10] - Checksum
    /// ```
    ///
    /// - Parameter data: The raw bytes read from the I2C device.
    /// - Returns: The parsed VCP reply.
    /// - Throws: `DDCError` if the reply is malformed or checksum fails.
    public func parseVCPReply(_ data: [UInt8]) throws -> VCPReply {
        guard data.count >= DDCConstants.vcpReplyLength else {
            throw DDCError.invalidReply(
                reason: "Reply too short: \(data.count) bytes, expected \(DDCConstants.vcpReplyLength)"
            )
        }

        // Validate checksum on the reply
        let expectedChecksum = Self.checksum(
            seed: DDCConstants.replyChecksumSeed,
            data: data,
            start: 0,
            end: data.count - 2
        )
        let actualChecksum = data[data.count - 1]

        guard expectedChecksum == actualChecksum else {
            throw DDCError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        // Extract fields
        let resultCode = data[2]
        let vcpCode = data[5]
        let typeCode = data[4]

        // Check if the display reports the VCP code as unsupported
        if resultCode != 0 {
            throw DDCError.vcpNotSupported(code: vcpCode)
        }

        let maxValue = UInt16(data[6]) << 8 | UInt16(data[7])
        let currentValue = UInt16(data[8]) << 8 | UInt16(data[9])

        return VCPReply(
            vcpCode: vcpCode,
            resultCode: resultCode,
            typeCode: typeCode,
            maxValue: maxValue,
            currentValue: currentValue
        )
    }

    // MARK: - Checksum

    /// Calculate DDC/CI XOR checksum.
    ///
    /// The checksum is computed by XOR-ing a seed value with each byte
    /// in the specified range of the data array.
    ///
    /// - Parameters:
    ///   - seed: The initial XOR seed value.
    ///   - data: The byte array to checksum.
    ///   - start: The starting index (inclusive).
    ///   - end: The ending index (inclusive).
    /// - Returns: The computed checksum byte.
    public static func checksum(seed: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
        var result = seed
        guard start >= 0, end < data.count, start <= end else {
            return result
        }
        for i in start...end {
            result ^= data[i]
        }
        return result
    }
}
