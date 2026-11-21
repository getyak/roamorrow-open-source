import CoreLocation
import CryptoKit
import Observation
import Photos
import SQLite3
import UIKit

private struct FootprintVisitObservation: Sendable {
    var coordinate: CLLocationCoordinate2D
    var arrivalDate: Date
    var departureDate: Date
    var horizontalAccuracy: Double
}

struct FootprintCaptureScope {
    let id = UUID()
    let since: Date

    func accepts(_ source: UUID, at timestamp: Date) -> Bool {
        id == source && timestamp >= since
    }
}

private final class FootprintLocationCallbacks: NSObject, CLLocationManagerDelegate {
    let authorizationChanged: () -> Void
    let locationsReceived: ([CLLocation]) -> Void
    let visitReceived: (FootprintVisitObservation) -> Void

    init(authorizationChanged: @escaping () -> Void, locationsReceived: @escaping ([CLLocation]) -> Void,
         visitReceived: @escaping (FootprintVisitObservation) -> Void) {
        self.authorizationChanged = authorizationChanged
        self.locationsReceived = locationsReceived
        self.visitReceived = visitReceived
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locationsReceived(locations)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        visitReceived(FootprintVisitObservation(coordinate: visit.coordinate, arrivalDate: visit.arrivalDate,
                                               departureDate: visit.departureDate,
                                               horizontalAccuracy: visit.horizontalAccuracy))
    }
}

struct FootprintEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: Kind
    var at: Int64
    var end: Int64?
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    var label: String?
    var segment: UUID?
    var preview: Data?
    var deleted: Bool?
    var version: Int64 = FootprintEntry.timestamp(Date())
    var city: String?
    var district: String?

    enum Kind: String, Codable { case point, visit, photo }

    static func timestamp(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    static func startsNewSegment(elapsed: TimeInterval, distance: CLLocationDistance) -> Bool {
        elapsed > 10 * 60 || (elapsed > 0 && distance / elapsed > 175)
    }
    var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
    var displayedMinutes: Int? {
        guard let end else { return nil }
        let (duration, overflow) = end.subtractingReportingOverflow(at)
        guard !overflow, duration >= 600_000 else { return nil }
        return Int(duration / 60_000)
    }

    mutating func removePhoto() {
        latitude = nil
        longitude = nil
        preview = nil
        deleted = true
        version = max(version + 1, Self.timestamp(Date()))
    }
}

struct FootprintPlaceCandidate: Identifiable {
    let id: String
    let name: String
    let address: String?
    let distance: CLLocationDistance
}

extension FootprintEntry {
    var placeSearchRadius: CLLocationDistance? {
        guard kind == .visit, displayedMinutes != nil, coordinate != nil,
              let accuracy, accuracy > 0, accuracy <= 100 else { return nil }
        return min(150, max(60, accuracy + 40))
    }

    func placeCandidates(from experiences: [Experience], previouslyNamed: [FootprintEntry]) -> [FootprintPlaceCandidate] {
        guard let radius = placeSearchRadius, let coordinate, let minutes = displayedMinutes else { return [] }
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let namedPlaces = previouslyNamed.compactMap { visit -> (String, CLLocation)? in
            guard visit.kind == .visit, visit.id != id, visit.at < at, let label = visit.label,
                  let coordinate = visit.coordinate, let accuracy = visit.accuracy,
                  accuracy > 0, accuracy <= 100 else { return nil }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return center.distance(from: location) <= radius ? (label, location) : nil
        }
        let ranked = experiences.compactMap { experience -> (FootprintPlaceCandidate, Double)? in
            let name = experience.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard experience.status != .retired, !name.isEmpty, let coordinate = experience.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = center.distance(from: location)
            guard distance <= radius else { return nil }
            let duration = experience.durationMinutes
            let durationGap = max(0, Double(duration.min) - Double(minutes), Double(minutes) - Double(duration.max))
            let dwellPenalty = duration.min > 0 && duration.max >= duration.min ? min(1, durationGap / 60) * 0.2 : 0
            let seen = namedPlaces.contains { label, previous in
                label.localizedCaseInsensitiveCompare(name) == .orderedSame && previous.distance(from: location) <= 35
            }
            let candidate = FootprintPlaceCandidate(id: experience.id, name: name,
                                                    address: experience.location.addressHint, distance: distance)
            return (candidate, distance / radius + dwellPenalty - (seen ? 0.3 : 0))
        }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1
        }
        return sorted.prefix(3).map { $0.0 }
    }

    static func refinementWindow(arrival: Int64, departure: Int64) -> Range<Int64>? {
        let (duration, overflow) = departure.subtractingReportingOverflow(arrival)
        guard !overflow, duration >= 600_000 else { return nil }
        let middle = arrival + duration / 2
        let radius = min(450_000, duration / 2 - 120_000)
        return (middle - radius)..<(middle + radius)
    }

    /// A completed visit can use a tightly clustered set of existing track points.
    /// Keep the operating system's arrival and departure and prefer its fix when
    /// the track does not establish a more precise center.
    static func refineVisit(at coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy,
                            arrival: Int64, departure: Int64, points: [FootprintEntry])
        -> (coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy)? {
        guard accuracy > 0, accuracy <= 250,
              let window = refinementWindow(arrival: arrival, departure: departure) else { return nil }
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearby = points.compactMap { point -> (at: Int64, location: CLLocation, accuracy: Double)? in
            guard point.kind == .point, window.contains(point.at),
                  let accuracy = point.accuracy, accuracy > 0, accuracy <= 35,
                  let coordinate = point.coordinate else { return nil }
            return (point.at, CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), accuracy)
        }
        guard nearby.count >= 3, let first = nearby.map({ $0.at }).min(), let last = nearby.map({ $0.at }).max(),
              last - first >= 120_000,
              nearby.allSatisfy({ $0.location.distance(from: center) <= min(125, max(35, accuracy)) }) else { return nil }

        var weightSum = 0.0
        var latitudeSum = 0.0
        var longitudeDeltaSum = 0.0
        for sample in nearby {
            let accuracy = max(8, sample.accuracy)
            let weight = 1 / (accuracy * accuracy)
            weightSum += weight
            latitudeSum += sample.location.coordinate.latitude * weight
            let delta = (sample.location.coordinate.longitude - coordinate.longitude).remainder(dividingBy: 360)
            longitudeDeltaSum += delta * weight
        }
        let latitude = latitudeSum / weightSum
        let longitude = (coordinate.longitude + longitudeDeltaSum / weightSum).remainder(dividingBy: 360)
        let refined = CLLocation(latitude: latitude, longitude: longitude)
        let spread = nearby.map { $0.location.distance(from: refined) }
        guard let furthest = spread.max(), furthest <= 25 else { return nil }
        let envelope = max(15, zip(nearby, spread).map { sample, distance in sample.accuracy + distance }.max() ?? accuracy)
        guard envelope < accuracy else { return nil }
        return (refined.coordinate, envelope)
    }
}

