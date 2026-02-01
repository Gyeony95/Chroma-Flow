import XCTest
@testable import DDCKit

// MARK: - Mock I2C Transport

/// A mock I2C transport for testing DDCInterface without real hardware.
final class MockI2CTransport: I2CTransport, @unchecked Sendable {

    /// The last data written via `write()`.
    var lastWrittenData: [UInt8]?
    /// The last address used in `write()`.
    var lastWriteAddress: UInt8?
    /// The number of times `write()` was called.
    var writeCallCount = 0
    /// The number of times `read()` was called.
    var readCallCount = 0

    /// The data to return from `read()`. Set this before calling readVCP.
    var readResponse: [UInt8] = []
    /// If set, `write()` will throw this error.
    var writeError: I2CTransportError?
    /// If set, `read()` will throw this error.
    var readError: I2CTransportError?

    func write(service: io_service_t, address: UInt8, data: [UInt8]) throws {
        if let error = writeError {
            throw error
        }
        writeCallCount += 1
        lastWriteAddress = address
        lastWrittenData = data
    }

    func read(service: io_service_t, address: UInt8, length: Int) throws -> [UInt8] {
        if let error = readError {
            throw error
        }
        readCallCount += 1
        return Array(readResponse.prefix(length))
    }

    func reset() {
        lastWrittenData = nil
        lastWriteAddress = nil
        writeCallCount = 0
        readCallCount = 0
        readResponse = []
        writeError = nil
        readError = nil
    }
}

// MARK: - DDCKit Version Test

final class DDCKitTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(DDCKit.version(), "0.1.0")
    }
}

// MARK: - Checksum Tests

final class DDCChecksumTests: XCTestCase {

    func testChecksumWithZeroSeed() {
        // XOR of [0x01, 0x02, 0x03] with seed 0x00 = 0x01 ^ 0x02 ^ 0x03 = 0x00
        let data: [UInt8] = [0x01, 0x02, 0x03]
        let result = DDCInterface.checksum(seed: 0x00, data: data, start: 0, end: 2)
        XCTAssertEqual(result, 0x00)
    }

    func testChecksumWithHostAddressSeed() {
        // Typical DDC write checksum: seed = 0x6E (host address)
        // For a VCP Get brightness command: [0x82, 0x01, 0x01, 0x10]
        // Packet (excluding checksum): [0x82, 0x01, 0x01, 0x10]
        // checksum = 0x6E ^ 0x82 ^ 0x01 ^ 0x01 ^ 0x10
        let data: [UInt8] = [0x82, 0x01, 0x01, 0x10]
        let expected: UInt8 = 0x6E ^ 0x82 ^ 0x01 ^ 0x01 ^ 0x10
        let result = DDCInterface.checksum(seed: 0x6E, data: data, start: 0, end: 3)
        XCTAssertEqual(result, expected)
    }

    func testChecksumWithReplySeed() {
        // Reply checksum: seed = 0x50
        let data: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        let expected: UInt8 = 0x50 ^ 0x6E ^ 0x88 ^ 0x02 ^ 0x00 ^ 0x10 ^ 0x00 ^ 0x00 ^ 0x64 ^ 0x00 ^ 0x32
        let result = DDCInterface.checksum(seed: 0x50, data: data, start: 0, end: 9)
        XCTAssertEqual(result, expected)
    }

    func testChecksumSingleByte() {
        let data: [UInt8] = [0xAB]
        let result = DDCInterface.checksum(seed: 0x00, data: data, start: 0, end: 0)
        XCTAssertEqual(result, 0xAB)
    }

    func testChecksumInvalidRange() {
        // Invalid range should return the seed unchanged
        let data: [UInt8] = [0x01, 0x02]
        let result = DDCInterface.checksum(seed: 0xFF, data: data, start: 5, end: 10)
        XCTAssertEqual(result, 0xFF)
    }

    func testChecksumEmptyArrayWithSeed() {
        let data: [UInt8] = []
        let result = DDCInterface.checksum(seed: 0x6E, data: data, start: 0, end: 0)
        // Empty array, invalid range -> returns seed
        XCTAssertEqual(result, 0x6E)
    }
}

