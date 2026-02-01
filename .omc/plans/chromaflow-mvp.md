# ChromaFlow MVP Implementation Plan

## Overview

This plan covers the complete MVP (Phase 1) of ChromaFlow: a macOS menubar app for professional color management and DDC hardware control. The MVP is broken into 4 mini-phases over 6 weeks, ordered by dependency chain: project scaffold and models first, then display engine and ColorSync integration, then DDC hardware control, and finally UI polish with system integration.

**Starting point:** Greenfield. No code exists yet.
**End state:** A signed, notarized macOS menubar app that switches color profiles per-display, controls external monitor brightness/contrast via DDC/CI, persists settings per-monitor, supports Korean/English localization, and is fully VoiceOver accessible.

**Total tasks:** 27 (updated from 26 to include localization task A7)

---

## Phase A: Foundation & Scaffold (Week 1)

**Goal:** Xcode project compiles and runs as a menubar app with stub UI. All data models, protocols, logging, and the local DDCKit package exist. No real hardware interaction yet.

### Task A1: Create Xcode Project and SPM Structure
**Files:** `ChromaFlow.xcodeproj`, `ChromaFlow/App/ChromaFlowApp.swift`, `Package.swift` (workspace-level), `Packages/DDCKit/Package.swift`
**Work:**
- Create a new macOS App project targeting macOS 15.0, Swift 5.9
- Set `SWIFT_STRICT_CONCURRENCY = complete` in build settings
- Configure `MenuBarExtra` as the app's primary scene (no dock icon)
- Set up `Info.plist` with `LSUIElement = true` (agent app)
- Create the `Packages/DDCKit/` local SPM package with empty sources
- Add SPM dependencies: `KeyboardShortcuts` (2.x), `LaunchAtLogin-Modern` (~> 1.0)
- Do NOT add Sparkle yet (Phase 2)
- Create `ChromaFlow.entitlements` with `com.apple.security.device.usb`

**Acceptance criteria:**
- `xcodebuild -scheme ChromaFlow build` succeeds
- App launches and shows a menubar icon (system default symbol)
- DDCKit package resolves and links

### Task A2: Define All Data Models
**Files:** `ChromaFlow/Models/ColorProfile.swift`, `DisplayDevice.swift`, `DDCCapabilities.swift`, `AutomationRule.swift`, `AutomationAction.swift`
**Work:**
- Implement `ColorProfile` struct with `ColorSpace` enum (sRGB, displayP3, adobeRGB, rec709, rec2020, custom)
- Implement `DisplayDevice` struct with `ConnectionType` enum and `CGDirectDisplayID` as id
- Implement `DDCCapabilities` struct (supportsBrightness, supportsContrast, supportsColorTemperature, max values)
- All models: `Identifiable`, `Codable`, `Sendable`
- Stub `AutomationRule` and `AutomationAction` (will be used in Phase 2 but define shape now)

**Acceptance criteria:**
- All model files compile with strict concurrency
- Round-trip Codable test for each model passes
- Models conform to Sendable without `@unchecked`

### Task A3: Define Core Protocols
**Files:** `ChromaFlow/DisplayEngine/Protocols/DisplayProfileManaging.swift`, `DisplayDetecting.swift`, `ChromaFlow/HardwareBridge/DDC/DDCProtocol.swift` (renamed from `DDCDeviceControlling`), `ChromaFlow/UI/Theme/UIThemeEngine.swift`
**Work:**
- `DisplayProfileManaging` protocol (availableProfiles, activeProfile, switchProfile, lock/unlock)
- `DisplayDetecting` protocol (events: AsyncStream<DisplayEvent>, connectedDisplays)
- `DDCDeviceControlling` protocol (readVCP, writeVCP, setBrightness, setContrast, setColorTemperature, capabilities)
- `UIThemeProviding` protocol (popoverMaterial, interactionSpring, supportsAdaptiveGlass)
- Define `DisplayEvent` enum: `.connected(DisplayDevice)`, `.disconnected(CGDirectDisplayID)`, `.profileChanged(CGDirectDisplayID)`
- Define `VCPCode` enum in `DDCKit/Sources/DDCKit/VCPCodes.swift`

**Acceptance criteria:**
- All protocols compile with `Sendable` conformance
- VCPCodes covers brightness (0x10), contrast (0x12), colorTemperature (0x14), inputSource (0x60)

