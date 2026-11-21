import CoreLocation
import Foundation

enum FootprintTimeFilter: Equatable, Sendable {
    case all, today, week, month
    case custom(ClosedRange<Date>)

    func days(endingOn today: Date, calendar: Calendar) -> ClosedRange<Date>? {
        switch self {
        case .all: return nil
        case .today: return today...today
        case .week, .month:
            let offset = self == .week ? -6 : -29
            return (calendar.date(byAdding: .day, value: offset, to: today) ?? today)...today
        case .custom(let days): return days
        }
    }
}

struct FootprintFilter: Equatable, Sendable {
    var time: FootprintTimeFilter = .all
    var cityID: String?
    var isActive: Bool { self != Self() }
}

struct FootprintCity: Identifiable, Sendable {
    static let unassignedID = "unassigned"
    let id: String
    let name: String
    let center: CLLocationCoordinate2D
}

struct FootprintHistory: Sendable {
    struct Day: Identifiable, Sendable {
        let date: Date
        var points = 0
        var stops = 0
        var photos = 0
        var id: Date { date }
        var entryCount: Int { points + stops + photos }
    }

    struct Selection: Sendable {
        let map: FootprintMapDay
        let days: [Day]
        let cities: [FootprintCity]
    }

    private struct Record: Sendable {
        let entry: FootprintEntry
        let day: Date
        let cityID: String
    }

    private let records: [Record]
    private let daysByCity: [String: [Day]]
    let days: [Day]
    let cities: [FootprintCity]
    let calendar: Calendar
    let hasUnassigned: Bool
    var today: Date { calendar.startOfDay(for: Date()) }
    var domain: ClosedRange<Date> {
        min(days.first?.date ?? today, today)...today
    }

    init(entries: [FootprintEntry] = [], cities: [FootprintCity] = [], calendar: Calendar = .current) {
        self.calendar = calendar
        var records: [Record] = []
        var allDays: [Date: Day] = [:]
        var cityDays: [String: [Date: Day]] = [:]
        var latest: [String: Int64] = [:]
        var previousPosition: CLLocationCoordinate2D?
        var cityID = FootprintCity.unassignedID
        for entry in entries {
            if Task.isCancelled { break }
            let date = calendar.startOfDay(for: entry.date)
            if let coordinate = entry.coordinate {
                if previousPosition?.latitude != coordinate.latitude || previousPosition?.longitude != coordinate.longitude {
                    cityID = Self.nearestCity(to: coordinate, among: cities)
                    previousPosition = coordinate
                }
            } else {
                cityID = FootprintCity.unassignedID
                previousPosition = nil
            }
            records.append(Record(entry: entry, day: date, cityID: cityID))
            allDays[date, default: Day(date: date)].add(entry.kind)
            cityDays[cityID, default: [:]][date, default: Day(date: date)].add(entry.kind)
            latest[cityID] = entry.at
        }
        self.records = records
        days = allDays.values.sorted { $0.date < $1.date }
        daysByCity = cityDays.mapValues { $0.values.sorted { $0.date < $1.date } }
        hasUnassigned = latest[FootprintCity.unassignedID] != nil
        self.cities = cities.filter { latest[$0.id] != nil }.sorted {
            let lhs = latest[$0.id] ?? 0
            let rhs = latest[$1.id] ?? 0
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
        }
    }

    func matchingDays(_ filter: FootprintFilter) -> [Day] {
        let candidates = filter.cityID.map { daysByCity[$0] ?? [] } ?? days
        guard let range = filter.time.days(endingOn: today, calendar: calendar) else { return candidates }
        return candidates.filter { range.contains($0.date) }
    }

    func select(_ filter: FootprintFilter) -> Selection {
        let range = filter.time.days(endingOn: today, calendar: calendar)
        var entries: [FootprintEntry] = []
        var breaks = Set<UUID>()
        var skippedPoint = false
        for record in records {
            if Task.isCancelled { break }
            if let range, !range.contains(record.day) { continue }
            if let cityID = filter.cityID, cityID != record.cityID {
                if record.entry.kind == .point { skippedPoint = true }
                continue
            }
            if record.entry.kind == .point && skippedPoint {
                breaks.insert(record.entry.id)
                skippedPoint = false
            }
            entries.append(record.entry)
        }
        let visibleCities = cities.filter { city in
            (filter.cityID == nil || filter.cityID == city.id) &&
                !matchingDays(FootprintFilter(time: filter.time, cityID: city.id)).isEmpty
        }
        return Selection(map: FootprintMapDay(entries: entries, breakBefore: breaks),
                         days: matchingDays(filter), cities: visibleCities)
    }

    private static func nearestCity(to coordinate: CLLocationCoordinate2D, among cities: [FootprintCity]) -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var closest = FootprintCity.unassignedID
        var bestDistance: CLLocationDistance = 75_000
        for city in cities where abs(city.center.latitude - coordinate.latitude) <= 0.7 {
            let center = CLLocation(latitude: city.center.latitude, longitude: city.center.longitude)
            let distance = location.distance(from: center)
            if distance < bestDistance {
                closest = city.id
                bestDistance = distance
            }
        }
        return closest
    }
}

private extension FootprintHistory.Day {
    mutating func add(_ kind: FootprintEntry.Kind) {
        switch kind {
        case .point: points += 1
        case .visit: stops += 1
        case .photo: photos += 1
        }
    }
}