// MARK: - Write Packet Construction Tests

final class DDCWritePacketTests: XCTestCase {

    var mockTransport: MockI2CTransport!
    var ddc: DDCInterface!

    override func setUp() {
        super.setUp()
        mockTransport = MockI2CTransport()
        ddc = DDCInterface(transport: mockTransport)
    }

    func testBuildVCPGetBrightnessPacket() {
        // VCP Get for brightness (0x10):
        // Payload: [0x01 (Get opcode), 0x10 (brightness)]
        // Packet: [0x80 | 3, 0x02, 0x01, 0x10, checksum]
        //       = [0x83, 0x02, 0x01, 0x10, checksum]
        let payload: [UInt8] = [0x01, 0x10]
        let packet = ddc.buildWritePacket(payload: payload)

        XCTAssertEqual(packet.count, 5, "VCP Get packet should be 5 bytes")
        XCTAssertEqual(packet[0], 0x83, "First byte should be 0x80 | (2+1) = 0x83")
        XCTAssertEqual(packet[1], 0x02, "Second byte should be payload length = 2")
        XCTAssertEqual(packet[2], 0x01, "Third byte should be Get opcode")
        XCTAssertEqual(packet[3], 0x10, "Fourth byte should be brightness VCP code")

        // Verify checksum: seed=0x6E, XOR bytes [0..3]
        let expectedChecksum: UInt8 = 0x6E ^ 0x83 ^ 0x02 ^ 0x01 ^ 0x10
        XCTAssertEqual(packet[4], expectedChecksum, "Checksum should be correct")
    }

    func testBuildVCPSetBrightnessPacket() {
        // VCP Set brightness to 50 (0x0032):
        // Payload: [0x03 (Set opcode), 0x10 (brightness), 0x00 (high), 0x32 (low)]
        // Packet: [0x80 | 5, 0x04, 0x03, 0x10, 0x00, 0x32, checksum]
        //       = [0x85, 0x04, 0x03, 0x10, 0x00, 0x32, checksum]
        let payload: [UInt8] = [0x03, 0x10, 0x00, 0x32]
        let packet = ddc.buildWritePacket(payload: payload)

        XCTAssertEqual(packet.count, 7, "VCP Set packet should be 7 bytes")
        XCTAssertEqual(packet[0], 0x85, "First byte should be 0x80 | (4+1) = 0x85")
        XCTAssertEqual(packet[1], 0x04, "Second byte should be payload length = 4")
        XCTAssertEqual(packet[2], 0x03, "Third byte should be Set opcode")
        XCTAssertEqual(packet[3], 0x10, "Fourth byte should be brightness VCP code")
        XCTAssertEqual(packet[4], 0x00, "Fifth byte should be value high")
        XCTAssertEqual(packet[5], 0x32, "Sixth byte should be value low (50)")

        let expectedChecksum: UInt8 = 0x6E ^ 0x85 ^ 0x04 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
        XCTAssertEqual(packet[6], expectedChecksum, "Checksum should be correct")
    }

    func testBuildWritePacketSingleByte() {
        let payload: [UInt8] = [0xAA]
        let packet = ddc.buildWritePacket(payload: payload)

        XCTAssertEqual(packet.count, 4)
        XCTAssertEqual(packet[0], 0x82) // 0x80 | (1+1)
        XCTAssertEqual(packet[1], 0x01) // length = 1
        XCTAssertEqual(packet[2], 0xAA) // payload

        let expectedChecksum: UInt8 = 0x6E ^ 0x82 ^ 0x01 ^ 0xAA
        XCTAssertEqual(packet[3], expectedChecksum)
    }
}

// MARK: - VCP Reply Parsing Tests

final class DDCVCPReplyTests: XCTestCase {

    var mockTransport: MockI2CTransport!
    var ddc: DDCInterface!

    override func setUp() {
        super.setUp()
        mockTransport = MockI2CTransport()
        ddc = DDCInterface(transport: mockTransport)
    }