### Task A4: Logging Infrastructure
**Files:** `ChromaFlow/Utilities/Logger.swift`, `ChromaFlow/Utilities/FeatureFlags.swift`
**Work:**
- Create `os.Logger` instances for subsystems: `com.chromaflow.display`, `com.chromaflow.ddc`, `com.chromaflow.ui`, `com.chromaflow.automation`, `com.chromaflow.persistence`
- Create `FeatureFlags` struct with static properties: `builtInBrightness: Bool`, `nightShiftDetection: Bool`, `ioKitAmbientLight: Bool` (all default false for MVP)
- Feature flags backed by UserDefaults for runtime toggling

**Acceptance criteria:**
- Logger messages appear in Console.app filtered by subsystem
- Feature flags can be toggled via `defaults write` command

### Task A5: Constants and Color Space Definitions
**Files:** `ChromaFlow/App/Constants.swift`, `ChromaFlow/DisplayEngine/ColorSpaceDefinitions.swift`
**Work:**
- Define app-wide constants (bundle ID, default profile IDs, DDC timing constants)
- Map `ColorSpace` enum cases to system ICC profile URLs:
  - `.sRGB` -> `/System/Library/ColorSync/Profiles/sRGB Profile.icc`
  - `.displayP3` -> `/System/Library/ColorSync/Profiles/Display P3.icc`
  - `.adobeRGB` -> `/System/Library/ColorSync/Profiles/Adobe RGB (1998).icc` (may need to bundle)
  - `.rec709` -> bundled `ChromaFlow-Rec709.icc`
- Verify each system ICC path exists on macOS 15

**Acceptance criteria:**
- All ICC profile URLs resolve to valid files (unit test)
- Constants compile and are accessible from any module

### Task A6: App State and Observable Store
**Files:** `ChromaFlow/App/AppState.swift`
**Work:**
- Create `@Observable @MainActor class AppState` with:
  - `displays: [DisplayDevice]`
  - `activeProfiles: [CGDirectDisplayID: ColorProfile]`
  - `selectedDisplayID: CGDirectDisplayID?`
  - `ddcValues: [CGDirectDisplayID: DDCValues]` (brightness, contrast as Double)
  - `isNightShiftActive: Bool`
  - `isTrueToneActive: Bool`
- `DDCValues` struct: brightness, contrast as Double (0.0-1.0)

**Acceptance criteria:**
- AppState compiles under strict concurrency with `@MainActor` isolation
- SwiftUI preview can instantiate AppState with mock data

### Task A7: Localization Infrastructure
**Files:** `ChromaFlow/Resources/Localizable.xcstrings`, update `Info.plist`
**Work:**
- Set up String Catalog (`Localizable.xcstrings`) for Korean (ko) and English (en) as base
- Extract all user-facing strings to use `String(localized:)` or `NSLocalizedString()`
- Key strings to localize (MVP minimum):
  - Profile names: "sRGB", "Display P3", "Adobe RGB", "Rec. 709"
  - UI labels: "Brightness", "Contrast", "Revert to Previous", "DDC Not Supported"
  - Conflict warnings: "Night Shift is active", "Competing app detected"
  - Toast messages: "Profile activated", "Failed to switch profile"
- Set `CFBundleDevelopmentRegion` to "en" and `CFBundleLocalizations` to ["en", "ko"] in Info.plist
- Provide Korean translations for all MVP strings

**Acceptance criteria:**
- Switching system language to Korean shows Korean UI strings
- Switching to English shows English UI strings
- All user-visible text is localized (no hardcoded English strings in views)
- String catalog compiles without warnings

---

## Phase B: Display Engine & ColorSync (Weeks 2-3)

**Goal:** Profile switching works end-to-end. Display hot-plug detection works. Per-monitor settings persist. The menubar UI shows real display data and lets users switch profiles.

### Task B1: Display Detector with Hot-Plug
**Files:** `ChromaFlow/DisplayEngine/DisplayDetector.swift`, `ChromaFlow/Utilities/EDIDParser.swift`
**Work:**
- Implement `DisplayDetector` conforming to `DisplayDetecting`
- Use `CGDisplayRegisterReconfigurationCallback` for hot-plug events
- On callback: enumerate `CGGetActiveDisplayList`, build `DisplayDevice` for each
- `EDIDParser`: extract manufacturer, model, serial from EDID via `IODisplayConnect` IOKit service
- Identify built-in display via `CGDisplayIsBuiltin()`
- Connection type detection via IOKit service plane traversal (HDMI, DP, USB-C, Thunderbolt)
- Publish changes via `AsyncStream<DisplayEvent>`

