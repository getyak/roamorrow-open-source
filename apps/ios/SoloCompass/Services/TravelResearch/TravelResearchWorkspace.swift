import Foundation
import CryptoKit
import Observation

/// Every automatic local mutation, its journal receipt and its version share one encrypted atomic file.
@Observable @MainActor
final class TravelResearchWorkspace {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var owner: String
        var fileRevision: UUID?
        var tasks: [String: TravelResearchTask] = [:]
        var tombstones: Set<String> = []
        var detachedProposals: [String: TravelJSON]?
        var detachedOperations: [String: TravelJSON]?
        var accountPlanCache: [TravelJSON]? = []
        var formalPlans: [String: TravelDraft] = [:] // device domain only; never legacy LWW.
    }
    let scope: TravelScope
    private let url: URL
    private let key: SymmetricKey
    private var snapshot: Snapshot
    private var staging = false
    var tasks: [TravelResearchTask] { snapshot.tasks.values.sorted { $0.updatedAt > $1.updatedAt } }
    init(url: URL, scope: TravelScope, key: Data) throws {
        guard key.count == 32 else { throw TravelResearchError.persistence }
        self.url = url; self.scope = scope; self.key = SymmetricKey(data: key)
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 8_000_000 else { throw TravelResearchError.persistence }
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: self.key, authenticating: Data(scope.owner.utf8))
            snapshot = try AgentRuntimeJSON.decoder().decode(Snapshot.self, from: decoded)
            guard snapshot.owner == scope.owner, snapshot.schemaVersion == 1 else { throw TravelResearchError.scopeChanged }
            for id in snapshot.tasks.keys {
                guard var task = snapshot.tasks[id] else { continue }
                if task.usedCalendarContext == nil, task.steps.flatMap({ $0.batch?.calls ?? [] }).contains(where: { ["list_calendar_events", "preview_calendar_changes", "get_operation"].contains($0.name) && $0.resultJSON != nil }) { task.usedCalendarContext = true }
                for index in task.conversation.indices where task.conversation[index].role == "system" {
                    task.conversation[index].role = "user"
                    task.conversation[index].content = "Untrusted retained material: " + (task.conversation[index].content ?? "")
                }
                snapshot.tasks[id] = task
            }
            for id in snapshot.tasks.keys where snapshot.tasks[id]?.state == "running" {
                snapshot.tasks[id]?.state = "paused"; snapshot.tasks[id]?.pauseReason = "interrupted"
                snapshot.tasks[id]?.activeSeconds = 90
            }
        } else { snapshot = Snapshot(owner: scope.owner) }
    }
    func atomicCheckpoint(taskID: UUID, stepID: UUID, call: AgentToolCheckpoint, body: () throws -> TravelJSON) throws -> AgentToolCheckpoint {
        guard !staging else { throw TravelResearchError.persistence }
        let before = snapshot; staging = true
        do {
            var observed = call
            do { observed.resultJSON = try body().encoded() }
            catch { observed.resultJSON = try TravelJSON.problem(Self.code(error), status: "conflict").encoded() }
            observed.state = .completed
            try update(taskID) { task in
                guard let s = task.steps.firstIndex(where: { $0.id == stepID }), let c = task.steps[s].batch?.calls.firstIndex(where: { $0.id == call.id }) else { throw TravelResearchError.notFound }
                task.steps[s].batch?.calls[c] = observed
            }
            let next = snapshot; staging = false; snapshot = before; try commit(next); return observed
        } catch { staging = false; snapshot = before; throw error }
    }
    static func code(_ error: Error) -> String {
        switch error as? TravelResearchError {
        case .versionConflict: return "version_conflict"
        case .lockedField: return "locked_field"
        case .notFound: return "not_found"
        case .budgetExhausted: return "budget_exhausted"
        case .placeTimezoneMismatch: return "place_timezone_mismatch_use_returned_place_timezone"
        default: return "invalid_arguments"
        }
    }
    func task(_ id: UUID) -> TravelResearchTask? { snapshot.tasks[id.uuidString] }
    func update(_ id: UUID, _ body: (inout TravelResearchTask) throws -> Void) throws {
        var next = snapshot
        guard var task = next.tasks[id.uuidString], !next.tombstones.contains(id.uuidString) else { throw TravelResearchError.notFound }
        try body(&task); task.updatedAt = Date(); next.tasks[id.uuidString] = task
        try commit(next)
    }
    private func commit(_ next: Snapshot) throws {
        if staging { snapshot = next; return }
        // A prior account-generation workspace must never overwrite a newer object's tombstones or drafts.
        if !FileManager.default.fileExists(atPath: url.path), snapshot.fileRevision != nil { throw TravelResearchError.versionConflict }
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Data(scope.owner.utf8))
            let disk = try AgentRuntimeJSON.decoder().decode(Snapshot.self, from: decoded)
            guard disk.fileRevision == snapshot.fileRevision else { throw TravelResearchError.versionConflict }
        }
        var next = next; next.fileRevision = UUID()
        let data = try AgentRuntimeJSON.encoder().encode(next)
        guard data.count <= 6_000_000 else { throw TravelResearchError.persistence }
        let encrypted = try AES.GCM.seal(data, using: key, authenticating: Data(scope.owner.utf8))
        guard let bytes = encrypted.combined else { throw TravelResearchError.persistence }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        snapshot = next
    }
    func start(messageID: UUID, url: String, context: TravelContext) throws -> TravelResearchTask {
        if let existing = tasks.first(where: { $0.messageID == messageID || $0.activeMessageID == messageID || ($0.linkInputAliases ?? []).contains(messageID) }) { return existing }
        if let existing = tasks.first(where: {
            $0.url == url && $0.context.message == context.message && $0.context.selectedArea == context.selectedArea
                && $0.context.authorizedLocation == context.authorizedLocation
                && (ISO8601DateFormatter().date(from: $0.context.capturedAt)?.timeIntervalSinceNow ?? -1000) > -900
        }) {
            try update(existing.id) { $0.linkInputAliases = Array(Set(($0.linkInputAliases ?? []) + [messageID])) }
            return task(existing.id) ?? existing
        }
        guard let parsed = URLComponents(string: url), ["https", "http"].contains(parsed.scheme), parsed.host != nil,
              parsed.user == nil, parsed.password == nil, url.count <= 4096 else { throw TravelResearchError.invalidArguments }
        let id = messageID // persistent input is the task identity, not a model-generated ID.
        guard !snapshot.tombstones.contains(id.uuidString) else { throw TravelResearchError.notFound }
        var task = TravelResearchTask(id: id, messageID: messageID, scopeRef: scope.reference, context: context, url: url)
        task.sourceFetchRefs = [TravelIdentity.fetchRef(url): url]
        var next = snapshot; next.tasks[id.uuidString] = task; try commit(next); return task
    }
    func forget(_ id: UUID) throws {
        var next = snapshot; next.tasks.removeValue(forKey: id.uuidString); next.tombstones.insert(id.uuidString)
        // Minimal external receipts are retained separately by the server; forgetting never deletes provider events.
        try commit(next)
    }
    func forgetAll() throws {
        var next = snapshot; next.tombstones.formUnion(next.tasks.keys); next.tasks = [:]; try commit(next)
    }
    func pauseAll() throws {
        var next = snapshot
        for id in next.tasks.keys where next.tasks[id]?.state == "running" {
            next.tasks[id]?.state = "paused"; next.tasks[id]?.pauseReason = "foreground_ended"
        }
        try commit(next)
    }
    func reserve(taskID: UUID, tool: String, queries: Int) throws {
        guard let task = task(taskID) else { throw TravelResearchError.notFound }
        if task.dispatches >= 24 || task.sourceReads + (tool == "read_source" ? 1 : 0) > 8
            || task.queries + queries > 4 || task.activeSeconds >= 90 {
            try update(taskID) { $0.state = "paused"; $0.pauseReason = "budget_exhausted" }
            throw TravelResearchError.budgetExhausted
        }
        try update(taskID) {
            $0.dispatches += 1; $0.sourceReads += tool == "read_source" ? 1 : 0; $0.queries += queries
        }
    }
    /// Reserve the remaining possible network work before crossing the gateway.
    /// A lost response/crash cannot silently refund embedded reads.
    func allocateSourceReadBudget(taskID: UUID) throws -> Int {
        guard let task = task(taskID), (1...8).contains(task.sourceReads) else { throw TravelResearchError.budgetExhausted }
        let allocation = 9 - task.sourceReads
        try update(taskID) { $0.sourceReads += allocation - 1 }
        return allocation
    }
    func cacheSource(_ result: TravelJSON, taskID: UUID, allocation: Int = 0, fetchURL: String? = nil) throws {
        let document = result["data"]
        guard !document["id"].string.isEmpty else { return }
        // Body evidence is retained with original sourceRef/blockId; the model cannot mint evidence.
        try update(taskID) { task in
            task.sources[document["id"].string] = result
            if allocation > 0 {
                let observed = result["usage"]["sourceReads"].isNull ? (result["status"].string == "unavailable" ? allocation : 1) : result["usage"]["sourceReads"].int
                task.sourceReads -= max(0, allocation - max(1, min(allocation, observed)))
            }
            var fetchRefs = task.sourceFetchRefs ?? [:]
            if let fetchURL, fetchRefs.values.contains(fetchURL) { fetchRefs[document["id"].string] = fetchURL }
            for raw in document["outboundReferences"].array.map(\.string) where fetchRefs.count < 200 && raw.count <= 4096 {
                guard let url = URL(string: raw), ["https", "http"].contains(url.scheme) else { continue }
                fetchRefs[TravelIdentity.fetchRef(raw)] = raw
            }
            task.sourceFetchRefs = fetchRefs
            func retainChildren(_ parent: TravelJSON) {
                for child in parent["children"].array {
                    var metadata = child.object
                    metadata["contentBlocks"] = .array(document["contentBlocks"].array.filter { $0["sourceRef"] == child["id"] })
                    var envelope = result.object; envelope["data"] = .object(metadata)
                    task.sources[child["id"].string] = .object(envelope)
                    retainChildren(child)
                }
            }
            retainChildren(document)
        }
    }
    func registerSourceURLs(_ urls: [String], taskID: UUID) throws {
        try update(taskID) { task in
            var refs = task.sourceFetchRefs ?? [:]
            for raw in urls where refs.count < 200 && raw.count <= 4096 {
                guard let url = URL(string: raw), ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil else { continue }
                refs[TravelIdentity.fetchRef(raw)] = raw
            }
            task.sourceFetchRefs = refs
        }
    }
    func source(_ id: String, taskID: UUID) -> TravelJSON? { task(taskID)?.sources[id] }
    static func availabilityField(_ path: String) -> String? {
        let leaf = (path.split(separator: ".").last.map(String.init) ?? "").lowercased().filter(\.isLetter)
        if ["hours", "openinghours", "openingtime"].contains(leaf) { return "hours" }
        if ["booking", "bookingavailability", "reservation", "reservationavailability"].contains(leaf) { return "booking" }
        return nil
    }
    static func isUnknownAvailability(_ claim: TravelJSON) -> Bool {
        guard availabilityField(claim["fieldPath"].string) != nil else { return false }
        return claim["value"].isNull || ["unknown", "unavailable", "unverified", "not verified", "未知", "未核实", "尚未核实", "不详"]
            .contains(claim["value"].string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    func saveResearch(_ args: TravelJSON, taskID: UUID) throws -> TravelJSON {
        try keys(args, allowed: ["researchId", "expectedVersion", "sourceRefs", "claims", "candidates", "decisionNotes", "openQuestions"])
        guard let current = task(taskID), args["claims"].array.count <= 40, args["candidates"].array.count <= 15,
              args["sourceRefs"].array.count <= 20, args["decisionNotes"].array.count <= 10, args["openQuestions"].array.count <= 10 else { throw TravelResearchError.invalidArguments }
        if current.researchVersion > 0 {
            guard args["researchId"].string == taskID.uuidString, args["expectedVersion"].int == current.researchVersion else { throw TravelResearchError.versionConflict }
        } else if !args["researchId"].isNull || !args["expectedVersion"].isNull { throw TravelResearchError.invalidArguments }
        guard args["sourceRefs"].array.allSatisfy({ current.sources[$0.string] != nil }) else { throw TravelResearchError.notFound }
        var refs: Set<String> = []
        let claims = try args["claims"].array.map { claim -> TravelJSON in
            try keys(claim, allowed: ["clientRef", "subjectRef", "fieldPath", "value", "status", "evidenceRefs", "effectiveRange"])
            guard !claim["clientRef"].string.isEmpty, refs.insert(claim["clientRef"].string).inserted else { throw TravelResearchError.invalidArguments }
            var copy = claim.object
            let evidence = claim["evidenceRefs"].array
            let valid = !evidence.isEmpty && evidence.allSatisfy { ref in
                guard let result = current.sources[ref["sourceRef"].string] else { return false }
                return result["data"]["contentBlocks"].array.contains {
                    $0["blockId"].string == ref["blockId"].string
                        && $0["sourceRef"].string == ref["sourceRef"].string
                        && TravelIdentity.hash($0["text"].string) == ref["excerptHash"].string
                }
            }
            guard ["imported", "unknown", "supported", "disputed"].contains(claim["status"].string) else { throw TravelResearchError.invalidArguments }
            if !valid || (current.sources[claim["subjectRef"].string] == nil && Self.isUnknownAvailability(claim)) { copy["status"] = .string("unknown") }
            else if claim["status"].string == "supported", evidence.allSatisfy({ current.sources[$0["sourceRef"].string]?["data"]["trust"].string == "user_supplied" }) { copy["status"] = .string("imported") }
            // A matching excerpt only proves the excerpt exists, not that its claim is current or independent.
            return .object(copy)
        }
        var candidates: Set<String> = []
        for candidate in args["candidates"].array {
            try keys(candidate, allowed: ["clientRef", "title", "action", "placeRef", "experienceRef", "claimRefs", "reason"])
            guard !candidate["clientRef"].string.isEmpty, candidates.insert(candidate["clientRef"].string).inserted,
                  !candidate["title"].string.isEmpty, candidate["title"].string.count <= 160,
                  candidate["claimRefs"].array.allSatisfy({ refs.contains($0.string) }),
                  candidate["placeRef"].isNull || current.places[candidate["placeRef"].string] != nil,
                  candidate["experienceRef"].isNull else { throw TravelResearchError.invalidArguments }
        }
        // The host supplies explicit conservative states even when a model
        // omits a field. These are not fabricated factual claims or citations.
        var availability: [String: TravelJSON] = [:]
        for candidate in args["candidates"].array {
            let placeRef = candidate["placeRef"].string
            let subject = placeRef.isEmpty ? candidate["clientRef"].string : placeRef
            let samePlace = args["candidates"].array.filter { !placeRef.isEmpty && $0["placeRef"].string == placeRef }.map { $0["clientRef"].string }
            let subjects = Set([candidate["clientRef"].string, subject] + samePlace)
            var fields: [String: TravelJSON] = [:]
            for field in ["hours", "booking"] {
                let statuses = Set(claims.filter { subjects.contains($0["subjectRef"].string) && Self.availabilityField($0["fieldPath"].string) == field }.map { $0["status"].string })
                let status = statuses.contains("disputed") ? "disputed" : statuses.count == 1 ? (statuses.first ?? "unknown") : "unknown"
                fields[field] = .string(status)
            }
            availability[subject] = .object(fields)
        }
        var research = args.object; research["claims"] = .array(claims); research["availability"] = .object(availability)
        research["researchId"] = .string(taskID.uuidString); research["version"] = .number(Double(current.researchVersion + 1))
        let saved = TravelJSON.object(research)
        try update(taskID) { $0.research = saved; $0.researchVersion += 1 }
        return .result(saved)
    }
    func saveDraft(_ args: TravelJSON, taskID: UUID) throws -> TravelJSON {
        try keys(args, allowed: ["draftId", "expectedVersion", "baseItinerary", "title", "dateScope", "days", "constraintRefs", "assumptions"])
        guard let current = task(taskID) else { throw TravelResearchError.notFound }
        let old = current.draft
        guard old == nil ? args["draftId"].isNull && args["expectedVersion"].isNull
            : args["draftId"].string == old?.id && args["expectedVersion"].int == old?.version else { throw TravelResearchError.versionConflict }
        // Existing-plan handles are host-bound; arbitrary model IDs cannot acquire authority.
        guard args["baseItinerary"].isNull || args["baseItinerary"] == old?.baseItinerary else { throw TravelResearchError.notFound }
        let candidateList = current.research["candidates"].array
        let candidateMap = Dictionary(uniqueKeysWithValues: candidateList.map { ($0["clientRef"].string, $0) })
        let claims = Set(current.research["claims"].array.map { $0["clientRef"].string })
        var dayIDs: Set<String> = []; var stopIDs: Set<String> = []
        let days = try args["days"].array.map { day -> TravelDay in
            try keys(day, allowed: ["clientDayRef", "date", "label", "stops"])
            let dayID = day["clientDayRef"].string
            guard !dayID.isEmpty, dayIDs.insert(dayID).inserted else { throw TravelResearchError.invalidArguments }
            let stops = try day["stops"].array.map { stop -> TravelStop in
                try keys(stop, allowed: ["clientStopRef", "candidateRef", "placeRef", "time", "durationMinutes", "claimRefs", "lockedFields"])
                let id = stop["clientStopRef"].string
                guard !id.isEmpty, stopIDs.insert(id).inserted, let candidate = candidateMap[stop["candidateRef"].string],
                      stop["lockedFields"].isNull || stop["lockedFields"].array.isEmpty,
                      stop["claimRefs"].array.allSatisfy({ claims.contains($0.string) }) else { throw TravelResearchError.invalidArguments }
                let placeRef = stop["placeRef"].string
                guard placeRef.isEmpty || current.places[placeRef] != nil else { throw TravelResearchError.notFound }
                let time = try stop["time"].decoded(TravelStopTime.self)
                try validatePlaceTime(time, place: current.places[placeRef])
                try validateTime(time, date: day["date"].string, dateScope: args["dateScope"])
                let duration = stop["durationMinutes"].isNull ? nil : stop["durationMinutes"].int
                if let duration, !(1...1440).contains(duration) { throw TravelResearchError.invalidArguments }
                return TravelStop(id: id, title: candidate["title"].string, candidateRef: candidate["clientRef"].string,
                                  place: current.places[placeRef], time: time, durationMinutes: duration,
                                  claimRefs: stop["claimRefs"].array.map(\.string), lockedFields: [])
            }
            return TravelDay(id: dayID, date: day["date"].isNull ? nil : day["date"].string, label: day["label"].string, stops: stops)
        }
        guard !args["title"].string.isEmpty, args["title"].string.count <= 160, (1...14).contains(days.count),
              stopIDs.count <= 50, args["assumptions"].array.count <= 10 else { throw TravelResearchError.invalidArguments }
        let dateScope = try args["dateScope"].decoded(TravelDateScope.self)
        try validateDates(dateScope, days: days)
        var plan = TravelPlanInput(stablePlanId: old?.plan.stablePlanId ?? UUID().uuidString,
                                   title: args["title"].string, dateScope: dateScope, days: days,
                                   assumptions: args["assumptions"].array.map(\.string))
        if let old {
            for oldDay in old.plan.days {
                for locked in oldDay.stops where !locked.lockedFields.isEmpty {
                    guard let di = plan.days.firstIndex(where: { $0.id == oldDay.id }),
                          let si = plan.days[di].stops.firstIndex(where: { $0.id == locked.id }),
                          plan.days[di].stops[si].title == locked.title, plan.days[di].stops[si].time == locked.time,
                          plan.days[di].stops[si].place == locked.place,
                          plan.days[di].stops[si].durationMinutes == locked.durationMinutes,
                          oldDay.stops.firstIndex(where: { $0.id == locked.id }) == si,
                          plan.dateScope == old.plan.dateScope, plan.days[di].date == oldDay.date else { throw TravelResearchError.lockedField }
                    plan.days[di].stops[si].lockedFields = locked.lockedFields
                }
            }
        }
        let draft = TravelDraft(id: old?.id ?? taskID.uuidString, version: (old?.version ?? 0) + 1, plan: plan, baseItinerary: old?.baseItinerary)
        try update(taskID) { $0.draft = draft; $0.proposals = [:] }
        return .result(try .from(draft), missing: plan.allStops.contains(where: { $0.place == nil }) ? ["unlocated_stops", "routes_unverified"] : ["routes_unverified"])
    }
    func previewDevicePlan(taskID: UUID) throws -> TravelJSON {
        guard !scope.isAccount, let task = task(taskID), let draft = task.draft else { throw TravelResearchError.notFound }
        let existing = snapshot.formalPlans.values.first { $0.plan.stablePlanId == draft.plan.stablePlanId }
        let id = "device-proposal-" + TravelIdentity.hash(taskID.uuidString + String(task.contextRevision) + String(draft.version) + String(existing?.version ?? 0))
        let intent: TravelJSON = .object(["id": .string(id), "kind": .string("itinerary"), "targetId": .string(existing?.id ?? ""),
                                         "baseVersion": .number(Double(existing?.version ?? 0)), "draftVersion": .number(Double(draft.version)),
                                         "contextRevision": .number(Double(task.contextRevision)), "before": try existing.map { try .from($0.plan) } ?? .null,
                                         "after": try .from(draft.plan), "expiresAt": .string(Date().addingTimeInterval(900).ISO8601Format())])
        var object = intent.object; object["digest"] = .string(TravelIdentity.hash(try intent.encoded()))
        let proposal = TravelJSON.object(object)
        try update(taskID) { $0.proposals[id] = proposal }; return proposal
    }
    func confirmDevicePlan(taskID: UUID, proposal: TravelJSON) throws -> TravelJSON {
        guard !scope.isAccount, let task = task(taskID), task.proposals[proposal["id"].string] == proposal,
              task.contextRevision == proposal["contextRevision"].int, task.draft?.version == proposal["draftVersion"].int,
              let expires = ISO8601DateFormatter().date(from: proposal["expiresAt"].string), expires > Date(), let draft = task.draft else { throw TravelResearchError.expired }
        if let receipt = task.operations[proposal["id"].string] { return receipt }
        let existing = snapshot.formalPlans.values.first { $0.plan.stablePlanId == draft.plan.stablePlanId }
        guard existing?.version ?? 0 == proposal["baseVersion"].int else { throw TravelResearchError.versionConflict }
        var next = snapshot
        let adopted = TravelDraft(id: existing?.id ?? UUID().uuidString, version: (existing?.version ?? 0) + 1, plan: draft.plan)
        let receipt: TravelJSON = .object(["id": .string(UUID().uuidString), "proposalId": proposal["id"], "state": .string("succeeded"), "readbackStatus": .string("verified"), "plan": try .from(adopted)])
        next.formalPlans[adopted.id] = adopted
        next.tasks[taskID.uuidString]?.draft?.baseItinerary = .object(["id": .string(adopted.id), "version": .number(Double(adopted.version))])
        next.tasks[taskID.uuidString]?.operations[proposal["id"].string] = receipt
        try commit(next); return receipt
    }
    func detachedProposal(_ id: String) -> TravelJSON? { snapshot.detachedProposals?[id] }
    func saveDetachedProposal(_ proposal: TravelJSON) throws {
        guard scope.isAccount, !proposal["id"].string.isEmpty else { throw TravelResearchError.notFound }
        var next = snapshot; var records = next.detachedProposals ?? [:]; records[proposal["id"].string] = proposal
        next.detachedProposals = records; try commit(next)
    }
    func saveDetachedOperation(_ operation: TravelJSON, proposalID: String) throws {
        guard scope.isAccount else { throw TravelResearchError.notFound }
        var next = snapshot; var records = next.detachedOperations ?? [:]; records[proposalID] = operation
        next.detachedOperations = records; try commit(next)
    }
    var detachedOperationEntries: [TravelJSON] { Array((snapshot.detachedOperations ?? [:]).values) }
    func rebindBase(taskID: UUID, plan: TravelJSON, expectedDraftVersion: Int) throws {
        try update(taskID) { task in
            guard var draft = task.draft, draft.version == expectedDraftVersion,
                  draft.baseItinerary?["id"].string == plan["id"].string,
                  draft.plan.stablePlanId == plan["stablePlanId"].string else { throw TravelResearchError.versionConflict }
            draft.baseItinerary = .object(["id": plan["id"], "version": plan["version"]]); draft.version += 1
            task.draft = draft; task.userEditedDraft = false; task.proposals = [:]
            task.contextRevision += 1; task.state = "paused"; task.pauseReason = "base_refreshed"
        }
    }
    var cachedAccountPlans: [TravelJSON] { scope.isAccount ? snapshot.accountPlanCache ?? [] : [] }
    func cacheAccountPlans(_ plans: [TravelJSON]) throws {
        guard scope.isAccount, plans.count <= 100 else { throw TravelResearchError.invalidArguments }
        var next = snapshot; next.accountPlanCache = plans; try commit(next)
    }
    var devicePlans: [TravelDraft] { scope.isAccount ? [] : snapshot.formalPlans.values.sorted { $0.plan.title < $1.plan.title } }
    func setDates(taskID: UUID, start: Date, timezone: String, expectedVersion: Int? = nil) throws {
        guard let zone = TimeZone(identifier: timezone) else { throw TravelResearchError.invalidArguments }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        try update(taskID) { task in
            guard var draft = task.draft else { throw TravelResearchError.notFound }
            guard expectedVersion == nil || draft.version == expectedVersion else { throw TravelResearchError.versionConflict }
            if draft.plan.dateScope.kind == "dated", draft.plan.dateScope.startDate == formatter.string(from: start), draft.plan.dateScope.timezone == timezone { return }
            guard draft.plan.allStops.allSatisfy({ $0.lockedFields.isEmpty }) else { throw TravelResearchError.lockedField }
            for index in draft.plan.days.indices {
                guard let date = calendar.date(byAdding: .day, value: index, to: start) else { throw TravelResearchError.invalidArguments }
                draft.plan.days[index].date = formatter.string(from: date)
                for si in draft.plan.days[index].stops.indices { draft.plan.days[index].stops[si].time = TravelStopTime(kind: "unscheduled") }
            }
            draft.plan.dateScope = TravelDateScope(kind: "dated", startDate: draft.plan.days.first?.date, endDate: draft.plan.days.last?.date, timezone: timezone)
            draft.version += 1; task.draft = draft; task.userEditedDraft = true; task.proposals = [:]
        }
    }
    func scheduleStop(taskID: UUID, stopID: String, instant: Date, timezone: String, durationMinutes: Int) throws {
        guard (1...1440).contains(durationMinutes), let zone = TimeZone(identifier: timezone) else { throw TravelResearchError.invalidArguments }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
        try update(taskID) { task in
            guard var draft = task.draft, draft.plan.dateScope.kind == "dated",
                  let di = draft.plan.days.firstIndex(where: { $0.stops.contains { $0.id == stopID } }),
                  let si = draft.plan.days[di].stops.firstIndex(where: { $0.id == stopID }),
                  f.string(from: instant) == draft.plan.days[di].date else { throw TravelResearchError.invalidArguments }
            let selectedTime = TravelStopTime(kind: "fixed", instant: instant.ISO8601Format(), timezone: timezone)
            try validatePlaceTime(selectedTime, place: draft.plan.days[di].stops[si].place)
            draft.plan.days[di].stops[si].time = selectedTime
            draft.plan.days[di].stops[si].durationMinutes = durationMinutes
            draft.plan.days[di].stops[si].lockedFields = ["title", "time", "place", "order"]
            draft.plan.assumptions.append("User selected time and duration for " + stopID)
            draft.version += 1; task.draft = draft; task.userEditedDraft = true; task.proposals = [:]
        }
    }
    func editStop(taskID: UUID, stopID: String, title: String, locked: Bool, schedule: TravelStopTime? = nil, durationMinutes: Int? = nil, expectedVersion: Int? = nil) throws {
        guard !title.isEmpty, title.count <= 160 else { throw TravelResearchError.invalidArguments }
        try update(taskID) { task in
            guard var draft = task.draft, let di = draft.plan.days.firstIndex(where: { $0.stops.contains(where: { $0.id == stopID }) }),
                  let si = draft.plan.days[di].stops.firstIndex(where: { $0.id == stopID }) else { throw TravelResearchError.notFound }
            guard expectedVersion == nil || draft.version == expectedVersion else { throw TravelResearchError.versionConflict }
            if let schedule {
                try validatePlaceTime(schedule, place: draft.plan.days[di].stops[si].place)
                try validateTime(schedule, date: draft.plan.days[di].date ?? "", dateScope: try .from(draft.plan.dateScope))
                guard let durationMinutes, (1...1440).contains(durationMinutes) else { throw TravelResearchError.invalidArguments }
                draft.plan.days[di].stops[si].time = schedule
                draft.plan.days[di].stops[si].durationMinutes = durationMinutes
                draft.plan.assumptions.append("User selected time and duration for " + stopID)
            }
            draft.plan.days[di].stops[si].title = title
            draft.plan.days[di].stops[si].lockedFields = locked ? ["title", "time", "place", "order"] : []
            draft.version += 1; task.draft = draft; task.userEditedDraft = true; task.proposals = [:]
        }
    }
    private func keys(_ args: TravelJSON, allowed: Set<String>) throws {
        guard case .object = args, Set(args.object.keys).isSubset(of: allowed) else { throw TravelResearchError.invalidArguments }
    }
    private func localDate(_ raw: String, zone: String) -> Date? {
        guard raw.count == 10, let tz = TimeZone(identifier: zone) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: raw), f.string(from: date) == raw else { return nil }; return date
    }
    private func validateDates(_ scope: TravelDateScope, days: [TravelDay]) throws {
        if scope.kind == "undated" {
            guard scope.startDate == nil, scope.endDate == nil, days.allSatisfy({ $0.date == nil }) else { throw TravelResearchError.invalidArguments }; return
        }
        guard scope.kind == "dated", let zone = scope.timezone, let start = scope.startDate, let end = scope.endDate,
              let a = localDate(start, zone: zone), let b = localDate(end, zone: zone), b >= a, b.timeIntervalSince(a) <= 14 * 86400,
              days.allSatisfy({ day in guard let date = day.date else { return false }; return localDate(date, zone: zone) != nil && date >= start && date <= end }) else { throw TravelResearchError.invalidArguments }
    }
    private func validateTime(_ t: TravelStopTime, date: String, dateScope: TravelJSON) throws {
        if t.kind == "unscheduled" {
            guard t.instant == nil, t.startLocal == nil, t.endLocal == nil, t.timezone == nil else { throw TravelResearchError.invalidArguments }; return
        }
        guard let zone = t.timezone, TimeZone(identifier: zone) != nil else { throw TravelResearchError.invalidArguments }
        if t.kind == "window" {
            guard let start = t.startLocal, let end = t.endLocal, validClock(start), validClock(end), start < end, t.instant == nil else { throw TravelResearchError.invalidArguments }
            // A window is an unscheduled preference, never a resolved DST-sensitive instant.
            return
        }
        guard t.kind == "fixed", dateScope["kind"].string == "dated", let instant = t.instant,
              instant.hasSuffix("Z"), t.startLocal == nil, t.endLocal == nil,
              let parsed = TravelIdentity.instant(instant) else { throw TravelResearchError.invalidArguments }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: zone); f.dateFormat = "yyyy-MM-dd"
        guard f.string(from: parsed) == date else { throw TravelResearchError.invalidArguments }
    }
    private func validatePlaceTime(_ time: TravelStopTime, place: TravelPlace?) throws {
        if time.kind != "unscheduled", let known = place?.timezone, time.timezone != known {
            throw TravelResearchError.placeTimezoneMismatch
        }
    }
    private func validClock(_ value: String) -> Bool {
        let parts = value.split(separator: ":"); return value.count == 5 && parts.count == 2 && (0...23).contains(Int(parts[0]) ?? -1) && (0...59).contains(Int(parts[1]) ?? -1)
    }
}