    /// Build a valid VCP reply with correct checksum for testing.
    private func buildValidReply(
        resultCode: UInt8 = 0x00,
        vcpOpcode: UInt8 = 0x02,
        typeCode: UInt8 = 0x00,
        vcpCode: UInt8 = 0x10,
        maxHigh: UInt8 = 0x00,
        maxLow: UInt8 = 0x64,
        curHigh: UInt8 = 0x00,
        curLow: UInt8 = 0x32
    ) -> [UInt8] {
        // Reply format:
        // [0] source marker, [1] length, [2] result_code, [3] opcode,
        // [4] type_code, [5] vcp_code, [6] max_high, [7] max_low,
        // [8] cur_high, [9] cur_low, [10] checksum
        var reply: [UInt8] = [
            0x6E,       // Source address marker
            0x88,       // Length byte (0x80 | 8)
            resultCode,
            vcpOpcode,
            typeCode,
            vcpCode,
            maxHigh, maxLow,
            curHigh, curLow,
            0x00        // Checksum placeholder
        ]

        // Calculate correct checksum with seed 0x50
        reply[10] = DDCInterface.checksum(seed: 0x50, data: reply, start: 0, end: 9)
        return reply
    }

    func testParseValidBrightnessReply() throws {
        // Brightness: current=50, max=100
        let reply = buildValidReply(
            vcpCode: 0x10,
            maxHigh: 0x00, maxLow: 0x64,   // max = 100
            curHigh: 0x00, curLow: 0x32     // current = 50
        )

        let result = try ddc.parseVCPReply(reply)

        XCTAssertEqual(result.vcpCode, 0x10)
        XCTAssertEqual(result.resultCode, 0x00)
        XCTAssertEqual(result.typeCode, 0x00)
        XCTAssertEqual(result.maxValue, 100)
        XCTAssertEqual(result.currentValue, 50)
    }

    func testParseHighValueReply() throws {
        // Test with larger values: current=1000, max=65535
        let reply = buildValidReply(
            vcpCode: 0x12,
            maxHigh: 0xFF, maxLow: 0xFF,   // max = 65535
            curHigh: 0x03, curLow: 0xE8     // current = 1000
        )

        let result = try ddc.parseVCPReply(reply)

        XCTAssertEqual(result.vcpCode, 0x12)
        XCTAssertEqual(result.maxValue, 65535)
        XCTAssertEqual(result.currentValue, 1000)
    }

    func testParseZeroValueReply() throws {
        let reply = buildValidReply(
            vcpCode: 0x10,
            maxHigh: 0x00, maxLow: 0x64,
            curHigh: 0x00, curLow: 0x00
        )

        let result = try ddc.parseVCPReply(reply)

        XCTAssertEqual(result.currentValue, 0)
        XCTAssertEqual(result.maxValue, 100)
    }

    func testParseReplyWithBadChecksum() {
        var reply = buildValidReply()
        // Corrupt the checksum
        reply[10] = reply[10] &+ 1

        XCTAssertThrowsError(try ddc.parseVCPReply(reply)) { error in
            guard case DDCError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch error, got \(error)")
                return
            }
        }
    }

    func testParseReplyTooShort() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10]

        XCTAssertThrowsError(try ddc.parseVCPReply(reply)) { error in
            guard case DDCError.invalidReply = error else {
                XCTFail("Expected invalidReply error, got \(error)")
                return
            }
        }
    }

    func testParseReplyVCPNotSupported() {
        // Result code != 0 means unsupported
        let reply = buildValidReply(resultCode: 0x01, vcpCode: 0x60)

        XCTAssertThrowsError(try ddc.parseVCPReply(reply)) { error in
            guard case DDCError.vcpNotSupported(let code) = error else {
                XCTFail("Expected vcpNotSupported error, got \(error)")
                return
            }
            XCTAssertEqual(code, 0x60)
        }
    }

    func testParseContrastReply() throws {
        let reply = buildValidReply(
            vcpCode: VCPCode.contrast.rawValue,
            maxHigh: 0x00, maxLow: 0x64,
            curHigh: 0x00, curLow: 0x4B  // 75
        )

        let result = try ddc.parseVCPReply(reply)

        XCTAssertEqual(result.vcpCode, VCPCode.contrast.rawValue)
        XCTAssertEqual(result.currentValue, 75)
        XCTAssertEqual(result.maxValue, 100)
    }
}

