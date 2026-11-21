import CoreLocation
import MapKit
import Photos
import XCTest
@testable import SoloCompass

final class FootprintEntryTests: XCTestCase {
    @MainActor
    func testOnlySavedNameIsPresentedAsThePlace() {
        var visit = FootprintEntry(kind: .visit, at: 0, end: 3_600_000,
                                   latitude: 18.79, longitude: 98.99, accuracy: 12)
        XCTAssertEqual(FootprintText.title(visit), FootprintText.text("visit"))
        visit.label = "Confirmed cafe"
        XCTAssertEqual(FootprintText.title(visit), "Confirmed cafe")
    }

    func testCandidatesRequireACompletedReliableStayAndRemainBounded() {
        var visit = FootprintEntry(kind: .visit, at: 0, end: 2_700_000,
                                   latitude: 18.79, longitude: 98.99, accuracy: 16)
        let nearby = (1...4).map { index in
            Experience.userDraft(uuid: String(index), title: "Cafe \(index)", oneLiner: "", category: .coffee,
                                 coordinates: [98.99, 18.79 + Double(index) / 100_000], cityCode: "cmi")
        }
        let oldVisit = FootprintEntry(kind: .visit, at: -86_400_000, latitude: 18.79, longitude: 98.99,
                                      accuracy: 16, label: "Cafe 4")
        XCTAssertEqual(visit.placeCandidates(from: nearby, previouslyNamed: [oldVisit]).map(\.name),
                       ["Cafe 4", "Cafe 1", "Cafe 2"])
        visit.accuracy = 150
        XCTAssertTrue(visit.placeCandidates(from: nearby, previouslyNamed: []).isEmpty)
        visit.accuracy = 16
        visit.end = nil
        XCTAssertTrue(visit.placeCandidates(from: nearby, previouslyNamed: []).isEmpty)
    }

    func testTrackPointsRefineCompletedStayOnlyWithTightTimeSpanningCluster() throws {
        let arrival: Int64 = 0
        let departure: Int64 = 1_200_000
        let original = CLLocationCoordinate2D(latitude: 18.79, longitude: 98.99)
        let points = [480_000, 600_000, 720_000].enumerated().map { index, at in
            FootprintEntry(kind: .point, at: Int64(at), latitude: 18.7903,
                           longitude: 98.99 + Double(index) / 1_000_000, accuracy: 12)
        }
        let result = try XCTUnwrap(FootprintEntry.refineVisit(at: original, accuracy: 65, arrival: arrival,
                                                            departure: departure, points: points))
        XCTAssertEqual(result.coordinate.latitude, 18.7903, accuracy: 0.00001)
        XCTAssertLessThan(result.accuracy, 65)
        XCTAssertNil(FootprintEntry.refineVisit(at: original, accuracy: 65, arrival: arrival,
                                               departure: departure, points: Array(points.prefix(2))))
        let split = Array(points.prefix(2)) + [FootprintEntry(kind: .point, at: 720_000, latitude: 18.7912,
                                                               longitude: 98.99, accuracy: 10)]
        XCTAssertNil(FootprintEntry.refineVisit(at: original, accuracy: 65, arrival: arrival,
                                               departure: departure, points: split))
    }

    @MainActor
    func testNamedVisitHistoryUsesEarlierLabelsAndLookupUsesRecordIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try FootprintDisk(scope: "test", directory: folder)
        let named = FootprintEntry(kind: .visit, at: 1, label: "Saved cafe")
        let sameTime = FootprintEntry(kind: .visit, at: 1)
        let later = FootprintEntry(kind: .visit, at: 2, label: "Later cafe")
        let tombstone = FootprintEntry(kind: .visit, at: 1, label: "Deleted cafe", deleted: true)
        for entry in [named, sameTime, later, tombstone] { try disk.save(entry) }

