import Foundation

enum Constants {
    static let bundleID = "com.chromaflow.ChromaFlow"
    static let appName = "ChromaFlow"

    // DDC Timing
    static let ddcCommandDelay: TimeInterval = 0.05  // 50ms
    static let ddcCommandTimeout: TimeInterval = 0.2  // 200ms
    static let ddcMaxRetries = 3

    // Profile IDs
    static let sRGBProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let displayP3ProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let adobeRGBProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let rec709ProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    // Performance Targets
    static let profileSwitchLatencyTarget: TimeInterval = 0.2  // 200ms
    static let sliderUpdateLatencyTarget: TimeInterval = 0.016  // 16ms
}
