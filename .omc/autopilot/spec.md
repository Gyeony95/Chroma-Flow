# ChromaFlow - Complete Specification

**Product:** ChromaFlow (크로마플로우)
**Platform:** macOS (targeting macOS 15+, optimized for Apple Silicon)
**Category:** Professional Color Management Menubar Utility
**Distribution:** Direct download (Developer ID signed, notarized)

---

## Executive Summary

ChromaFlow is a lightweight, native macOS menubar application that provides professional-grade color management and hardware display control. Unlike BetterDisplay's broad feature set, ChromaFlow focuses exclusively on:

1. **Display Profile Engine** - Instant switching between color spaces (P3, sRGB, Adobe RGB, Rec.709) via ColorSync
2. **Intelligent Automation** - App-aware profiles, solar scheduling, ambient light sync
3. **Hardware Control** - DDC/CI communication for external monitor brightness/contrast/color temperature

The MVP (Phase 1) delivers core profile switching and DDC hardware control. Phase 2 adds the automation layer. Phase 3 explores experimental features like Virtual HDR emulation.

**Critical Design Decisions:**
- **Direct distribution** (not App Store) - required for DDC/CI I2C access
- **macOS 15 baseline** - build on shipped APIs, abstraction layer for future "Liquid UI" adoption
- **Forked DDC layer** - leverages MonitorControl's battle-tested ARM64/Intel I2C implementation
- **Actor-based concurrency** - Swift 5.9+ with strict concurrency warnings for thread safety

---

# Part 1: Requirements Analysis

## 1.1 Functional Requirements

### A. Display Profile Engine

| ID | Requirement | Testable Criterion |
|----|-------------|-------------------|
| F-A1 | Switch between color profiles (P3, sRGB, Adobe RGB, Rec.709) using ColorSync & Quartz Display Services | Profile switch completes and is verified via ColorSync API within a defined time |
| F-A2 | Support per-display profile assignment for multi-monitor setups | Each connected display can hold an independent active profile |
| F-A3 | Delta-E calibration correction from hardware calibration data import | User can import .icc/.icm calibration file and system applies correction matrix |
| F-A4 | Reference Mode lock that prevents any color setting mutation | When locked, all programmatic and user-initiated color changes are blocked system-wide |
| F-A5 | Custom profile creation and saving | User can create, name, and persist custom color profiles |

### B. Intelligent Automation

| ID | Requirement | Testable Criterion |
|----|-------------|-------------------|
| F-B1 | Detect focused window process and auto-switch color gamut | When Final Cut Pro gains focus, HDR/P3 profile activates within defined latency |
| F-B2 | User-configurable app-to-profile mapping rules | Settings UI allows CRUD operations on app-profile mappings |
| F-B3 | Ambient light sensor integration for white balance adjustment (D50, D65, D75) | White balance shifts measurably when ambient light changes |
| F-B4 | Solar Schedule: blue light and contrast adjustment based on sunrise/sunset | Given a geographic location, adjustments follow solar schedule with smooth transitions |
| F-B5 | Liquid Transition effect for Solar Schedule changes | Transition uses physics-based animation, not abrupt steps |

### C. Advanced Hardware Control

| ID | Requirement | Testable Criterion |
|----|-------------|-------------------|
| F-C1 | DDC/CI communication for external monitor brightness control | Software slider adjusts physical monitor brightness via I2C |
| F-C2 | DDC/CI communication for external monitor contrast control | Software slider adjusts physical monitor contrast via I2C |
| F-C3 | DDC/CI communication for external monitor color temperature control | Software slider adjusts physical monitor color temperature via I2C |
| F-C4 | Virtual HDR Emulation via software tone mapping on SDR monitors | Tone mapping applies and produces measurably higher perceived contrast on SDR panel |

### D. UX / UI

| ID | Requirement | Testable Criterion |
|----|-------------|-------------------|
| F-D1 | Menubar icon (droplet shape) that opens control panel | Click on menubar icon opens panel |
| F-D2 | Liquid-spreading animation on panel open/close | Animation plays with physics-based timing curve |
| F-D3 | Real-time color temperature slider with live screen preview | Moving slider changes screen color continuously, not on release |
| F-D4 | Haptic feedback on trackpad when slider hits hardware limits | Trackpad produces haptic tap at min/max boundary |
| F-D5 | Toast notification for automatic profile changes | "P3 Color Space Activated" style notification appears in upper-right |
| F-D6 | Adaptive Glass material for panel background | Panel blur reflects background brightness and saturation |
| F-D7 | Elastic Interactions for sliders and buttons | UI elements use squash-and-stretch physics animations |
| F-D8 | Organic Depth layer separation via shadows, not lines | Visual hierarchy uses shadow/depth, zero hard divider lines |