// Each handle stays with its caller. Background import opens independent handles
// and SQLite WAL coordinates their transactions with the active device journal.
final class FootprintDisk {
    private let db: OpaquePointer
    let url: URL

    private static let entriesSchema = """
        CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY, kind TEXT, at INTEGER,
            version INTEGER, pending INTEGER, deleted INTEGER, body BLOB);
        CREATE INDEX IF NOT EXISTS entries_date ON entries(at);
        CREATE INDEX IF NOT EXISTS entries_pending ON entries(pending, at);
        CREATE INDEX IF NOT EXISTS entries_kind ON entries(kind, deleted);
        """

    init(scope: String, directory: URL? = nil) throws {
        var root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true).appendingPathComponent("Footprints")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        try root.setResourceValues(backupValues)
        var path = root.appendingPathComponent(scope + ".sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: path.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try path.setResourceValues(values)
            guard sqlite3_exec(handle, """
                PRAGMA journal_mode=WAL;
                PRAGMA busy_timeout=1000;
                CREATE TABLE IF NOT EXISTS journal_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS remote_entries(id TEXT PRIMARY KEY);
                \(Self.entriesSchema)
                """, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = handle
        url = path
    }

    // The handle owns no references to actor-isolated Swift values.
    deinit { sqlite3_close(db) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw CocoaError(.fileReadUnknown)
        }
        return query
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    func save(_ entry: FootprintEntry) throws {
        if try write(entry, pending: true), entry.kind == .photo {
            let query = try prepare("DELETE FROM remote_entries WHERE id=?")
            defer { sqlite3_finalize(query) }
            sqlite3_bind_text(query, 1, entry.id.uuidString, -1, transient)
            guard sqlite3_step(query) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    @discardableResult
    private func write(_ entry: FootprintEntry, pending: Bool) throws -> Bool {
        let data = try JSONEncoder().encode(entry)
        let q = try prepare("""
            INSERT INTO entries(id,kind,at,version,pending,deleted,body) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET at=excluded.at, version=excluded.version, pending=excluded.pending,
                deleted=excluded.deleted, body=excluded.body
            WHERE entries.kind=excluded.kind AND excluded.version>=entries.version
            """)
        defer { sqlite3_finalize(q) }
        sqlite3_bind_text(q, 1, entry.id.uuidString, -1, transient)
        sqlite3_bind_text(q, 2, entry.kind.rawValue, -1, transient)
        sqlite3_bind_int64(q, 3, entry.at)
        sqlite3_bind_int64(q, 4, entry.version)
        sqlite3_bind_int(q, 5, pending ? 1 : 0)
        sqlite3_bind_int(q, 6, entry.deleted == true ? 1 : 0)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(q, 7, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(q) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        return sqlite3_changes(db) != 0
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func savePhotos(_ entries: [FootprintEntry]) throws {
        try transaction {
            for entry in entries { try save(entry) }
        }
    }

    func metadata(_ key: String) throws -> String? {
        let query = try prepare("SELECT value FROM journal_meta WHERE key=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, key, -1, transient)
        switch sqlite3_step(query) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let value = sqlite3_column_text(query, 0) else { throw CocoaError(.fileReadCorruptFile) }
            return String(cString: value)
        default: throw CocoaError(.fileReadUnknown)
        }
    }

    private func setMetadata(_ key: String, value: String) throws {
        let query = try prepare("INSERT OR REPLACE INTO journal_meta(key,value) VALUES(?,?)")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, key, -1, transient)
        sqlite3_bind_text(query, 2, value, -1, transient)
        guard sqlite3_step(query) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    func hasEntries() throws -> Bool {
        let query = try prepare("SELECT 1 FROM entries WHERE deleted=0 LIMIT 1")
        defer { sqlite3_finalize(query) }
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw CocoaError(.fileReadUnknown)
        }
    }

    var hasPriorAccountJournal: Bool {
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return true
        }
        return siblings.contains { name in
            name != url.lastPathComponent && name.range(of: #"^[0-9a-f]{64}\.sqlite$"#,
                options: .regularExpression) != nil
        }
    }

    /// The guest database seals membership before the account database is opened.
    /// New guest entries created after sign-out cannot join this snapshot.
    func sealGuestJournal(for scope: String, mayClaim: Bool) throws -> Bool {
        var isOwner = false
        try transaction {
            if let owner = try metadata("guest_owner") {
                isOwner = owner == scope
                return
            }
            try setMetadata("guest_owner", value: mayClaim ? scope : "")
            guard mayClaim else { return }
            try exec("""
                ALTER TABLE entries RENAME TO guest_archive;
                DROP INDEX entries_date;
                DROP INDEX entries_pending;
                DROP INDEX entries_kind;
                \(Self.entriesSchema)
                """)
            isOwner = true
        }
        return isOwner
    }

    /// Destination import and its receipt commit together. A crash after that
    /// commit can safely retry source cleanup, without marking old rows pending.
    func importGuestJournal(_ guest: FootprintDisk, scope: String) throws {
        guard try guest.metadata("guest_owner") == scope else { throw CocoaError(.fileReadNoPermission) }
        if try metadata("guest_imported") == nil {
            try attachGuest(at: guest.url)
            do {
                try transaction {
                    try exec("""
                        INSERT INTO entries(id,kind,at,version,pending,deleted,body)
                        SELECT id,kind,at,version,1,deleted,body FROM guest_journal.guest_archive WHERE true
                        ON CONFLICT(id) DO UPDATE SET at=excluded.at,version=excluded.version,pending=1,
                            deleted=excluded.deleted,body=excluded.body
                        WHERE entries.kind=excluded.kind AND excluded.version>entries.version
                        """)
                    try setMetadata("guest_imported", value: "1")
                }
                try exec("DETACH DATABASE guest_journal")
            } catch {
                try? exec("DETACH DATABASE guest_journal")
                throw error
            }
        }
        try guest.exec("DROP TABLE IF EXISTS guest_archive")
    }

    private func attachGuest(at url: URL) throws {
        let query = try prepare("ATTACH DATABASE ? AS guest_journal")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, url.path, -1, transient)
        guard sqlite3_step(query) == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
    }

    func cloudCursor() throws -> String {
        try metadata("cloud_cursor") ?? "0"
    }

    func mergeCloud(_ entries: [FootprintEntry], cursor: String) throws {
        try transaction {
            let existing = try prepare("SELECT version FROM entries WHERE id=?")
            defer { sqlite3_finalize(existing) }
            let remote = try prepare("INSERT OR IGNORE INTO remote_entries(id) VALUES(?)")
            defer { sqlite3_finalize(remote) }
            for entry in entries {
                let id = entry.id.uuidString
                sqlite3_reset(existing)
                sqlite3_bind_text(existing, 1, id, -1, transient)
                let result = sqlite3_step(existing)
                let existed = result == SQLITE_ROW
                guard existed || result == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
                let isNewer = !existed || sqlite3_column_int64(existing, 0) < entry.version
                sqlite3_reset(existing)
                guard isNewer else { continue }
                try write(entry, pending: false)
                if !existed {
                    sqlite3_reset(remote)
                    sqlite3_bind_text(remote, 1, id, -1, transient)
                    guard sqlite3_step(remote) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
                }
            }
            try setMetadata("cloud_cursor", value: cursor)
        }
    }

    private nonisolated static func reading<Value>(at url: URL, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1_000)
        return try body(handle)
    }

    nonisolated static func history(at url: URL, includePhotos: Bool,
                                    range: Range<Int64>? = nil) throws -> [FootprintEntry] {
        let projection = includePhotos
            ? "CASE WHEN kind = 'photo' THEN json_remove(CAST(body AS TEXT), '$.preview') ELSE body END"
            : "body"
        let kinds = includePhotos ? "" : " AND kind IN ('point', 'visit')"
        let dates = range == nil ? "" : " AND at >= ? AND at < ?"
        return try reading(at: url) { handle in
            try read(handle, "SELECT \(projection) FROM entries WHERE deleted=0\(kinds)\(dates) ORDER BY at, id") {
                if let range {
                    sqlite3_bind_int64($0, 1, range.lowerBound)
                    sqlite3_bind_int64($0, 2, range.upperBound)
                }
            }
        }
    }

    nonisolated static func photos(at url: URL) throws -> [FootprintEntry] {
        try reading(at: url) { handle in
            try read(handle, """
                SELECT json_remove(CAST(body AS TEXT), '$.preview') FROM entries
                WHERE kind='photo' AND NOT EXISTS (SELECT 1 FROM remote_entries WHERE remote_entries.id=entries.id)
                """) { _ in }
        }
    }

    nonisolated static func photoPreview(at url: URL, id: UUID, version: Int64) throws -> Data? {
        try reading(at: url) { handle in
            try read(handle, "SELECT body FROM entries WHERE id=? AND version=? AND kind='photo' AND deleted=0 LIMIT 1") {
                sqlite3_bind_text($0, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64($0, 2, version)
            }.first?.preview
        }
    }

    func visit(arriving at: Int64) throws -> FootprintEntry? {
        try read("""
            SELECT body FROM entries WHERE kind='visit' AND at=?
            AND NOT EXISTS (SELECT 1 FROM remote_entries WHERE remote_entries.id=entries.id) LIMIT 1
            """) {
            sqlite3_bind_int64($0, 1, at)
        }.first
    }

    func openVisit() throws -> FootprintEntry? {
        try read("""
            SELECT body FROM entries WHERE kind='visit'
            AND NOT EXISTS (SELECT 1 FROM remote_entries WHERE remote_entries.id=entries.id)
            ORDER BY at DESC LIMIT 1
            """) { _ in }.first
    }

    func trackPoints(in range: Range<Int64>) throws -> [FootprintEntry] {
        try read("""
            SELECT body FROM entries INDEXED BY entries_date
            WHERE kind='point' AND deleted=0 AND at>=? AND at<?
            AND NOT EXISTS (SELECT 1 FROM remote_entries WHERE remote_entries.id=entries.id)
            ORDER BY at LIMIT 48
            """) {
            sqlite3_bind_int64($0, 1, range.lowerBound)
            sqlite3_bind_int64($0, 2, range.upperBound)
        }
    }

    nonisolated static func namedVisits(at url: URL, before: Int64) throws -> [FootprintEntry] {
        try reading(at: url) { db in
            try read(db, """
                SELECT body FROM entries WHERE kind='visit' AND deleted=0 AND at<?
                AND json_type(CAST(body AS TEXT), '$.label')='text' ORDER BY at DESC LIMIT 64
                """) { sqlite3_bind_int64($0, 1, before) }
        }
    }

    func visit(id: UUID) throws -> FootprintEntry? {
        try read("SELECT body FROM entries WHERE id=? AND kind='visit' AND deleted=0") {
            sqlite3_bind_text($0, 1, id.uuidString, -1, transient)
        }.first
    }

    func outbox() throws -> [FootprintEntry] {
        try read("SELECT body FROM entries WHERE pending=1 ORDER BY at LIMIT 16") { _ in }
    }

    func acknowledge(_ entries: [FootprintEntry]) throws {
        let q = try prepare("UPDATE entries SET pending=0 WHERE id=? AND version=?")
        defer { sqlite3_finalize(q) }
        for entry in entries {
            sqlite3_reset(q)
            sqlite3_bind_text(q, 1, entry.id.uuidString, -1, transient)
            sqlite3_bind_int64(q, 2, entry.version)
            guard sqlite3_step(q) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func read(_ sql: String, bind: (OpaquePointer) -> Void) throws -> [FootprintEntry] {
        try Self.read(db, sql, bind: bind)
    }

    private nonisolated static func read(_ db: OpaquePointer, _ sql: String,
                                         bind: (OpaquePointer) -> Void) throws -> [FootprintEntry] {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let q = query else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(q) }
        bind(q)
        let decoder = JSONDecoder()
        var values: [FootprintEntry] = []
        while true {
            if Task.isCancelled { throw CancellationError() }
            switch sqlite3_step(q) {
            case SQLITE_DONE: return values
            case SQLITE_ROW:
                guard let bytes = sqlite3_column_blob(q, 0) else { throw CocoaError(.fileReadCorruptFile) }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(q, 0)))
                values.append(try decoder.decode(FootprintEntry.self, from: data))
            default: throw CocoaError(.fileReadUnknown)
            }
        }
    }
}

enum FootprintSyncIndicator {
    case syncing, synced, waitingForNetwork, retrying, paused, needsLogin, partial
}

struct FootprintCloudStatus: Decodable {
    let trackPoints: Int
    let visits: Int
    let favoritePhotos: Int
    let latestReceivedAtMs: Int64?
    let agentAccess: Bool
    private let oauthAvailableValue: Bool?
    private let oauthConnectedValue: Bool?

