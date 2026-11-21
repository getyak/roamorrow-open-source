import MapKit
import SwiftUI

struct TripPlaceTarget: Identifiable {
    let day: TripDay
    let stop: TripStop?
    let guide: TripGuidePlace?

    init(day: TripDay, stop: TripStop) {
        self.day = day
        self.stop = stop
        self.guide = nil
    }

    init(day: TripDay, guide: TripGuidePlace) {
        self.day = day
        self.stop = nil
        self.guide = guide
    }

    var id: String { stop?.id ?? guide?.id ?? day.id }
    var title: String { stop?.title ?? guide?.title ?? day.city.name }
    var note: String? { stop?.note ?? guide?.note }
    var place: TripPlace? { stop?.place ?? guide?.place }
    var activity: TripActivity? { stop?.activity ?? guide?.activity }

    var zone: TimeZone { TimeZone(identifier: day.city.timezone) ?? .gmt }

    var interval: DateInterval? {
        guard let date = TripPlan.date(day.date, zone: zone) else { return nil }
        guard let stop else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.dateInterval(of: .day, for: date)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(bySettingHour: stop.startMinute / 60, minute: stop.startMinute % 60,
                                        second: 0, of: date, matchingPolicy: .strict),
              calendar.isDate(start, inSameDayAs: date) else { return nil }
        return DateInterval(start: start, duration: Double(stop.durationMinutes) * 60)
    }
}