**Acceptance criteria:**
- Connecting/disconnecting an external monitor fires `.connected`/`.disconnected` events
- Each display has a non-empty name and manufacturer parsed from EDID
- Built-in display is correctly identified
- Unit test with mock IOKit data verifies EDID parsing

### Task B2: Profile Manager with ColorSync Integration
**Files:** `ChromaFlow/DisplayEngine/ProfileManager.swift`
**Work:**
- Implement `ProfileManager` conforming to `DisplayProfileManaging`
- `switchProfile()`:
  1. Resolve ICC profile URL from `ColorSpaceDefinitions`
  2. Call `ColorSyncDeviceSetCustomProfiles()` with the display's ColorSync UUID
  3. Map `CGDirectDisplayID` to ColorSync device UUID via `ColorSyncDeviceCopyDeviceInfo()`
  4. Verify switch by reading back active profile
- `activeProfile()`: query `ColorSyncDeviceCopyDeviceInfo()` for current profile
- `availableProfiles()`: return the 4 bundled profiles + any custom ones from disk
- Handle errors: profile not found, ColorSync failure, display disconnected

**Acceptance criteria:**
- Switching to sRGB on the built-in display changes the profile (verifiable via System Preferences > Displays > Color)
- Switch completes in < 200ms (measured with `os_signpost`)
- Switching back restores the original profile
- Error case: switching on a disconnected display returns appropriate error

### Task B3: Display Engine Actor
**Files:** `ChromaFlow/DisplayEngine/DisplayEngineActor.swift`
**Work:**
- Create `actor DisplayEngineActor` that owns `ProfileManager` and `DisplayDetector`
- Public API:
  - `func switchProfile(_ profile: ColorProfile, for displayID: CGDirectDisplayID) async throws -> ProfileSwitchConfirmation`
  - `func connectedDisplays() async -> [DisplayDevice]`
  - `var displayEvents: AsyncStream<DisplayEvent> { get }`
- On display connect: auto-restore last profile from `DeviceMemory`
- On display disconnect: clean up state
- Thread safety: all mutable state is actor-isolated

**Acceptance criteria:**
- Concurrent profile switch requests are serialized (no race conditions)
- Display events propagate to subscribers
- Actor compiles without any strict concurrency warnings

### Task B4: Device Memory (Per-Monitor Persistence)
**Files:** `ChromaFlow/Persistence/DeviceMemory.swift`, `ChromaFlow/Persistence/ProfileStore.swift`
**Work:**
- `DeviceMemory`: stores per-monitor settings keyed by EDID serial number (or manufacturer+model hash if no serial)
- Storage: JSON files in `~/Library/Application Support/ChromaFlow/devices/`
- Data stored per device: last active profile, last DDC brightness, last DDC contrast
- `ProfileStore`: stores custom user profiles in `~/Library/Application Support/ChromaFlow/profiles/`
- Auto-save on every change (debounced 500ms)
- Auto-restore on display connect

**Acceptance criteria:**
- After switching a profile and restarting the app, the same profile is active
- Connecting a previously-seen monitor restores its last settings
- Corrupt JSON files are handled gracefully (reset to defaults)

### Task B5: System Conflict Detector
**Files:** `ChromaFlow/Utilities/SystemConflictDetector.swift`
**Work:**
- Detect Night Shift status: try dynamic loading of `CBBlueLightClient` from CoreBrightness framework
  - `dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)`
  - If unavailable: report "unknown" status
- Detect True Tone status: similar approach via CoreBrightness
- Detect competing apps: check `NSRunningApplication` for bundle IDs of MonitorControl, BetterDisplay, Lunar, f.lux
- Publish conflicts to AppState for UI warning display
- All behind `FeatureFlags.nightShiftDetection`

**Acceptance criteria:**
- When Night Shift is enabled, `isNightShiftActive` becomes true (if API available)
- When MonitorControl is running, a conflict warning is surfaced
- When private API is unavailable, graceful fallback to "unknown" (no crash)