    var oauthAvailable: Bool { oauthAvailableValue ?? false }
    var oauthConnected: Bool { oauthConnectedValue ?? false }

    private enum CodingKeys: String, CodingKey {
        case trackPoints, visits, favoritePhotos, latestReceivedAtMs, agentAccess
        case oauthAvailableValue = "oauthAvailable"
        case oauthConnectedValue = "oauthConnected"
    }

    var latestUpload: Date? {
        latestReceivedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }
}

@MainActor @Observable
final class FootprintRecorder: NSObject {
    static let shared = FootprintRecorder()
    private(set) var isEnabled = false
    private(set) var hasStarted = false
    private(set) var favoritesEnabled = false
    private(set) var cloudEnabled = false
    private(set) var authorization = CLAuthorizationStatus.notDetermined
    private(set) var photosAuthorization = PHAuthorizationStatus.notDetermined
    private(set) var isSyncing = false
    private(set) var syncFailed = false
    private(set) var storageFailed = false
    private(set) var lastSync: Date?
    private(set) var grantRevision = 0
    private(set) var revision = 0
    private(set) var scopeNeedsSetup = false
    private(set) var hasUnownedPendingFootprints = false
    private var hasUnclaimedHistory = false
    private var needsLogin = false
    private var confirmedCloudRoundTrip = false
    private var manager = CLLocationManager()
    private var callbacks: FootprintLocationCallbacks?
    private var captureScope = FootprintCaptureScope(since: .distantFuture)
    private let account = EmailAccountService.shared
    private let transport = AccountHTTP.transport()
    private var disk: FootprintDisk?
    private var scope = ""
    private var photoIdentityScope: String?
    private var nextCloudRead: Date?
    private var preparedJournal = false
    private var guestImport: Task<Void, Never>?
    private var boundGeneration: UInt64?
    private var boundOwner: String?
    private var foreground = false
    private var isRunning = false
    private var monitoringBackground = false
    private var retryAfter: Date?
    private var segment = UUID()
    private var lastPoint: CLLocation?
    private var syncing: Task<Void, Never>?
    private var syncID: UUID?
    private var retryTask: Task<Void, Never>?
    private var scanning: Task<Void, Never>?
    private var photoScanID: UUID?
    private var needsPhotoRescan = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private var pref: String { "footprints.v1." + scope }
    var accountID: String? { account.identity?.userID }
    var hasAccount: Bool { accountID != nil }
    var importingFavorites: Bool { scanning != nil }
    var lastSyncedAt: Date? { lastSync }
    var syncIndicator: FootprintSyncIndicator? {
        guard hasAccount, accountID == boundOwner else { return nil }
        if needsLogin { return .needsLogin }
        if !cloudEnabled { return .paused }
        if !NetworkMonitor.shared.isConnected { return .waitingForNetwork }
        if isSyncing || (!preparedJournal && guestImport != nil) { return .syncing }
        if storageFailed || hasUnclaimedHistory { return .partial }
        if syncFailed { return confirmedCloudRoundTrip ? .partial : .retrying }
        return confirmedCloudRoundTrip ? .synced : .syncing
    }
    var endpoint: URL? {
        Secrets.resolvedHarnessBaseURL().flatMap { TravelerHarnessClient.validatedOrigin($0.absoluteString) }?
            .appendingPathComponent("mcp/footprints")
    }