// MARK: - DDCInterface Read/Write Integration Tests (with Mock)

final class DDCInterfaceTests: XCTestCase {

    var mockTransport: MockI2CTransport!
    var ddc: DDCInterface!

    override func setUp() {
        super.setUp()
        mockTransport = MockI2CTransport()
        // Use minimal retries and no sleep for fast tests
        let config = DDCInterface.RetryConfig(
            retryCount: 1,
            baseDelay: 0.0,
            writeCycles: 1,
            readSleep: 0,
            writeSleep: 0
        )
        ddc = DDCInterface(transport: mockTransport, config: config)
    }

    func testReadVCPSendsCorrectPacketAndParsesResponse() throws {
        // Prepare a valid brightness reply
        var reply: [UInt8] = [0x6E, 0x88, 0x00, 0x02, 0x00, 0x10, 0x00, 0x64, 0x00, 0x32, 0x00]
        reply[10] = DDCInterface.checksum(seed: 0x50, data: reply, start: 0, end: 9)
        mockTransport.readResponse = reply

        // Use a dummy service (1 is valid for mock)
        let result = try ddc.readVCP(service: 1, code: .brightness)

        XCTAssertEqual(result.vcpCode, 0x10)
        XCTAssertEqual(result.currentValue, 50)
        XCTAssertEqual(result.maxValue, 100)

        // Verify transport was called correctly
        XCTAssertEqual(mockTransport.writeCallCount, 1)
        XCTAssertEqual(mockTransport.readCallCount, 1)
        XCTAssertEqual(mockTransport.lastWriteAddress, DDCConstants.slaveAddress)
    }

    func testWriteVCPSendsCorrectPacket() throws {
        try ddc.writeVCP(service: 1, code: .brightness, value: 75)

        XCTAssertEqual(mockTransport.writeCallCount, 1)
        XCTAssertEqual(mockTransport.lastWriteAddress, DDCConstants.slaveAddress)

        // Verify the packet structure
        guard let packet = mockTransport.lastWrittenData else {
            XCTFail("No data was written")
            return
        }

        // Should contain: [length_header, length, SET_opcode, VCP_code, value_high, value_low, checksum]
        XCTAssertEqual(packet[0], 0x85, "Header should be 0x80 | 5")
        XCTAssertEqual(packet[1], 0x04, "Payload length should be 4")
        XCTAssertEqual(packet[2], DDCConstants.vcpSetOpcode)
        XCTAssertEqual(packet[3], VCPCode.brightness.rawValue)
        XCTAssertEqual(packet[4], 0x00, "Value high byte for 75")
        XCTAssertEqual(packet[5], 75, "Value low byte for 75")
    }

    func testReadVCPRetriesOnTransportError() throws {
        // Set up a valid reply
        var reply: [UInt8] = [0x6E, 0x88, 0x00, 0x02, 0x00, 0x10, 0x00, 0x64, 0x00, 0x32, 0x00]
        reply[10] = DDCInterface.checksum(seed: 0x50, data: reply, start: 0, end: 9)
        mockTransport.readResponse = reply

        // Simulate transport error on first write
        mockTransport.writeError = .writeFailed(1)

        // With retryCount=1, we get 2 total attempts. Both will fail.
        XCTAssertThrowsError(try ddc.readVCP(service: 1, code: .brightness)) { error in
            guard case DDCError.retriesExhausted = error else {
                XCTFail("Expected retriesExhausted, got \(error)")
                return
            }
        }

        // Both attempts should have tried to write
        XCTAssertEqual(mockTransport.writeCallCount, 0, "Write should not succeed when transport errors")
    }

    func testWriteVCPFailsWithTransportError() {
        mockTransport.writeError = .writeFailed(-1)

        XCTAssertThrowsError(try ddc.writeVCP(service: 1, code: .brightness, value: 50)) { error in
            guard case DDCError.retriesExhausted(let attempts, _) = error else {
                XCTFail("Expected retriesExhausted, got \(error)")
                return
            }
            XCTAssertEqual(attempts, 2) // 1 initial + 1 retry
        }
    }

