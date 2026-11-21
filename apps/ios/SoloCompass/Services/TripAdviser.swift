import CoreLocation
import Foundation

enum TripAdviser {
    static func indoorAlternative(to stop: TripStop, day: TripDay, in trip: TripRecord, summary: String) -> TripProposal? {
        guard stop.activity == .outdoor, !stop.locked, let origin = stop.place?.coordinate,
              let dayIndex = trip.plan.days.firstIndex(where: { $0.id == day.id }),
              trip.plan.days[dayIndex].stops.contains(stop) else { return nil }

        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let used = Set(trip.plan.plannedChanges.keys)
        let nearby = trip.plan.handbook.filter {
            $0.cityCode == day.city.code && $0.activity == .indoor && !used.contains($0.id)
        }.compactMap { place -> (TripGuidePlace, CLLocationDistance)? in
            let distance = originLocation.distance(from: CLLocation(latitude: place.place.latitude, longitude: place.place.longitude))
            return distance <= 2_000 ? (place, distance) : nil
        }.sorted { $0.1 < $1.1 }

        var adjusted = trip.plan
        adjusted.days[dayIndex].stops.removeAll { $0.id == stop.id }
        let nextStart = day.stops.filter { $0.startMinute > stop.startMinute }.map(\.startMinute).min() ?? 19 * 60
        guard let candidate = nearby.first(where: {
            adjusted.days[dayIndex].availableTime(duration: $0.0.durationMinutes, earliest: stop.startMinute + 20,
                                                   latest: nextStart - 20) != nil
        }), let time = adjusted.days[dayIndex].availableTime(duration: candidate.0.durationMinutes,
                                                               earliest: stop.startMinute + 20, latest: nextStart - 20) else {
            return nil
        }
        adjusted.days[dayIndex].stops.append(candidate.0.stop(at: time))

        let following = dayIndex + 1
        if adjusted.days.indices.contains(following), adjusted.days[following].city.code == day.city.code,
           let slot = adjusted.days[following].availableTime(duration: stop.durationMinutes, earliest: 10 * 60 + 30, latest: 17 * 60) {
            var moved = stop
            moved.time = slot
            adjusted.days[following].stops.append(moved)
        } else if let place = stop.place {
            let id = "weather-" + stop.id
            if !adjusted.handbook.contains(where: { $0.id == id }) {
                adjusted.handbook.append(TripGuidePlace(id: id, cityCode: day.city.code, title: stop.title,
                    durationMinutes: stop.durationMinutes, activity: stop.activity, place: place, note: stop.note, sourceURL: nil))
            }
        }
        guard (try? adjusted.validate(preserving: trip.plan)) != nil else { return nil }
        return TripProposal(tripId: trip.id, baseVersion: trip.version, summary: summary, plan: adjusted)
    }

    static func nearbyEvents(_ events: [CityEvent], day: TripDay, place: TripPlace, limit: Int = 4) -> [CityEvent] {
        guard let zone = TimeZone(identifier: day.city.timezone),
              let date = TripPlan.date(day.date, zone: zone) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let dates = calendar.dateInterval(of: .day, for: date) else { return [] }
        let here = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return events.compactMap { event -> (CityEvent, CLLocationDistance)? in
            guard !event.isNotice, let source = event.sourceURL, source.scheme == "https", source.host != nil,
                  source.user == nil, source.password == nil, !event.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = event.startsAt, start < dates.end, (event.endsAt ?? start) >= dates.start,
                  event.endsAt.map({ $0 >= start }) ?? true,
                  let lat = event.lat, let lng = event.lng,
                  CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lng)) else { return nil }
            let distance = here.distance(from: CLLocation(latitude: lat, longitude: lng))
            return distance <= 3_000 ? (event, distance) : nil
        }.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }
}
