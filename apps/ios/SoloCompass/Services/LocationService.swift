import Foundation
import CoreLocation
import Observation

/// Wraps CLLocationManager. Single shared instance — there is one device GPS,
/// so one manager. UI reads `currentLocation` and `authorizationStatus` directly.
@Observable
public final class LocationService: NSObject {
    public static let shared = LocationService()

    struct ForegroundFix {
        enum Quality: Equatable { case reliable, approximate }

        let location: CLLocation
        let quality: Quality
        let expiresAt: Date
    }

    public private(set) var currentLocation: CLLocation?
    public private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var latestForegroundSample: CLLocation?
    private var latestReliableForegroundSample: CLLocation?
    private var minimumForegroundSampleTime = Date.distantPast
    public private(set) var lastError: Error?
    public private(set) var heading: CLHeading?

    /// Geohash precision-6 (~600m×600m) of `currentLocation`. Nil when
    /// no location is known. Precise coordinates are never exposed — only
    /// the coarse cell string computed locally on device.
    public var coarseGeohash6: String? {
        guard let loc = currentLocation else { return nil }
        return Geohash.encode(loc.coordinate, precision: 6)
    }

    /// Optional preferences sink — when set, geofence enter events record
    /// pending check-ins so the app can prompt the user later.
    public weak var preferences: UserPreferences?
    public weak var notificationService: NotificationService?
    public var onRegionEnter: ((String) -> Void)?
    public var onRegionExit: ((String) -> Void)?