### Task B6: Menubar Popover UI - Profile Switcher
**Files:** `ChromaFlow/App/ChromaFlowApp.swift` (update), `ChromaFlow/UI/Popover/PopoverContentView.swift`, `ChromaFlow/UI/Popover/ProfileSwitcherView.swift`, `ChromaFlow/UI/Popover/DisplaySelectorView.swift`, `ChromaFlow/UI/MenuBar/MenuBarView.swift`
**Work:**
- `ChromaFlowApp`: `MenuBarExtra` with `.window` style for popover
- `PopoverContentView`: top-level layout with display selector and profile switcher
- `DisplaySelectorView`: horizontal picker showing connected displays (icon + name)
- `ProfileSwitcherView`: vertical list of profiles (sRGB, P3, AdobeRGB, Rec.709) with checkmark on active
- Tapping a profile calls `DisplayEngineActor.switchProfile()` and updates UI
- **Undo/Revert:** Add "Revert to Previous" button that restores last-known-good profile (from DeviceMemory)
- Show conflict warnings (Night Shift, competing apps) as a banner at top
- Menubar icon: SF Symbol `drop.fill` (placeholder; custom icon in Phase D)
- **Accessibility:** Add `.accessibilityLabel()` to all buttons and pickers, `.accessibilityValue()` for active profile state, `.accessibilityHint()` for switcher actions

**Acceptance criteria:**
- Clicking menubar icon opens popover with real display list
- Selecting a profile switches the ColorSync profile on the selected display
- Active profile shows checkmark
- **"Revert to Previous" button restores the previous profile (testable with 2 switches then revert)**
- Conflict warnings display when applicable
- Popover closes on outside click
- **VoiceOver can navigate all controls and announces current profile state**

### Task B7: Gamma Controller (Slider Foundation)
**Files:** `ChromaFlow/DisplayEngine/GammaController.swift`, `ChromaFlow/Utilities/Debouncer.swift`
**Work:**
- `GammaController`: wraps `CGSetDisplayTransferByTable` for real-time gamma/LUT adjustments
- API: `func setGamma(red: [Float], green: [Float], blue: [Float], for displayID: CGDirectDisplayID)`
- `Debouncer`: generic debouncer utility (configurable delay, default 16ms for slider path)
- Color temperature adjustment via gamma table manipulation (warm = boost red, reduce blue)
- Reset gamma: `CGDisplayRestoreColorSyncSettings()` to return to ICC profile defaults

**Acceptance criteria:**
- Setting a warm color temperature visibly shifts the screen orange
- Resetting gamma returns to normal
- Gamma update takes < 1ms (synchronous CoreGraphics call)
- Debouncer correctly coalesces rapid calls

---

## Phase C: DDC Hardware Integration (Weeks 4-5)

**Goal:** External monitors controlled via DDC/CI for brightness and contrast. DDCKit local package is functional. Full end-to-end hardware control from UI sliders.

### Task C1: DDCKit Package - I2C Core
**Files:** `Packages/DDCKit/Sources/DDCKit/I2CTransport.swift`, `Packages/DDCKit/Sources/DDCKit/DDCInterface.swift`, `Packages/DDCKit/Sources/DDCKit/VCPCodes.swift`
**Work:**
- Study MonitorControl's `Arm64DDC.swift` implementation (MIT license)
- Implement `I2CTransport` protocol:
  - `func write(service: io_service_t, address: UInt8, data: [UInt8]) throws`
  - `func read(service: io_service_t, address: UInt8, length: Int) throws -> [UInt8]`
- ARM64 implementation using `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`
  - Dynamic loading via `dlopen`/`dlsym` for IOKit symbols
  - Fallback: return `.unsupported` error if symbols not found
- DDC/CI protocol framing:
  - Write: `[0x51, length, opcode, ...payload, checksum]`
  - Read: parse VCP reply `[0x02, length, result_code, vcp_code, type, max_high, max_low, cur_high, cur_low, checksum]`
- `VCPCodes` enum: brightness (0x10), contrast (0x12), colorTemp (0x14), inputSource (0x60), powerMode (0xD6)

**Acceptance criteria:**
- DDCKit compiles as standalone SPM package
- I2C write builds correct DDC/CI frame with valid checksum
- I2C read parses VCP reply correctly (unit test with known byte sequences)
- Dynamic loading gracefully fails on unsupported systems

### Task C2: DDCKit Package - Capability Detection
**Files:** `Packages/DDCKit/Sources/DDCKit/DDCCapabilityDetector.swift`, `Packages/DDCKit/Sources/DDCKit/EDIDReader.swift`
**Work:**
- `DDCCapabilityDetector`:
  1. Read EDID to confirm external display
  2. Query VCP capability string (command 0xF3) - parse response
  3. Test write/read cycle on brightness (0x10) as probe
  4. Build `DDCCapabilities` struct from results
