# DisplayModeController

A Swift controller for managing display pixel formats and RGB ranges on macOS, similar to Better Display's display mode controls.

## Features

- **Display Mode Enumeration**: List all available display modes with pixel encoding information
- **RGB Format Control**: Switch between 8-bit SDR and 10-bit HDR modes
- **RGB Range Control**: Toggle between Full (0-255) and Limited (16-235) ranges
- **Color Encoding Support**: Detect RGB, YCbCr 4:4:4, 4:2:2, and 4:2:0 formats
- **Enhanced IOKit Integration**: Deep mode analysis using IOKit for accurate pixel encoding detection
- **Display Capabilities Detection**: Query display's supported bit depths, encodings, and HDR support

## Usage

### Basic Usage

```swift
import Foundation

@MainActor
class MyDisplayManager {
    let controller = DisplayModeController()

    func getCurrentMode() {
        let displayID = CGMainDisplayID()

        if let mode = controller.currentMode(for: displayID) {
            print("Current: \(mode.description)")
            // Example: "3840×2160 60Hz 10-bit RGB Limited (16-235)"
        }
    }

    func listEncodingVariants() {
        let displayID = CGMainDisplayID()

        // Get modes with same resolution/refresh but different encodings
        let variants = controller.encodingVariants(for: displayID)

        for mode in variants {
            print("- \(mode.description)")
        }
    }

    func switchToSDR() async throws {
        let displayID = CGMainDisplayID()

        // Find and set 8-bit RGB Full range mode
        if let sdrMode = controller.findMode(
            for: displayID,
            bitDepth: 8,
            colorEncoding: .rgb,
            range: .full
        ) {
            try controller.setMode(sdrMode, for: displayID)
        }
    }

    func switchToHDR() async throws {
        let displayID = CGMainDisplayID()

        // Find and set 10-bit mode (typically uses limited range)
        if let hdrMode = controller.findMode(
            for: displayID,
            bitDepth: 10
        ) {
            try controller.setMode(hdrMode, for: displayID)
        }
    }

    func toggleRGBRange() async throws {
        let displayID = CGMainDisplayID()

        try controller.toggleRGBRange(for: displayID)
    }
}
```

### Advanced Features

```swift
// Get display capabilities
let capabilities = controller.displayCapabilities(for: displayID)
print(capabilities.description)
// Output:
// Bit Depth: 8-bit, 10-bit
// Encodings: RGB, YCbCr 4:4:4
// RGB Range: Full, Limited
// HDR: Supported
// Max Refresh: 120 Hz
// Resolutions: 3840×2160, 2560×1440, 1920×1080

// Use enhanced IOKit parsing for better accuracy
let enhancedModes = controller.availableModesEnhanced(for: displayID)

// Find specific mode matching criteria
if let targetMode = controller.findMode(
    for: displayID,
    bitDepth: 10,
    colorEncoding: .rgb,
    range: .limited,
    matchCurrentTiming: true  // Keep same resolution/refresh
) {
    try controller.setMode(targetMode, for: displayID)
}
```

## API Reference

### DisplayMode Structure

```swift
struct DisplayMode {
    let cgMode: CGDisplayMode          // CoreGraphics mode reference
    let bitDepth: Int                  // 8, 10, 12, etc.
    let colorEncoding: ColorEncoding   // RGB, YCbCr variants
    let range: RGBRange                // Full, Limited, Auto
    let refreshRate: Double            // Hz
    let resolution: Resolution         // Width × Height
    let pixelEncoding: String?         // Raw encoding string
}
```

### Main Methods

| Method | Description |
|--------|-------------|
| `availableModes(for:)` | Get all display modes |
| `availableModesEnhanced(for:)` | Get modes with IOKit enhancement |
| `currentMode(for:)` | Get current display mode |
| `encodingVariants(for:matchingCurrent:)` | Get modes with same timing |
| `setMode(_:for:)` | Change display mode |
| `findMode(for:bitDepth:colorEncoding:range:matchCurrentTiming:)` | Find specific mode |
| `displayCapabilities(for:)` | Get display capabilities |
| `toggleRGBRange(for:)` | Toggle between Full/Limited range |
| `setSDRMode(for:)` | Switch to 8-bit SDR |
| `setHDRMode(for:)` | Switch to 10-bit HDR |

### Error Handling

```swift
enum DisplayModeError: LocalizedError {
    case modeNotSupported       // Mode not available on display
    case modeChangeFailed(CGError)  // CoreGraphics error
    case displayNotFound        // Invalid display ID
    case permissionDenied       // Insufficient permissions
    case invalidConfiguration   // Configuration error
}
```

## Implementation Details

### CoreGraphics Integration

The controller uses CoreGraphics APIs for mode management:
- `CGDisplayCopyAllDisplayModes()` - Enumerate modes
- `CGDisplayCopyDisplayMode()` - Get current mode
- `CGDisplaySetDisplayMode()` - Change mode
- `CGBeginDisplayConfiguration()` - Start configuration
- `CGCompleteDisplayConfiguration()` - Apply changes

### IOKit Enhancement

For improved pixel encoding detection, the controller can query IOKit:
- Searches for `IODisplayConnect` services
- Matches displays by vendor/product IDs
- Extracts properties like HDR support, bit depth, pixel formats
- Provides more accurate encoding information than CoreGraphics alone

### Thread Safety

The controller is marked with `@MainActor` and should be used from the main thread. Display configuration changes affect the UI and must be performed on the main thread.

### Logging

Comprehensive logging via `os.log` with subsystem `com.chromaflow.display`:
- Mode enumeration results
- Mode changes with before/after info
- Errors and permission issues
- Available encoding configurations

## Testing

Use the included test file to verify functionality:

```swift
await testDisplayModeController()
```

This will:
1. List current display mode
2. Enumerate all available modes
3. Find encoding variants
4. Test IOKit enhancement
5. Query display capabilities
6. Find specific mode configurations

## Requirements

- macOS 10.15+
- Swift 5.5+
- Frameworks: CoreGraphics, IOKit

## Notes

- Mode changes are persistent across reboots when using `.permanently` option
- Some displays may not support all encoding combinations
- HDR modes typically use limited RGB range (16-235)
- YCbCr modes may be available on external displays via HDMI
- Actual pixel encoding support depends on display and connection type

## Comparison with Better Display

This implementation provides similar functionality to Better Display's RGB format controls:
- Switches between SDR/HDR modes (8-bit vs 10-bit+)
- Controls RGB range (Full vs Limited)
- Detects color encoding formats
- Lists only relevant encoding variants for current resolution

## Future Enhancements

- [ ] Monitor display mode change notifications
- [ ] Profile-based mode switching
- [ ] Automatic HDR detection based on content
- [ ] Integration with ColorSync profiles
- [ ] Support for custom modelines