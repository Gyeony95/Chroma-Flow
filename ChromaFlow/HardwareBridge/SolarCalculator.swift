//
//  SolarCalculator.swift
//  ChromaFlow
//
//  Solar position calculator using astronomical algorithms.
//  Calculates sunrise/sunset times for blue light filtering.
//

import Foundation
import CoreLocation

/// Solar phase of the day
enum SolarPhase: String, Codable, Sendable {
    case daytime    // Sunrise → Sunset
    case twilight   // Sunset → Sunset + 1 hour
    case night      // Sunset + 1 hour → Sunrise - 1 hour
    case dawn       // Sunrise - 1 hour → Sunrise
}

/// Solar times for a given date and location
struct SolarTimes: Sendable {
    let date: Date
    let sunrise: Date
    let sunset: Date
    let dawnStart: Date      // Sunrise - 1 hour
    let twilightEnd: Date    // Sunset + 1 hour

    /// Get the current solar phase
    func getCurrentPhase(at time: Date = Date()) -> SolarPhase {
        if time >= dawnStart && time < sunrise {
            return .dawn
        } else if time >= sunrise && time < sunset {
            return .daytime
        } else if time >= sunset && time < twilightEnd {
            return .twilight
        } else {
            return .night
        }
    }

    /// Get the progress through the current phase (0.0 - 1.0)
    func getPhaseProgress(at time: Date = Date()) -> Double {
        let phase = getCurrentPhase(at: time)

        switch phase {
        case .dawn:
            let duration = sunrise.timeIntervalSince(dawnStart)
            let elapsed = time.timeIntervalSince(dawnStart)
            return max(0, min(1, elapsed / duration))

        case .daytime:
            let duration = sunset.timeIntervalSince(sunrise)
            let elapsed = time.timeIntervalSince(sunrise)
            return max(0, min(1, elapsed / duration))

        case .twilight:
            let duration = twilightEnd.timeIntervalSince(sunset)
            let elapsed = time.timeIntervalSince(sunset)
            return max(0, min(1, elapsed / duration))

        case .night:
            // Night phase wraps around midnight
            // For simplicity, return 0.5 at midnight
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: time)
            return Double(hour) / 24.0
        }
    }
}

/// Solar position calculator using astronomical algorithms
@MainActor
final class SolarCalculator: NSObject, @unchecked Sendable {

    // MARK: - Properties

    /// Location manager for user location
    private let locationManager = CLLocationManager()

    /// Current location (default: Seoul, South Korea)
    private(set) var currentLocation: CLLocation = CLLocation(
        latitude: 37.5665,
        longitude: 126.9780
    )

    /// Whether location services are authorized
    private(set) var isLocationAuthorized = false