    override private init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    private static func scopeKey(_ owner: String) -> String {
        SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let guestScope = scopeKey("device")

    func preloadLocalSyncDisclosure() async {
        guard accountID == nil, !preparedJournal else { return }
        let generation = account.identityGeneration
        let guestScope = Self.guestScope
        let eligible = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Footprints"),
                manager.fileExists(atPath: root.appendingPathComponent(guestScope + ".sqlite").path) else {
                return false
            }
            do {
                let guest = try FootprintDisk(scope: guestScope, directory: root)
                return try !guest.hasPriorAccountJournal && guest.metadata("guest_owner") == nil && guest.hasEntries()
            } catch { return true }
        }.value
        guard accountID == nil, generation == account.identityGeneration,
              !preparedJournal, !Task.isCancelled else { return }
        hasUnownedPendingFootprints = eligible
    }

    private func resetCaptureScope(for key: String) {
        let defaults = UserDefaults.standard
        let scopeKey = "footprints.v1.capture-scope"
        let sinceKey = "footprints.v1.capture-since"
        let since: Date
        if defaults.string(forKey: scopeKey) == key, let saved = defaults.object(forKey: sinceKey) as? Date {
            since = saved
        } else {
            since = Date()
            defaults.set(since, forKey: sinceKey)
            defaults.set(key, forKey: scopeKey)
        }
        captureScope = FootprintCaptureScope(since: since)
        let id = captureScope.id
        manager.delegate = nil
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 18
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true

        let callbacks = FootprintLocationCallbacks(
            authorizationChanged: { [weak self] in
                Task { @MainActor in
                    guard let self, self.captureScope.id == id else { return }
                    self.authorization = self.manager.authorizationStatus
                    self.reconcileLocation()
                }
            },
            locationsReceived: { [weak self] locations in
                Task { @MainActor in self?.record(samples: locations, from: id) }
            },
            visitReceived: { [weak self] visit in
                Task { @MainActor in self?.record(visit: visit, from: id) }
            }
        )
        self.callbacks = callbacks
        manager.delegate = callbacks
    }