- `EDIDReader`: read EDID block from IOKit display service
- Handle common failure modes:
  - Monitor doesn't respond to I2C at all
  - Monitor responds but doesn't support specific VCP codes
  - USB-C/Thunderbolt displays that route I2C differently
- Timeout: 200ms per command, 3 retries with exponential backoff (100ms, 200ms, 400ms)

**Acceptance criteria:**
- On a DDC-capable external monitor: capabilities detected correctly
- On built-in display: correctly reports "DDC not supported"
- On unresponsive monitor: times out gracefully, returns empty capabilities
- Unit tests with mocked I2C transport verify detection logic

### Task C3: DDC Actor
**Files:** `ChromaFlow/HardwareBridge/DDC/DDCActor.swift`, `ChromaFlow/HardwareBridge/DDC/Arm64DDCAdapter.swift`
**Work:**
- `actor DDCActor` with dedicated serial executor
- 50ms minimum inter-command delay (hardware requirement)
- Command queue: FIFO with priority (brightness/contrast are high-priority)
- `Arm64DDCAdapter`: conforms to `DDCDeviceControlling`, wraps DDCKit's I2C transport
- API:
  - `func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) async throws`
  - `func setContrast(_ value: Double, for displayID: CGDirectDisplayID) async throws`
  - `func readBrightness(for displayID: CGDirectDisplayID) async throws -> Double`
  - `func readContrast(for displayID: CGDirectDisplayID) async throws -> Double`
  - `func detectCapabilities(for displayID: CGDirectDisplayID) async -> DDCCapabilities`
- Map `CGDirectDisplayID` to IOKit service for I2C access
- After 3 consecutive failures on a display: mark DDC as disabled, surface warning

**Acceptance criteria:**
- Setting brightness to 50% on an external monitor physically changes brightness
- Reading brightness returns the current hardware value
- Concurrent requests from multiple UI sliders are serialized (no I2C collision)
- 50ms delay between commands is enforced
- Failed display is marked as DDC-disabled after 3 consecutive errors

### Task C4: Brightness/Contrast Sliders UI
**Files:** `ChromaFlow/UI/Popover/BrightnessContrastSliders.swift` (update `PopoverContentView.swift` to include)
**Work:**
- Brightness slider: 0-100% range, updates DDCActor on change
- Contrast slider: 0-100% range, updates DDCActor on change
- Debounced: 16ms debounce on slider movement, fire-and-forget async DDC command
- Show current hardware value on initial load (read from DDCActor)
- Disable sliders (grayed out) when DDC is not supported for selected display
- Show "DDC Not Supported" label for built-in displays or unsupported monitors
- Haptic feedback at min/max boundaries (NSHapticFeedbackManager)
- **Accessibility:** Add `.accessibilityLabel("Brightness")`, `.accessibilityValue("\(Int(brightness))%")`, `.accessibilityAdjustableAction()` for increment/decrement support

**Acceptance criteria:**
- Moving brightness slider physically changes external monitor brightness
- Slider starts at the current hardware brightness value
- Slider is disabled for built-in display with explanatory text
- **VoiceOver announces slider value and allows adjustment via rotor actions**
- Haptic feedback fires at 0% and 100%
- No UI stutter during rapid slider movement (DDC commands are fire-and-forget)

### Task C5: Wire DDC to Device Memory
**Files:** Update `ChromaFlow/Persistence/DeviceMemory.swift`, `ChromaFlow/HardwareBridge/DDC/DDCActor.swift`
**Work:**
- After each successful DDC write, persist the value to DeviceMemory (debounced 500ms)
- On display connect: if DDC capable, restore last brightness/contrast from DeviceMemory
- Key format: EDID serial or manufacturer+model hash
- Handle edge case: monitor was at 100% when disconnected, user doesn't want 100% on reconnect -> respect stored value

**Acceptance criteria:**
- Disconnect and reconnect external monitor: brightness restores to last-set value
- Restart app with external monitor connected: brightness restores
- DeviceMemory JSON file contains DDC values per device

---

## Phase D: System Integration & Polish (Week 6)

**Goal:** Login item works, keyboard shortcuts work, the app is polished enough for dogfooding. Basic theming applied. Build is signed and notarized.

### Task D1: Login Item (Launch at Login)
**Files:** `ChromaFlow/App/ChromaFlowApp.swift` (update), Settings UI
**Work:**
- Integrate `LaunchAtLogin-Modern` package
- Add toggle in popover footer or settings: "Launch at Login"
- Uses `SMAppService.mainApp` under the hood (macOS 13+)

