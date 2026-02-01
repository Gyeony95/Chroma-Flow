//
//  AmbientLightSensor.swift
//  ChromaFlow
//
//  MacBook ambient light sensor access via IOHIDServiceClient.
//  Provides real-time lux values for Ambient Sync feature.
//

import Foundation
import IOKit
import IOKit.hid

/// Provides access to MacBook's built-in ambient light sensor
final class AmbientLightSensor: @unchecked Sendable {

    // MARK: - Properties

    /// Sampling interval in milliseconds
    private let samplingInterval: UInt64 = 500

    /// HID service client for ambient light sensor
    private var serviceClient: IOHIDServiceClient?

    /// HID event system client
    private var eventSystemClient: IOHIDEventSystemClient?

    /// Whether sensor is currently active
    private var isActive = false

    /// Continuation for AsyncStream
    private var continuation: AsyncStream<Double>.Continuation?

    // MARK: - Initialization

    init() {
        // Sensor will be initialized when startMonitoring is called
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    /// Start monitoring ambient light sensor
    /// - Returns: AsyncStream of lux values (updated every 500ms)
    func startMonitoring() -> AsyncStream<Double>? {
        guard !isActive else {
            print("AmbientLightSensor: Already monitoring")
            return nil
        }

        guard FeatureFlags.ioKitAmbientLight else {
            print("AmbientLightSensor: Feature flag disabled")
            return nil
        }

        // Try to initialize sensor
        guard setupSensor() else {
            print("AmbientLightSensor: Failed to setup sensor (not available on this Mac)")
            return nil
        }

        isActive = true

        let stream = AsyncStream<Double> { continuation in
            self.continuation = continuation

            // Set termination handler
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stopMonitoring()
            }

            // Start sampling on background thread
            Task.detached {
                await self.sampleLoop()
            }
        }

        return stream
    }

    /// Stop monitoring ambient light sensor
    func stopMonitoring() {
        guard isActive else { return }

        isActive = false
        continuation?.finish()
        continuation = nil

        // Cleanup HID resources
        if let client = serviceClient {
            // IOHIDServiceClient doesn't need explicit closure
            serviceClient = nil
        }

        if let eventClient = eventSystemClient {
            // IOHIDEventSystemClient doesn't need explicit closure
            eventSystemClient = nil
        }

        print("AmbientLightSensor: Stopped monitoring")
    }

    /// Get current lux value (synchronous, single reading)
    /// - Returns: Current lux value, or nil if sensor unavailable
    func getCurrentLux() -> Double? {
        guard FeatureFlags.ioKitAmbientLight else {
            return nil
        }

        // If not already set up, try to set up temporarily
        if serviceClient == nil {
            guard setupSensor() else {
                return nil
            }
        }

        return readLuxValue()
    }

    // MARK: - Private Methods

    /// Setup IOHIDServiceClient for ambient light sensor
    private func setupSensor() -> Bool {
        // Try to get IOHIDEventSystemClient
        guard let eventClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return false
        }

        eventSystemClient = eventClient

        // Match ambient light sensor
        // Primary Page: 0xFF00 (AppleVendor), Usage: 0x0004 (AmbientLightSensor)
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 0x0004
        ]

        IOHIDEventSystemClientSetMatching(eventClient, matching as CFDictionary)

        // Try to get services
        guard let services = IOHIDEventSystemClientCopyServices(eventClient) as? [IOHIDServiceClient],
              let service = services.first else {
            return false
        }

        serviceClient = service

        print("AmbientLightSensor: Successfully initialized sensor")
        return true
    }

    /// Sample loop that reads sensor at regular intervals
    private func sampleLoop() async {
        while isActive {
            // Read current value
            if let lux = readLuxValue() {
                continuation?.yield(lux)
            }

            // Sleep for sampling interval
            try? await Task.sleep(nanoseconds: samplingInterval * 1_000_000)
        }
    }

    /// Read raw lux value from sensor
    private func readLuxValue() -> Double? {
        guard let service = serviceClient else {
            return nil
        }

        // Create event for ambient light
        // kIOHIDEventTypeAmbientLightSensor = 12
        let eventType: Int32 = 12

        guard let event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0) else {
            return nil
        }

        // Get lux value from event
        // IOHIDEventFieldBase(kIOHIDEventTypeAmbientLightSensor) = (12 << 16)
        let field = (eventType << 16)
        let luxValue = IOHIDEventGetFloatValue(event, field)

        // Convert to Double (lux value is typically in range 0-100000)
        let lux = Double(luxValue)

        return lux > 0 ? lux : 0
    }
}

// MARK: - IOKit C Functions (Dynamic Loading)

// These functions are from IOKit.framework/IOHIDEventSystemClient
// We declare them here for Swift usage

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClient, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClient) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(
    _ service: IOHIDServiceClient,
    _ type: Int32,
    _ options: IOOptionBits,
    _ timestamp: UInt64
) -> IOHIDEvent?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEvent, _ field: Int32) -> Float

// MARK: - IOKit Types

private typealias IOHIDEventSystemClient = UnsafeMutableRawPointer
private typealias IOHIDServiceClient = UnsafeMutableRawPointer
private typealias IOHIDEvent = UnsafeMutableRawPointer