    func refresh(foreground: Bool) {
        let becameActive = foreground && !self.foreground
        self.foreground = foreground
        let owner = accountID
        let key = owner.map(Self.scopeKey) ?? Self.guestScope
        if key != scope {
            stop()
            cancelSync()
            cancelPhotoScan()
            scope = key
            boundOwner = owner
            resetCaptureScope(for: key)
            hasStarted = false
            isEnabled = false
            favoritesEnabled = false
            hasUnownedPendingFootprints = false
            hasUnclaimedHistory = false
            cloudEnabled = owner != nil && (UserDefaults.standard.object(forKey: pref + ".cloud") as? Bool ?? true)
            scopeNeedsSetup = false
            lastSync = nil
            photoIdentityScope = nil
            preparedJournal = false
            nextCloudRead = nil
            disk = nil
            storageFailed = false
            revision += 1
        }
        if boundGeneration != account.identityGeneration {
            cancelSync()
            boundGeneration = account.identityGeneration
            needsLogin = false
            confirmedCloudRoundTrip = false
            syncFailed = false
            retryAfter = nil
            nextCloudRead = nil
        }
        authorization = manager.authorizationStatus
        photosAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        openDiskIfNeeded()
        reconcileLocation()
        if foreground {
            if becameActive {
                retryAfter = nil
                nextCloudRead = nil
            }
            scanFavorites()
            sync()
        } else {
            cancelPhotoScan()
            cancelRetry()
        }
    }

    func deferSetup() {
        UserDefaults.standard.set(true, forKey: pref + ".setup")
        scopeNeedsSetup = false
    }

    func enable(favorites: Bool, cloud _: Bool) {
        guard accountID == boundOwner, !scope.isEmpty else { return }
        deferSetup()
        isEnabled = true
        hasStarted = true
        UserDefaults.standard.set(true, forKey: pref + ".started")
        favoritesEnabled = favorites
        UserDefaults.standard.set(true, forKey: pref + ".enabled")
        UserDefaults.standard.set(favoritesEnabled, forKey: pref + ".favorites")
        openDiskIfNeeded()
        reconcileLocation()
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        scanFavorites()
        sync()
    }