**Acceptance criteria:**
- Enabling toggle and logging out/in: ChromaFlow starts automatically
- Toggle state persists across app restarts

### Task D2: Keyboard Shortcuts
**Files:** `ChromaFlow/App/KeyboardShortcutBindings.swift`, update `PopoverContentView.swift`
**Work:**
- Integrate `KeyboardShortcuts` package
- Define shortcut names: `.switchToSRGB`, `.switchToP3`, `.switchToAdobeRGB`, `.switchToRec709`, `.togglePopover`
- Register handlers that call `DisplayEngineActor.switchProfile()`
- Add shortcut hints in profile switcher UI (right-aligned text)
- Allow customization in a future settings window (for now, define defaults)
- Defaults: Cmd+Shift+1 through 4 for profiles, Cmd+Shift+C for popover toggle

**Acceptance criteria:**
- Pressing Cmd+Shift+1 switches to sRGB regardless of popover state
- Shortcut hints appear in profile switcher UI
- Shortcuts work when popover is closed

### Task D3: Sleep/Wake Profile Restoration
**Files:** `ChromaFlow/App/AppDelegate.swift`
**Work:**
- Register for `NSWorkspace.willSleepNotification` and `didWakeNotification`
- On wake: re-apply active profiles for all connected displays (macOS often resets on wake)
- On wake: re-detect displays (hot-plug may have changed during sleep)
- Delay 2 seconds after wake before re-applying (displays need time to initialize)

**Acceptance criteria:**
- After sleep/wake, the custom profile is re-applied (not reset to system default)
- If a display was disconnected during sleep, it's properly removed from state

### Task D4: Sequoia Theme Implementation
**Files:** `ChromaFlow/UI/Theme/SequoiaTheme.swift`, `ChromaFlow/UI/Theme/GlassEffects.swift`, `ChromaFlow/UI/Theme/ElasticAnimations.swift`
**Work:**
- `SequoiaTheme` conforming to `UIThemeProviding`
- Popover material: `.ultraThinMaterial` background
- Elastic spring animation: `spring(response: 0.35, dampingFraction: 0.86)`
- Glass effect: rounded rectangle with blur + vibrancy
- Shadow-based depth (organic depth): no hard dividers, use shadow layers
- Apply theme to all popover views

**Acceptance criteria:**
- Popover has glassmorphic background with blur
- Profile switches animate with spring physics
- No hard lines or dividers in the UI (shadows only)

### Task D5: Custom Menubar Icon
**Files:** `ChromaFlow/Resources/Assets.xcassets/` (AppIcon, MenuBarIcon)
**Work:**
- Create menubar icon: droplet shape, 16x16 and 18x18 @1x/@2x
- Template image (white, system-tinted) for menubar
- AppIcon for About/Settings: full-color droplet
- Add to asset catalog with proper template rendering mode

**Acceptance criteria:**
- Menubar shows custom droplet icon (not SF Symbol)
- Icon adapts to light/dark mode (template image)
- About window shows full-color app icon

### Task D6: Error States and Toast Notifications
**Files:** `ChromaFlow/UI/Popover/ToastView.swift`, update `PopoverContentView.swift`
**Work:**
- Toast notification view: appears at top of popover, auto-dismisses after 3 seconds
- Toast types: success ("P3 Activated"), warning ("Night Shift Active"), error ("DDC Failed")
- Surface DDC errors: "Monitor not responding", "DDC not supported"
- Surface conflict warnings: "Night Shift is active and may interfere with color profiles"
- Animate in/out with spring

**Acceptance criteria:**
- Profile switch shows success toast
- DDC failure shows error toast with explanation
- Night Shift conflict shows persistent warning banner
- Toasts auto-dismiss and don't stack

### Task D7: Code Signing, Notarization, and DMG
**Files:** `Scripts/notarize.sh`, `Scripts/create-dmg.sh`
**Work:**
- Code signing script using `codesign` with Developer ID certificate
- Notarization via `xcrun notarytool submit`
- DMG creation with drag-to-Applications shortcut
- Entitlements: `com.apple.security.device.usb`, `com.apple.security.app-sandbox = NO` (need direct IOKit access)
- Hardened Runtime enabled

**Acceptance criteria:**
- `codesign --verify` passes
- `spctl --assess` returns accepted
- DMG mounts and app installs correctly
- GateKeeper does not show warnings on first launch

