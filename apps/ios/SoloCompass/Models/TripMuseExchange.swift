import Foundation

enum TripMuseExchange {
    static func request(_ instruction: String, revising record: TripRecord?) throws -> String {
        let schema = """
        Return exactly one JSON object, no prose. Follow the travelers' language. Use these keys:
        {"tripId":null,"baseVersion":null,"summary":"Short reason for the plan","plan":{"title":"Trip name","days":[{"date":"2027-01-01","city":{"code":"bkk","name":"Bangkok","timezone":"Asia/Bangkok"},"stops":[{"id":"stable-id","time":"10:00","title":"Stop title","durationMinutes":60,"activity":"outdoor","place":{"name":"Verified location","latitude":13.75,"longitude":100.50},"locked":false,"note":"Why this fits or what to verify"}]}],"handbook":[{"id":"guide-id","cityCode":"bkk","title":"Saved place","durationMinutes":60,"activity":"indoor","place":{"name":"Verified location","latitude":13.75,"longitude":100.50},"note":null,"sourceURL":null}]}}
        The dates in the schema are examples, not requirements. Include every local travel date (up to 31 consecutive days) exactly once, even free days; use stops: [] for a free day. Use city codes such as kyoto, osaka, bkk, cmi, kul, pen and IANA time zones. Use city-local 24-hour time with non-overlapping stops and time for transfers. Use the exact activity values indoor, outdoor, transit or other. Use unique stable IDs. Verify locations when possible. For an unverified stop use place: null, and omit unverified places from the handbook. Only include an HTTPS source if you actually have it. Treat future weather, hours and reservations as unverified unless supported by a source for the date. Avoid using personal data unless the traveler explicitly requests it. Output a complete plan.
        """
        guard let record else {
            return "Create a new Roamorrow trip (keep tripId and baseVersion null).\n\nTraveler request:\n\(instruction)\n\n\(schema)"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input = TripProposal(tripId: record.id, baseVersion: record.version, summary: "", plan: record.plan)
        let plan = String(decoding: try encoder.encode(input), as: UTF8.self)
        return """
        Propose a change to this Roamorrow trip. Keep the exact tripId and baseVersion shown below and use stable IDs for stops you update. Keep all locked stops byte-for-byte equivalent on the original dates and cities. Only make changes that are needed for the request. Explain the reason in summary.

        Traveler request:
        \(instruction)

        \(schema)

        Current version:
        \(plan)
        """
    }

    static func proposal(from content: String, for record: TripRecord?) throws -> TripProposal {
        guard content.utf8.count <= 512_000 else { throw TravelResearchError.invalidArguments }
        var value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```"), let heading = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: heading)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let draft = try JSONDecoder().decode(TripProposal.self, from: Data(value.utf8))
        guard draft.tripId == record?.id, draft.baseVersion == record?.version,
              !draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.summary.count <= 600,
              draft.plan != record?.plan else { throw TravelResearchError.invalidArguments }
        try draft.plan.validate(preserving: record?.plan)
        return draft
    }
}

struct TripPlanChange: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var before: String?
    var after: String?
    var dates: [String] = []

    static func between(_ before: TripPlan?, and after: TripPlan) -> [Self] {
        guard let before else { return [] }
        var result: [Self] = []
        if before.title != after.title {
            result.append(Self(id: "title", symbol: "pencil", title: tripText("review.titleChanged", "Trip name"), before: before.title, after: after.title))
        }
        let priorDays = Dictionary(uniqueKeysWithValues: before.days.map { ($0.id, $0) })
        let nextDays = Dictionary(uniqueKeysWithValues: after.days.map { ($0.id, $0) })
        for id in Set(priorDays.keys).union(nextDays.keys).sorted() {
            let previous = priorDays[id]
            let updated = nextDays[id]
            if previous?.city != updated?.city {
                result.append(Self(id: "day.\(id)", symbol: "calendar", title: (updated ?? previous).map { tripDateLabel($0) } ?? id,
                    before: previous.map { dayDescription($0) }, after: updated.map { dayDescription($0) }, dates: [id]))
            }
        }
        let priorStops = stops(before)
        let nextStops = stops(after)
        for id in Set(priorStops.keys).union(nextStops.keys).sorted(by: {
            let a = nextStops[$0] ?? priorStops[$0]
            let b = nextStops[$1] ?? priorStops[$1]
            let left = (a?.day.date ?? "", a?.stop.time ?? "", $0)
            let right = (b?.day.date ?? "", b?.stop.time ?? "", $1)
            return left < right
        }) {
            let previous = priorStops[id]
            let updated = nextStops[id]
            guard previous?.stop != updated?.stop || previous?.day.date != updated?.day.date else { continue }
            result.append(Self(id: "stop.\(id)",
                symbol: previous == nil ? "plus" : updated == nil ? "minus" : "arrow.right",
                title: updated?.stop.title ?? previous?.stop.title ?? id,
                before: previous.map { stopDescription($0.day, $0.stop) },
                after: updated.map { stopDescription($0.day, $0.stop) },
                dates: [previous?.day.date, updated?.day.date].compactMap { $0 }))
        }
        let oldGuide = Dictionary(uniqueKeysWithValues: before.handbook.map { ($0.id, $0) })
        let newGuide = Dictionary(uniqueKeysWithValues: after.handbook.map { ($0.id, $0) })
        for id in Set(oldGuide.keys).union(newGuide.keys).sorted() where oldGuide[id] != newGuide[id] {
            result.append(Self(id: "guide.\(id)", symbol: "book",
                title: tripText("handbook", "Handbook"),
                before: oldGuide[id].map { guideDescription($0, in: before) },
                after: newGuide[id].map { guideDescription($0, in: after) }))
        }
        return result
    }

    private static func stops(_ plan: TripPlan) -> [String: (day: TripDay, stop: TripStop)] {
        Dictionary(uniqueKeysWithValues: plan.days.flatMap { day in day.stops.map { ($0.id, (day, $0)) } })
    }

    private static func dayDescription(_ day: TripDay) -> String {
        "\(day.city.name) · \(day.city.timezone)"
    }

    private static func stopDescription(_ day: TripDay, _ stop: TripStop) -> String {
        let time = "\(tripDateLabel(day)) · \(stop.time) · " + String(format: tripText("minutes", "%d min"), stop.durationMinutes)
        return [time, stop.place?.name, stop.locked ? tripText("locked", "Locked") : nil, stop.note]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func guideDescription(_ place: TripGuidePlace, in plan: TripPlan) -> String {
        [place.title, plan.days.first { $0.city.code == place.cityCode }?.city.name, place.note, place.sourceURL?.host]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