## 1.2 Non-Functional Requirements

| Category | Requirement | Measurable Target |
|----------|-------------|-------------------|
| **Performance** | Profile switching latency | < 200ms from trigger to completion |
| **Performance** | App-aware detection latency | < 500ms after focus change |
| **Performance** | Memory footprint as menubar app | < 50MB RSS idle |
| **Performance** | CPU idle usage | < 0.5% idle |
| **Performance** | DDC/CI command round-trip | < 200ms per command (3 retries max) |
| **UX** | Animation frame rate | 60fps minimum (120fps on ProMotion) |
| **UX** | Slider-to-screen update latency | < 16ms for gamma table updates |
| **Reliability** | Multi-monitor thread safety | Zero race conditions under Swift 5.9+ strict concurrency |
| **Reliability** | Crash recovery | App restores last-known-good profile on crash/force-quit |
| **Compatibility** | Apple Silicon only | M1 through M4+ series |
| **Compatibility** | macOS 15.0+ baseline | MenuBarExtra, SensorKit ALS |
| **Security** | Minimal privilege elevation | No root/admin required for core features |
| **Accessibility** | VoiceOver support for all controls | All sliders, buttons, toggles are VoiceOver-navigable |
| **Localization** | Korean and English at minimum | Given Korean product name |

## 1.3 Implicit Requirements (Not Stated but Necessary)

| ID | Implicit Requirement | Why It Matters |
|----|---------------------|----------------|
| I-1 | **Monitor hot-plug detection** | Users connect/disconnect displays constantly; app must react without restart |
| I-2 | **Profile persistence across reboots** | Users expect their color profile to survive a restart |
| I-3 | **Profile persistence across sleep/wake** | macOS often resets display profiles on wake; app must re-apply |
| I-4 | **Graceful degradation for unsupported monitors** | Not all monitors support DDC/CI; app must detect and disable those controls |
| I-5 | **DDC/CI capability detection per monitor** | Must probe each display for DDC/CI support before showing hardware sliders |
| I-6 | **Undo/revert mechanism** | If a profile change looks wrong, user needs a quick way back |
| I-7 | **Conflict handling with Night Shift and True Tone** | macOS has built-in color shifting; ChromaFlow must either integrate or explicitly override |
| I-8 | **Conflict handling with other display managers** | What if BetterDisplay, Lunar, or MonitorControl is also running? |
| I-9 | **Export/import of app-to-profile mappings** | Professionals move between machines |
| I-10 | **First-run onboarding** | Complex tool needs guided setup for display detection, calibration import |
| I-11 | **Location Services permission for Solar Schedule** | Sunrise/sunset requires location; needs permission flow |
| I-12 | **Ambient light sensor availability check** | Not all Macs have ambient light sensors (external keyboards, clamshell mode) |
| I-13 | **Error states for DDC/CI failures** | I2C commands can fail silently; user needs feedback |
| I-14 | **Settings/preferences window** | Menubar-only apps still need a way to configure automation rules, app mappings, etc. |
| I-15 | **Login item / launch-at-startup** | Menubar utility must persist across login sessions |
| I-16 | **Keyboard shortcuts** | Power users expect hotkeys for profile switching |
| I-17 | **Update mechanism** | How does the app update itself? Sparkle for direct distribution |
| I-18 | **Logging and diagnostics** | When DDC/CI fails or profiles misbehave, users need exportable logs for support |

## 1.4 Out of Scope (What ChromaFlow is NOT)

| Exclusion | Rationale |
|-----------|-----------|
| **Display resolution/scaling management** | This is BetterDisplay territory; ChromaFlow is color-only |
| **Display arrangement/positioning** | System Preferences handles this |
| **Screen recording or screenshot color management** | Separate concern |
| **Color picker / eyedropper tool** | Separate utility category |
| **ICC profile creation from scratch** | ChromaFlow imports calibration data, does not replace hardware calibrators |
| **Windows/Linux support** | macOS-only, Apple Silicon-only |
| **Intel Mac support** | Apple Silicon required (MVP); Intel may come in Phase 2 |
| **Pre-macOS 15 support** | MenuBarExtra, SensorKit dependency |
| **Built-in hardware calibration sensor** | Relies on external calibration tools for Delta-E data |
| **Monitor firmware updates** | Out of scope for a color management tool |
| **Audio or non-display peripheral control** | Display-only |