        XCTAssertEqual(try FootprintDisk.namedVisits(at: disk.url, before: 2), [named])
        XCTAssertEqual(try disk.visit(id: sameTime.id), sameTime)
        XCTAssertNil(try disk.visit(id: tombstone.id))
    }

    func testSyncAcknowledgementMustCoverTheWholeBatch() throws {
        try FootprintRecorder.validateAcknowledgement(Data(#"{"received":2}"#.utf8), expected: 2)
        XCTAssertThrowsError(try FootprintRecorder.validateAcknowledgement(Data(#"{"received":1}"#.utf8), expected: 2))
        XCTAssertThrowsError(try FootprintRecorder.validateAcknowledgement(Data(#"{"ok":true}"#.utf8), expected: 2))
    }

    func testCaptureScopeRejectsPreviousOwnerCallbacksAndQueuedHistoricalLocations() {
        let oldScope = FootprintCaptureScope(since: Date(timeIntervalSince1970: 10))
        let newScope = FootprintCaptureScope(since: Date(timeIntervalSince1970: 20))
        XCTAssertFalse(newScope.accepts(oldScope.id, at: Date(timeIntervalSince1970: 21)))
        XCTAssertFalse(newScope.accepts(newScope.id, at: Date(timeIntervalSince1970: 19)))
        XCTAssertTrue(newScope.accepts(newScope.id, at: Date(timeIntervalSince1970: 20)))
    }

    func testLimitedPhotoAuthorizationDoesNotReconcileMissingAssets() {
        XCTAssertTrue(FootprintRecorder.canRemoveMissingFavorites(startedWith: .authorized, current: .authorized))
        XCTAssertFalse(FootprintRecorder.canRemoveMissingFavorites(startedWith: .limited, current: .authorized))
        XCTAssertFalse(FootprintRecorder.canRemoveMissingFavorites(startedWith: .authorized, current: .limited))
        XCTAssertFalse(FootprintRecorder.canRemoveMissingFavorites(startedWith: .limited, current: .limited))
    }

    func testFootprintLabelPreservesWholeGraphemesWithinTheServerByteLimit() {
        let family = "👩‍👩‍👧‍👦"
        let label = FootprintRecorder.footprintLabel(String(repeating: family, count: 100))
        XCTAssertEqual(label, String(repeating: family, count: 800 / family.utf8.count))
        XCTAssertLessThanOrEqual(label.utf8.count, 800)
        XCTAssertEqual(FootprintRecorder.footprintLabel(String(repeating: "a", count: 120)).count, 100)
    }

    @MainActor
    func testCitySummaryUsesOnlyNearbyCoverageFromTheLocalCatalog() {
        let shyOfFutian = CLLocationCoordinate2D(latitude: 22.5431, longitude: 114.0579)
        XCTAssertNotNil(FootprintRecorder.knownCity(near: shyOfFutian, accuracy: 12))
        XCTAssertNil(FootprintRecorder.knownCity(near: shyOfFutian, accuracy: 2_000))
        let ocean = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertNil(FootprintRecorder.knownCity(near: ocean, accuracy: 12))
    }

    @MainActor
    func testGuestJournalSealsOriginalMembershipAndKeepsTheReceiptAcrossRetries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = try FootprintDisk(scope: "device", directory: folder)
        let originalVisit = FootprintEntry(kind: .visit, at: 1, end: 700_000,
                                           latitude: 39.90, longitude: 116.39,
                                           label: "Recorded stop", version: 6)
        let laterGuestVisit = FootprintEntry(kind: .visit, at: 2)
        try guest.save(originalVisit)

        XCTAssertTrue(try guest.sealGuestJournal(for: "accountA", mayClaim: true))
        XCTAssertFalse(try guest.hasEntries())
        try guest.save(laterGuestVisit)
        XCTAssertFalse(try guest.sealGuestJournal(for: "accountB", mayClaim: true))

        let reopenedGuest = try FootprintDisk(scope: "device", directory: folder)
        let accountA = try FootprintDisk(scope: "accountA", directory: folder)
        let accountB = try FootprintDisk(scope: "accountB", directory: folder)
        XCTAssertTrue(try reopenedGuest.sealGuestJournal(for: "accountA", mayClaim: false))
        try accountA.importGuestJournal(reopenedGuest, scope: "accountA")
        XCTAssertEqual(try accountA.outbox(), [originalVisit])
        try accountA.acknowledge([originalVisit])
        try accountA.importGuestJournal(reopenedGuest, scope: "accountA")
        XCTAssertTrue(try accountA.outbox().isEmpty)
        XCTAssertEqual(try FootprintDisk.history(at: accountA.url, includePhotos: false), [originalVisit])
        XCTAssertEqual(try FootprintDisk.history(at: guest.url, includePhotos: false), [laterGuestVisit])

        XCTAssertThrowsError(try accountB.importGuestJournal(reopenedGuest, scope: "accountB"))
        XCTAssertTrue(try accountB.outbox().isEmpty)
    }

    @MainActor
    func testAmbiguousGuestHistoryStaysLocalWhenAnAccountJournalAlreadyExists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = try FootprintDisk(scope: String(repeating: "1", count: 64), directory: folder)
        let previousAccount = try FootprintDisk(scope: String(repeating: "2", count: 64), directory: folder)
        let visit = FootprintEntry(kind: .visit, at: 1)
        try guest.save(visit)

        XCTAssertTrue(guest.hasPriorAccountJournal)
        XCTAssertFalse(try guest.sealGuestJournal(for: "accountB", mayClaim: !guest.hasPriorAccountJournal))
        XCTAssertFalse(try guest.sealGuestJournal(for: "accountA", mayClaim: true))
        XCTAssertEqual(try FootprintDisk.history(at: guest.url, includePhotos: false), [visit])
        XCTAssertTrue(try previousAccount.outbox().isEmpty)
    }

    @MainActor
    func testCloudRestorePreservesLocalPendingChangesAndSkipsRemotePhotosDuringReconciliation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = try FootprintDisk(scope: "account", directory: folder)
        let local = FootprintEntry(kind: .visit, at: 1, label: "Local edit", version: 3)
        let remoteVisit = FootprintEntry(kind: .visit, at: 2, version: 4)
        let remotePhoto = FootprintEntry(kind: .photo, at: 3, preview: Data([1, 2, 3]), version: 4)
        var stale = local
        stale.label = nil
        stale.version = 2
        try account.save(local)

        try account.mergeCloud([stale, remoteVisit, remotePhoto], cursor: "42")
        XCTAssertEqual(try account.cloudCursor(), "42")
        XCTAssertEqual(try account.outbox(), [local])
        XCTAssertEqual(try account.visit(id: remoteVisit.id), remoteVisit)
        XCTAssertEqual(try account.openVisit(), local)
        XCTAssertTrue(try FootprintDisk.photos(at: account.url).isEmpty)
        XCTAssertEqual(try FootprintDisk.photoPreview(at: account.url, id: remotePhoto.id, version: remotePhoto.version),
                       remotePhoto.preview)

        var tombstone = remotePhoto
        tombstone.removePhoto()
        try account.mergeCloud([tombstone], cursor: "43")
        XCTAssertEqual(try account.cloudCursor(), "43")
        XCTAssertEqual(try account.outbox(), [local])
        XCTAssertNil(try FootprintDisk.photoPreview(at: account.url, id: remotePhoto.id, version: tombstone.version))
    }

    func testDurationOnlyAppearsAtTenMinutes() {
        var visit = FootprintEntry(kind: .visit, at: 1_000)
        XCTAssertNil(visit.displayedMinutes)
        visit.end = visit.at + 599_999
        XCTAssertNil(visit.displayedMinutes)
        visit.end = visit.at + 600_000
        XCTAssertEqual(visit.displayedMinutes, 10)
    }

    func testGapsAndImpossibleJumpsSplitRoute() {
        XCTAssertFalse(FootprintEntry.startsNewSegment(elapsed: 10, distance: 25))
        XCTAssertTrue(FootprintEntry.startsNewSegment(elapsed: 601, distance: 25))
        XCTAssertTrue(FootprintEntry.startsNewSegment(elapsed: 3, distance: 6000))
    }

    func testOnlyConnectedLocationsAreCountedAsRoutes() {
        let entries = [
            FootprintEntry(kind: .point, at: 0, latitude: 18.786, longitude: 98.989),
            FootprintEntry(kind: .point, at: 60_000, latitude: 18.786, longitude: 98.990),
            FootprintEntry(kind: .point, at: 900_000, latitude: 18.790, longitude: 98.990),
            FootprintEntry(kind: .point, at: 1_800_000, latitude: 18.791, longitude: 98.990)
        ]
        let day = FootprintMapDay(entries: entries)
        XCTAssertEqual(day.routes.map(\.count), [2])
        XCTAssertEqual(day.isolatedPoints.count, 2)
        XCTAssertNil(day.routeEndpoint)
        XCTAssertTrue(day.hasMap)

        let sparseDay = FootprintMapDay(entries: Array(entries.suffix(2)))
        XCTAssertTrue(sparseDay.routes.isEmpty)
        XCTAssertEqual(sparseDay.isolatedPoints.count, 2)
        XCTAssertNotNil(sparseDay.cameraPosition)
    }

    func testFavoriteRemovalProducesNewerTombstoneWithoutLocationOrImage() {
        var photo = FootprintEntry(kind: .photo, at: 1_000, latitude: 18.79,
                                   longitude: 98.99, preview: Data([1]), version: 10)
        let previous = photo
        photo.removePhoto()
        XCTAssertEqual(photo.id, previous.id)
        XCTAssertGreaterThan(photo.version, previous.version)
        XCTAssertEqual(photo.deleted, true)
        XCTAssertNil(photo.coordinate)
        XCTAssertNil(photo.preview)
    }

    func testHistoryDefaultsToAllDaysAndCombinesDateAndCity() throws {
        let calendar = Calendar(identifier: .gregorian)
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 2, day: 20)))
        let newer = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: older))
        let chiangMai = FootprintCity(id: "cmi", name: "Chiang Mai", center: .init(latitude: 18.79, longitude: 98.99))
        let bangkok = FootprintCity(id: "bkk", name: "Bangkok", center: .init(latitude: 13.75, longitude: 100.50))
        let first = FootprintEntry(kind: .visit, at: FootprintEntry.timestamp(older), latitude: 18.79, longitude: 98.99)
        let second = FootprintEntry(kind: .photo, at: FootprintEntry.timestamp(newer), latitude: 13.75, longitude: 100.50)
        let third = FootprintEntry(kind: .visit, at: second.at + 60_000, latitude: 18.79, longitude: 98.99)
        let unknown = FootprintEntry(kind: .photo, at: second.at + 90_000)
        let history = FootprintHistory(entries: [first, second, third, unknown], cities: [chiangMai, bangkok], calendar: calendar)

        XCTAssertEqual(history.matchingDays(FootprintFilter()).map(\.date), [older, newer])
        let scope = FootprintFilter(time: .custom(newer...newer), cityID: chiangMai.id)
        XCTAssertEqual(history.select(scope).map.entries, [third])
        XCTAssertEqual(history.matchingDays(scope).first?.stops, 1)
        XCTAssertEqual(history.select(FootprintFilter(cityID: FootprintCity.unassignedID)).map.entries, [unknown])
    }

    func testCityFilterDoesNotJoinAcrossAnExcludedPoint() {
        let city = FootprintCity(id: "cmi", name: "Chiang Mai", center: .init(latitude: 18.79, longitude: 98.99))
        let entries = [
            FootprintEntry(kind: .point, at: 0, latitude: 18.79, longitude: 98.99),
            FootprintEntry(kind: .point, at: 300_000, latitude: 19.50, longitude: 98.99),
            FootprintEntry(kind: .point, at: 560_000, latitude: 18.80, longitude: 98.99)
        ]
        let history = FootprintHistory(entries: entries, cities: [city])
        let map = history.select(FootprintFilter(cityID: city.id)).map
        XCTAssertTrue(map.routes.isEmpty)
        XCTAssertEqual(map.isolatedPoints.count, 2)
    }
    @MainActor
    func testLargePhotoArchiveCanReadRoutesBeforeIndexingPhotos() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try FootprintDisk(scope: "test", directory: folder)
        let point = FootprintEntry(kind: .point, at: 0, latitude: 18.79, longitude: 98.99)
        try disk.save(point)
        let preview = Data(repeating: 23, count: 4_096)
        let photos = (1...10_000).map { index in
            FootprintEntry(kind: .photo, at: Int64(index), latitude: 18.79, longitude: 98.99, preview: preview, version: 10)
        }
        try disk.savePhotos(photos)
        var removed = try XCTUnwrap(photos.last)
        removed.removePhoto()
        try disk.savePhotos([removed])

        let clock = ContinuousClock()
        let movementStart = clock.now
        XCTAssertEqual(try FootprintDisk.history(at: disk.url, includePhotos: false), [point])
        let movementTime = movementStart.duration(to: clock.now)
        let metadataStart = clock.now
        let metadata = try FootprintDisk.history(at: disk.url, includePhotos: true)
        let metadataTime = metadataStart.duration(to: clock.now)
        print("10k-photo SQLite fixture: movement=\(movementTime), combined metadata=\(metadataTime)")
        XCTAssertEqual(metadata.count, photos.count)
        XCTAssertTrue(metadata.allSatisfy { $0.preview == nil })
        let photo = photos[0]
        XCTAssertEqual(try FootprintDisk.photoPreview(at: disk.url, id: photo.id, version: photo.version), preview)
        XCTAssertNil(try FootprintDisk.photoPreview(at: disk.url, id: removed.id, version: removed.version))
        XCTAssertEqual(try FootprintDisk.history(at: disk.url, includePhotos: true, range: 0..<4).count, 4)
    }

    func testPhotoMapUsesBoundedVisibleMarkersAndPreservesOlderPhotos() throws {
        let old = FootprintEntry(kind: .photo, at: 0, latitude: 35, longitude: 135)
        let newest = (1...10_000).map { index in
            FootprintEntry(kind: .photo, at: Int64(index),
                           latitude: 18.7 + Double(index % 100) / 1000,
                           longitude: 98.9 + Double(index / 100) / 1000)
        }
        let day = FootprintMapDay(entries: [old] + newest)
        XCTAssertEqual(day.rows.count, 10_001)
        XCTAssertLessThanOrEqual(day.photoMarkers(in: .world).count, FootprintMapDay.photoMarkerLimit)
        let point = MKMapPoint(try XCTUnwrap(old.coordinate))
        let focus = MKMapRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
        XCTAssertEqual(day.photoMarkers(in: focus).map(\.id), [old.id])
        let edgePhoto = FootprintEntry(kind: .photo, at: 1, latitude: 0, longitude: -179.99)
        let edgeDay = FootprintMapDay(entries: [edgePhoto])
        let y = MKMapPoint(try XCTUnwrap(edgePhoto.coordinate)).y
        let seam = MKMapRect(x: MKMapRect.world.width - 30_000, y: y - 100, width: 60_000, height: 200)
        XCTAssertEqual(edgeDay.photoMarkers(in: seam).map(\.id), [edgePhoto.id])
    }

    func testFavoriteIdentityRemainsCompatibleWithEarlierImports() {
        XCTAssertEqual(FootprintRecorder.favoriteID(scope: "device", localIdentifier: "example").uuidString.lowercased(),
                       "a9681d49-8193-8b37-e914-be4015e177e4")
    }

    func testLongHistoryCapsDrawnTrailsWhileRetainingFullHistory() throws {
        let first = UUID()
        let longRoute = (0..<600).map { index in
            FootprintEntry(kind: .point, at: Int64(index) * 10_000,
                           latitude: 18.78, longitude: 98.98 + Double(index) / 100_000, segment: first)
        }
        let moreRoutes: [FootprintEntry] = (1...100).flatMap { index in
            let segment = UUID()
            let at = 6_000_000 + Int64(index) * 20_000
            return [
                FootprintEntry(kind: .point, at: at, latitude: 18.78, longitude: 98.98, segment: segment),
                FootprintEntry(kind: .point, at: at + 10_000, latitude: 18.781, longitude: 98.98, segment: segment)
            ]
        }
        let isolated = FootprintMapDay(entries: longRoute)
        let line = try XCTUnwrap(isolated.drawing(in: .world).trails.first)
        XCTAssertEqual(line.coordinates.count, FootprintMapDay.routePointLimit)
        XCTAssertEqual(line.coordinates.first?.longitude, longRoute.first?.longitude)
        XCTAssertEqual(line.coordinates.last?.longitude, longRoute.last?.longitude)
        let day = FootprintMapDay(entries: longRoute + moreRoutes)
        let drawing = day.drawing(in: .world)
        XCTAssertEqual(day.routes.count, 101)
        XCTAssertEqual(drawing.trails.count, FootprintMapDay.routeLimit)
        XCTAssertEqual(drawing.trails.filter(\.isLatest).count, 1)
        XCTAssertNotNil(day.latestTrailFrame)
    }

    func testLiveFrameKeepsUserAtCenterAndRejectsBrokenCoordinates() {
        let here = CLLocationCoordinate2D(latitude: 18.78, longitude: 98.98)
        let region = FootprintMapDay().liveRegion(centeredOn: here)
        XCTAssertEqual(region.center.latitude, here.latitude, accuracy: 0.00001)
        XCTAssertEqual(region.center.longitude, here.longitude, accuracy: 0.00001)
        XCTAssertNil(FootprintEntry(kind: .point, at: 0, latitude: -91, longitude: 98).coordinate)
    }

}