### Task D8: Unit and Integration Tests
**Files:** `Tests/ChromaFlowTests/DisplayEngine/`, `Tests/ChromaFlowTests/HardwareBridge/`, `Tests/ChromaFlowTests/Models/`, `Tests/ChromaFlowUITests/AccessibilityTests.swift`
**Work:**
- Model tests: Codable round-trip for all models
- ProfileManager tests: mock ColorSync calls, verify profile switching logic
- DDCKit tests: mock I2C transport, verify frame building, checksum, parsing
- DisplayDetector tests: mock CGDisplay functions, verify hot-plug event emission
- DeviceMemory tests: write/read/corrupt file handling
- EDIDParser tests: known EDID byte sequences parsed correctly
- Integration test: full profile switch flow with mocked hardware layer
- Performance test: profile switch completes in < 200ms (`XCTMetric`)
- **VoiceOver accessibility tests:**
  - UI test with VoiceOver enabled: verify all controls have accessibility labels
  - Test rotor navigation through profile switcher and sliders
  - Test VoiceOver value announcements for active profile and slider positions
  - Test accessibility actions (increment/decrement sliders, activate profile buttons)

**Acceptance criteria:**
- `xcodebuild test` passes with 0 failures
- Code coverage > 70% for DisplayEngine and HardwareBridge modules
- Performance test validates < 200ms profile switch
- **VoiceOver UI tests pass: all controls navigable, values announced correctly**

---

## Critical Path

The critical path determines what blocks what. Tasks off the critical path can be parallelized.

```
A1 (Xcode Project)
 |
 +---> A2 (Models) ---> A3 (Protocols) ---> B1 (Display Detector)
 |                                      |
 |                                      +---> B2 (Profile Manager) ---> B3 (Display Engine Actor)
 |                                      |                                    |
 |                                      +---> B7 (Gamma Controller)          |
 |                                                                           |
 +---> A4 (Logging) ----+                                                    |
 |                       |                                                   v
 +---> A5 (Constants) ---+---> B4 (Device Memory) ---------> B6 (Popover UI)
 |                       |                                        |
 +---> A6 (AppState) ----+                                        v
                                                             C4 (Sliders UI)
                                                                  |
 A1 ---> C1 (DDCKit I2C) ---> C2 (Capability Detection)          |
                                    |                             |
                                    v                             |
                               C3 (DDC Actor) ---------> C4 (Sliders UI)
                                    |
                                    v
                               C5 (DDC + DeviceMemory)

Phase D tasks (D1-D8) depend on Phase B+C completion but are parallelizable with each other.
```

**Critical chain:** A1 -> A2 -> A3 -> B2 -> B3 -> B6 -> C4

**Parallelizable streams:**
- Stream 1 (Display): A2 -> A3 -> B1 -> B3
- Stream 2 (ColorSync): A5 -> B2 -> B3
- Stream 3 (DDC): C1 -> C2 -> C3 -> C4
- Stream 4 (Persistence): A6 -> B4 -> C5
- Stream 5 (UI): B6 -> C4 -> D4 -> D5

---

## Success Criteria

The MVP is complete when ALL of the following are true:

### Functional Checklist
- [ ] App launches as menubar-only agent (no dock icon)
- [ ] Menubar icon opens popover with display list
- [ ] All connected displays detected and shown by name
- [ ] External display connect/disconnect updates UI in real-time
- [ ] Switching between sRGB, P3, AdobeRGB, Rec.709 works on each display independently
- [ ] Profile switch persists across app restart
- [ ] Profile re-applies after sleep/wake
- [ ] DDC brightness slider controls external monitor brightness
- [ ] DDC contrast slider controls external monitor contrast
- [ ] DDC values persist per-monitor across restart
- [ ] DDC sliders disabled for unsupported monitors with explanation
- [ ] Night Shift / True Tone conflict warning displayed
- [ ] Competing app (MonitorControl, Lunar) conflict warning displayed
- [ ] Launch at Login toggle works
- [ ] Keyboard shortcuts switch profiles globally
- [ ] Toast notifications for profile switches and errors
- [ ] **"Revert to Previous" button restores last profile**
- [ ] **Korean/English localization: UI switches language based on system setting**
- [ ] **VoiceOver can navigate all controls and announces state correctly**

### Performance Checklist
- [ ] Profile switch < 200ms (measured with os_signpost)
- [ ] Memory < 50MB at idle (measured with Instruments)
- [ ] CPU < 0.5% at idle (measured with Activity Monitor over 30s)
- [ ] Slider interaction < 16ms to gamma update
- [ ] DDC command < 200ms round-trip

