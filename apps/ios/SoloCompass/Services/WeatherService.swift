import Foundation
import CoreLocation
import Observation
import SwiftData

// MARK: - Public value types

/// Immutable current-weather reading for a coordinate. Encoded into
/// `WeatherCacheRecord.snapshotJSON` for the 12-hour cache and read by NowScore
/// (US-003) so weather can influence the now-score without a per-marker fetch.
public struct WeatherSnapshot: Sendable, Codable {
    public let tempC: Double
    public let condition: WeatherCondition
    public let precipChancePct: Int
    public let windKph: Double
    public let observedAt: Date

    public init(
        tempC: Double,
        condition: WeatherCondition,
        precipChancePct: Int,
        windKph: Double,
        observedAt: Date
    ) {
        self.tempC = tempC
        self.condition = condition
        self.precipChancePct = precipChancePct
        self.windKph = windKph
        self.observedAt = observedAt
    }
}

/// Coarse sky/precipitation bucket. Raw values are stable for `Codable`
/// round-tripping through the cache; never rename existing cases.
public enum WeatherCondition: String, Sendable, Codable {
    case clear
    case partlyCloudy
    case cloudy
    case rain
    case storm
    case snow
    case fog
}

/// Failures surfaced by `WeatherService`. Callers must handle `.noAPIKey`
/// gracefully (NowScore falls back to non-weather signals).
public enum WeatherError: Error {
    case noAPIKey
    case networkUnavailable
    case decodingFailed
}

// MARK: - Network seam

/// Minimal seam over `URLSession` so tests can inject a mock that counts calls
/// and returns canned bytes. Production uses `URLSessionWeatherFetcher`.
public protocol WeatherDataFetching: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

/// Production fetcher backed by a real `URLSession`.
public struct URLSessionWeatherFetcher: WeatherDataFetching {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    /// Fetches data for `url` through the injected session.
    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }
}

// MARK: - WeatherService

/// Fetches and caches current weather for any coordinate. A SwiftData-backed
/// 12-hour cache keyed by a ~1.1 km coordinate cell means NowScore can score
/// many markers from one network call.
///
/// Offline behaviour (`NetworkMonitor.shared.isConnected == false`): read the
/// cache only. On a miss the call resolves without a network round-trip — it
/// surfaces `.networkUnavailable` so the caller degrades quietly rather than
/// blocking on a request that cannot succeed.
@MainActor
@Observable
public final class WeatherService {
    /// TTL for a cached snapshot: 12 hours.
    public static let cacheTTL: TimeInterval = 12 * 3600

    private let context: ModelContext
    private let fetcher: WeatherDataFetching
    private let apiKeyProvider: @Sendable () -> String?
    private let isOnlineProvider: @MainActor () -> Bool
    @ObservationIgnored private var tripForecasts: [String: (fetchedAt: Date, data: [TripWeatherReading])] = [:]

    /// - Parameters:
    ///   - container: SwiftData container holding `WeatherCacheRecord`. Defaults
    ///     to the app-wide singleton; tests pass `makeInMemory()`.
    ///   - fetcher: network seam; tests inject a counting mock.
    ///   - apiKeyProvider: resolves the OpenWeather key; defaults to
    ///     `Secrets.openWeatherAPIKey`. Returns `nil` when unconfigured.
    ///   - isOnlineProvider: reachability seam; defaults to `NetworkMonitor`.
    public init(
        container: ModelContainer = SoloCompassModelContainer.shared,
        fetcher: WeatherDataFetching = URLSessionWeatherFetcher(),
        apiKeyProvider: (@Sendable () -> String?)? = nil,
        isOnlineProvider: (@MainActor () -> Bool)? = nil
    ) {
        self.context = ModelContext(container)
        self.fetcher = fetcher
        // `Secrets` is internal so it can't be a public-init default arg value;
        // wrap it in a closure here instead.
        self.apiKeyProvider = apiKeyProvider ?? { Secrets.openWeatherAPIKey }
        self.isOnlineProvider = isOnlineProvider ?? { NetworkMonitor.shared.isConnected }
    }

