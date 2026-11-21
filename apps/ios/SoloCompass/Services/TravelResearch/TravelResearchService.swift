import Foundation
import Observation
import CryptoKit
import MapKit

/// The global chat stores only this service's opaque references and neutral summary.
@Observable @MainActor final class TravelResearchService {
    static let shared = TravelResearchService()
    static let continueInChat = Notification.Name("Roamorrow.TravelResearch.Continue")
    private(set) var workspace: TravelResearchWorkspace?
    private(set) var errorCode: String?
    private let account = EmailAccountService.shared
    private let gateway: TravelGatewayClient
    private var coordinator: TravelResearchCoordinator?
    private var activeRun: Task<TravelResearchTask, Error>?
    private var aiService: AIService?
    private var foreground = true
    private var invocation = UUID()
    private var initializedScope: TravelScope?
    init(workspace: TravelResearchWorkspace? = nil, gateway: TravelGatewayClient = TravelGatewayClient()) {
        self.workspace = workspace; initializedScope = workspace?.scope; self.gateway = gateway
    }
    var configured: Bool { aiService != nil }
    func configure(aiService: AIService) { self.aiService = aiService }
    var currentScope: TravelScope { .init(owner: account.identity?.userID ?? "device", generation: account.generation) }
    func visibleTask(_ reference: TravelResearchReference) -> TravelResearchTask? {
        guard initializedScope == currentScope, reference.scopeRef == currentScope.reference else { return nil }
        return workspace?.task(reference.taskID)
    }
    func refreshIdentity() async {
        if initializedScope != currentScope { invalidate() }
        do { try await openWorkspace() } catch { errorCode = "workspace_unavailable" }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { invocation = UUID(); activeRun?.cancel(); try? workspace?.pauseAll() }
    }
    func invalidate() {
        invocation = UUID(); activeRun?.cancel(); activeRun = nil; try? workspace?.pauseAll(); coordinator = nil; workspace = nil; initializedScope = nil
    }
    func forgetAll() throws {
        invocation = UUID(); activeRun?.cancel(); activeRun = nil; coordinator = nil
        try workspace?.forgetAll()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Roamorrow/TravelResearch/v1")
        if FileManager.default.fileExists(atPath: root.path) {
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "sealed" {
                try FileManager.default.removeItem(at: file)
                guard KeychainStore.delete(account: "sc.travel-research.key." + file.deletingPathExtension().lastPathComponent) else { throw TravelResearchError.persistence }
            }
        }
        workspace = nil; initializedScope = nil
    }
    static func firstURL(_ text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .first(where: { ["https", "http"].contains($0.scheme) })?.absoluteString
    }
    static func isResearchFollowUp(_ text: String) -> Bool {
        let value = text.lowercased()
        return ["行程", "草稿", "轻松", "慢一点", "删掉", "再加", "这些", "那天", "几点", "更早", "继续", "优化", "改成", "换成", "第二天", "第一天", "第三天", "下午", "上午", "留空", "日历", "日期", "预算", "预约", "交通", "itinerary", "draft", "continue", "reschedule", "calendar", "day 2", "day two", "replace", "trip"].contains { value.contains($0) }
    }
    func respond(entries: [CompanionHomeEntry], area: CompanionHomeSearchArea?, progress: @escaping @MainActor (String) -> Void,
                 locationHint: @escaping @MainActor () -> TravelLocationHint? = { nil },
                 isAdmitted: @escaping @MainActor () -> Bool = { true },
                 onAccepted: @escaping @MainActor (TravelResearchReference) async throws -> Void = { _ in }) async throws -> TravelResearchReference? {
        guard let user = entries.last(where: { $0.role == .user }), let aiService else { return nil }
        let url = Self.firstURL(user.text)
        let recentReply = entries.dropLast().last(where: { $0.role == .companion })
        let quotedReference = user.quotedMessage.flatMap { quote in entries.first(where: { $0.id == quote.entryID })?.researchReference ?? entries.first(where: { $0.replyToID == quote.entryID })?.researchReference }
        let followsResearch = Self.isResearchFollowUp(user.text)
        let previous = user.researchReference ?? quotedReference ?? (followsResearch ? recentReply?.researchReference : nil)
        guard url != nil || previous != nil else { return nil }
        try await openWorkspace()
        guard let workspace, foreground, isAdmitted() else { throw CancellationError() }
        let scope = currentScope; let attempt = UUID(); invocation = attempt
        if let selected = user.researchReference, selected.scopeRef != scope.reference { throw TravelResearchError.scopeChanged }
        var context = TravelContext(message: CompanionHomeAgent.messageContent(user), selectedArea: area?.name, authorizedLocation: nil,
                                    history: entries.suffix(12).filter { $0.researchReference == nil }.map { String($0.text.prefix(1000)) }.joined(separator: "\n"),
                                    areaLongitude: area?.longitude, areaLatitude: area?.latitude)
        let hint = locationHint()
        context.authorizedLocation = hint?.label
        context.authorizedAreaLongitude = hint?.longitude; context.authorizedAreaLatitude = hint?.latitude
        let previouslyUsedCalendar = previous.flatMap { workspace.task($0.taskID)?.usedCalendarContext } == true
        let needsCalendar = previouslyUsedCalendar || ["日历", "calendar"].contains { user.text.lowercased().contains($0) }
        let needsAccountActions = needsCalendar || ["采用", "正式行程", "保存行程", "adopt"].contains { user.text.lowercased().contains($0) }
        let capabilities: TravelJSON? = scope.isAccount && needsAccountActions ? try? await gateway.call("capabilities") : nil
        let modelCalendarConsent = scope.isAccount && needsCalendar ? (try? await calendarConsent()) == true : false
        context.capabilities = ["account_plans": capabilities?["account_plans"] == TravelJSON.bool(true),
                                "calendar_read": capabilities?["calendar_read"] == TravelJSON.bool(true) && modelCalendarConsent,
                                "calendar_write": capabilities?["calendar_write"] == TravelJSON.bool(true) && modelCalendarConsent]
        guard scope == currentScope, invocation == attempt, isAdmitted() else { throw CancellationError() }
        let task: TravelResearchTask; var followUp: String?
        if let selected = user.researchReference, selected.scopeRef == scope.reference, let existing = workspace.task(selected.taskID) {
            task = existing
            followUp = (existing.activeMessageID ?? existing.messageID) == user.id ? nil : context.message
        } else if let url {
            task = try workspace.start(messageID: user.id, url: url, context: context)
        } else if let previous, previous.scopeRef == scope.reference, let existing = workspace.task(previous.taskID) {
            task = existing
            // Retrying the original persisted input restores its journal rather than starting new actions.
            followUp = (existing.activeMessageID ?? existing.messageID) == user.id ? nil : context.message
        } else { return nil }
        // Capability changes are host-owned. Refresh them on admission without
        // replacing the task's frozen destination/map/location snapshot.
        try workspace.update(task.id) { $0.context.capabilities = context.capabilities }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let urls = detector.matches(in: user.text, range: NSRange(user.text.startIndex..., in: user.text)).compactMap { $0.url?.absoluteString }
            try workspace.registerSourceURLs(urls, taskID: task.id)
        }
        if user.researchReference != nil, context.message.count > 120, Self.firstURL(user.text) == nil {
            let text = String(context.message.prefix(16_000)); let hash = TravelIdentity.hash(text); let sourceID = "user_" + hash
            let document: TravelJSON = .object(["id": .string(sourceID), "title": .string("User supplied material"), "displayURL": .string(""), "contentHash": .string(hash), "accessStatus": .string("read"), "trust": .string("user_supplied"),
                "contentBlocks": .array([.object(["blockId": .string("b_" + hash), "sourceRef": .string(sourceID), "text": .string(text), "excerptHash": .string(hash)])]), "children": .array([])])
            try workspace.cacheSource(.result(document), taskID: task.id)
        }
        let reference = TravelResearchReference(taskID: task.id, scopeRef: scope.reference)
        try await onAccepted(reference)
        guard scope == currentScope, invocation == attempt, isAdmitted() else { throw CancellationError() }
        if task.state == "completed", followUp == nil { return .init(taskID: task.id, scopeRef: scope.reference) }
        let coordinator = TravelResearchCoordinator(workspace: workspace, model: { [weak self] messages, names in
            guard let self else { throw CancellationError() }
            if workspace.task(task.id)?.usedCalendarContext == true, (try? await self.calendarConsent()) != true { throw TravelResearchError.unavailable }
            guard self.currentScope == scope, self.invocation == attempt, self.foreground, isAdmitted(), !Task.isCancelled else { throw CancellationError() }
            let transport = messages.map { message in
                VoiceAgentSession.Message(role: VoiceAgentSession.Role(rawValue: message.role) ?? .system, content: message.content,
                                          toolCalls: message.calls.map { .init(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) },
                                          toolCallId: message.callID, name: message.name)
            }
            let result = try await aiService.sendAgentMessage(messages: transport, tools: TravelResearchTools.all.filter { names.contains($0.name) }, maxOutputTokens: 4096)
            return .init(text: result.content, calls: result.toolCalls.map { .init(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) })
        }, provider: { [weak self] name, args, task in
            guard let self else { throw CancellationError() }
            do { return try await self.provide(name, args: args, task: task) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as TravelGatewayClient.Failure { return .problem(failure.code, status: failure.code == "permission_required" ? "blocked" : "unavailable") }
            catch { return .problem("provider_unavailable") }
        }, isCurrent: { [weak self] in
            guard let self else { return false }; return self.foreground && self.currentScope == scope && self.invocation == attempt && isAdmitted()
        })
        self.coordinator = coordinator; coordinator.progress = progress
        var allowed = TravelResearchCoordinator.toolNames
        // Private calendars need both provider access and explicit model-context consent, checked in provide too.
        if context.capabilities?["calendar_read"] != true { allowed.remove("list_calendar_events") }
        if context.capabilities?["calendar_write"] != true { allowed.remove("preview_calendar_changes") }
        if scope.isAccount && context.capabilities?["account_plans"] != true { allowed.remove("preview_itinerary_changes") }
        let run = Task { try await coordinator.respond(taskID: task.id, message: followUp, inputID: user.id, allowedTools: allowed) }
        activeRun = run
        defer { if invocation == attempt { activeRun = nil } }
        _ = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
        guard currentScope == scope, invocation == attempt, foreground else { throw CancellationError() }
        return .init(taskID: task.id, scopeRef: scope.reference)
    }
    private func openWorkspace() async throws {
        if let identity = account.identity {
            _ = try await account.accessToken()
            guard account.identity == identity else { throw TravelResearchError.scopeChanged }
        }
        let scope = currentScope
        if initializedScope == scope, workspace != nil { return }
        invalidate()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Roamorrow/TravelResearch/v1")
        let url = root.appendingPathComponent(scope.reference + ".sealed")
        let keyAccount = "sc.travel-research.key." + scope.reference
        let key: Data
        if let raw = KeychainStore.read(account: keyAccount), let existing = Data(base64Encoded: raw), existing.count == 32 { key = existing }
        else {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw TravelResearchError.persistence }
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            guard KeychainStore.write(account: keyAccount, value: key.base64EncodedString()) else { throw TravelResearchError.persistence }
        }
        workspace = try TravelResearchWorkspace(url: url, scope: scope, key: key); initializedScope = scope
    }
    private func provide(_ name: String, args: TravelJSON, task: TravelResearchTask) async throws -> TravelJSON {
        switch name {
        case "read_source":
            guard let parsed = URLComponents(string: args["url"].string), ["https", "http"].contains(parsed.scheme), parsed.user == nil, parsed.password == nil else { throw TravelResearchError.invalidArguments }
            var body = args.object; body.removeValue(forKey: "refresh"); body.removeValue(forKey: "sourceId")
            return try await gateway.call("public-source", method: "POST", body: .object(body), publicSource: true)
        case "web_search":
            var results: [TravelJSON] = []; var missing: [String] = []; var fetchRefs: [String: TravelJSON] = [:]
            for query in args["queries"].array {
                try Task.checkCancellation()
                let outcome = await WebSearchService.shared.searchOutcome(query: query["query"].string)
                if !outcome.available { missing.append("search_unavailable"); continue }
                let pages = outcome.results.prefix(5).enumerated().map { index, page in
                    fetchRefs[TravelIdentity.fetchRef(page.url)] = .string(page.url)
                    return TravelJSON.object(["resultRef": .string(TravelIdentity.fetchRef(page.url)), "title": .string(page.title),
                                       "url": .string(Self.displayURL(page.url)), "snippet": .string(String(page.content.prefix(1500))),
                                       "provider": .string("tavily"), "rank": .number(Double(index))])
                }
                results.append(.object(["query": query["query"], "results": .array(pages)]))
            }
            return .webSearchResult(queries: results, missing: missing, fetchRefs: fetchRefs)
        case "search_places": return try await searchPlaces(args, task: task)
        case "get_place_evidence":
            let refs = args["placeRefs"].array
            guard (1...5).contains(refs.count), refs.allSatisfy({ task.places[$0.string] != nil }) else { throw TravelResearchError.notFound }
            return .result(.object(["places": .array(try refs.map { ref in
                .object(["place": try .from(task.places[ref.string]!), "status": .string("partial"), "unknowns": .array(args["fields"].array.filter { $0.string != "identity" })])
            })]), status: "partial", missing: ["hours", "booking", "price", "solo_quality"])
        case "estimate_route": return try await estimateRoute(args, task: task)
        case "get_itinerary":
            guard let id = task.draft?.baseItinerary?["id"].string, args["target"]["id"].string == id else { throw TravelResearchError.notFound }
            return .result(try await gateway.call("plans/" + id))
        case "preview_itinerary_changes":
            guard let draft = task.draft, args["draftId"].string == draft.id, args["draftVersion"].int == draft.version else { throw TravelResearchError.versionConflict }
            let target = args["target"]
            if target["kind"].string == "existing" {
                guard target["itineraryId"] == draft.baseItinerary?["id"], target["expectedVersion"] == draft.baseItinerary?["version"] else { throw TravelResearchError.notFound }
            } else if target["kind"].string != "new" { throw TravelResearchError.invalidArguments }
            return .result(try await previewPlan(taskID: task.id, target: target))
        case "list_calendar_events":
            guard args["provider"].string == "google", args["purpose"].string == "availability" else { return .problem("capability_unsupported", status: "blocked") }
            guard try await calendarConsent() else { return .problem("model_context_consent_required", status: "blocked") }
            // The existing product's explicit primary-calendar connection is the only supported target.
            guard args["calendarRefs"].isNull || args["calendarRefs"].array == [.string("primary")] else { throw TravelResearchError.invalidArguments }
            let page = try await gateway.call("calendar/list", method: "POST", body: .object(["calendarRef": .string("primary"), "range": args["range"]]))
            return .result(page, status: page["hasMore"] == TravelJSON.bool(true) ? "partial" : "ok", missing: page["coverage"]["missing"].array.map(\.string))
        case "preview_calendar_changes":
            guard args["provider"].string == "google", args["calendarRef"].string == "primary", try await calendarConsent() else { return .problem("permission_required", status: "blocked") }
            guard let draft = task.draft, args["source"]["kind"].string == "draft", args["source"]["id"].string == draft.id,
                  args["source"]["version"].int == draft.version else { throw TravelResearchError.versionConflict }
            return .result(try await previewCalendar(taskID: task.id, items: args["items"]))
        case "get_operation":
            guard task.operations[args["operationId"].string] != nil else { throw TravelResearchError.notFound }
            let cached = task.operations[args["operationId"].string] ?? .null
            if cached["kind"].string == "calendar" || !cached["items"].array.isEmpty {
                guard try await calendarConsent() else { return .problem("model_context_consent_required", status: "blocked") }
            }
            let path = cached["id"].string.isEmpty ? "proposals/" + cached["proposalId"].string + "/operation" : "operations/" + cached["id"].string
            let operation = try await gateway.call(path)
            if !operation["items"].array.isEmpty, (try? await calendarConsent()) != true { return .problem("model_context_consent_required", status: "blocked") }
            return .result(operation)
        default: return .problem("capability_unsupported", status: "blocked")
        }
    }
    private func calendarConsent() async throws -> Bool {
        let profile = try await TravelerHarnessClient().profile()
        return profile.ai_context_consent
    }
    func previewPlan(taskID: UUID, target: TravelJSON = .object(["kind": .string("new")]), userEdit: Bool = false) async throws -> TravelJSON {
        guard let workspace, initializedScope == currentScope, let task = workspace.task(taskID), let draft = task.draft else { throw TravelResearchError.notFound }
        if !currentScope.isAccount { return try workspace.previewDevicePlan(taskID: taskID) }
        let resolvedTarget = draft.baseItinerary.map { TravelJSON.object(["kind": .string("existing"), "itineraryId": $0["id"], "expectedVersion": $0["version"]]) } ?? target
        let beforeScope = currentScope
        var body: [String: TravelJSON] = ["plan": try .from(draft.plan), "contextRevision": .number(Double(task.contextRevision)), "draftVersion": .number(Double(draft.version)),
                                          "idempotencyKey": .string("preview-" + UUID().uuidString)]
        if resolvedTarget["kind"].string == "existing" { body["targetId"] = resolvedTarget["itineraryId"]; body["expectedVersion"] = resolvedTarget["expectedVersion"] }
        let proposal = try await gateway.call(userEdit ? "plans/preview-user-edit" : "plans/preview", method: "POST", body: .object(body))
        guard currentScope == beforeScope, workspace.task(taskID)?.draft?.version == draft.version, workspace.task(taskID)?.contextRevision == task.contextRevision else { throw TravelResearchError.scopeChanged }
        try workspace.update(taskID) { $0.proposals[proposal["id"].string] = proposal }
        return proposal
    }
    /// UI only. Model T11 always uses the lock-preserving previewPlan path.
    func previewUserPlan(taskID: UUID, refreshBase: Bool = false) async throws -> TravelJSON {
        guard let workspace, workspace.scope == currentScope, let task = workspace.task(taskID), let draft = task.draft else { throw TravelResearchError.notFound }
        if refreshBase, currentScope.isAccount, let base = draft.baseItinerary, !base["id"].string.isEmpty {
            let scope = currentScope
            let latest = try await gateway.call("plans/" + base["id"].string)
            guard scope == currentScope else { throw TravelResearchError.scopeChanged }
            try workspace.rebindBase(taskID: taskID, plan: latest, expectedDraftVersion: draft.version)
            activeRun?.cancel(); invocation = UUID()
        }
        return try await previewPlan(taskID: taskID, userEdit: workspace.task(taskID)?.userEditedDraft == true)
    }
    func previewCalendar(taskID: UUID, items: TravelJSON) async throws -> TravelJSON {
        guard let workspace, initializedScope == currentScope, let task = workspace.task(taskID), let draft = task.draft else { throw TravelResearchError.notFound }
        let scope = currentScope
        let body: TravelJSON = .object(["sourceKind": .string("draft"), "sourceId": .string(draft.id), "sourceVersion": .number(Double(draft.version)),
                                       "contextRevision": .number(Double(task.contextRevision)), "plan": try .from(draft.plan), "calendarRef": .string("primary"), "changes": items,
                                       "idempotencyKey": .string("calendar-preview-" + UUID().uuidString)])
        let proposal = try await gateway.call("calendar/preview", method: "POST", body: body)
        guard scope == currentScope, workspace.task(taskID)?.draft?.version == draft.version, workspace.task(taskID)?.contextRevision == task.contextRevision else { throw TravelResearchError.scopeChanged }
        try workspace.update(taskID) { $0.proposals[proposal["id"].string] = proposal }; return proposal
    }
    /// Called only by the native preview's explicit confirmation button. Never registered with the model.
    func confirm(taskID: UUID, displayed: TravelJSON) async throws -> TravelJSON {
        guard let workspace, initializedScope == currentScope, let task = workspace.task(taskID),
              let stored = task.proposals[displayed["id"].string], stored == displayed,
              displayed["contextRevision"].int == task.contextRevision,
              displayed["draftVersion"].int == task.draft?.version else { throw TravelResearchError.versionConflict }
        if !currentScope.isAccount { return try workspace.confirmDevicePlan(taskID: taskID, proposal: displayed) }
        let scope = currentScope
        let id = displayed["id"].string
        let body: TravelJSON = .object(["proposalId": .string(id), "digest": displayed["digest"], "contextRevision": .number(Double(task.contextRevision)), "idempotencyKey": .string("confirm-" + id)])
        // Persist the intent before crossing the network. Unknown outcomes remain queryable under the original account.
        try workspace.update(taskID) { $0.operations[id] = .object(["proposalId": .string(id), "state": .string("uncertain"), "kind": displayed["kind"], "draftVersion": displayed["draftVersion"], "digest": displayed["digest"]]) }
        let operation: TravelJSON
        do { operation = try await gateway.call(displayed["kind"].string == "calendar" ? "calendar/confirm" : "proposals/confirm", method: "POST", body: body) }
        catch {
            // Keep the uncertain intent for read-only receipt lookup. Reconnection
            // cannot make a failed preview actionable without a fresh comparison.
            try? workspace.update(taskID) { $0.proposals.removeValue(forKey: id) }
            throw error
        }
        // An already-observed server receipt stays under its original workspace, even if the visible account changed.
        try workspace.update(taskID) { task in
            task.operations[id] = operation
            if !operation["id"].string.isEmpty { task.operations[operation["id"].string] = operation }
            if operation["state"].string == "succeeded", !operation["plan"]["id"].string.isEmpty, task.draft?.plan.stablePlanId == operation["plan"]["stablePlanId"].string {
                task.draft?.baseItinerary = .object(["id": operation["plan"]["id"], "version": operation["plan"]["version"]])
                if task.draft?.version == displayed["draftVersion"].int { task.userEditedDraft = false }
            }
        }
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }
        return operation
    }
    func reconcile(taskID: UUID, operationID: String) async throws -> TravelJSON {
        guard let workspace, initializedScope == currentScope, workspace.task(taskID)?.operations[operationID] != nil else { throw TravelResearchError.notFound }
        let scope = currentScope
        let result = try await gateway.call("operations/" + operationID + "/reconcile", method: "POST", body: .object([:]))
        try recordRecoveredOperation(result, taskID: taskID, workspace: workspace)
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }; return result
    }
    func refreshFormalPlans() async throws {
        try await openWorkspace()
        guard let workspace, currentScope.isAccount else { return }
        let scope = currentScope
        let result = try await gateway.call("plans")
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }
        try workspace.cacheAccountPlans(result["plans"].array)
    }
    private func recordRecoveredOperation(_ operation: TravelJSON, taskID: UUID, workspace: TravelResearchWorkspace) throws {
        try workspace.update(taskID) { task in
            let proposalID = operation["proposalId"].string
            task.operations[proposalID] = operation
            if !operation["id"].string.isEmpty { task.operations[operation["id"].string] = operation }
            if operation["state"].string == "succeeded", task.draft?.plan.stablePlanId == operation["plan"]["stablePlanId"].string {
                task.draft?.baseItinerary = .object(["id": operation["plan"]["id"], "version": operation["plan"]["version"]])
            }
        }
    }
    func resolveProposalReceipt(taskID: UUID, proposalID: String) async throws -> TravelJSON {
        guard let workspace, workspace.scope == currentScope, workspace.task(taskID)?.operations[proposalID] != nil else { throw TravelResearchError.notFound }
        let scope = currentScope
        var operation = try await gateway.call("proposals/" + proposalID + "/operation")
        if ["uncertain", "executing"].contains(operation["state"].string), !operation["items"].array.isEmpty {
            operation = try await gateway.call("operations/" + operation["id"].string + "/reconcile", method: "POST", body: .object([:]))
        }
        try recordRecoveredOperation(operation, taskID: taskID, workspace: workspace)
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }; return operation
    }
    func resolveDetachedProposalReceipt(_ proposalID: String) async throws -> TravelJSON {
        guard let workspace, workspace.scope == currentScope, workspace.detachedOperationEntries.contains(where: { $0["proposalId"].string == proposalID }) else { throw TravelResearchError.notFound }
        let scope = currentScope
        var operation = try await gateway.call("proposals/" + proposalID + "/operation")
        if ["uncertain", "executing"].contains(operation["state"].string), !operation["items"].array.isEmpty {
            operation = try await gateway.call("operations/" + operation["id"].string + "/reconcile", method: "POST", body: .object([:]))
        }
        try workspace.saveDetachedOperation(operation, proposalID: proposalID)
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }; return operation
    }
    func recoverableOperations() async throws -> [TravelJSON] {
        guard currentScope.isAccount, workspace?.scope == currentScope else { return [] }
        var operations = try await gateway.call("operations")["operations"].array
        for local in workspace?.detachedOperationEntries ?? [] where local["state"].string == "uncertain" && local["id"].string.isEmpty {
            if !operations.contains(where: { $0["proposalId"] == local["proposalId"] }) { operations.append(local) }
        }
        return operations
    }
    func reconcileServerOperation(_ operationID: String) async throws -> TravelJSON {
        guard let workspace, workspace.scope == currentScope, currentScope.isAccount else { throw TravelResearchError.scopeChanged }
        let scope = currentScope
        let result = try await gateway.call("operations/" + operationID + "/reconcile", method: "POST", body: .object([:]))
        try workspace.saveDetachedOperation(result, proposalID: result["proposalId"].string)
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }; return result
    }
    func calendarBindings() async throws -> [TravelJSON] {
        guard currentScope.isAccount, workspace?.scope == currentScope else { return [] }
        return try await gateway.call("calendar/bindings")["bindings"].array
    }
    func previewCalendarRemoval(_ binding: TravelJSON) async throws -> TravelJSON {
        guard let workspace, workspace.scope == currentScope, currentScope.isAccount else { throw TravelResearchError.scopeChanged }
        let scope = currentScope
        let proposal = try await gateway.call("calendar/bindings/preview-delete", method: "POST", body: .object([
            "binding": binding, "idempotencyKey": .string("remove-preview-" + UUID().uuidString)
        ]))
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }
        try workspace.saveDetachedProposal(proposal); return proposal
    }
    func confirmCalendarRemoval(_ displayed: TravelJSON, scopeRef: String) async throws -> TravelJSON {
        guard currentScope.reference == scopeRef, let workspace, workspace.scope == currentScope,
              workspace.detachedProposal(displayed["id"].string) == displayed,
              displayed["calendar"]["sourceKind"].string == "binding" else { throw TravelResearchError.scopeChanged }
        let scope = currentScope; let id = displayed["id"].string
        try workspace.saveDetachedOperation(.object(["state": .string("uncertain"), "proposalId": .string(id)]), proposalID: id)
        let operation = try await gateway.call("calendar/confirm", method: "POST", body: .object([
            "proposalId": .string(id), "digest": displayed["digest"], "contextRevision": displayed["contextRevision"], "idempotencyKey": .string("confirm-" + id)
        ]))
        try workspace.saveDetachedOperation(operation, proposalID: id)
        guard scope == currentScope else { throw TravelResearchError.scopeChanged }; return operation
    }
    func connectGoogleWrite() async throws {
        let scope = currentScope
        let result = try await gateway.call("google/start", method: "POST", body: .object(["calendarWrite": .bool(true)]))
        guard scope == currentScope, let url = URL(string: result["authorization_url"].string), url.scheme == "https", url.host == "accounts.google.com", url.user == nil, url.password == nil else { throw TravelResearchError.unavailable }
        try await GoogleAccountAuthorization().authorize(url)
    }
    static func displayURL(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return "" }; c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        // Signed share paths are not exported to calendars, labels or logs.
        if c.host == "muse.ai" && c.path.hasPrefix("/s/") { c.path = "/s/" }
        return c.string ?? ""
    }
    private func searchPlaces(_ args: TravelJSON, task: TravelResearchTask) async throws -> TravelJSON {
        let query = args["query"].string
        guard !query.isEmpty, query.count <= 300 else { throw TravelResearchError.invalidArguments }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query; request.resultTypes = .pointOfInterest
        // Only explicitly requested near-context bias uses the frozen map center. A destination query is unbounded.
        let authorized = args["areaRef"].string == "authorized_city"
        guard args["areaRef"].isNull || ["authorized_city", "selected_area"].contains(args["areaRef"].string) else { throw TravelResearchError.notFound }
        let longitude = authorized ? task.context.authorizedAreaLongitude : task.context.areaLongitude
        let latitude = authorized ? task.context.authorizedAreaLatitude : task.context.areaLatitude
        if authorized && (longitude == nil || latitude == nil) { throw TravelResearchError.notFound }
        if args["bias"].string == "near_context" || !args["areaRef"].isNull, let lng = longitude, let lat = latitude {
            let space = MapKitCoordinateSpace.shared
            try await space.prepare(near: CLLocationCoordinate2D(latitude: lat, longitude: lng))
            if let center = space.searchCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                request.region = MKCoordinateRegion(center: center, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
            }
        }
        let response = try await MKLocalSearch(request: request).start()
        try Task.checkCancellation()
        var places: [TravelPlace] = []
        for item in response.mapItems.prefix(min(10, max(1, args["limit"].isNull ? 5 : args["limit"].int))) {
            let space = MapKitCoordinateSpace.shared
            try await space.prepare(near: item.placemark.coordinate, countryCode: item.placemark.isoCountryCode)
            guard let coordinate = space.canonicalSearchCoordinate(item.placemark.coordinate, countryCode: item.placemark.isoCountryCode), let name = item.name else { continue }
            let timezone = (item.timeZone?.identifier).flatMap { TimeZone.knownTimeZoneIdentifiers.contains($0) ? $0 : nil }
            places.append(.init(ref: "apple_maps:" + TravelIdentity.hash(name + String(coordinate.longitude) + "," + String(coordinate.latitude)), name: name, coordinates: [coordinate.longitude, coordinate.latitude], timezone: timezone))
        }
        return .result(.object(["places": .array(try places.map { try .from($0) }), "provider": .string("apple_maps"), "interpretation": .string("Candidates require disambiguation; no safety, hours or availability assessment.")]), status: places.isEmpty ? "empty" : "ok")
    }
    private func estimateRoute(_ args: TravelJSON, task: TravelResearchTask) async throws -> TravelJSON {
        guard ["walk", "drive"].contains(args["mode"].string) else { return .problem("capability_unsupported", status: "blocked") }
        let stops = args["stops"].array
        guard (2...10).contains(stops.count), stops.allSatisfy({ task.places[$0["placeRef"].string] != nil }) else { throw TravelResearchError.notFound }
        var segments: [TravelJSON] = []
        for index in 1..<stops.count {
            try Task.checkCancellation()
            let a = task.places[stops[index-1]["placeRef"].string]!, b = task.places[stops[index]["placeRef"].string]!
            let space = MapKitCoordinateSpace.shared
            let ac = CLLocationCoordinate2D(latitude: a.coordinates[1], longitude: a.coordinates[0]), bc = CLLocationCoordinate2D(latitude: b.coordinates[1], longitude: b.coordinates[0])
            try await space.prepare(near: ac); try await space.prepare(near: bc)
            guard let from = space.searchCoordinate(ac), let to = space.searchCoordinate(bc) else { continue }
            let request = MKDirections.Request(); request.source = MKMapItem(placemark: MKPlacemark(coordinate: from)); request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = args["mode"].string == "walk" ? .walking : .automobile
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first { segments.append(.object(["from": stops[index-1]["stopRef"], "to": stops[index]["stopRef"], "meters": .number(route.distance), "seconds": .number(route.expectedTravelTime), "freshness": .string("estimated"), "observedAt": .string(Date().ISO8601Format())])) }
        }
        return .result(.object(["segments": .array(segments), "provider": .string("apple_maps"), "freshness": .string("estimated")]), status: "partial", missing: ["date_specific_availability", "booking_reachability"])
    }
}