    /// Cached solar times
    private var cachedSolarTimes: SolarTimes?
    private var cachedDate: Date?

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        checkLocationAuthorization()
    }

    // MARK: - Public API

    /// Request location permission
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Calculate solar times for the current date and location
    func calculateSolarTimes(for date: Date = Date()) -> SolarTimes {
        // Check cache (solar times change once per day)
        let calendar = Calendar.current
        if let cachedDate = cachedDate,
           let cachedTimes = cachedSolarTimes,
           calendar.isDate(cachedDate, inSameDayAs: date) {
            return cachedTimes
        }

        // Calculate new solar times
        let times = calculateSolarTimesForLocation(
            latitude: currentLocation.coordinate.latitude,
            longitude: currentLocation.coordinate.longitude,
            date: date
        )

        // Cache result
        cachedDate = date
        cachedSolarTimes = times

        return times
    }

    /// Get the current solar phase
    func getCurrentPhase() -> SolarPhase {
        let times = calculateSolarTimes()
        return times.getCurrentPhase()
    }

    /// Get the progress through the current phase (0.0 - 1.0)
    func getPhaseProgress() -> Double {
        let times = calculateSolarTimes()
        return times.getPhaseProgress()
    }

    // MARK: - Private Methods

    private func checkLocationAuthorization() {
        let status = locationManager.authorizationStatus

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            isLocationAuthorized = true
            locationManager.requestLocation()

        case .notDetermined:
            isLocationAuthorized = false
            // Don't request automatically - wait for user action

        case .denied, .restricted:
            isLocationAuthorized = false
            print("SolarCalculator: Location access denied, using default location (Seoul)")

        @unknown default:
            isLocationAuthorized = false
        }
    }

    /// Calculate solar times using astronomical algorithms
    /// Based on simplified NOAA Solar Calculator equations
    private func calculateSolarTimesForLocation(
        latitude: Double,
        longitude: Double,
        date: Date
    ) -> SolarTimes {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            // Fallback to default times if date components fail
            return createDefaultSolarTimes(for: date)
        }

        // Calculate Julian day
        let julianDay = calculateJulianDay(year: year, month: month, day: day)

        // Calculate sunrise and sunset
        let sunrise = calculateSunriseOrSunset(
            julianDay: julianDay,
            latitude: latitude,
            longitude: longitude,
            isSunrise: true
        )

        let sunset = calculateSunriseOrSunset(
            julianDay: julianDay,
            latitude: latitude,
            longitude: longitude,
            isSunrise: false
        )

        // Calculate dawn and twilight boundaries
        let dawnStart = sunrise.addingTimeInterval(-3600) // 1 hour before sunrise
        let twilightEnd = sunset.addingTimeInterval(3600) // 1 hour after sunset

        return SolarTimes(
            date: date,
            sunrise: sunrise,
            sunset: sunset,
            dawnStart: dawnStart,
            twilightEnd: twilightEnd
        )
    }

    /// Calculate Julian Day Number
    private func calculateJulianDay(year: Int, month: Int, day: Int) -> Double {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3

        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        return Double(jdn)
    }

    /// Calculate sunrise or sunset time
    /// Simplified algorithm based on NOAA Solar Calculator
    private func calculateSunriseOrSunset(
        julianDay: Double,
        latitude: Double,
        longitude: Double,
        isSunrise: Bool
    ) -> Date {
        // Solar zenith angle at sunrise/sunset (90.833 degrees for horizon + refraction)
        let zenith = 90.833

        // Convert latitude to radians
        let latRad = latitude * .pi / 180.0

        // Calculate day of year
        let n = julianDay - 2451545.0 + 0.0008

        // Mean solar time
        let j = n - longitude / 360.0

        // Solar mean anomaly
        let m = (357.5291 + 0.98560028 * j).truncatingRemainder(dividingBy: 360.0)
        let mRad = m * .pi / 180.0

        // Equation of center
        let c = 1.9148 * sin(mRad) + 0.0200 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)

        // Ecliptic longitude
        let lambda = (m + c + 180.0 + 102.9372).truncatingRemainder(dividingBy: 360.0)
        let lambdaRad = lambda * .pi / 180.0

        // Solar transit
        let jtransit = 2451545.0 + j + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)

        // Declination of the Sun
        let sinDelta = sin(lambdaRad) * sin(23.44 * .pi / 180.0)
        let delta = asin(sinDelta)

        // Hour angle
        let cosOmega = (sin(-zenith * .pi / 180.0) - sin(latRad) * sin(delta)) / (cos(latRad) * cos(delta))

        // Check if sun rises/sets at this latitude
        guard cosOmega >= -1.0 && cosOmega <= 1.0 else {
            // Polar day or polar night - return noon or midnight
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day], from: Date())
            let baseDate = calendar.date(from: components) ?? Date()
            return baseDate.addingTimeInterval(isSunrise ? 6 * 3600 : 18 * 3600)
        }

        let omega = acos(cosOmega) * 180.0 / .pi

        // Calculate sunrise or sunset Julian date
        let jdate = jtransit + (isSunrise ? -omega : omega) / 360.0

        // Convert Julian date to Date
        let unixTimestamp = (jdate - 2440587.5) * 86400.0
        return Date(timeIntervalSince1970: unixTimestamp)
    }

    /// Create default solar times (6 AM sunrise, 6 PM sunset)
    private func createDefaultSolarTimes(for date: Date) -> SolarTimes {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        let sunrise = calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 6,
                minute: 0
            )
        ) ?? date

        let sunset = calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 18,
                minute: 0
            )
        ) ?? date

        return SolarTimes(
            date: date,
            sunrise: sunrise,
            sunset: sunset,
            dawnStart: sunrise.addingTimeInterval(-3600),
            twilightEnd: sunset.addingTimeInterval(3600)
        )
    }
}

// MARK: - CLLocationManagerDelegate

extension SolarCalculator: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            self.currentLocation = location
            // Clear cache to force recalculation with new location
            self.cachedDate = nil
            self.cachedSolarTimes = nil
            print("SolarCalculator: Location updated to \(location.coordinate.latitude), \(location.coordinate.longitude)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("SolarCalculator: Failed to get location - \(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.checkLocationAuthorization()
        }
    }
}
