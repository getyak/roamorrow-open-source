import CoreLocation
import Foundation

struct TripPlace: Codable, Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool {
        (1...160).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && CLLocationCoordinate2DIsValid(coordinate)
    }
}

struct TripCity: Codable, Equatable, Sendable {
    var code: String
    var name: String
    var timezone: String
}

enum TripActivity: String, Codable, Sendable {
    case indoor, outdoor, transit, other

    var symbol: String {
        switch self {
        case .indoor: "cup.and.saucer"
        case .outdoor: "figure.walk"
        case .transit: "train.side.front.car"
        case .other: "mappin"
        }
    }
}

struct TripStop: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var time: String
    var title: String
    var durationMinutes: Int
    var activity: TripActivity
    var place: TripPlace?
    var locked: Bool
    var note: String?

    var startMinute: Int { TripPlan.minute(of: time) ?? 0 }
    var minutes: Range<Int> { startMinute..<(startMinute + durationMinutes) }
}

struct TripDay: Codable, Equatable, Identifiable, Sendable {
    var date: String
    var city: TripCity
    var stops: [TripStop]
    var id: String { date }

    func availableTime(duration: Int, earliest: Int = 9 * 60, latest: Int = 19 * 60) -> String? {
        guard duration > 0, earliest + duration <= latest else { return nil }
        for start in stride(from: earliest, through: latest - duration, by: 15) {
            if !stops.contains(where: { $0.minutes.overlaps(start..<(start + duration)) }) {
                return String(format: "%02d:%02d", start / 60, start % 60)
            }
        }
        return nil
    }
}

struct TripGuidePlace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var cityCode: String
    var title: String
    var durationMinutes: Int
    var activity: TripActivity
    var place: TripPlace
    var note: String?
    var sourceURL: URL?

    func stop(at time: String) -> TripStop {
        TripStop(id: id, time: time, title: title, durationMinutes: durationMinutes, activity: activity,
                 place: place, locked: false, note: note)
    }
}

struct TripPlan: Codable, Equatable, Sendable {
    var title: String
    var days: [TripDay]
    var handbook: [TripGuidePlace]

    var cityRoute: [String] {
        days.reduce(into: []) { route, day in
            if route.last != day.city.name { route.append(day.city.name) }
        }
    }

    static func minute(of time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func formatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func date(_ value: String, zone: TimeZone) -> Date? {
        guard value.utf8.count == 10 else { return nil }
        let formatter = formatter(zone)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    func validate(preserving previous: TripPlan? = nil) throws {
        func present(_ value: String, max: Int = 160) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= max
        }
        guard present(title), (1...31).contains(days.count), handbook.count <= 150 else {
            throw TravelResearchError.invalidArguments
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var last: Date?
        var stopIDs = Set<String>()
        let cities = Set(days.map(\.city.code))
        for day in days {
            guard let date = Self.date(day.date, zone: .gmt),
                  present(day.city.code, max: 32), present(day.city.name),
                  TimeZone(identifier: day.city.timezone) != nil, day.stops.count <= 16,
                  last.map({ calendar.date(byAdding: .day, value: 1, to: $0) == date }) ?? true else {
                throw TravelResearchError.invalidArguments
            }
            last = date
            var scheduled: [Range<Int>] = []
            for stop in day.stops {
                guard present(stop.id), stopIDs.insert(stop.id).inserted, present(stop.title),
                      let minute = Self.minute(of: stop.time), (5...720).contains(stop.durationMinutes),
                      minute + stop.durationMinutes <= 24 * 60, stop.place?.isValid ?? true,
                      (stop.note?.count ?? 0) <= 600,
                      !scheduled.contains(where: { $0.overlaps(stop.minutes) }) else {
                    throw TravelResearchError.invalidArguments
                }
                scheduled.append(stop.minutes)
            }
        }
        var guideIDs = Set<String>()
        for place in handbook {
            guard present(place.id), guideIDs.insert(place.id).inserted, cities.contains(place.cityCode),
                  present(place.title), (5...720).contains(place.durationMinutes), place.place.isValid,
                  (place.note?.count ?? 0) <= 600,
                  place.sourceURL.map({ $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil }) ?? true else {
                throw TravelResearchError.invalidArguments
            }
        }
        if let previous {
            for day in previous.days {
                for stop in day.stops where stop.locked {
                    guard days.first(where: { $0.date == day.date && $0.city == day.city })?.stops.contains(stop) == true else {
                        throw TravelResearchError.lockedField
                    }
                }
            }
        }
    }

    var plannedChanges: [String: TripStop] {
        var result: [String: TripStop] = [:]
        for day in days { for stop in day.stops { result[stop.id] = stop } }
        return result
    }
}

struct TripRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var version: Int
    var plan: TripPlan
    var undo: TripPlan?
    var latestSummary: String?
    var isExample: Bool
}

struct TripProposal: Codable, Equatable, Sendable {
    var tripId: String?
    var baseVersion: Int?
    var summary: String
    var plan: TripPlan
}