### Quality Checklist
- [ ] Zero strict concurrency warnings
- [ ] All tests pass (`xcodebuild test`)
- [ ] Code coverage > 70% for DisplayEngine and HardwareBridge
- [ ] App signed with Developer ID and notarized
- [ ] No GateKeeper warnings on clean install

---

## Risk Mitigation

### Risk 1: DDC/CI Unreliability
**Problem:** Many monitors have buggy DDC implementations. Some USB-C hubs block I2C. Some monitors respond to reads but ignore writes.
**Mitigation:**
- Three-tier capability detection (EDID -> Capability String -> Test Write/Read)
- After 3 consecutive failures: disable DDC for that display, show warning
- Log all I2C failures for diagnostics
- 50ms inter-command delay, 200ms timeout, exponential backoff
- Test on at least 3 different monitor brands before shipping

### Risk 2: Private API Breakage (Night Shift/True Tone Detection)
**Problem:** `CBBlueLightClient` and CoreBrightness are private. Apple could remove or change them.
**Mitigation:**
- All private API access via `dlopen`/`dlsym` (no link-time dependency)
- Feature-flagged: can be disabled remotely or by user
- Graceful fallback: show "Status Unknown" instead of crash
- Night Shift/True Tone detection is read-only (no control), lower risk

### Risk 3: ColorSync Profile Persistence Across Sleep/Wake
**Problem:** macOS often resets display profiles on wake from sleep or when displays reconnect.
**Mitigation:**
- Register for `didWakeNotification` and re-apply all profiles after 2-second delay
- Register for `CGDisplayReconfigurationCallback` to catch display changes
- Store the expected profile per display in DeviceMemory
- Periodically verify (every 60s) that profiles haven't been reset

### Risk 4: IOKit Service Discovery for I2C
**Problem:** Mapping `CGDirectDisplayID` to the correct IOKit I2C service is non-trivial and varies by connection type (HDMI, DisplayPort, USB-C, Thunderbolt).
**Mitigation:**
- Study MonitorControl's service discovery code thoroughly
- IOKit registry traversal: CGDisplay -> framebuffer -> IOAVService
- Different paths for Apple Silicon vs Intel (ARM64DDC vs legacy IOFB)
- Build a test matrix of connection types

### Risk 5: App Sandbox Restrictions
**Problem:** IOKit I2C access requires non-sandboxed execution.
**Mitigation:**
- Direct distribution only (not App Store)
- Hardened Runtime enabled (for notarization) but no sandbox
- Entitlement: `com.apple.security.device.usb` as documentation of intent
- Document clearly that App Store distribution is not possible due to DDC requirement

---

## Commit Strategy

Each task should produce at least one commit. Suggested atomic commit points:

| Commit | Content |
|--------|---------|
| `feat: scaffold Xcode project with MenuBarExtra` | A1 |
| `feat: define data models and core protocols` | A2 + A3 |
| `feat: add logging infrastructure and feature flags` | A4 |
| `feat: add color space definitions and constants` | A5 |
| `feat: add observable AppState` | A6 |
| `feat: add localization infrastructure (Korean/English)` | A7 |
| `feat: implement display detection with EDID parsing` | B1 |
| `feat: implement ColorSync profile switching` | B2 |
| `feat: implement DisplayEngineActor with hot-plug` | B3 |
| `feat: add per-monitor device memory persistence` | B4 |
| `feat: add Night Shift and conflict detection` | B5 |
| `feat: build menubar popover with profile switcher UI` | B6 |
| `feat: add gamma controller and debouncer` | B7 |
| `feat: implement DDCKit I2C transport` | C1 |
| `feat: add DDC capability detection` | C2 |
| `feat: implement DDCActor with command queue` | C3 |
| `feat: add brightness/contrast sliders with DDC control` | C4 |
| `feat: wire DDC persistence to device memory` | C5 |
| `feat: add launch-at-login support` | D1 |
| `feat: add global keyboard shortcuts for profiles` | D2 |
| `feat: add sleep/wake profile restoration` | D3 |
| `feat: implement Sequoia theme with glass effects` | D4 |
| `feat: add custom menubar and app icons` | D5 |
| `feat: add toast notifications and error states` | D6 |
| `chore: add signing, notarization, DMG scripts` | D7 |
| `test: add unit and integration tests` | D8 |

---

**END OF PLAN**
