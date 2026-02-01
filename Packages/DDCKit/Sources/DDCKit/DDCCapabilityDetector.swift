import Foundation
import IOKit

public enum DDCDetectionError: Error, Sendable {
    case displayNotFound
    case notExternalDisplay
    case i2cTimeout
    case i2cNotResponding
    case invalidResponse
    case capabilityStringMalformed
}

public final class DDCCapabilityDetector: @unchecked Sendable {

    private let edidReader: EDIDReader
    private static let commandTimeout: TimeInterval = 0.2 // 200ms
    private static let retryDelays: [TimeInterval] = [0.1, 0.2, 0.4] // Backoff delays

    public init(edidReader: EDIDReader = EDIDReader()) {
        self.edidReader = edidReader
    }

    /// Detect DDC capabilities for a display
    public func detectCapabilities(for displayID: UInt32) async throws -> DDCCapabilities {
        // Step 1: Verify this is an external display
        guard await edidReader.isExternalDisplay(for: displayID) else {
            throw DDCDetectionError.notExternalDisplay
        }

        // Step 2: Read EDID for basic display info
        let edidInfo = try await edidReader.readEDID(for: displayID)

        // Step 3: Query VCP capability string (0xF3)
        let capabilityString = try await queryCapabilityString(for: displayID)

        // Step 4: Parse capability string
        let parsedCapabilities = parseCapabilityString(capabilityString)

        // Step 5: Test brightness write/read as probe
        let supportsBrightness = await testBrightnessProbe(for: displayID)

        // Step 6: Build final capabilities
        var supportedCodes = parsedCapabilities.supportedCodes
        if supportsBrightness {
            supportedCodes.insert(.brightness)
        }

        return DDCCapabilities(
            supportedCodes: supportedCodes,
            modelName: edidInfo.modelName ?? parsedCapabilities.modelName,
            protocolClass: parsedCapabilities.protocolClass,
            supportsBrightness: supportsBrightness,
            supportsContrast: supportedCodes.contains(.contrast),
            supportsColorPresetSelect: supportedCodes.contains(.colorPresetSelect),
            supportsInputSource: supportedCodes.contains(.inputSource),
            supportedColorPresets: parsedCapabilities.supportedColorPresets,
            maxBrightness: parsedCapabilities.maxBrightness,
            maxContrast: parsedCapabilities.maxContrast,
            rawCapabilityString: capabilityString
        )
    }

    /// Query VCP capability string (command 0xF3) with retries
    private func queryCapabilityString(for displayID: UInt32) async throws -> String {
        var lastError: Error?

        // Try initial attempt + 3 retries
        for (attempt, delay) in [(0, 0.0)] + Self.retryDelays.enumerated().map({ ($0.offset + 1, $0.element) }) {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                return try await performCapabilityQuery(for: displayID)
            } catch {
                lastError = error
                // Continue to next retry
            }
        }

        throw lastError ?? DDCDetectionError.i2cNotResponding
    }

    /// Perform a single capability query attempt
    private func performCapabilityQuery(for displayID: UInt32) async throws -> String {
        // This is a mock implementation - real implementation would use I2C transport
        // For now, return empty string to indicate no response
        try await Task.sleep(nanoseconds: UInt64(Self.commandTimeout * 1_000_000_000))

        // In real implementation:
        // 1. Open I2C connection to display
        // 2. Send VCP command 0xF3 (capabilities request)
        // 3. Read response in chunks
        // 4. Reassemble capability string
        // 5. Validate checksum

        // Mock: return empty to trigger fallback behavior
        return ""
    }

    /// Test brightness write/read cycle as capability probe
    private func testBrightnessProbe(for displayID: UInt32) async -> Bool {
        // This is a mock implementation - real implementation would:
        // 1. Read current brightness (VCP 0x10)
        // 2. Write a test value
        // 3. Read back to confirm
        // 4. Restore original value
        // 5. Return true if all steps succeed within timeout

        do {
            try await Task.sleep(nanoseconds: UInt64(Self.commandTimeout * 1_000_000_000))
            // Mock: assume brightness is not supported for now
            return false
        } catch {
            return false
        }
    }

    /// Parse VCP capability string into structured capabilities
    private func parseCapabilityString(_ capString: String) -> ParsedCapabilities {
        // Empty or very short strings indicate no DDC support
        guard capString.count > 10 else {
            return ParsedCapabilities()
        }

        var supportedCodes = Set<VCPCode>()
        var modelName: String?
        var protocolClass: String?
        var supportedColorPresets: [Int] = []
        let maxBrightness: UInt16 = 100
        let maxContrast: UInt16 = 100

        // Capability string format: (prot(monitor)type(LCD)model(ACME)cmds(01 02 03)vcp(10 12 14(01 02 03)))
        // - prot: protocol class (monitor, LCD, CRT)
        // - type: display type
        // - model: model name
        // - cmds: supported commands
        // - vcp: VCP codes with optional value lists in parentheses

        // Extract model name
        if let modelMatch = capString.range(of: "model\\(([^)]+)\\)", options: .regularExpression) {
            let modelSubstring = capString[modelMatch]
            modelName = String(modelSubstring.dropFirst(6).dropLast(1)) // Remove "model(" and ")"
        }

        // Extract protocol class
        if let protMatch = capString.range(of: "prot\\(([^)]+)\\)", options: .regularExpression) {
            let protSubstring = capString[protMatch]
            protocolClass = String(protSubstring.dropFirst(5).dropLast(1)) // Remove "prot(" and ")"
        }

        // Extract VCP codes
        if let vcpMatch = capString.range(of: "vcp\\(([^)]+)\\)", options: .regularExpression) {
            let vcpSubstring = String(capString[vcpMatch].dropFirst(4).dropLast(1)) // Remove "vcp(" and ")"

            // Split by space, parse hex codes
            let components = vcpSubstring.split(separator: " ")
            for component in components {
                // Remove any nested parentheses (value lists)
                let cleanComponent = component.split(separator: "(").first ?? component[...]

                if let code = UInt8(cleanComponent, radix: 16) {
                    if let vcpCode = VCPCode(rawValue: code) {
                        supportedCodes.insert(vcpCode)

                        // If this is color preset select, extract presets
                        if vcpCode == .colorPresetSelect,
                           let presetRange = component.range(of: "\\(([^)]+)\\)", options: .regularExpression) {
                            let presetSubstring = component[presetRange]
                            let presetStr = String(presetSubstring.dropFirst(1).dropLast(1))
                            supportedColorPresets = presetStr.split(separator: " ").compactMap { Int($0, radix: 16) }
                        }
                    }
                }
            }
        }

        return ParsedCapabilities(
            supportedCodes: supportedCodes,
            modelName: modelName,
            protocolClass: protocolClass,
            supportedColorPresets: supportedColorPresets,
            maxBrightness: maxBrightness,
            maxContrast: maxContrast
        )
    }
}

// MARK: - Helper Types

private struct ParsedCapabilities {
    var supportedCodes: Set<VCPCode> = []
    var modelName: String?
    var protocolClass: String?
    var supportedColorPresets: [Int] = []
    var maxBrightness: UInt16 = 100
    var maxContrast: UInt16 = 100
}