    func testWriteVCPValueEncoding() throws {
        // Test value 256 (0x0100)
        try ddc.writeVCP(service: 1, code: .brightness, value: 256)

        guard let packet = mockTransport.lastWrittenData else {
            XCTFail("No data written")
            return
        }

        XCTAssertEqual(packet[4], 0x01, "High byte of 256 should be 0x01")
        XCTAssertEqual(packet[5], 0x00, "Low byte of 256 should be 0x00")
    }
}

// MARK: - I2CTransport Error Tests

final class I2CTransportErrorTests: XCTestCase {

    func testErrorDescriptions() {
        let errors: [I2CTransportError] = [
            .unsupported,
            .writeFailed(42),
            .readFailed(-1),
            .invalidService,
            .serviceCreationFailed,
            .invalidLength
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) should have a description")
        }
    }
}

// MARK: - ARM64I2CTransport Availability Test

final class ARM64I2CTransportTests: XCTestCase {

    func testTransportInitializes() {
        let transport = ARM64I2CTransport()
        // On CI/test machines, IOAVService may not be available.
        // We just verify that initialization does not crash.
        _ = transport.isAvailable
    }

    func testTransportRejectsInvalidService() {
        let transport = ARM64I2CTransport()

        // Writing to service 0 should fail with invalidService
        // (only if symbols are available; otherwise unsupported)
        XCTAssertThrowsError(try transport.write(service: 0, address: 0x37, data: [0x01])) { error in
            guard let transportError = error as? I2CTransportError else {
                XCTFail("Expected I2CTransportError, got \(error)")
                return
            }
            switch transportError {
            case .invalidService, .unsupported:
                break // Both are acceptable
            default:
                XCTFail("Expected invalidService or unsupported, got \(transportError)")
            }
        }
    }

    func testTransportRejectsEmptyData() {
        let transport = ARM64I2CTransport()

        XCTAssertThrowsError(try transport.write(service: 1, address: 0x37, data: [])) { error in
            guard let transportError = error as? I2CTransportError else {
                XCTFail("Expected I2CTransportError, got \(error)")
                return
            }
            switch transportError {
            case .invalidLength, .unsupported:
                break
            default:
                XCTFail("Expected invalidLength or unsupported, got \(transportError)")
            }
        }
    }

    func testTransportRejectsZeroLengthRead() {
        let transport = ARM64I2CTransport()

        XCTAssertThrowsError(try transport.read(service: 1, address: 0x37, length: 0)) { error in
            guard let transportError = error as? I2CTransportError else {
                XCTFail("Expected I2CTransportError, got \(error)")
                return
            }
            switch transportError {
            case .invalidLength, .unsupported:
                break
            default:
                XCTFail("Expected invalidLength or unsupported, got \(transportError)")
            }
        }
    }

    func testInvalidateService() {
        let transport = ARM64I2CTransport()
        // Should not crash even with arbitrary service values
        transport.invalidateService(12345)
        transport.invalidateAll()
    }
}

// MARK: - DDC Constants Tests

final class DDCConstantsTests: XCTestCase {

    func testSlaveAddress() {
        XCTAssertEqual(DDCConstants.slaveAddress, 0x37)
    }

    func testDataAddress() {
        XCTAssertEqual(DDCConstants.dataAddress, 0x51)
    }

    func testHostAddress() {
        XCTAssertEqual(DDCConstants.hostAddress, DDCConstants.slaveAddress << 1)
    }

    func testVCPOpcodes() {
        XCTAssertEqual(DDCConstants.vcpGetOpcode, 0x01)
        XCTAssertEqual(DDCConstants.vcpSetOpcode, 0x03)
        XCTAssertEqual(DDCConstants.vcpReplyOpcode, 0x02)
    }

    func testReplyLength() {
        XCTAssertEqual(DDCConstants.vcpReplyLength, 11)
    }
}
