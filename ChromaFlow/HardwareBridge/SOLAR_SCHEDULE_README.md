# Solar Schedule Feature

## Overview

The Solar Schedule feature provides automated blue light filtering based on sunrise and sunset times. It reduces eye strain and improves sleep quality by adjusting display color temperature throughout the day.

## Architecture

### Components

1. **SolarCalculator.swift**
   - Uses CoreLocation for user location (default: Seoul)
   - Calculates sunrise/sunset times using astronomical algorithms
   - Based on NOAA Solar Calculator equations
   - Defines solar phases: daytime, dawn, twilight, night

2. **SolarScheduleEngine.swift**
   - Timer-based scheduler (5-minute intervals)
   - Smooth 10-minute transitions between phases
   - Manages blue light filter application via GammaController
   - Observable state for UI integration

3. **GammaController.swift** (Enhanced)
   - New `setBlueLightFilter(strength:for:)` method
   - Generates gamma tables with blue channel reduction
   - Applies contrast adjustment for better readability
   - < 1ms gamma updates for smooth transitions

4. **AppState.swift** (Extended)
   - `isSolarScheduleEnabled: Bool`
   - `currentSolarPhase: SolarPhase?`
   - `blueLightFilterStrength: Double`
   - `solarScheduleEngine: SolarScheduleEngine?`

5. **AutomationEngine.swift** (Integrated)
   - `startSolarSchedule()` / `stopSolarSchedule()`
   - `toggleSolarSchedule()`
   - `getSolarScheduleStatus() -> SolarScheduleStatus?`

## Solar Phases

| Phase | Time Range | Blue Light Filter | Description |
|-------|-----------|-------------------|-------------|
| **Dawn** 🌄 | Sunrise - 1h → Sunrise | 50% → 0% | Gradual reduction |
| **Daytime** ☀️ | Sunrise → Sunset | 0% | No filtering |
| **Twilight** 🌅 | Sunset → Sunset + 1h | 0% → 50% | Gradual increase |
| **Night** 🌙 | Sunset + 1h → Sunrise - 1h | 50% | Maximum filtering |

## Blue Light Filtering

### Parameters

- **Maximum Reduction**: 50% of blue channel at night
- **Red Boost**: 10% increase for warm tint
- **Contrast**: 90% of original (adjustable)
- **Transition Duration**: 10 minutes (smooth interpolation)

### Gamma Table Generation

```swift
// At maximum strength (1.0):
// - Blue channel: 50% reduction
// - Red channel: 10% boost
// - Green channel: Neutral
// - Contrast: 90%
```

## Location Services

### Permission

The feature requests CoreLocation "When In Use" permission. This needs to be added to the app's Info.plist:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>ChromaFlow needs your location to calculate sunrise and sunset times for blue light filtering.</string>
```

### Fallback

If location access is denied or unavailable, the system uses Seoul, South Korea (37.5665°N, 126.9780°E) as the default location.

## Usage

### Starting Solar Schedule

```swift
// Via AutomationEngine
await automationEngine.startSolarSchedule()

// Check status
if let status = await automationEngine.getSolarScheduleStatus() {
    print("Phase: \(status.phaseDescription)")
    print("Filter: \(status.filterPercentage)")
    print("Sunrise: \(status.sunrise)")
    print("Sunset: \(status.sunset)")
}
```

### Stopping Solar Schedule

```swift
await automationEngine.stopSolarSchedule()
```

### Manual Control

```swift
// Directly control filter strength
solarScheduleEngine?.setFilterStrength(0.5) // 50% filtering
```

## State Management

### Observable Properties

The `SolarScheduleEngine` is `@Observable` and updates:
- `currentPhase: SolarPhase?`
- `blueLightFilterStrength: Double`

### Callbacks

```swift
solarScheduleEngine?.onStateChanged = { phase, strength in
    print("Phase changed to \(phase) with strength \(strength)")
}
```

## Technical Details

### Update Interval

The engine checks solar phase every 5 minutes to balance accuracy and battery efficiency.

### Transition Algorithm

Linear interpolation over 10 minutes:

```swift
progress = elapsed / transitionDuration
newStrength = startStrength + (targetStrength - startStrength) * progress
```

### Caching

Solar times are cached per day to avoid repeated calculations:
- Cache key: Date (day-level precision)
- Cache invalidation: Daily or on location change

## Integration Notes

### Conflict Detection

⚠️ **Potential Conflicts**:
- **Night Shift**: Apple's built-in blue light filter (should warn user)
- **Ambient Sync**: White balance adjustment (can coexist)
- **Color Profile Changes**: App-aware color space switching (can coexist)

### Performance

- Solar calculation: < 1ms
- Gamma table generation: < 1ms
- Gamma application: < 1ms
- Total phase transition: ~10 minutes (smooth)

### Memory Usage

- Gamma tables: 3 × 256 floats = ~3KB per update
- Cached solar times: < 1KB
- Total overhead: < 5KB

## Future Enhancements

### Planned Features

1. **Custom Schedule**: User-defined transition times
2. **Location Override**: Manual latitude/longitude entry
3. **Filter Strength**: Adjustable maximum reduction (0-100%)
4. **Transition Curves**: Easing functions (ease-in, ease-out)
5. **Multi-Display**: Independent settings per display
6. **Brightness Dimming**: Optional brightness reduction at night

### UI Components (To Be Implemented)

- Solar schedule toggle in settings
- Visual timeline showing current phase
- Sunrise/sunset time display
- Filter strength slider
- Location permission prompt
- Conflict warnings (Night Shift detection)

## Testing

### Manual Testing

1. **Enable Feature**:
   ```swift
   await automationEngine.startSolarSchedule()
   ```

2. **Verify Current Phase**:
   ```swift
   let phase = solarCalculator.getCurrentPhase()
   print("Current phase: \(phase)")
   ```

3. **Check Solar Times**:
   ```swift
   let times = solarCalculator.calculateSolarTimes()
   print("Sunrise: \(times.sunrise)")
   print("Sunset: \(times.sunset)")
   ```

4. **Test Manual Override**:
   ```swift
   solarScheduleEngine?.setFilterStrength(0.5)
   ```

### Automated Testing (Future)

- Unit tests for solar calculations
- Mock location for different latitudes
- Transition accuracy tests
- Edge cases (polar regions, equator)

## Known Limitations

1. **Polar Regions**: Simplified behavior during polar day/night
2. **Real-time Updates**: 5-minute polling (not instant)
3. **Single Display**: Currently controls primary display only
4. **No Persistence**: Settings not saved between launches (yet)

## References

- [NOAA Solar Calculator](https://gml.noaa.gov/grad/solcalc/)
- [Astronomical Algorithms by Jean Meeus](https://www.willbell.com/math/MC1.HTM)
- [CoreLocation Framework](https://developer.apple.com/documentation/corelocation)
- [CoreGraphics Gamma API](https://developer.apple.com/documentation/coregraphics)

---

**Implementation Date**: 2026-02-01
**Version**: 1.0.0
**Status**: ✅ Complete (Backend implementation ready for UI integration)