## 1.5 Critical Risks and Mitigations

| Risk | Impact | Mitigation Strategy |
|------|--------|---------------------|
| **macOS 16 "Liquid UI" is speculative** | Entire UI design language may not exist | Build on macOS 15 SwiftUI with `UIThemeEngine` abstraction layer; swap implementation when real APIs ship |
| **Private APIs (DisplayServices, CoreBrightness)** | App Store rejection, breakage on OS updates | Direct distribution only; dynamic loading with feature flags; always have public API fallbacks |
| **DDC/CI reliability varies wildly** | Users with incompatible monitors get broken features | Capability detection, defensive retry logic, known-device database, graceful degradation |
| **Virtual HDR Emulation is research-grade** | Could derail timeline | Defer to Phase 3; define very narrow scope (contrast curve only, no local tone mapping) |
| **Performance targets undefined** | "Ultra-lightweight" has no metric | Define concrete targets: < 50MB memory, < 0.5% CPU idle, < 200ms profile switch, < 16ms slider latency |

---

# Part 2: Technical Specification

## 2.1 Tech Stack Decision

### Resolved Architectural Decisions

**Decision 1: Direct Distribution (Not App Store)**

The DDC/CI hardware control path requires `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` from IOKit, which Apple explicitly discourages for App Store apps. MonitorControl, Lunar, and BetterDisplay all distribute directly for this reason.

**Consequence:** Distribute via direct download (DMG/PKG) with Sparkle 2.x for updates. Code-sign with Developer ID certificate and notarize with Apple.

**Decision 2: macOS 15 (Sequoia) Baseline, Not macOS 16**

macOS 16 and its rumored "Liquid UI" do not exist as a developer target today. Build on SwiftUI 5 / Swift 5.9+ targeting macOS 15, with a `UIThemeEngine` abstraction layer. When macOS 16 ships, swap the theme engine implementation without touching business logic.

**Decision 3: Swift 5.9+ with Strict Concurrency Warnings**

Use Swift 5.9+ with `StrictConcurrency = complete` warnings enabled. This provides the same safety checks as Swift 6 while allowing pragmatic `@unchecked Sendable` escapes for C interop types (IOKit, ColorSync, CoreGraphics).

**Decision 4: Fork MonitorControl's DDC Layer**

MonitorControl's `Arm64DDC.swift` (MIT licensed) is battle-tested on Apple Silicon and Intel. Extract and wrap it behind a protocol for testability.

Reference: [MonitorControl/Arm64DDC.swift](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift)

**Decision 5: ColorSync Profile Switching via C API Bridge**

Use `ColorSyncDeviceSetCustomProfiles` from the ColorSync framework (public API) for programmatic ICC profile assignment.

