# ChromaFlow Build Instructions

## Building ChromaFlow macOS App

ChromaFlow is a menu bar application for macOS that manages display color profiles and brightness.

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15+ or Swift 5.9+ toolchain
- Git (for dependency management)

### Build Methods

#### Option 1: Using Xcode (Recommended)

1. Open Package.swift in Xcode:
   ```bash
   open Package.swift
   ```

2. Wait for package dependencies to resolve (KeyboardShortcuts, LaunchAtLogin)

3. Select the "ChromaFlow" scheme from the scheme selector

4. Build and run: `Cmd+R`

5. The app will launch as a menu bar application (look for the drop icon in your menu bar)

#### Option 2: Command Line Build

1. Build the executable:
   ```bash
   swift build
   ```

2. Run the built executable:
   ```bash
   .build/debug/ChromaFlow
   ```

3. The app will launch as a menu bar application

#### Option 3: Release Build

For an optimized release build:

```bash
swift build -c release
.build/release/ChromaFlow
```

### Package Configuration

The Package.swift is configured with:

- **Platform**: macOS 14.0+
- **Dependencies**:
  - KeyboardShortcuts (2.0.0+) - Global hotkey support
  - LaunchAtLogin-Modern (1.0.0+) - Launch at login functionality
  - DDCKit (local package) - Display hardware control

- **Resources**:
  - Assets.xcassets - App icons and visual assets
  - Localizable.xcstrings - Localization strings

- **Excluded Files**:
  - ChromaFlow.entitlements (managed separately in Xcode)
  - Info.plist (managed separately)
  - Documentation files

### Entry Point

The application entry point is defined in `ChromaFlow/ChromaFlowApp.swift`:

```swift
@main
struct ChromaFlowApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("ChromaFlow", systemImage: "drop.fill") {
            PopoverContentView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

This creates a menu bar extra (status bar item) with a popover interface.

### Entitlements

ChromaFlow requires specific entitlements (defined in ChromaFlow.entitlements):

- **App Sandbox**: Disabled (`com.apple.security.app-sandbox: false`)
  - Required for direct hardware access (DDC/CI control)

- **USB Device Access**: Enabled (`com.apple.security.device.usb: true`)
  - Required for display hardware communication

### Troubleshooting

**Issue**: "ChromaFlow" can't be opened because Apple cannot check it for malicious software
- **Solution**: Right-click the app and select "Open", or run `xattr -cr .build/debug/ChromaFlow`

**Issue**: Menu bar icon doesn't appear
- **Solution**: Check System Preferences > Control Center > Menu Bar Only to ensure menu bar extras are visible

**Issue**: Display control not working
- **Solution**: Ensure the app is not sandboxed and has proper entitlements configured

**Issue**: Build fails with unresolved dependencies
- **Solution**: Run `swift package resolve` to fetch dependencies

### Project Structure

```
ChromaFlow/
├── App/                    # Application state and initialization
├── DisplayEngine/          # Color correction and gamma control
├── HardwareBridge/         # DDC/CI hardware communication
├── Models/                 # Data models (profiles, devices, automation)
├── Persistence/            # Storage layer (device memory, profiles)
├── UI/                     # SwiftUI views and components
├── Utilities/              # Helper functions and extensions
└── Resources/              # Assets and localization
```

### Running Tests

Currently, the project includes executable targets only. To add tests:

1. Add a test target to Package.swift:
   ```swift
   .testTarget(
       name: "ChromaFlowTests",
       dependencies: ["ChromaFlow"]
   )
   ```

2. Create test files in `Tests/ChromaFlowTests/`

3. Run tests: `swift test`

### Next Steps

- To create an Xcode project: The Package.swift already provides full Xcode integration
- To distribute: Archive in Xcode and export as a signed application
- To add code signing: Configure in Xcode project settings or add signing identity to build