    private let manager: CLLocationManager
    private let bypassesLocationManager: Bool
    /// Identifiers we've actively asked to monitor — so we can stop a previous
    /// set without touching regions other code may have registered.
    private var monitoredIdentifiers: Set<String> = []
    /// Most recent visit list — kept so identifier→experience lookup is cheap
    /// during region callbacks.
    private var monitoredVisits: [String: Experience] = [:]

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        #if DEBUG
        // Under -uiTestBypassLocationPrompt we synthesise an authorised state
        // and DO NOT read `manager.authorizationStatus` — on iOS 26 the first
        // read attaches the process to CoreLocation and SpringBoard eagerly
        // shows the auth dialog before requestPermission() is even called.
        let args = ProcessInfo.processInfo.arguments
        self.bypassesLocationManager = args.contains("-uiTestBypassLocationPrompt")
        if bypassesLocationManager {
            self.authorizationStatus = .authorizedWhenInUse
            self.accuracyAuthorization = .fullAccuracy
            // Also inject a stub currentLocation matched to -startCity so
            // the "Can't find your location — showing a default area"
            // banner doesn't cover the seeded Nearby cards.
            if let idx = args.firstIndex(of: "-startCity"), idx + 1 < args.count {
                let city = args[idx + 1].lowercased()
                let stub: (Double, Double)?
                switch city {
                case "szx", "shenzhen", "cn-深圳市":  stub = (22.5431, 114.0579)
                case "nyc", "new-york":              stub = (40.7484, -73.9857)
                case "tyo", "tokyo":                 stub = (35.6817, 139.7708)
                case "sgn", "ho-chi-minh":           stub = (10.7769, 106.7009)
                case "lis", "lisbon":                stub = (38.7223, -9.1393)
                case "san-francisco", "sfo":         stub = (37.7749, -122.4194)
                case "cmi", "chiang-mai", "chiangmai": stub = (18.7877, 98.9938)
                case "vte", "vientiane":             stub = (17.9757, 102.6331)
                default: stub = nil
                }
                if let s = stub {
                    let stub = Self.simulatedForegroundSample(at: .init(latitude: s.0, longitude: s.1))
                    self.currentLocation = stub
                    self.latestForegroundSample = stub
                    self.latestReliableForegroundSample = stub
                }
            }
        } else {
            self.authorizationStatus = manager.authorizationStatus
            self.accuracyAuthorization = manager.accuracyAuthorization
        }
        #else
        self.bypassesLocationManager = false
        self.authorizationStatus = manager.authorizationStatus
        self.accuracyAuthorization = manager.accuracyAuthorization
        #endif
        super.init()
        #if DEBUG
        // On iOS 26, setting CLLocationManager.delegate alone triggers the
        // system authorization dialog. When bypassing the prompt for UI
        // testing / screenshots, skip the entire CLLocationManager setup.
        if bypassesLocationManager { return }
        #endif
        self.manager.delegate = self
        // Tighter accuracy so we don't burn battery chasing sub-10m fixes the
        // map never needs. The distance filter is deliberately *small* (5m) —
        // not large — so Core Location still hands us the stream of drifting
        // fixes while the traveler stands still, and the accuracy-aware
        // `shouldPublish` gate in `didUpdateLocations` decides which ones are
        // real movement versus GPS jitter. A large OS-level `distanceFilter`
        // can't tell drift from motion (a 25m noise jump looks like a 25m walk),
        // so the smoothing has to live in our gate, and the gate needs the
        // samples to smooth.
        self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        self.manager.distanceFilter = 5
    }

    /// Ask the user for location access, escalating from when-in-use to
    /// always so the app can fire geofence check-ins in the background.
    public func requestPermission() {
        #if DEBUG
        // e2e rubric harness (scripts/user-story-rubric/run.sh) can't dismiss
        // the CoreLocation modal — `simctl privacy grant location` no-ops for
        // CL prompts. This flag skips the system dialog and synthesises an
        // authorised state so screenshots capture the app, not the alert.
        if bypassesLocationManager {
            self.authorizationStatus = .authorizedWhenInUse
            startUpdating()
            return
        }
        #endif
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Two-step pattern required by Apple: WhenInUse must be granted before requesting Always.
            manager.requestAlwaysAuthorization()
            startUpdating()
        case .authorizedAlways:
            startUpdating()
            enableBackgroundUpdates()
        default:
            break
        }
    }

    /// Begin tracking the traveler's location and compass heading to power
    /// the map and the directional "walk this way" arrow.
    public func startUpdating() {
        guard Self.canUseLocation(authorizationStatus) else { return }
        #if DEBUG
        if bypassesLocationManager {
            if foregroundFix() == nil { refreshForegroundFix() }
            return
        }
        #endif
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    /// Restart standard delivery for an explicit locate action. Calling
    /// startUpdatingLocation again while it is running does not deliver a new
    /// initial sample, even if the previous sample has expired.
    func refreshForegroundFix() {
        guard Self.canUseLocation(authorizationStatus) else { return }
        #if DEBUG
        if bypassesLocationManager {
            if let coordinate = currentLocation?.coordinate {
                recordLocationSamples([Self.simulatedForegroundSample(at: coordinate)])
            }
            return
        }
        #endif
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    private func enableBackgroundUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Stop tracking location and heading, e.g. to conserve battery when
    /// the map is not in use.
    public func stopUpdating() {
        guard !bypassesLocationManager else { return }
        manager.stopUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.stopUpdatingHeading()
        }
    }

    /// Register CLCircularRegions (200m radius) for each experience so the OS
    /// wakes us when the user enters/exits. Replaces any previously-monitored
    /// set this service installed. iOS caps simultaneous regions at 20 per app.
    public func startMonitoring(visits: [Experience]) {
        // Clear what we previously installed.
        for id in monitoredIdentifiers {
            if let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
                manager.stopMonitoring(for: region)
            }
        }
        monitoredIdentifiers.removeAll()
        monitoredVisits.removeAll()

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        for exp in visits.prefix(20) {
            guard let coord = exp.coordinate else { continue }
            let region = CLCircularRegion(center: coord, radius: 200, identifier: exp.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            monitoredIdentifiers.insert(exp.id)
            monitoredVisits[exp.id] = exp
        }
    }

    // MARK: - Beta-P1-H: route geofencing
    //
    // Per-stop CLCircularRegions tied to the active route. Reuses the
    // same CLCircularRegion plumbing as `startMonitoring(visits:)` but
    // identifiers are prefixed with `routeStop:` so the dispatch path
    // (handled by the existing didEnterRegion delegate) can publish a
    // routeStopEntered notification distinct from visit check-ins.
    //
    // iOS caps regions at 20 per app. We deliberately register at most
    // 5 route stops so the visits monitor still has 15 slots — typical
    // route in this app is 3–6 stops, so the cap is enough for the
    // common case.

    public static let routeStopEntered = Notification.Name("SoloCompass.LocationService.routeStopEntered")
    public static let routeRegionPrefix = "routeStop:"
    public static let maxRouteRegions = 5

    /// Register up to `maxRouteRegions` CLCircularRegions for the given
    /// route stops, on top of (not replacing) the existing visit
    /// monitors. Pass an empty array to clear just the route regions.
    public func startMonitoringRouteStops(_ stops: [Experience]) {
        // Strip any previously-installed route regions.
        let oldRouteIds = monitoredIdentifiers.filter { $0.hasPrefix(Self.routeRegionPrefix) }
        for id in oldRouteIds {
            if let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
                manager.stopMonitoring(for: region)
            }
            monitoredIdentifiers.remove(id)
        }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        for exp in stops.prefix(Self.maxRouteRegions) {
            guard let coord = exp.coordinate else { continue }
            let identifier = Self.routeRegionPrefix + exp.id
            let region = CLCircularRegion(center: coord, radius: 200, identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
            monitoredIdentifiers.insert(identifier)
        }
    }

    /// Tear down all geofences this service installed, so no further
    /// arrival or departure check-ins fire.
    public func stopMonitoringAll() {
        for id in monitoredIdentifiers {
            if let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
                manager.stopMonitoring(for: region)
            }
        }
        monitoredIdentifiers.removeAll()
        monitoredVisits.removeAll()
    }

    /// Distance in meters from the current location to a coordinate.
    /// Returns `.greatestFiniteMagnitude` if no current location is known.
    public func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        guard let here = currentLocation else { return .greatestFiniteMagnitude }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return here.distance(from: target)
    }

    /// Initial great-circle bearing in degrees (0 = N, clockwise) from the current
    /// location to `coordinate`. Returns nil when no GPS fix is available.
    public func bearing(to coordinate: CLLocationCoordinate2D) -> Double? {
        guard let here = currentLocation else { return nil }
        let lat1 = here.coordinate.latitude * .pi / 180
        let lat2 = coordinate.latitude * .pi / 180
        let dLon = (coordinate.longitude - here.coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Bearing relative to the device's current heading (0 = straight ahead).
    /// When a valid heading is available, subtracts `trueHeading` from the
    /// great-circle bearing so the arrow points where the user should walk.
    /// Falls back to the absolute bearing when heading is nil or has negative
    /// accuracy (invalid), so behavior is unchanged on devices without a compass.
    public func relativeBearing(to coordinate: CLLocationCoordinate2D) -> Double? {
        guard let absolute = bearing(to: coordinate) else { return nil }
        guard let h = heading, h.headingAccuracy >= 0 else { return absolute }
        return (absolute - h.trueHeading + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Test-only: inject a simulated location. Bypasses CLLocationManager so
    /// tests can exercise ViewModel logic synchronously without real GPS.
    /// Not called in production code — harmless to ship.
    public func simulate(location: CLLocation) {
        self.currentLocation = location
    }

    #if DEBUG
    private static func simulatedForegroundSample(at coordinate: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date())
    }
    #endif

    /// Test-only: inject a simulated heading.
    public func simulate(heading: CLHeading) {
        self.heading = heading
    }

    /// Test-only: inject a simulated GPS error. Mirrors the
    /// `locationManager(_:didFailWithError:)` delegate path so views and view
    /// models can be exercised without a real CLLocationManager failure.
    public func simulate(error: Error) {
        self.lastError = error
    }
}

extension LocationService {
    private static let maxApproximateAccuracy: CLLocationDistance = 5_000
    private static let maxReducedAccuracy: CLLocationDistance = 25_000
    private static let maxReducedFixAge: TimeInterval = 15 * 60

    // Reduced-accuracy authorization may deliver a city-scale observation
    // only a few times per hour. It is never a street-level fix.
    private var foregroundMaxAge: TimeInterval {
        accuracyAuthorization == .reducedAccuracy ? Self.maxReducedFixAge : Self.maxFixAge
    }

    private static func canUseLocation(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Precision and freshness are independent. Keep using a reliable fix
    /// while it is fresh, then fall back to the newest approximate fix.
    func foregroundFix(now: Date = Date()) -> ForegroundFix? {
        guard Self.canUseLocation(authorizationStatus) else { return nil }
        if accuracyAuthorization == .fullAccuracy,
           let sample = latestReliableForegroundSample, Self.isFresh(sample, now: now) {
            return .init(location: sample, quality: .reliable, expiresAt: sample.timestamp.addingTimeInterval(Self.maxFixAge))
        }
        let maxAge = foregroundMaxAge
        guard let sample = latestForegroundSample, Self.isFresh(sample, now: now, maxAge: maxAge) else { return nil }
        return .init(location: sample, quality: .approximate, expiresAt: sample.timestamp.addingTimeInterval(maxAge))
    }

    func updateAuthorization(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, now: Date = Date()) {
        guard status != authorizationStatus || accuracy != accuracyAuthorization else { return }
        if Self.canUseLocation(status) != Self.canUseLocation(authorizationStatus) || accuracy != accuracyAuthorization {
            minimumForegroundSampleTime = now
            latestForegroundSample = nil
            latestReliableForegroundSample = nil
            currentLocation = nil
        }
        authorizationStatus = status
        accuracyAuthorization = accuracy
    }

    func recordLocationSamples(_ locations: [CLLocation], now: Date = Date()) {
        guard Self.canUseLocation(authorizationStatus) else { return }
        let maxAccuracy = accuracyAuthorization == .reducedAccuracy ? Self.maxReducedAccuracy : Self.maxApproximateAccuracy
        let maxAge = foregroundMaxAge
        for sample in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard Self.isFresh(sample, now: now, maxAge: maxAge),
                  sample.timestamp >= minimumForegroundSampleTime,
                  sample.timestamp > (latestForegroundSample?.timestamp ?? .distantPast),
                  sample.coordinate.latitude.isFinite, sample.coordinate.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(sample.coordinate),
                  sample.horizontalAccuracy > 0, sample.horizontalAccuracy <= maxAccuracy else { continue }
            latestForegroundSample = sample
            if accuracyAuthorization == .fullAccuracy, sample.horizontalAccuracy <= Self.maxAcceptableAccuracy {
                latestReliableForegroundSample = sample
                if Self.shouldPublish(candidate: sample, over: currentLocation, now: now) {
                    currentLocation = sample
                }
            }
        }
    }

    private static func isFresh(_ sample: CLLocation, now: Date, maxAge: TimeInterval = maxFixAge) -> Bool {
        (0..<maxAge).contains(now.timeIntervalSince(sample.timestamp))
    }
}

extension LocationService: CLLocationManagerDelegate {
    /// Reacts when the user grants or revokes location access, starting
    /// tracking (and background updates) once permission allows.
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            let changed = status != self.authorizationStatus || self.manager.accuracyAuthorization != self.accuracyAuthorization
            self.updateAuthorization(status, accuracy: self.manager.accuracyAuthorization)
            switch status {
            case .authorizedAlways:
                self.startUpdating()
                self.enableBackgroundUpdates()
            case .authorizedWhenInUse:
                self.startUpdating()
            default:
                break
            }
            if changed { self.refreshForegroundFix() }
        }
    }

    /// Records fresh samples under the manager's current permission and precision.
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            let accuracy = self.manager.accuracyAuthorization
            if status != self.authorizationStatus || accuracy != self.accuracyAuthorization {
                self.updateAuthorization(status, accuracy: accuracy)
                self.refreshForegroundFix()
                return
            }
            self.recordLocationSamples(locations)
        }
    }

    // MARK: - Jitter rejection

    /// The maximum uncertainty for a reliable or legacy precise fix, in metres.
    static let maxAcceptableAccuracy: CLLocationDistance = 100
    /// Fixes older than this (seconds) are discarded as cached / replayed
    /// samples from Core Location's ring buffer, not a real "now" position.
    static let maxFixAge: TimeInterval = 15
    /// Movement below this (metres) is always treated as noise, even when the
    /// two fixes report pinpoint accuracy — GPS never truly holds still, so a
    /// sub-`jitterFloor` "move" is drift, not walking.
    static let jitterFloor: CLLocationDistance = 8
    /// A fix at least this many metres tighter than the current one is accepted
    /// even without real movement, so the pin converges onto better readings as
    /// the GPS warms up rather than staying stuck on the first coarse fix.
    static let accuracyImprovementThreshold: CLLocationDistance = 15
    /// Upper bound on the drift-rejection radius so a spell of poor accuracy
    /// (large error circles) can't freeze the marker while the traveler is
    /// genuinely moving.
    static let maxJitterRadius: CLLocationDistance = 40
    /// If the published fix is older than this (seconds), accept the next valid
    /// candidate unconditionally. Without this floor a traveler moving in small
    /// steps (each below `noiseRadius`) can have every fix rejected as drift, so
    /// the marker stays planted at the departure point while the real position
    /// walks away — the pin visibly lags hundreds of metres behind. Re-anchoring
    /// to a fresh fix after a stale spell keeps the dot honest.
    static let staleCurrentAge: TimeInterval = 30

    /// Pure decision: should `candidate` replace `current` as the published
    /// location, or be suppressed as noise? Kept static and side-effect-free so
    /// the jitter policy is unit-testable without a live `CLLocationManager`.
    ///
    /// Order of rules:
    ///   1. Reject invalid (`horizontalAccuracy <= 0`), too-coarse, or stale
    ///      fixes outright.
    ///   2. Always accept the first fix — there's nothing to compare against.
    ///   3. Accept a meaningfully tighter fix even if it barely moved, so the
    ///      pin can converge onto a better reading.
    ///   4. Re-anchor when the published fix has gone stale (`staleCurrentAge`),
    ///      so a series of sub-noise-floor steps can't strand the marker at the
    ///      departure point while the real position walks away.
    ///   5. Otherwise accept only when the traveler moved beyond the noise
    ///      floor: the two fixes' error circles must have pulled apart
    ///      (`distance > combined accuracy`) by at least `jitterFloor`, capped
    ///      at `maxJitterRadius`. Movement inside that radius is
    ///      indistinguishable from drift, so the marker stays put.
    static func shouldPublish(
        candidate: CLLocation,
        over current: CLLocation?,
        now: Date = Date()
    ) -> Bool {
        guard candidate.horizontalAccuracy > 0 else { return false }
        guard candidate.horizontalAccuracy <= maxAcceptableAccuracy else { return false }
        guard isFresh(candidate, now: now), CLLocationCoordinate2DIsValid(candidate.coordinate) else { return false }

        guard let current else { return true }

        if candidate.horizontalAccuracy + accuracyImprovementThreshold < current.horizontalAccuracy {
            return true
        }

        // The published fix has aged out — the traveler may have walked away in
        // small steps that each read as drift. Accept this fresh, valid fix to
        // re-anchor rather than letting the marker lag behind reality.
        if now.timeIntervalSince(current.timestamp) > staleCurrentAge {
            return true
        }

        let moved = candidate.distance(from: current)
        let combinedError = candidate.horizontalAccuracy + current.horizontalAccuracy
        let noiseRadius = min(maxJitterRadius, max(jitterFloor, combinedError))
        return moved > noiseRadius
    }

    /// Records a location-tracking failure so the UI can surface a
    /// "can't find you" state.
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error
        }
    }

    /// Receives a compass heading update so the directional arrow can point
    /// the traveler toward an experience.
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        Task { @MainActor in
            self.heading = newHeading
        }
    }

    /// Fires when the traveler arrives at a monitored experience, recording
    /// a pending check-in and prompting them to log the visit.
    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard monitoredIdentifiers.contains(region.identifier) else { return }

        // Beta-P1-H: route-stop regions go down a separate publish path
        // so callers binding to the active route can advance the stop
        // index, refresh Live Activity copy, etc, without touching the
        // visit check-in flow that fires for every monitored Experience.
        if region.identifier.hasPrefix(Self.routeRegionPrefix) {
            let expId = String(region.identifier.dropFirst(Self.routeRegionPrefix.count))
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.routeStopEntered,
                    object: self,
                    userInfo: ["experienceId": expId]
                )
            }
            return
        }

        let expTitle = monitoredVisits[region.identifier]?.title ?? region.identifier
        Task { @MainActor in
            self.preferences?.recordPendingCheckIn(region.identifier)
            self.onRegionEnter?(region.identifier)
            if let prefs = self.preferences, let ns = self.notificationService {
                await ns.scheduleCheckInPrompt(
                    experienceId: region.identifier,
                    experienceTitle: expTitle,
                    preferences: prefs
                )
            }
        }
    }

    /// Fires when the traveler leaves a monitored experience's geofence,
    /// notifying observers of the departure.
    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard monitoredIdentifiers.contains(region.identifier) else { return }
        Task { @MainActor in
            self.onRegionExit?(region.identifier)
        }
    }
}
