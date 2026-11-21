#if DEBUG
import CoreLocation
import XCTest
@testable import SoloCompass

@MainActor
final class TripPlanTests: XCTestCase {
    func testExamplesAndRainPreview() throws {
        let examples = TripExamples.records
        XCTAssertEqual(examples.map { $0.plan.cityRoute.count }, [3, 2, 2])
        for example in examples { try example.plan.validate() }
        let trip = examples[0]
        let originalDay = trip.plan.days[2]
        let walk = try XCTUnwrap(originalDay.stops.first { $0.id == "jp-river" })
        let proposal = try XCTUnwrap(TripAdviser.indoorAlternative(to: walk, day: originalDay, in: trip, summary: "Rain example"))
        XCTAssertEqual(proposal.baseVersion, trip.version)
        XCTAssertEqual(proposal.plan.days[2].stops.first { $0.id == "jp-tea" }?.time, "14:30")
        XCTAssertEqual(proposal.plan.days[3].stops.first { $0.id == "jp-river" }?.time, "10:30")
        XCTAssertEqual(proposal.plan.days[2].stops.first { $0.id == "jp-dinner" }, originalDay.stops.first { $0.id == "jp-dinner" })
        XCTAssertEqual(Set(TripPlanChange.between(trip.plan, and: proposal.plan).map(\.id)), ["stop.jp-river", "stop.jp-tea"])
        XCTAssertEqual(trip.plan.days[2].stops.first { $0.id == "jp-river" }?.time, "14:10")
    }

    func testApplyUndoAndStaleDraftAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scope = TravelScope(owner: "test-trip-owner", generation: 1)
        let key = Data(repeating: 0x55, count: 32)
        let file = folder.appending(path: "trips.sealed")
        let store = try TripWorkspace(url: file, scope: scope, key: key)
        try store.addTripExamples()
        let japan = try XCTUnwrap(store.trip("example-japan"))
        let day = japan.plan.days[2]
        let walk = try XCTUnwrap(japan.plan.plannedChanges["jp-river"])
        let proposal = try XCTUnwrap(TripAdviser.indoorAlternative(to: walk, day: day, in: japan, summary: "Rain"))
        let applied = try store.applyTrip(proposal)
        XCTAssertThrowsError(try store.applyTrip(proposal))
        let reopened = try TripWorkspace(url: file, scope: scope, key: key)
        XCTAssertEqual(reopened.trip(japan.id), applied)
        let restored = try reopened.undoTrip(japan.id, expectedVersion: applied.version)
        XCTAssertEqual(restored.plan, japan.plan)
        XCTAssertEqual(restored.version, applied.version + 1)
        XCTAssertThrowsError(try reopened.applyTrip(proposal))
        XCTAssertThrowsError(try reopened.deleteTrip(japan.id, expectedVersion: applied.version))
        try reopened.deleteTrip(japan.id, expectedVersion: restored.version)
        let afterDeletion = try TripWorkspace(url: file, scope: scope, key: key)
        XCTAssertNil(afterDeletion.trip(japan.id))
        XCTAssertEqual(afterDeletion.trips.count, 2)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data(japan.plan.title.utf8)))
        XCTAssertThrowsError(try TripWorkspace(url: file, scope: .init(owner: "someone-else", generation: 1), key: key))
    }

    func testDraftImportAndLockedAndOverlapRejection() throws {
        let original = TripExamples.records[0]
        var modified = original.plan
        modified.days[2].stops.removeAll { $0.id == "jp-dinner" }
        XCTAssertThrowsError(try modified.validate(preserving: original.plan))
        modified = original.plan
        modified.days[2].stops[1].time = "10:45"
        XCTAssertThrowsError(try modified.validate())

        let candidate = TripProposal(summary: "Bangkok and Chiang Mai", plan: TripExamples.records[1].plan)
        let payload = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
        XCTAssertEqual(try TripMuseExchange.proposal(from: "```json\n" + payload + "\n```", for: nil), candidate)
        XCTAssertThrowsError(try TripMuseExchange.proposal(from: payload, for: original))
        XCTAssertTrue(try TripMuseExchange.request("Keep dinner", revising: original).contains("jp-dinner"))
    }

    func testWeatherAndEventsUseEvidence() throws {
        let input = #"{"list":[{"dt":1797234000,"main":{"temp":12.3},"weather":[{"id":500}],"pop":0.67}]}"#
        let reading = try XCTUnwrap(WeatherService.decodeTripForecast(Data(input.utf8)).first)
        XCTAssertEqual(reading.probability, 67)
        XCTAssertTrue(reading.warrantsIndoorOption)
        let day = TripExamples.records[0].plan.days[2]
        let walk = try XCTUnwrap(day.stops[1].place)
        let inputEvents = """
        [
          {"id":"near","city_code":"kyoto","name":"Nearby","when_label":"Afternoon","starts_at":"2026-12-14T06:00:00Z","lat":35.005,"lng":135.773,"source_url":"https://example.com/event"},
          {"id":"other-day","city_code":"kyoto","name":"Other day","when_label":"Afternoon","starts_at":"2026-12-15T06:00:00Z","lat":35.005,"lng":135.773,"source_url":"https://example.com/event"},
          {"id":"far","city_code":"kyoto","name":"Far","when_label":"Afternoon","starts_at":"2026-12-14T06:00:00Z","lat":34.9,"lng":135.3,"source_url":"https://example.com/event"},
          {"id":"no-url","city_code":"kyoto","name":"No source","when_label":"Afternoon","starts_at":"2026-12-14T06:00:00Z","lat":35.005,"lng":135.773}
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([CityEvent].self, from: Data(inputEvents.utf8))
        XCTAssertEqual(TripAdviser.nearbyEvents(events, day: day, place: walk).map(\.id), ["near"])
    }
}
#endif