    func pause() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: pref + ".enabled")
        stop()
        cancelPhotoScan()
    }

    func setCloud(_ enabled: Bool) {
        guard accountID == boundOwner, !scope.isEmpty else { return }
        cloudEnabled = enabled && hasAccount
        UserDefaults.standard.set(cloudEnabled, forKey: pref + ".cloud")
        retryAfter = nil
        if cloudEnabled {
            syncNow()
        } else {
            cancelSync()
            syncFailed = false
        }
    }

    func requestAlways() { manager.requestAlwaysAuthorization() }

    func requestPhotos() async {
        guard isEnabled else { return }
        if !favoritesEnabled {
            favoritesEnabled = true
            UserDefaults.standard.set(true, forKey: pref + ".favorites")
        }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        photosAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        scanFavorites()
    }

    var historyScope: String { scope }

    func history(cities: [FootprintCity], includePhotos: Bool) async throws -> FootprintHistory {
        try await readHistory { url in
            FootprintHistory(entries: try FootprintDisk.history(at: url, includePhotos: includePhotos), cities: cities)
        } ?? FootprintHistory()
    }

    func journalDay(on date: Date, allowedEntryIDs: Set<UUID>?, includePhotos: Bool) async throws -> FootprintMapDay {
        guard let day = Calendar.current.dateInterval(of: .day, for: date) else { return FootprintMapDay() }
        let range = FootprintEntry.timestamp(day.start)..<FootprintEntry.timestamp(day.end)
        return try await readHistory { url in
            let entries = try FootprintDisk.history(at: url, includePhotos: includePhotos, range: range)
            return FootprintMapDay(entries: entries, allowedEntryIDs: allowedEntryIDs)
        } ?? FootprintMapDay()
    }

    func photoPreview(for entry: FootprintEntry) async -> Data? {
        try? await readHistory { url in
            try FootprintDisk.photoPreview(at: url, id: entry.id, version: entry.version)
        } ?? nil
    }

    func namedVisits(before entry: FootprintEntry) async -> [FootprintEntry] {
        (try? await readHistory { url in
            try FootprintDisk.namedVisits(at: url, before: entry.at)
        }) ?? []
    }

    private func readHistory<Value: Sendable>(_ read: @escaping @Sendable (URL) throws -> Value) async throws -> Value? {
        guard let url = disk?.url else {
            if storageFailed { throw CocoaError(.fileReadUnknown) }
            return nil
        }
        let scope = scope
        let generation = account.identityGeneration
        let task = Task.detached(priority: .userInitiated) { try read(url) }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard scope == self.scope, accountID == boundOwner,
              generation == account.identityGeneration, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    private func openDiskIfNeeded() {
        guard !preparedJournal, !scope.isEmpty else { return }
        do {
            let defaults = UserDefaults.standard
            let guest = try FootprintDisk(scope: Self.guestScope)
            if hasAccount {
                let isOwner = try guest.sealGuestJournal(for: scope, mayClaim: !guest.hasPriorAccountJournal)
                let target = try FootprintDisk(scope: scope)
                if isOwner {
                    if try target.metadata("guest_imported") == nil {
                        importGuestHistory(from: guest.url.deletingLastPathComponent(), into: scope)
                        return
                    }
                    photoIdentityScope = Self.guestScope
                    let guestPref = "footprints.v1." + Self.guestScope
                    for suffix in [".setup", ".started", ".enabled", ".favorites"] {
                        if defaults.object(forKey: pref + suffix) == nil,
                           let value = defaults.object(forKey: guestPref + suffix) {
                            defaults.set(value, forKey: pref + suffix)
                        }
                    }
                }
                hasUnclaimedHistory = try guest.hasEntries()
                disk = target
            } else {
                let unclaimed = try guest.metadata("guest_owner") == nil
                hasUnownedPendingFootprints = try unclaimed && !guest.hasPriorAccountJournal && guest.hasEntries()
                disk = guest
            }
            hasStarted = defaults.bool(forKey: pref + ".started")
            isEnabled = defaults.bool(forKey: pref + ".enabled")
            favoritesEnabled = defaults.bool(forKey: pref + ".favorites")
            cloudEnabled = hasAccount && (defaults.object(forKey: pref + ".cloud") as? Bool ?? true)
            scopeNeedsSetup = !hasAccount && !defaults.bool(forKey: pref + ".setup")
            lastSync = defaults.object(forKey: pref + ".sync") as? Date
            storageFailed = false
            preparedJournal = true
        } catch {
            disk = nil
            storageFailed = true
        }
    }

    private func importGuestHistory(from directory: URL, into targetScope: String) {
        guard guestImport == nil else { return }
        let guestScope = Self.guestScope
        let work = Task.detached(priority: .utility) {
            let source = try FootprintDisk(scope: guestScope, directory: directory)
            let target = try FootprintDisk(scope: targetScope, directory: directory)
            try target.importGuestJournal(source, scope: targetScope)
        }
        guestImport = Task { [weak self] in
            let result = await work.result
            guard let self else { return }
            self.guestImport = nil
            guard self.scope == targetScope, self.accountID == self.boundOwner else { return }
            switch result {
            case .success:
                self.revision += 1
                self.refresh(foreground: self.foreground)
            case .failure:
                self.storageFailed = true
                self.scheduleRetry(at: Date().addingTimeInterval(30))
            }
        }
    }

    private func reconcileLocation() {
        guard isEnabled, disk != nil, authorization == .authorizedAlways ||
                (foreground && authorization == .authorizedWhenInUse) else { stop(); return }
        let background = authorization == .authorizedAlways
        if manager.allowsBackgroundLocationUpdates != background { manager.allowsBackgroundLocationUpdates = background }
        if !isRunning {
            isRunning = true
            manager.startUpdatingLocation()
        }
        if background != monitoringBackground {
            monitoringBackground = background
            if background {
                manager.startMonitoringVisits()
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringVisits()
                manager.stopMonitoringSignificantLocationChanges()
            }
        }
    }

    private func stop() {
        if isRunning {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        if monitoringBackground {
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
        }
        isRunning = false
        monitoringBackground = false
        segment = UUID()
        lastPoint = nil
    }

    private func save(_ entry: FootprintEntry) -> Bool {
        guard let disk else { return false }
        do {
            try disk.save(entry)
            revision += 1
            if !hasAccount, !hasUnownedPendingFootprints, try disk.metadata("guest_owner") == nil {
                hasUnownedPendingFootprints = !disk.hasPriorAccountJournal
            }
            return true
        }
        catch { storageFailed = true; return false }
    }

    private func record(samples: [CLLocation], from captureID: UUID) {
        guard isEnabled, isRunning, account.identity?.userID == boundOwner else { return }
        let now = Date()
        for point in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let age = now.timeIntervalSince(point.timestamp)
            guard captureScope.accepts(captureID, at: point.timestamp),
                  point.horizontalAccuracy >= 0, point.horizontalAccuracy <= 100,
                  CLLocationCoordinate2DIsValid(point.coordinate),
                  age > -10 * 60, age < 15 * 60 else { continue }
            if let lastPoint {
                let elapsed = point.timestamp.timeIntervalSince(lastPoint.timestamp)
                let distance = point.distance(from: lastPoint)
                guard elapsed > 0, elapsed >= 60 || distance >= 18 else { continue }
                if FootprintEntry.startsNewSegment(elapsed: elapsed, distance: distance) { segment = UUID() }
            }
            if save(.init(kind: .point, at: FootprintEntry.timestamp(point.timestamp), latitude: point.coordinate.latitude,
                          longitude: point.coordinate.longitude, accuracy: point.horizontalAccuracy, segment: segment)) {
                lastPoint = point
            }
        }
        sync()
    }

    func nameStop(_ item: FootprintEntry, name: String, scope expectedScope: String) -> Bool {
        guard item.kind == .visit, scope == expectedScope, account.identity?.userID == boundOwner,
              var current = try? disk?.visit(id: item.id) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Self.footprintLabel(trimmed)
        guard trimmed.isEmpty || !name.isEmpty else { return false }
        let label = name.isEmpty ? nil : name
        guard current.label != label else { return true }
        current.label = label
        current.version = max(current.version + 1, FootprintEntry.timestamp(Date()))
        guard save(current) else { return false }
        sync()
        return true
    }

    nonisolated static func footprintLabel(_ value: String) -> String {
        var budget = 800
        return String(value.prefix(100).prefix { character in
            let bytes = String(character).utf8.count
            guard bytes <= budget else { return false }
            budget -= bytes
            return true
        })
    }

    /// The bundled city catalogue is sufficient for a conservative city-level
    /// match near its known centers. No coordinates are sent to a geocoder.
    static func knownCity(near coordinate: CLLocationCoordinate2D, accuracy: Double?) -> String? {
        guard CLLocationCoordinate2DIsValid(coordinate), let accuracy, accuracy > 0, accuracy <= 200 else {
            return nil
        }
        let reference = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates = Set(MapViewModel.knownCityCenters.compactMap { item -> String? in
            let center = CLLocation(latitude: item.value.latitude, longitude: item.value.longitude)
            guard reference.distance(from: center) + accuracy < 12_000 else { return nil }
            let fallback = item.key.replacingOccurrences(of: "-", with: " ").capitalized
            return MapViewModel.cityNameMap[item.key] ??
                CompanionPlacePresentation.cityName(code: item.key, fallback: fallback)
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    private func record(visit: FootprintVisitObservation, from captureID: UUID) {
        guard captureScope.id == captureID, isEnabled, account.identity?.userID == boundOwner,
              authorization == .authorizedAlways, CLLocationCoordinate2DIsValid(visit.coordinate) else { return }
        let hasArrival = visit.arrivalDate != .distantPast
        if hasArrival && !captureScope.accepts(captureID, at: visit.arrivalDate) { return }
        let previous = hasArrival ? try? disk?.visit(arriving: FootprintEntry.timestamp(visit.arrivalDate)) : try? disk?.openVisit()
        let closeBy = previous?.coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            .distance(from: CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)) < 150 } ?? false
        let arrived = hasArrival ? FootprintEntry.timestamp(visit.arrivalDate) :
            (closeBy && previous?.end == nil ? previous?.at : nil)
        guard let arrived, captureScope.accepts(captureID, at: Date(timeIntervalSince1970: Double(arrived) / 1_000)) else {
            return
        }
        let departed = visit.departureDate == .distantFuture ? nil : FootprintEntry.timestamp(visit.departureDate)
        guard departed.map({ $0 >= arrived }) ?? true else { return }
        let same = previous?.at == arrived && (hasArrival || closeBy)
        if same && previous?.end != nil && departed == nil { return }
        let accuracy = visit.horizontalAccuracy >= 0 && visit.horizontalAccuracy <= 100_000 ? visit.horizontalAccuracy : nil
        let refined = departed.flatMap { end -> (coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy)? in
            guard let accuracy, accuracy > 0, accuracy <= 250,
                  let range = FootprintEntry.refinementWindow(arrival: arrived, departure: end),
                  let points = try? disk?.trackPoints(in: range) else { return nil }
            return FootprintEntry.refineVisit(at: visit.coordinate, accuracy: accuracy,
                                              arrival: arrived, departure: end, points: points)
        }
        let coordinate = refined?.coordinate ?? visit.coordinate
        let entry = FootprintEntry(id: same ? previous?.id ?? UUID() : UUID(), kind: .visit, at: arrived, end: departed,
                                   latitude: coordinate.latitude, longitude: coordinate.longitude,
                                   accuracy: refined?.accuracy ?? accuracy,
                                   label: same ? previous?.label : nil,
                                   version: max(FootprintEntry.timestamp(Date()), same ? (previous?.version ?? 0) + 1 : 0),
                                   city: same ? previous?.city : nil, district: same ? previous?.district : nil)
        if save(entry) { sync() }
    }

    private var canScanFavorites: Bool {
        foreground && isEnabled && account.identity?.userID == boundOwner &&
            favoritesEnabled && CompanionPhotoLibrary.canRead(photosAuthorization)
    }

    private func cancelPhotoScan() {
        scanning?.cancel()
        scanning = nil
        photoScanID = nil
        needsPhotoRescan = false
    }

    private func scanFavorites() {
        guard canScanFavorites, scanning == nil, let disk else { return }
        let run = UUID()
        let scope = photoIdentityScope ?? scope
        let url = disk.url
        let photoAuthorizationAtStart = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoScanID = run
        let storeBatch: @Sendable ([FootprintEntry]) async -> Bool = { [weak self] batch in
            await self?.storePhotoBatch(batch, run: run, authorizationAtStart: photoAuthorizationAtStart) ?? false
        }
        let worker = Task.detached(priority: .utility) {
            try await Self.importFavorites(at: url, scope: scope,
                                           authorizationAtStart: photoAuthorizationAtStart, emit: storeBatch)
        }
        scanning = Task {
            defer {
                if photoScanID == run {
                    scanning = nil
                    photoScanID = nil
                    if needsPhotoRescan {
                        needsPhotoRescan = false
                        scanFavorites()
                    }
                    sync()
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
            } catch {
                if photoScanID == run, !Task.isCancelled { storageFailed = true }
            }
        }
    }

    private func storePhotoBatch(_ batch: [FootprintEntry], run: UUID,
                                 authorizationAtStart: PHAuthorizationStatus) -> Bool {
        guard photoScanID == run, canScanFavorites, let disk else { return false }
        let currentAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard CompanionPhotoLibrary.canRead(currentAuthorization) else { return false }
        let canRemoveMissing = !needsPhotoRescan &&
            Self.canRemoveMissingFavorites(startedWith: authorizationAtStart, current: currentAuthorization)
        let entries = canRemoveMissing ? batch : batch.filter { $0.deleted != true }
        guard !entries.isEmpty else { return true }
        do {
            try disk.savePhotos(entries)
            revision += 1
            if !hasAccount, !hasUnownedPendingFootprints, try disk.metadata("guest_owner") == nil {
                hasUnownedPendingFootprints = !disk.hasPriorAccountJournal && entries.contains { $0.deleted != true }
            }
            sync()
            return true
        } catch {
            storageFailed = true
            return false
        }
    }

    nonisolated static func canRemoveMissingFavorites(startedWith start: PHAuthorizationStatus,
                                                      current: PHAuthorizationStatus) -> Bool {
        start == .authorized && current == .authorized
    }

    private nonisolated static func importFavorites(
        at url: URL, scope: String, authorizationAtStart: PHAuthorizationStatus,
        emit: @Sendable ([FootprintEntry]) async -> Bool
    ) async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "favorite == YES")
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let saved = try FootprintDisk.photos(at: url)
        let stored = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var eligible = Set<UUID>()
        var batch: [FootprintEntry] = []
        let newest = Date().addingTimeInterval(600)
        for index in 0..<result.count {
            try Task.checkCancellation()
            let asset = result.object(at: index)
            guard let date = asset.creationDate, date <= newest else { continue }
            let id = favoriteID(scope: scope, localIdentifier: asset.localIdentifier)
            eligible.insert(id)
            let coordinate = asset.location?.coordinate
            let old = stored[id]
            let at = FootprintEntry.timestamp(date)
            if old?.deleted != true, old?.at == at,
               old?.latitude == coordinate?.latitude, old?.longitude == coordinate?.longitude { continue }
            guard let image = try? await CompanionPhotoLibrary.thumbnail(asset),
                  let preview = image.jpegData(compressionQuality: 0.55),
                  preview.count <= 72 * 1_024 else { continue }
            batch.append(.init(id: id, kind: .photo, at: at, latitude: coordinate?.latitude,
                               longitude: coordinate?.longitude, preview: preview,
                               version: max(FootprintEntry.timestamp(Date()), (old?.version ?? 0) + 1)))
            if batch.count == 12 {
                try Task.checkCancellation()
                guard await emit(batch) else { return }
                batch.removeAll(keepingCapacity: true)
            }
        }
        // A limited library enumerates a projection. Missing assets in that
        // projection are not deletions, and authorization can change mid-scan.
        let canRemoveMissing = canRemoveMissingFavorites(
            startedWith: authorizationAtStart, current: PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        for var item in saved where canRemoveMissing && item.deleted != true && !eligible.contains(item.id) {
            try Task.checkCancellation()
            item.removePhoto()
            batch.append(item)
            if batch.count == 12 {
                guard await emit(batch) else { return }
                batch.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !batch.isEmpty { _ = await emit(batch) }
    }

    nonisolated static func favoriteID(scope: String, localIdentifier: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data((scope + "/" + localIdentifier).utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    func networkRestored() {
        if foreground { syncNow() }
    }

    func syncNow() {
        guard hasAccount, accountID == boundOwner else { return }
        cancelRetry()
        retryAfter = nil
        nextCloudRead = nil
        openDiskIfNeeded()
        sync()
    }

    private func cancelSync() {
        cancelRetry()
        syncID = nil
        syncing?.cancel()
        syncing = nil
        isSyncing = false
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func scheduleRetry(at date: Date) {
        guard foreground, retryTask == nil else { return }
        let owner = boundOwner
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.foreground, self.accountID == owner else { return }
            self.openDiskIfNeeded()
            self.reconcileLocation()
            self.sync()
        }
    }

    private func sync() {
        guard cloudEnabled, !needsLogin, NetworkMonitor.shared.isConnected, syncing == nil,
              let disk, hasAccount, accountID == boundOwner else { return }
        let canRead = foreground && (nextCloudRead.map { $0 <= Date() } ?? true)
        do {
            if !canRead, try disk.outbox().isEmpty { return }
        } catch {
            storageFailed = true
            return
        }
        if let retryAfter, retryAfter > Date() {
            scheduleRetry(at: retryAfter)
            return
        }
        cancelRetry()
        let id = UUID()
        syncID = id
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Footprint sync") { [weak self] in
            Task { @MainActor in
                guard self?.syncID == id else { return }
                self?.cancelSync()
            }
        }
        isSyncing = true
        syncing = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.syncID == id {
                    self.syncID = nil
                    self.syncing = nil
                    self.endBackgroundTime()
                    self.isSyncing = false
                }
            }
            do {
                var attemptedDownload = false
                while !Task.isCancelled, self.syncID == id, self.cloudEnabled {
                    let batch = try disk.outbox()
                    if !batch.isEmpty {
                        let response = try await self.upload(batch)
                        try Self.validateAcknowledgement(response, expected: batch.count)
                        try Task.checkCancellation()
                        guard self.syncID == id, self.cloudEnabled else { return }
                        try disk.acknowledge(batch)
                        self.didSync()
                    } else if canRead, !attemptedDownload {
                        attemptedDownload = true
                        try await self.restoreCloud(disk, syncID: id)
                        self.nextCloudRead = Date().addingTimeInterval(60)
                    } else {
                        break
                    }
                }
            } catch {
                if !Task.isCancelled, self.syncID == id {
                    if (error as? URLError)?.code == .userAuthenticationRequired ||
                        (error as? EmailAccountService.Failure) == .rejected {
                        self.needsLogin = true
                        return
                    }
                    self.syncFailed = true
                    let retry = Date().addingTimeInterval(30)
                    self.retryAfter = retry
                    self.scheduleRetry(at: retry)
                }
            }
        }
    }

    private func upload(_ batch: [FootprintEntry]) async throws -> Data {
        var includesCity = false
        let records = batch.map { entry in
            var record = entry
            if record.kind == .visit {
                if let label = record.label { record.label = Self.footprintLabel(label) }
                if record.city == nil, let coordinate = record.coordinate {
                    record.city = Self.knownCity(near: coordinate, accuracy: record.accuracy)
                }
                includesCity = includesCity || record.city != nil || record.district != nil
            }
            return record
        }
        do {
            let body = try JSONEncoder().encode(["records": records])
            return try await request("sync", method: "POST", body: body)
        } catch let error as URLError where error.code == .cannotParseResponse && includesCity {
            // An older backend's strict decoder rejects new optional fields.
            let compatibleRecords = records.map { entry in
                var record = entry
                record.city = nil
                record.district = nil
                return record
            }
            let body = try JSONEncoder().encode(["records": compatibleRecords])
            return try await request("sync", method: "POST", body: body)
        }
    }

    private struct CloudPage: Decodable {
        let records: [FootprintEntry]
        let next_cursor: String
        let has_more: Bool
    }

    private func restoreCloud(_ disk: FootprintDisk, syncID id: UUID) async throws {
        var cursor = try disk.cloudCursor()
        while true {
            let data = try await request("history", method: "GET", query: [
                .init(name: "cursor", value: cursor), .init(name: "limit", value: "32")
            ])
            let page = try JSONDecoder().decode(CloudPage.self, from: data)
            guard page.records.count <= 32, let previous = Int64(cursor), let next = Int64(page.next_cursor),
                  next >= previous, !page.has_more || next > previous else {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            guard syncID == id, cloudEnabled else { throw CancellationError() }
            try disk.mergeCloud(page.records, cursor: page.next_cursor)
            if !page.records.isEmpty {
                let defaults = UserDefaults.standard
                if !hasStarted {
                    hasStarted = true
                    defaults.set(true, forKey: pref + ".started")
                }
                revision += 1
            }
            didSync()
            if !page.has_more { return }
            cursor = page.next_cursor
        }
    }

    private func didSync() {
        confirmedCloudRoundTrip = true
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: pref + ".sync")
        storageFailed = false
        syncFailed = false
        retryAfter = nil
    }

    nonisolated static func validateAcknowledgement(_ data: Data, expected: Int) throws {
        struct Acknowledgement: Decodable { let received: Int }
        guard try JSONDecoder().decode(Acknowledgement.self, from: data).received == expected else {
            throw URLError(.badServerResponse)
        }
    }

    func cloudStatus() async throws -> FootprintCloudStatus {
        let data = try await request("status", method: "GET")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FootprintCloudStatus.self, from: data)
    }

    func issueGrant(raw: Bool, previews: Bool) async throws -> String {
        let body = try JSONEncoder().encode(["raw_tracks": raw, "photo_previews": previews])
        let data = try await request("grant", method: "POST", body: body)
        struct Grant: Decodable { let token: String }
        let token = try JSONDecoder().decode(Grant.self, from: data).token
        grantRevision += 1
        return token
    }

    func revokeGrant() async throws {
        _ = try await request("grant", method: "DELETE")
        grantRevision += 1
    }

    func revokeOAuth() async throws {
        _ = try await request("oauth", method: "DELETE")
        grantRevision += 1
    }

    private func request(_ path: String, method: String, body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard let base = Secrets.resolvedHarnessBaseURL().flatMap({ TravelerHarnessClient.validatedOrigin($0.absoluteString) })
        else { throw URLError(.resourceUnavailable) }
        guard let owner = account.identity, owner.userID == boundOwner else { throw URLError(.userAuthenticationRequired) }
        let generation = account.identityGeneration
        let token: String
        do {
            token = try await account.accessToken()
        } catch EmailAccountService.Failure.rejected where account.identityGeneration == generation {
            // Another account request may have completed the same session refresh.
            token = try await account.accessToken()
        }
        try Task.checkCancellation()
        guard account.identity == owner, boundOwner == owner.userID,
              account.identityGeneration == generation else { throw CancellationError() }
        var url = base.appendingPathComponent("v1/footprints").appendingPathComponent(path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard account.identity == owner, account.identityGeneration == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch response.statusCode {
        case 200..<300: return data
        case 400: throw URLError(.cannotParseResponse)
        case 401: throw URLError(.userAuthenticationRequired)
        case 404: throw URLError(.resourceUnavailable)
        default: throw URLError(.badServerResponse)
        }
    }
}

extension FootprintRecorder: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            if self.scanning == nil { self.scanFavorites() }
            else { self.needsPhotoRescan = true }
        }
    }
}
