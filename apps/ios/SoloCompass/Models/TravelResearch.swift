import Foundation
import CryptoKit

/// Bounded JSON at tool/provider boundaries. Never interpreted as host authority.
indirect enum TravelJSON: Codable, Equatable, Sendable {
    case object([String: TravelJSON]), array([TravelJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: TravelJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([TravelJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> TravelJSON { object[key] ?? .null }
    var object: [String: TravelJSON] { if case .object(let v) = self { return v }; return [:] }
    var array: [TravelJSON] { if case .array(let v) = self { return v }; return [] }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var int: Int { if case .number(let v) = self, v.isFinite, abs(v) < Double(Int.max) { return Int(v) }; return 0 }
    var isNull: Bool { self == .null }
    static func parse(_ raw: String) throws -> Self {
        guard raw.utf8.count <= 256_000 else { throw TravelResearchError.invalidArguments }
        return try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
    }
    static func from<T: Encodable>(_ value: T) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    func encoded() throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(self), as: UTF8.self)
    }
    static func result(_ data: Self, status: String = "ok", missing: [String] = []) -> Self {
        .object(["contractVersion": .number(1), "status": .string(status), "data": data,
                 "coverage": .object(["kind": .string(missing.isEmpty ? "complete" : "partial"), "missing": .array(missing.map(Self.string))]),
                 "observedAt": .string(Date().ISO8601Format())])
    }
    static func problem(_ code: String, status: String = "unavailable") -> Self {
        .object(["contractVersion": .number(1), "status": .string(status), "data": .null,
                 "coverage": .object(["kind": .string("unknown"), "missing": .array([.string(code)])]),
                 "error": .object(["code": .string(code), "retryable": .bool(true)])])
    }
    static func webSearchResult(queries: [Self], missing: [String], fetchRefs: [String: Self]) -> Self {
        let status = queries.isEmpty && !missing.isEmpty ? "unavailable"
            : !missing.isEmpty ? "partial"
            : queries.allSatisfy({ $0["results"].array.isEmpty }) ? "empty" : "ok"
        var envelope = result(.object(["queries": .array(queries)]), status: status, missing: missing).object
        envelope["_hostFetchRefs"] = .object(fetchRefs)
        return .object(envelope)
    }
}

struct TravelScope: Codable, Equatable, Sendable {
    var owner: String
    var generation: UInt64
    var reference: String { TravelIdentity.hash(owner) }
    var isAccount: Bool { owner != "device" }
}
enum TravelIdentity {
    static func instant(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    static func fetchRef(_ url: String) -> String { "fetch_" + hash(url) }
    static func hash(_ raw: String) -> String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }
}
enum TravelResearchError: Error, Equatable {
    case invalidArguments, notFound, versionConflict, lockedField, budgetExhausted, scopeChanged, persistence, expired, unavailable, placeTimezoneMismatch
}

struct TravelLocationHint: Sendable {
    var label: String
    var longitude: Double
    var latitude: Double
}

struct TravelContext: Codable, Equatable, Sendable {
    /// Explicit destination in this message outranks map selection; neither proves physical location.
    var message: String
    var selectedArea: String?
    var authorizedLocation: String?
    var history: String = ""
    var capturedAt: String = Date().ISO8601Format()
    var clockTimezone: String = TimeZone.current.identifier
    var capabilities: [String: Bool]?
    var areaLongitude: Double?
    var areaLatitude: Double?
    var authorizedAreaLongitude: Double?
    var authorizedAreaLatitude: Double?
}
struct TravelDateScope: Codable, Equatable, Sendable {
    var kind: String
    var startDate: String?
    var endDate: String?
    var timezone: String?
}
struct TravelStopTime: Codable, Equatable, Sendable {
    var kind: String
    var instant: String?
    var timezone: String?
    var startLocal: String?
    var endLocal: String?
}
struct TravelPlace: Codable, Equatable, Sendable {
    var ref: String
    var name: String
    var coordinates: [Double] // GeoJSON [longitude, latitude].
    var timezone: String? = nil // Host/provider IANA zone, never the device clock zone.
}
struct TravelStop: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var candidateRef: String?
    var experienceRef: String?
    var place: TravelPlace?
    var time: TravelStopTime
    var durationMinutes: Int?
    var claimRefs: [String]
    var lockedFields: [String]
}
struct TravelDay: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var date: String?
    var label: String
    var stops: [TravelStop]
}
struct TravelPlanInput: Codable, Equatable, Sendable {
    var stablePlanId: String
    var title: String
    var dateScope: TravelDateScope
    var days: [TravelDay]
    var assumptions: [String]
    var allStops: [TravelStop] { days.flatMap(\.stops) }
}
struct TravelDraft: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var version: Int
    var plan: TravelPlanInput
    var baseItinerary: TravelJSON?
}
struct TravelConversation: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var calls: [TravelModelCall] = []
    var callID: String?
    var name: String?
}
struct TravelModelCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}
struct TravelModelResponse: Sendable { var text: String?; var calls: [TravelModelCall] }
struct TravelStep: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var batch: AgentToolBatch?
    var completed: Bool = false
}
struct TravelResearchTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var messageID: UUID
    var activeMessageID: UUID?
    var linkInputAliases: [UUID]?
    var inputRevisions: [String: Int]?
    var scopeRef: String
    var context: TravelContext
    var contextRevision: Int = 1
    var url: String
    var invocationID: UUID?
    var state: String = "running"
    var sourceReads: Int = 0
    var queries: Int = 0
    var dispatches: Int = 0
    var modelSteps: Int = 0
    var activeSeconds: Double = 0
    var sourceFetchRefs: [String: String]?
    var sources: [String: TravelJSON] = [:]
    var places: [String: TravelPlace] = [:]
    var research: TravelJSON = .null
    var researchVersion: Int = 0
    var usedCalendarContext: Bool?
    var draft: TravelDraft?
    var userEditedDraft: Bool?
    var proposals: [String: TravelJSON] = [:]
    var operations: [String: TravelJSON] = [:]
    var steps: [TravelStep] = []
    var conversation: [TravelConversation] = []
    var answer: String = ""
    var pauseReason: String?
    var updatedAt: Date = Date()
}