struct TripPlaceSheet: View {
    let target: TripPlaceTarget
    let record: TripRecord
    let onAdd: (TripGuidePlace, String) -> Void
    let onProposal: (TripProposal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var weather = WeatherService()
    @State private var brief = CityBriefService()
    @State private var localToday = false
    @State private var weatherStatus: WeatherStatus = .loading
    @State private var eventsReady = false
    @State private var searchRequest = 0
    @State private var webOutcome: WebSearchService.SearchOutcome?

    private enum WeatherStatus {
        case loading, ready(TripWeatherReading), outsideForecast, unavailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    title
                    if let place = target.place {
                        if !record.isExample || target.id != "jp-tea" { map(place) }
                        weatherCard
                        eventsCard(place)
                    } else {
                        Text(tripText("place.noCoordinates", "Add a verified location to check weather and nearby events."))
                            .font(.subheadline)
                    }
                    if let source = target.guide?.sourceURL {
                        Link(destination: source) { Label(tripText("place.source", "Open source"), systemImage: "arrow.up.right") }
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(21)
            }
            .safeAreaInset(edge: .bottom) { addButton }
            .foregroundStyle(CompanionHomeStyle.ink)
            .background(CompanionHomeStyle.paper.ignoresSafeArea())
            .navigationTitle(tripText("place.title", "Place details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tripText("done", "Done")) { dismiss() } } }
            .task(id: localToday) { await loadWeather() }
            .task {
                guard target.place != nil else { return }
                await brief.load(cityCode: target.day.city.code)
                guard !Task.isCancelled else { return }
                eventsReady = true
            }
            .task(id: searchRequest) {
                guard searchRequest > 0 else { return }
                let outcome = await WebSearchService.shared.searchOutcome(query: eventQuery)
                if !Task.isCancelled { webOutcome = outcome }
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(target.title).font(.system(.largeTitle, design: .serif, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text([target.day.city.name, tripDateLabel(target.day), target.stop?.time].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.medium)).foregroundStyle(CompanionHomeStyle.secondaryInk)
            if let note = target.note { Text(note).font(.subheadline) }
        }
    }

    private func map(_ place: TripPlace) -> some View {
        Map(initialPosition: .region(.init(center: place.coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200)),
            interactionModes: []) {
            Marker(place.name, coordinate: place.coordinate).tint(CompanionHomeStyle.accent)
        }
        .frame(height: 153)
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(localToday ? tripText("weather.today", "Local weather today") : tripText("weather.scheduled", "Weather for this stop"),
                  systemImage: "cloud.sun")
                .font(.headline)
            switch weatherStatus {
            case .loading:
                ProgressView().accessibilityLabel(tripText("weather.loading", "Checking forecast"))
            case .outsideForecast:
                Text(tripText("weather.outside", "There’s no forecast for this date yet. Check within five days of the visit."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .accessibilityIdentifier("trip.weather.outside")
            case .unavailable:
                Text(tripText("weather.unavailable", "Weather is unavailable right now."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .accessibilityIdentifier("trip.weather.unavailable")
            case .ready(let reading):
                weatherResult(reading)
            }
            Button(localToday ? tripText("weather.back", "Return to planned date") : tripText("weather.checkToday", "Check local weather today")) {
                localToday.toggle()
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 36)
            .accessibilityIdentifier("trip.weather.localToday")
        }
        .tripInfoCard()
    }

    private func weatherResult(_ reading: TripWeatherReading) -> some View {
        let date = reading.date.formatted(.dateTime.month().day().hour().minute().timeZone(target.zone))
        let temperature = String(format: "%.0f°C", reading.temperature)
        let values = [temperature, reading.probability.map { String(format: tripText("weather.rain", "%d%% chance of rain"), $0) }]
        return VStack(alignment: .leading, spacing: 7) {
            Text(values.compactMap { $0 }.joined(separator: " · "))
                .font(.title3.weight(.semibold)).accessibilityIdentifier("trip.weather.result")
            Text("\(date) · \(reading.provider.rawValue)").font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
            if target.activity == .outdoor, reading.warrantsIndoorOption {
                Text(tripText("weather.risk", "Rain or snow may affect this outdoor stop."))
                    .font(.subheadline)
                if !localToday, let stop = target.stop,
                   let proposal = TripAdviser.indoorAlternative(to: stop, day: target.day, in: record,
                       summary: tripText("weather.adjust", "Use a nearby indoor option and check the weather before the rescheduled walk.")) {
                    Button(tripText("review", "Review changes")) { onProposal(proposal) }
                        .font(.subheadline.bold())
                }
            } else if target.activity == .outdoor {
                Text(tripText("weather.outdoor", "The forecast indicates a low rain risk for this window."))
                    .font(.subheadline)
            }
        }
    }

    private func eventsCard(_ place: TripPlace) -> some View {
        let events = TripAdviser.nearbyEvents(brief.events, day: target.day, place: place)
        return VStack(alignment: .leading, spacing: 9) {
            Label(tripText("events.title", "Nearby that day"), systemImage: "sparkle.magnifyingglass").font(.headline)
            if !eventsReady {
                ProgressView().accessibilityLabel(tripText("events.loading", "Checking local events"))
            } else if events.isEmpty {
                Text(tripText("events.empty", "Roamorrow has no sourced listings within 3 km for this date."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .accessibilityIdentifier("trip.events.empty")
            } else {
                ForEach(events) { event in
                    if let source = event.sourceURL {
                        Link(destination: source) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(event.name, systemImage: "arrow.up.right").font(.subheadline.bold())
                                Text([event.whenLabel, event.seenLabel].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            if searchRequest == 0 {
                Button {
                    searchRequest += 1
                } label: {
                    Label(tripText("events.search", "Search this date and area"), systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 40)
                }
                .accessibilityIdentifier("trip.events.search")
            } else if let webOutcome {
                webResults(webOutcome)
            } else {
                ProgressView().accessibilityLabel(tripText("events.loading", "Checking local events"))
            }
        }
        .tripInfoCard()
    }

    @ViewBuilder private func webResults(_ outcome: WebSearchService.SearchOutcome) -> some View {
        switch outcome.status {
        case .results:
            let sources = outcome.results.compactMap { result -> (WebSearchResult, URL)? in
                guard let url = URL(string: result.url), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil else { return nil }
                return (result, url)
            }
            if !sources.isEmpty {
                Text(tripText("events.leads", "Web results · check the date and venue with the organizer"))
                    .font(.footnote.weight(.semibold))
                ForEach(sources.prefix(4), id: \.0.id) { result, url in
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).font(.subheadline.bold()).lineLimit(2)
                            Text(result.host).font(.caption)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        case .empty:
            Text(tripText("events.webEmpty", "No web results for that search.")).font(.footnote)
        case .unavailable:
            Text(tripText("events.webUnavailable", "In-app web search is temporarily unavailable.")).font(.footnote)
        }
        if outcome.status != .results, let searchURL {
                Link(destination: searchURL) {
                    Label(tripText("events.browser", "Search in browser"), systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 36)
                }
        }
    }

    private var eventQuery: String {
        "\(target.day.city.name) \(target.place?.name ?? "") \(target.day.date) \(tripText("events.query", "events"))"
    }

    private var searchURL: URL? {
        var url = URLComponents(string: "https://www.google.com/search")
        url?.queryItems = [.init(name: "q", value: eventQuery)]
        return url?.url
    }

    @ViewBuilder private var addButton: some View {
        if let guide = target.guide, record.plan.plannedChanges[guide.id] == nil {
            let time = target.day.availableTime(duration: guide.durationMinutes, earliest: 16 * 60)
                ?? target.day.availableTime(duration: guide.durationMinutes)
            VStack {
                if let time {
                    Button { onAdd(guide, time) } label: {
                        Text(String(format: tripText("guide.add", "Add to this day · %@"), time))
                            .frame(maxWidth: .infinity, minHeight: 37)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CompanionHomeStyle.accent)
                    .foregroundStyle(CompanionHomeStyle.paper)
                    .accessibilityIdentifier("trip.guide.add")
                } else {
                    Text(tripText("guide.noSlot", "There isn’t enough free time on this day. Choose another date."))
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 21).padding(.vertical, 9)
            .background(CompanionHomeStyle.paper)
        }
    }

    private func loadWeather() async {
        guard let place = target.place else { return }
        weatherStatus = .loading
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = target.zone
        let localEnd = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3 * 3_600)
        let todayWindow = DateInterval(start: now, end: min(localEnd, now.addingTimeInterval(3 * 3_600)))
        let interval = localToday ? todayWindow : target.interval
        guard let interval, interval.end >= now, interval.start < now.addingTimeInterval(5 * 86_400) else {
            weatherStatus = .outsideForecast
            return
        }
        do {
            let reading = try await weather.tripForecast(at: place.coordinate, for: interval, now: now)
            guard !Task.isCancelled else { return }
            weatherStatus = reading.map(WeatherStatus.ready) ?? .unavailable
        } catch {
            guard !Task.isCancelled else { return }
            weatherStatus = .unavailable
        }
    }
}

private extension Date.FormatStyle {
    func timeZone(_ zone: TimeZone) -> Self {
        var result = self
        result.timeZone = zone
        return result
    }
}

private extension View {
    func tripInfoCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 16))
    }
}