Reference: [Configuring ColorSync display profiles](https://macops.ca/configuring-colorsync-display-profiles-using-the-command-line/)

### Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | Swift 5.9+ (strict concurrency warnings) | C API interop stability; migrate to Swift 6 later |
| UI Framework | SwiftUI 5 (macOS 15) | `MenuBarExtra` scene type; native popover support |
| Target OS | macOS 15.0+ (Sequoia) | `MenuBarExtra`, `SensorKit` ALS |
| Distribution | Direct (Developer ID + Notarization + Sparkle) | DDC/CI and DisplayServices require out-of-store |
| DDC Library | Forked from MonitorControl (MIT), wrapped in protocol | Battle-tested ARM64/Intel I2C, saves months |
| Color Engine | ColorSync C API + Quartz Display Services (public) | `ColorSyncDeviceSetCustomProfiles`, `CGSetDisplayTransferByTable` |
| Concurrency | Actor-based isolation; `@MainActor` for UI; dedicated `DDCActor` | Hardware I2C is slow (~50ms round-trip), must not block UI |
| Package Manager | Swift Package Manager | No CocoaPods/Carthage complexity |
| Updates | Sparkle 2.x | Industry standard for direct-distributed macOS apps |

### API Classification

| API | Status | Risk | Mitigation |
|-----|--------|------|-----------|
| `ColorSyncDeviceSetCustomProfiles` | Public (ApplicationServices) | Low | Stable since OS X 10.4 |
| `CGSetDisplayTransferByTable` | Public (CoreGraphics) | Low | Stable, used for gamma/LUT |
| `CGDisplayRegisterReconfigurationCallback` | Public (CoreGraphics) | Low | Hot-plug detection |
| `IOAVServiceWriteI2C` / `ReadI2C` | Semi-private (IOKit) | Medium | Used by MonitorControl/Lunar; wrap in protocol with graceful failure |
| `DisplayServicesSetBrightness` | Private (DisplayServices) | High | Built-in display only; feature-flag with fallback to "not supported" |
| `CoreBrightness` / ALS | Private | High | Use SensorKit public API (`SRSensor.ambientLightSensor`) on macOS 14+; fallback to IOKit |
| Night Shift control | Private (CBBlueLightClient) | High | Detect-only (read state, warn user of conflict), do not control |

## 2.2 Architecture Overview

### High-Level System Architecture

```
+------------------------------------------------------------------+
|                        ChromaFlow.app                            |
|  +------------------------------------------------------------+  |
|  |                    SwiftUI Layer                           |  |
|  |  MenuBarExtra  |  PopoverView  |  SettingsWindow          |  |
|  +--------+-------------------+-------------------+----------+  |
|           |                   |                   |             |
|  +--------v-------------------v-------------------v----------+  |
|  |                   AppState (@MainActor)                    |  |
|  |  DisplayStore  |  AutomationStore  |  PreferencesStore     |  |
|  +--------+-------------------+-------------------+----------+  |
|           |                   |                   |             |
|  +--------v--------+ +-------v--------+ +--------v---------+  |
|  |  DisplayEngine  | | AutomationEngine| |  UIThemeEngine   |  |
|  |  (actor)        | | (actor)         | |  (abstraction)   |  |
|  | - ProfileMgr    | | - AppDetector   | +------------------+  |
|  | - CalibrateSvc  | | - ScheduleRun   |                      |
|  | - GammaCtrl     | | - AmbientSync   |                      |
|  +--------+--------+ +-------+---------+                      |
|           |                   |                                 |
|  +--------v-------------------v------------------------------+  |
|  |                   HardwareBridge                          |  |
|  |  DDCController (actor)  |  BuiltInDisplayCtrl | SensorSvc |  |
|  |  - I2C read/write       |  - DisplayServices  | - ALS     |  |
|  |  - Capability cache     |  - CoreBrightness   | - Location|  |
|  +----------------------------------------------------------+  |
+------------------------------------------------------------------+
         |              |               |               |
    [IOKit I2C]   [ColorSync]   [CoreGraphics]   [SensorKit]
```

### Concurrency Model

```
@MainActor:
  - All SwiftUI views and @Observable state stores
  - Receives async results from engine actors

DisplayEngineActor (nonisolated background):
  - Owns ColorSync/CoreGraphics calls
  - Profile switching is ~10-50ms, runs off main thread
  - Publishes state changes to @MainActor stores via AsyncSequence

DDCActor (dedicated serial executor):
  - ALL I2C operations serialized (hardware cannot handle concurrent I2C)
  - 50ms minimum inter-command delay (DDC/CI spec requirement)
  - Timeout: 200ms per command, 3 retries with exponential backoff

AutomationActor (background):
  - Polls NSWorkspace.shared.frontmostApplication every 500ms (debounced)
  - Schedules profile switches via DisplayEngineActor
  - Location/solar calculations run here

Slider Interaction Path (< 16ms target):
  1. SwiftUI Slider.onChanged -> @MainActor
  2. Debounce 16ms (one frame at 60Hz)
  3. Apply gamma table via CGSetDisplayTransferByTable (synchronous, ~1ms)
  4. Async dispatch DDC command to DDCActor (fire-and-forget)
```

### Data Flow: Profile Switching

```
User taps "sRGB" in popover
  -> PopoverView sends action to DisplayStore (@MainActor)
  -> DisplayStore calls DisplayEngineActor.switchProfile(.sRGB, for: displayID)
  -> DisplayEngineActor:
       1. Resolves ICC profile path for .sRGB
       2. Calls ColorSyncDeviceSetCustomProfiles(displayID, profileURL)
       3. Optionally adjusts gamma LUT via CGSetDisplayTransferByTable
       4. Returns Result<ProfileSwitchConfirmation, DisplayEngineError>
  -> DisplayStore updates @Published state
  -> SwiftUI re-renders with new active profile indicator

  Total latency target: < 200ms
```

## 2.3 File Structure

```
ChromaFlow/
├── ChromaFlow.xcodeproj/
├── ChromaFlow/
│   ├── App/
│   │   ├── ChromaFlowApp.swift              # @main, MenuBarExtra scene
│   │   ├── AppDelegate.swift                # NSApplicationDelegate
│   │   ├── AppState.swift                   # Central @Observable state
│   │   └── Constants.swift                  # App-wide constants
│   │
│   ├── UI/
│   │   ├── MenuBar/
│   │   │   ├── MenuBarView.swift
│   │   │   └── StatusItemManager.swift
│   │   ├── Popover/
│   │   │   ├── PopoverContentView.swift
│   │   │   ├── ProfileSwitcherView.swift
│   │   │   ├── BrightnessContrastSliders.swift
│   │   │   └── DisplaySelectorView.swift
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift
│   │   │   ├── AutomationRulesView.swift
│   │   │   ├── ScheduleSettingsView.swift
│   │   │   ├── CalibrationView.swift
│   │   │   └── AboutView.swift
│   │   └── Theme/
│   │       ├── UIThemeEngine.swift          # Protocol abstraction
│   │       ├── SequoiaTheme.swift           # macOS 15 implementation
│   │       ├── GlassEffects.swift
│   │       └── ElasticAnimations.swift
│   │
│   ├── DisplayEngine/
│   │   ├── DisplayEngineActor.swift
│   │   ├── ProfileManager.swift
│   │   ├── GammaController.swift
│   │   ├── CalibrationService.swift
│   │   ├── DisplayDetector.swift
│   │   └── ColorSpaceDefinitions.swift
│   │
│   ├── AutomationEngine/
│   │   ├── AutomationEngineActor.swift
│   │   ├── AppDetector.swift
│   │   ├── ScheduleRunner.swift
│   │   ├── AmbientSyncService.swift
│   │   ├── SolarCalculator.swift
│   │   └── RuleEvaluator.swift
│   │
│   ├── HardwareBridge/
│   │   ├── DDC/
│   │   │   ├── DDCActor.swift
│   │   │   ├── DDCProtocol.swift
│   │   │   ├── Arm64DDCAdapter.swift
│   │   │   ├── IntelDDCAdapter.swift
│   │   │   ├── DDCCapabilityParser.swift
│   │   │   ├── DDCCommandQueue.swift
│   │   │   └── VCPCodes.swift
│   │   ├── BuiltIn/
│   │   │   ├── BuiltInDisplayController.swift
│   │   │   └── BuiltInDisplayFallback.swift
│   │   └── Sensors/
│   │       ├── AmbientLightService.swift
│   │       └── LocationService.swift
│   │
│   ├── Models/
│   │   ├── ColorProfile.swift
│   │   ├── DisplayDevice.swift
│   │   ├── AutomationRule.swift
│   │   ├── Schedule.swift
│   │   ├── CalibrationResult.swift
│   │   ├── DDCCapabilities.swift
│   │   └── AppIdentity.swift
│   │
│   ├── Persistence/
│   │   ├── ProfileStore.swift
│   │   ├── RuleStore.swift
│   │   └── DeviceMemory.swift
│   │
│   ├── Utilities/
│   │   ├── Logger.swift
│   │   ├── FeatureFlags.swift
│   │   ├── EDIDParser.swift
│   │   ├── Debouncer.swift
│   │   └── SystemConflictDetector.swift
│   │
│   └── Resources/
│       ├── Assets.xcassets/
│       ├── Profiles/                        # Bundled ICC profiles
│       │   ├── ChromaFlow-sRGB.icc
│       │   ├── ChromaFlow-DisplayP3.icc
│       │   ├── ChromaFlow-AdobeRGB.icc
│       │   └── ChromaFlow-Rec709.icc
│       ├── Info.plist
│       └── ChromaFlow.entitlements
│
├── Tests/
│   ├── ChromaFlowTests/
│   │   ├── DisplayEngine/
│   │   ├── AutomationEngine/
│   │   ├── HardwareBridge/
│   │   └── Models/
│   └── ChromaFlowUITests/
│
├── Packages/
│   └── DDCKit/                              # Local SPM package
│       ├── Package.swift
│       ├── Sources/DDCKit/
│       └── Tests/DDCKitTests/
│
├── Scripts/
│   ├── notarize.sh
│   └── create-dmg.sh
│
└── README.md
```

## 2.4 Dependencies

### Swift Package Manager

| Package | Version | Purpose |
|---------|---------|---------|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.x | Auto-updates |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 2.x | Global hotkeys |
| [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) | ~> 1.0 | Login item |
| [Solar](https://github.com/ceeK/Solar) | ~> 3.0 | Sunrise/sunset calculation |

### System Frameworks

| Framework | Import | API Used | Status |
|-----------|--------|----------|--------|
| ApplicationServices | `import ApplicationServices` | `ColorSyncDeviceSetCustomProfiles` | Public |
| CoreGraphics | `import CoreGraphics` | `CGSetDisplayTransferByTable`, display callbacks | Public |
| IOKit | `import IOKit` | `IOAVServiceWriteI2C`, `IOAVServiceReadI2C` | Semi-private |
| AppKit | `import AppKit` | `NSWorkspace`, `NSScreen`, `NSStatusItem` | Public |
| CoreLocation | `import CoreLocation` | `CLLocationManager` | Public |
| SensorKit | `import SensorKit` | `SRSensor.ambientLightSensor` | Public (macOS 14+) |
| os | `import os` | `Logger` | Public |
| ServiceManagement | `import ServiceManagement` | `SMAppService` | Public |
| DisplayServices | Dynamic load | `DisplayServicesSetBrightness` | Private (feature-flagged) |

## 2.5 API / Interfaces

### Core Protocols

```swift
// Display Profile Management
protocol DisplayProfileManaging: Sendable {
    func availableProfiles(for display: DisplayDevice) -> [ColorProfile]
    func activeProfile(for display: DisplayDevice) async throws -> ColorProfile
    func switchProfile(_ profile: ColorProfile, for display: DisplayDevice) async throws -> ProfileSwitchConfirmation
    func lockProfile(_ profile: ColorProfile, for display: DisplayDevice) async
    func unlockProfile(for display: DisplayDevice) async
}

// DDC Device Control
protocol DDCDeviceControlling: Sendable {
    var capabilities: DDCCapabilities { get async }
    func readVCP(_ code: VCPCode) async throws -> (current: UInt16, max: UInt16)
    func writeVCP(_ code: VCPCode, value: UInt16) async throws
    func setBrightness(_ value: Double) async throws
    func setContrast(_ value: Double) async throws
    func setColorTemperature(_ kelvin: Int) async throws
}

// Automation Rule Engine
protocol AutomationRuleEngine: Sendable {
    var rules: [AutomationRule] { get async }
    func addRule(_ rule: AutomationRule) async
    func removeRule(id: AutomationRule.ID) async
    func evaluate(context: AutomationContext) async -> [AutomationAction]
}

// Display Detection
protocol DisplayDetecting: Sendable {
    var events: AsyncStream<DisplayEvent> { get }
    func connectedDisplays() async -> [DisplayDevice]
}

// Theme Engine (abstraction for future Liquid UI)
protocol UIThemeProviding {
    func popoverMaterial() -> some View
    func interactionSpring() -> Animation
    var supportsAdaptiveGlass: Bool { get }
}
```

### Key Data Models

```swift
struct ColorProfile: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let colorSpace: ColorSpace
    let iccProfileURL: URL?
    let isCustom: Bool

    enum ColorSpace: String, Codable, Sendable, CaseIterable {
        case sRGB, displayP3, adobeRGB, rec709, rec2020, custom
    }
}

struct DisplayDevice: Identifiable, Codable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let manufacturer: String
    let model: String
    let serialNumber: String?
    let connectionType: ConnectionType
    let isBuiltIn: Bool
    let ddcCapabilities: DDCCapabilities?

    enum ConnectionType: String, Codable, Sendable {
        case builtIn, hdmi, displayPort, usbC, thunderbolt, unknown
    }
}

struct AutomationRule: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [Condition]
    var actions: [AutomationAction]
    var priority: Int

    enum Condition: Codable, Sendable {
        case appForeground(bundleID: String)
        case timeRange(start: DateComponents, end: DateComponents)
        case solarEvent(SolarTrigger)
        case ambientLight(below: Double)
        case displayConnected(serialNumber: String)
    }
}

enum AutomationAction: Codable, Sendable {
    case switchProfile(profileID: UUID, displayID: CGDirectDisplayID)
    case setBrightness(value: Double, displayID: CGDirectDisplayID)
    case setContrast(value: Double, displayID: CGDirectDisplayID)
    case setColorTemperature(kelvin: Int, displayID: CGDirectDisplayID)
}

struct DDCCapabilities: Codable, Sendable {
    let supportsBrightness: Bool
    let supportsContrast: Bool
    let supportsColorTemperature: Bool
    let maxBrightness: UInt16
    let maxContrast: UInt16
    let rawCapabilityString: String?
}
```

## 2.6 Implementation Phases

### Phase 1: MVP (Weeks 1-6)

**Goal:** Working menubar app with profile switching and DDC hardware control.

| Feature | Scope | Key Files |
|---------|-------|-----------|
| Menubar popover | Profile list, display selector | `MenuBarView.swift`, `PopoverContentView.swift` |
| Profile switching | sRGB, P3, AdobeRGB, Rec.709 via ColorSync | `ProfileManager.swift`, `DisplayEngineActor.swift` |
| Display detection | Hot-plug, multi-monitor | `DisplayDetector.swift`, `EDIDParser.swift` |
| DDC brightness/contrast | External monitors via I2C | `DDCActor.swift`, `Arm64DDCAdapter.swift` |
| Per-monitor memory | Remember settings by EDID serial | `DeviceMemory.swift`, `ProfileStore.swift` |
| Conflict detection | Warn if Night Shift/True Tone active | `SystemConflictDetector.swift` |
| Login item | Launch at login | `LaunchAtLogin-Modern` integration |
| Keyboard shortcuts | Global hotkeys for profile switching | `KeyboardShortcuts` integration |
| Logging | os.Logger throughout | `Logger.swift` |

**Deferred from MVP:**
- Automation engine (app detection, schedules)
- Ambient light sync
- Calibration wizard
- Built-in display brightness (private API)
- Virtual HDR
- Advanced UI theming

### Phase 2: Intelligence Layer (Weeks 7-12)

| Feature | Scope |
|---------|-------|
| App-aware automation | NSWorkspace monitoring, rule engine, per-app profiles |
| Solar schedule | Sunrise/sunset profile transitions |
| Time-based schedule | Cron-like rules |
| Ambient light sync | SensorKit ALS -> brightness/profile mapping |
| Reference Lock | Lock profile to prevent automation override |
| Built-in display brightness | DisplayServices private API with feature flag |
| Settings window | Full preferences UI with rule editor |
| Sparkle updates | Auto-update mechanism |
| Delta-E calibration (basic) | White point / gamma calibration |

### Phase 3: Experimental (Weeks 13+)

| Feature | Scope | Risk Level |
|---------|-------|-----------|
| Virtual HDR Emulation | Software tone mapping via Metal, tone curve via `CGSetDisplayTransferByTable` | Very high |
| Advanced calibration | Colorimeter integration, full ICC profile generation | High |
| macOS 16 Liquid UI | Swap `UIThemeEngine` implementation when SDK ships | Medium |
| Color temperature via DDC | Fine-grained Kelvin control | Medium |
| Profile export/import | Share calibration profiles | Low |

## 2.7 Risk Mitigation

### Risk 1: macOS 16 "Liquid UI" Dependency

**Strategy: Abstraction Layer with Zero Speculation**

The `UIThemeEngine` protocol isolates all visual styling:

```swift
protocol UIThemeProviding {
    func popoverMaterial() -> some View
    func interactionSpring() -> Animation
    var supportsAdaptiveGlass: Bool { get }
}

// Today: SequoiaTheme (macOS 15)
struct SequoiaTheme: UIThemeProviding {
    func popoverMaterial() -> some View {
        Rectangle().background(.ultraThinMaterial)
    }
    func interactionSpring() -> Animation {
        .spring(response: 0.35, dampingFraction: 0.86)
    }
    var supportsAdaptiveGlass: Bool { false }
}

// Future: LiquidTheme (macOS 16)
// Swap implementation when SDK ships
```

### Risk 2: Private API Fragility

**Strategy: Feature Flags + Dynamic Loading + Graceful Degradation**

Every private API call wrapped in three layers:

1. **Feature flag** - can be remotely disabled
2. **Dynamic loading** (`dlopen`/`dlsym`) - no crash if framework removed
3. **Fallback path** - always a degraded-but-functional alternative

| Private API | Feature Flag | Fallback |
|-------------|-------------|----------|
| `DisplayServicesSetBrightness` | `builtInBrightness` | Gamma table adjustment |
| `CBBlueLightClient` | `nightShiftDetection` | Disable, show "unknown" |
| IOKit ALS | `ioKitAmbientLight` | SensorKit public API |

### Risk 3: DDC/CI Unreliability

**Strategy: Capability Detection + Defensive Communication**

```
DDC Reliability Stack:
  1. EDID Detection (always works)
  2. Capability String Query (VCP 0xF3)
  3. Test Write/Read Cycle
  4. Ongoing Communication with retry logic
```

- 50ms minimum between commands
- 200ms timeout per command
- 3 retries with exponential backoff
- After 3 consecutive failures: disable DDC, show warning

### Risk 4: Performance Targets

| Target | Measurement | Enforcement |
|--------|-------------|-------------|
| < 50MB memory (idle) | Instruments Allocations | CI test with memory ceiling assertion |
| < 0.5% CPU (idle) | Instruments Time Profiler | No polling faster than 500ms |
| < 200ms profile switch | `os_signpost` | Unit test with `XCTMetric` |
| < 16ms slider-to-screen | `os_signpost` | Gamma path synchronous (~1ms) |

---

# Part 3: Development Guidelines

## 3.1 Code Quality Standards

- **Swift Concurrency:** Use actors for all hardware communication
- **Error Handling:** All async throws must be handled explicitly
- **Logging:** Use `os.Logger` with subsystems (`com.chromaflow.display`, `com.chromaflow.ddc`, etc.)
- **Testing:** Minimum 70% code coverage for DisplayEngine and HardwareBridge modules
- **Documentation:** All public APIs documented with Swift DocC

## 3.2 Performance Budgets

| Operation | Budget | Measurement |
|-----------|--------|-------------|
| Profile switch | < 200ms | End-to-end signpost |
| DDC command | < 200ms | Per-command signpost |
| Slider interaction | < 16ms | Frame timing |
| App detection | < 500ms | After focus change |
| Memory footprint | < 50MB | RSS at idle |
| CPU usage (idle) | < 0.5% | 30-second average |

## 3.3 Distribution Checklist

- [ ] Code signing with Developer ID Application certificate
- [ ] Notarization via `notarytool`
- [ ] DMG packaging with drag-to-Applications
- [ ] Sparkle 2.x integration with EdDSA signing
- [ ] Privacy manifest for Location Services
- [ ] Entitlements: `com.apple.security.device.usb` for DDC/CI

---

# Part 4: References

## Documentation

- [ColorSync Manager](https://developer.apple.com/documentation/applicationservices/colorsync_manager)
- [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
- [SensorKit ambientLightSensor](https://developer.apple.com/documentation/sensorkit/srsensor/ambientlightsensor)
- [Configuring ColorSync profiles via CLI](https://macops.ca/configuring-colorsync-display-profiles-using-the-command-line/)

## Open Source References

- [MonitorControl](https://github.com/MonitorControl/MonitorControl) - MIT-licensed DDC implementation
- [MonitorControl/Arm64DDC.swift](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift) - ARM64 I2C layer
- [timsutton/customdisplayprofiles](https://github.com/timsutton/customdisplayprofiles) - Python ColorSync tool

## Technical Articles

- [Alin Panaitiu: Journey to DDC on M1](https://alinpanaitiu.com/blog/journey-to-ddc-on-m1-macs/) - Deep dive on Apple Silicon I2C
- [Reverse Engineering CoreDisplay](https://alexdelorenzo.dev/programming/2018/08/16/reverse_engineering_private_apple_apis) - Private API patterns

## Competitive Analysis

- [Lunar](https://lunar.fyi/) - Commercial DDC app
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) - Full-featured display manager
- [LightKit](https://github.com/maxmouchet/LightKit) - Swift ALS/brightness library

---

**END OF SPECIFICATION**