    // MARK: - Public

    /// Current weather for `coord`. Returns a cached snapshot when one is fresh
    /// (< 12h); otherwise fetches, caches, and returns. Throws `.noAPIKey` when
    /// no key is configured. When offline, only the cache is consulted; a miss
    /// throws `.networkUnavailable` (callers treat that as "no weather").
    public func current(at coord: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        let key = Self.coordKey(lat: coord.latitude, lon: coord.longitude)

        // Cache hit (fresh) short-circuits the network regardless of connectivity.
        if let cached = cachedSnapshot(for: key), Self.isFresh(cached.observedAt) {
            return cached
        }

        // Offline: cache-only. A miss is not fetched — return a stale snapshot
        // if present, else surface `.networkUnavailable`.
        guard isOnlineProvider() else {
            if let stale = cachedSnapshot(for: key) {
                return stale
            }
            throw WeatherError.networkUnavailable
        }

        // Online + (miss or stale): fetch fresh, persist, return.
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw WeatherError.noAPIKey
        }
        guard let url = Self.requestURL(coord: coord, apiKey: apiKey) else {
            throw WeatherError.networkUnavailable
        }

        let data: Data
        do {
            (data, _) = try await fetcher.data(from: url)
        } catch {
            throw WeatherError.networkUnavailable
        }

