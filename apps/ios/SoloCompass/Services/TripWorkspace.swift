import CryptoKit
import Foundation
import Observation

/// Saved trips have their own encrypted file, independent of temporary AI research history.
@MainActor
@Observable
final class TripWorkspace {
    private static var active: TripWorkspace?

    private struct Snapshot: Codable {
        var revision: UUID?
        var trips: [String: TripRecord] = [:]
    }

    let scope: TravelScope
    private let url: URL
    private let key: SymmetricKey
    private var snapshot: Snapshot

    init(url: URL, scope: TravelScope, key: Data) throws {
        guard key.count == 32 else { throw TravelResearchError.persistence }
        self.url = url
        self.scope = scope
        self.key = SymmetricKey(data: key)
        snapshot = try Self.read(url, key: self.key, scope: scope) ?? Snapshot()
    }

    static func open(scope: TravelScope) throws -> TripWorkspace {
        if let active, active.scope == scope { return active }
        active = nil
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roamorrow/Trips/v1")
        let file = root.appendingPathComponent(scope.reference + ".sealed")
        let account = "sc.trip.key." + scope.reference
        let key: Data
        if let raw = KeychainStore.read(account: account), let saved = Data(base64Encoded: raw), saved.count == 32 {
            key = saved
        } else {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw TravelResearchError.persistence }
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            guard KeychainStore.write(account: account, value: key.base64EncodedString()) else { throw TravelResearchError.persistence }
        }
        let workspace = try TripWorkspace(url: file, scope: scope, key: key)
        active = workspace
        return workspace
    }

    private static func read(_ url: URL, key: SymmetricKey, scope: TravelScope) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 6_100_000 else { throw TravelResearchError.persistence }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Data(scope.owner.utf8))
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func commit(_ candidate: Snapshot) throws {
        let diskRevision = try Self.read(url, key: key, scope: scope)?.revision
        guard diskRevision == snapshot.revision else { throw TravelResearchError.versionConflict }
        var next = candidate
        next.revision = UUID()
        let payload = try JSONEncoder().encode(next)
        guard payload.count <= 6_000_000,
              let bytes = try AES.GCM.seal(payload, using: key, authenticating: Data(scope.owner.utf8)).combined else {
            throw TravelResearchError.persistence
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        snapshot = next
    }

    var trips: [TripRecord] {
        snapshot.trips.values.sorted {
            let left = $0.plan.days.first?.date ?? ""
            let right = $1.plan.days.first?.date ?? ""
            return left == right ? $0.id < $1.id : left < right
        }
    }

    func trip(_ id: String) -> TripRecord? { snapshot.trips[id] }

    @discardableResult
    func applyTrip(_ proposal: TripProposal) throws -> TripRecord {
        guard !proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposal.summary.count <= 600 else { throw TravelResearchError.invalidArguments }
        var next = snapshot
        var records = next.trips
        let saved: TripRecord
        if let id = proposal.tripId {
            guard let prior = records[id] else { throw TravelResearchError.notFound }
            guard prior.version == proposal.baseVersion else { throw TravelResearchError.versionConflict }
            try proposal.plan.validate(preserving: prior.plan)
            saved = TripRecord(id: id, version: prior.version + 1, plan: proposal.plan,
                               undo: prior.plan, latestSummary: proposal.summary, isExample: prior.isExample)
        } else {
            guard proposal.baseVersion == nil else { throw TravelResearchError.invalidArguments }
            try proposal.plan.validate()
            saved = TripRecord(id: UUID().uuidString, version: 1, plan: proposal.plan,
                               undo: nil, latestSummary: nil, isExample: false)
        }
        records[saved.id] = saved
        next.trips = records
        try commit(next)
        return saved
    }

    @discardableResult
    func undoTrip(_ id: String, expectedVersion: Int) throws -> TripRecord {
        var records = snapshot.trips
        guard var record = records[id], let before = record.undo else {
            throw TravelResearchError.notFound
        }
        guard expectedVersion == record.version else { throw TravelResearchError.versionConflict }
        record.plan = before
        record.version += 1
        record.undo = nil
        record.latestSummary = nil
        records[id] = record
        var next = snapshot
        next.trips = records
        try commit(next)
        return record
    }

    func deleteTrip(_ id: String, expectedVersion: Int) throws {
        guard let saved = snapshot.trips[id] else { throw TravelResearchError.notFound }
        guard saved.version == expectedVersion else { throw TravelResearchError.versionConflict }
        var next = snapshot
        next.trips.removeValue(forKey: id)
        try commit(next)
    }

    #if DEBUG
    func addTripExamples() throws {
        var next = snapshot
        var records = next.trips
        for example in TripExamples.records where records[example.id] == nil {
            try example.plan.validate()
            records[example.id] = example
        }
        guard records != next.trips else { return }
        next.trips = records
        try commit(next)
    }
    #endif

}