        let snapshot = try Self.decode(data)
        persist(snapshot, key: key)
        return snapshot
    }

    /// The itinerary asks for a destination-local time, converted to an instant by the caller.
    func tripForecast(at coordinate: CLLocationCoordinate2D, for interval: DateInterval, now: Date = Date()) async throws -> TripWeatherReading? {
        guard interval.end >= now, interval.start <= now.addingTimeInterval(5 * 86_400) else { return nil }
        let key = Self.coordKey(lat: coordinate.latitude, lon: coordinate.longitude)
        let readings: [TripWeatherReading]
        if let cached = tripForecasts[key], now.timeIntervalSince(cached.fetchedAt) < 1_800 {
            readings = cached.data
        } else {
            guard isOnlineProvider() else { throw WeatherError.networkUnavailable }
            readings = try await requestTripForecast(at: coordinate)
            if tripForecasts.count >= 12 { tripForecasts.removeAll() }
            tripForecasts[key] = (now, readings)
        }
        let usable = readings.filter { reading in
            reading.provider == .openWeather
                ? reading.date >= interval.start.addingTimeInterval(-5_400) && reading.date <= interval.end.addingTimeInterval(5_400)
                : reading.date >= interval.start.addingTimeInterval(-1_800) && reading.date <= interval.end.addingTimeInterval(1_800)
        }
        return usable.max {
            if $0.rainRisk != $1.rainRisk { return $0.rainRisk < $1.rainRisk }
            return abs($0.date.timeIntervalSince(interval.start)) > abs($1.date.timeIntervalSince(interval.start))
        }
    }

    private func requestTripForecast(at coordinate: CLLocationCoordinate2D) async throws -> [TripWeatherReading] {
        if let key = apiKeyProvider(), !key.isEmpty,
           let currentURL = Self.requestURL(coord: coordinate, apiKey: key),
           var parts = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) {
            parts.path = "/data/2.5/forecast"
            if let url = parts.url {
                do {
                    let (data, response) = try await fetcher.data(from: url)
                    guard response is HTTPURLResponse, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw WeatherError.networkUnavailable
                    }
                    return try Self.decodeTripForecast(data)
                } catch {
                    #if DEBUG
                    try Task.checkCancellation()
                    #else
                    throw error
                    #endif
                }
            }
        }
        #if DEBUG
        return try await developmentTripForecast(at: coordinate)
        #else
        throw WeatherError.noAPIKey
        #endif
    }

    static func decodeTripForecast(_ data: Data) throws -> [TripWeatherReading] {
        struct Response: Decodable {
            struct Reading: Decodable {
                struct Main: Decodable { let temp: Double }
                struct Condition: Decodable { let id: Int }
                struct Clouds: Decodable { let all: Int }
                let dt: Double
                let main: Main
                let weather: [Condition]
                let clouds: Clouds?
                let pop: Double?
            }
            let list: [Reading]
        }
        return try JSONDecoder().decode(Response.self, from: data).list.compactMap {
            guard let code = $0.weather.first?.id, $0.main.temp.isFinite else { return nil }
            return TripWeatherReading(date: Date(timeIntervalSince1970: $0.dt), temperature: $0.main.temp,
                probability: $0.pop.flatMap { (0...1).contains($0) ? Int(($0 * 100).rounded()) : nil },
                condition: mapCondition(id: code, cloudPct: $0.clouds?.all ?? 0), provider: .openWeather)
        }
    }

    #if DEBUG
    private func developmentTripForecast(at coordinate: CLLocationCoordinate2D) async throws -> [TripWeatherReading] {
        struct Result: Decodable {
            struct Hourly: Decodable {
                let time: [Int]
                let temperature_2m: [Double?]
                let precipitation_probability: [Int?]
                let weather_code: [Int?]
            }
            let hourly: Hourly
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "timeformat", value: "unixtime"), URLQueryItem(name: "forecast_days", value: "6")
        ]
        guard let url = components?.url else { throw WeatherError.networkUnavailable }
        let (data, response) = try await fetcher.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WeatherError.networkUnavailable }
        let hourly = try JSONDecoder().decode(Result.self, from: data).hourly
        return hourly.time.indices.compactMap { index in
            guard hourly.temperature_2m.indices.contains(index), hourly.weather_code.indices.contains(index),
                  let temp = hourly.temperature_2m[index], let code = hourly.weather_code[index] else { return nil }
            let condition: WeatherCondition
            switch code {
            case 0: condition = .clear
            case 1...2: condition = .partlyCloudy
            case 3: condition = .cloudy
            case 45...48: condition = .fog
            case 71...77, 85...86: condition = .snow
            case 95...99: condition = .storm
            default: condition = .rain
            }
            let probability = hourly.precipitation_probability.indices.contains(index) ? hourly.precipitation_probability[index] : nil
            return TripWeatherReading(date: Date(timeIntervalSince1970: Double(hourly.time[index])), temperature: temp,
                probability: probability, condition: condition, provider: .openMeteo)
        }
    }
    #endif

    // MARK: - Cache

    /// Read a snapshot for `key` if a record exists. Returns `nil` on miss or
    /// when the stored JSON can't be decoded (treated as a miss).
    private func cachedSnapshot(for key: String) -> WeatherSnapshot? {
        var descriptor = FetchDescriptor<WeatherCacheRecord>(
            predicate: #Predicate { $0.coordKey == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(WeatherSnapshot.self, from: record.snapshotJSON)
    }

    /// Insert-or-update the cache row for `key`. Keeps one row per cell.
    private func persist(_ snapshot: WeatherSnapshot, key: String) {
        guard let json = try? JSONEncoder().encode(snapshot) else { return }
        var descriptor = FetchDescriptor<WeatherCacheRecord>(
            predicate: #Predicate { $0.coordKey == key }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.snapshotJSON = json
            existing.observedAt = snapshot.observedAt
        } else {
            context.insert(WeatherCacheRecord(
                coordKey: key,
                snapshotJSON: json,
                observedAt: snapshot.observedAt
            ))
        }
        try? context.save()
    }

    /// True when `observedAt` is within the 12-hour TTL of now.
    static func isFresh(_ observedAt: Date) -> Bool {
        Date().timeIntervalSince(observedAt) < cacheTTL
    }

    /// Deterministic cache key: lat/lon rounded to 2 decimals (~1.1 km cell),
    /// e.g. `"21.03_105.85"`.
    static func coordKey(lat: Double, lon: Double) -> String {
        let rLat = (lat * 100).rounded() / 100
        let rLon = (lon * 100).rounded() / 100
        return String(format: "%.2f_%.2f", rLat, rLon)
    }

    // MARK: - Request / decode (OpenWeather Current Weather API)

    /// Build the OpenWeather `/data/2.5/weather` URL for `coord` in metric units.
    static func requestURL(coord: CLLocationCoordinate2D, apiKey: String) -> URL? {
        var components = URLComponents(string: "https://api.openweathermap.org/data/2.5/weather")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(coord.latitude)),
            URLQueryItem(name: "lon", value: String(coord.longitude)),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "appid", value: apiKey)
        ]
        return components?.url
    }

    /// Decode an OpenWeather current-weather response into a `WeatherSnapshot`.
    /// `observedAt` is stamped at decode time so cache freshness tracks our
    /// fetch time rather than the upstream observation timestamp.
    static func decode(_ data: Data) throws -> WeatherSnapshot {
        struct Response: Decodable {
            struct Weather: Decodable { let id: Int }
            struct Main: Decodable { let temp: Double }
            struct Wind: Decodable { let speed: Double }
            struct Clouds: Decodable { let all: Int? }
            let weather: [Weather]
            let main: Main
            let wind: Wind?
            let clouds: Clouds?
            let pop: Double?            // probability of precipitation (0–1), if present
        }
        let resp: Response
        do {
            resp = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }
        let weatherId = resp.weather.first?.id ?? 800
        let cloudPct = resp.clouds?.all ?? 0
        let condition: WeatherCondition = mapCondition(id: weatherId, cloudPct: cloudPct)
        // `pop` is 0–1; OpenWeather Current Weather often omits it, so fall back
        // to a coarse estimate from the condition bucket.
        let precipPct: Int
        if let pop = resp.pop {
            precipPct = Int((pop * 100).rounded())
        } else {
            precipPct = Self.defaultPrecip(for: condition)
        }
        let windKph = (resp.wind?.speed ?? 0) * 3.6   // m/s → km/h
        return WeatherSnapshot(
            tempC: resp.main.temp,
            condition: condition,
            precipChancePct: precipPct,
            windKph: windKph,
            observedAt: Date()
        )
    }

    /// Map an OpenWeather condition id (+ cloud cover) to a coarse bucket.
    /// id ranges per OpenWeather docs: 2xx storm, 3xx/5xx rain, 6xx snow,
    /// 7xx atmosphere/fog, 800 clear, 80x clouds.
    static func mapCondition(id: Int, cloudPct: Int) -> WeatherCondition {
        switch id {
        case 200..<300: return .storm
        case 300..<600: return .rain
        case 600..<700: return .snow
        case 700..<800: return .fog
        case 800: return .clear
        default:
            // 80x cloud group: split partly vs fully cloudy by cover.
            return cloudPct >= 70 ? .cloudy : .partlyCloudy
        }
    }

    /// Coarse precip-chance fallback when the response omits `pop`.
    private static func defaultPrecip(for condition: WeatherCondition) -> Int {
        switch condition {
        case .storm: return 90
        case .rain: return 70
        case .snow: return 60
        case .fog: return 20
        case .cloudy: return 20
        case .partlyCloudy: return 10
        case .clear: return 0
        }
    }
}

struct TripWeatherReading: Equatable, Sendable {
    enum Provider: String, Sendable { case openWeather = "OpenWeather", openMeteo = "Open-Meteo" }
    let date: Date
    let temperature: Double
    let probability: Int?
    let condition: WeatherCondition
    let provider: Provider

    var rainRisk: Int {
        switch condition {
        case .storm, .snow: return 110
        case .rain: return max(70, probability ?? 0)
        default: return probability ?? 0
        }
    }
    var warrantsIndoorOption: Bool { rainRisk >= 55 }
}
