import SwiftUI
import MapKit

@MainActor struct TravelResearchDetail: View {
    let reference: TravelResearchReference
    let service: TravelResearchService
    @Environment(\.dismiss) private var dismiss
    @State private var preview: TravelPreviewPresentation?
    @State private var editing: TravelStopPresentation?
    @State private var dateEditor: TravelDatePresentation?
    @State private var busy = false
    @State private var notice: String?
    @State private var deletion = false
    private var task: TravelResearchTask? { service.visibleTask(reference) }
    var body: some View {
        NavigationStack {
            List {
                if let task {
                    Section {
                        if task.state != "completed" && task.state != "running" {
                            Label(travelText("travel.paused", "研究已暂停 · 已保存的内容仍可查看"), systemImage: "pause.circle")
                                .foregroundStyle(.secondary)
                        }
                        if !task.answer.isEmpty { Text(task.answer).textSelection(.enabled) }
                        if task.answer.isEmpty && task.sources.isEmpty {
                            Text(travelText("travel.noBody", "还没有读到可用正文。可以重试，或在聊天中补充内容。"))
                        }
                    }
                    sources(task)
                    research(task)
                    if let draft = task.draft {
                        Section {
                            Text(draft.plan.title).font(.title3.weight(.medium))
                            Text(draft.plan.dateScope.kind == "undated" ? travelText("travel.undated", "日期未定") : "\(draft.plan.dateScope.startDate ?? "") – \(draft.plan.dateScope.endDate ?? "") · \(draft.plan.dateScope.timezone ?? "")")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button { dateEditor = .init(taskID: task.id, scopeRef: reference.scopeRef, draftVersion: draft.version, timezone: draft.plan.dateScope.timezone ?? draft.plan.allStops.compactMap { $0.place?.timezone ?? $0.time.timezone }.first ?? TimeZone.current.identifier) } label: {
                                Label(travelText("travel.setDates", "设置日期与时区"), systemImage: "calendar").frame(minHeight: 44)
                            }.accessibilityIdentifier("travel.dates")
                            TravelDraftMap(plan: draft.plan)
                        } header: { Text(travelText("travel.draft", "行程草稿")) }
                        ForEach(draft.plan.days) { day in
                            Section {
                                ForEach(day.stops) { stop in
                                    Button { editing = .init(taskID: task.id, scopeRef: reference.scopeRef, draftVersion: draft.version, stop: stop, dayDate: day.date, timezone: stop.place?.timezone ?? stop.time.timezone ?? draft.plan.dateScope.timezone ?? TimeZone.current.identifier) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(stop.title).font(.body.weight(.medium))
                                                if !stop.lockedFields.isEmpty { Image(systemName: "lock.fill").accessibilityLabel(travelText("travel.locked", "已锁定")) }
                                            }
                                            Text(stop.time.kind == "fixed" ? "\(stop.time.instant ?? "") · \(stop.time.timezone ?? "")" : travelText("travel.timeUnknown", "时间待定"))
                                                .font(.subheadline).foregroundStyle(.secondary)
                                            if stop.place == nil { Text(travelText("travel.unlocated", "待定位 · 相邻交通尚未核实")).font(.footnote).foregroundStyle(.secondary) }
                                            Label(travelText("travel.editStop", "修改或锁定"), systemImage: "pencil").font(.footnote)
                                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityIdentifier("travel.stop.\(stop.id)")
                                }
                            } header: { Text(day.label + (day.date.map { " · " + $0 } ?? "")) }
                        }
                        Section {
                            ForEach(Array(draft.plan.assumptions.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote).foregroundStyle(.secondary) }
                            Button { perform { preview = .init(value: try await service.previewUserPlan(taskID: task.id)) } } label: {
                                Label(travelText("travel.adopt", "预览保存为正式行程"), systemImage: "checkmark.rectangle").frame(minHeight: 44)
                            }.disabled(busy).accessibilityIdentifier("travel.previewPlan")
                            if draft.baseItinerary != nil {
                                Button { perform { preview = .init(value: try await service.previewUserPlan(taskID: task.id, refreshBase: true)) } } label: {
                                    Label(travelText("travel.refreshPreview", "读取最新行程并重新预览差异"), systemImage: "arrow.clockwise").frame(minHeight: 44)
                                }.disabled(busy)
                            }
                            let fixed = draft.plan.allStops.filter { $0.time.kind == "fixed" && $0.durationMinutes != nil }
                            if !fixed.isEmpty {
                                ForEach(fixed) { stop in
                                    NavigationLink {
                                        TravelAppleCalendarPreview(reference: reference, stop: stop, draftVersion: draft.version, service: service)
                                    } label: { Label(travelText("travel.apple", "在系统日历中编辑") + " · " + stop.title, systemImage: "calendar.badge.plus").frame(minHeight: 44) }
                                    .accessibilityIdentifier("travel.apple.preview." + stop.id)
                                }
                                Button {
                                    perform {
                                        let items = TravelJSON.array(fixed.prefix(10).map { .object(["stopId": .string($0.id), "action": .string("create")]) })
                                        preview = .init(value: try await service.previewCalendar(taskID: task.id, items: items))
                                    }
                                } label: { Label(travelText("travel.googlePreview", "预览加入 Google 主日历"), systemImage: "calendar").frame(minHeight: 44) }.disabled(busy)
                            } else { Text(travelText("travel.calendarNeedsTime", "为活动选择日期、时间和时长后，可预览加入日历。")) .font(.footnote).foregroundStyle(.secondary) }
                            Button { perform { try await service.connectGoogleWrite(); notice = travelText("travel.connected", "已连接，可重新生成日历预览。") } } label: {
                                Text(travelText("travel.googleConnect", "连接 Google 日历写入权限")).frame(minHeight: 44)
                            }.disabled(busy)
                        } header: { Text(travelText("travel.next", "采用与日历")) }
                    }
                    if !task.operations.isEmpty {
                        Section {
                            ForEach(task.operations.keys.sorted().filter { key in
                                let op = task.operations[key] ?? .null
                                return op["id"].string.isEmpty || op["id"].string == key || task.operations[op["id"].string] == nil
                            }, id: \.self) { id in
                                let op = task.operations[id]!
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(travelText("travel.operation", "操作状态") + ": " + travelStatusLabel(op["state"].string))
                                    Text(travelText("travel.readback", "读回状态") + ": " + travelStatusLabel(op["readbackStatus"].string)).font(.footnote).foregroundStyle(.secondary)
                                    if op["state"].string == "uncertain", op["id"].string.isEmpty, !op["proposalId"].string.isEmpty {
                                        Button(travelText("travel.reconcile", "核对原操作结果")) { perform { _ = try await service.resolveProposalReceipt(taskID: task.id, proposalID: op["proposalId"].string) } }.frame(minHeight: 44).disabled(busy)
                                    }
                                    if op["state"].string == "uncertain", !op["id"].string.isEmpty {
                                        Button(travelText("travel.reconcile", "核对原操作结果")) { perform { _ = try await service.reconcile(taskID: task.id, operationID: op["id"].string) } }.frame(minHeight: 44).disabled(busy)
                                    }
                                }
                            }
                        } header: { Text(travelText("travel.receipts", "操作回执")) }
                    }
                    Section {
                        Button {
                            NotificationCenter.default.post(name: TravelResearchService.continueInChat, object: reference)
                            dismiss()
                        } label: { Label(travelText("travel.continueChat", "继续这份研究／补充材料"), systemImage: "bubble.left").frame(minHeight: 44) }
                        Text(travelText("travel.resumeHint", "在聊天中补充要求可继续这份研究。研究仅在前台运行；已保存的资料不会因暂停丢失。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(role: .destructive) { deletion = true } label: { Text(travelText("travel.delete", "删除这份研究与草稿")).frame(minHeight: 44) }
                    }
                } else { Text(travelText("travel.scopeUnavailable", "登录此研究所属账号后可查看资料。")) }
                if busy { ProgressView().accessibilityLabel(travelText("travel.working", "正在处理")) }
                if let notice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("travel.notice") }
            }
            .onChange(of: service.currentScope) { _, _ in preview = nil; editing = nil; dateEditor = nil; dismiss() }
            .navigationTitle(travelText("travel.research", "旅行研究")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(travelText("travel.done", "完成")) { dismiss() }.frame(minHeight: 44) } }
            .sheet(item: $preview) { selected in TravelChangePreview(reference: reference, proposal: selected.value, service: service) }
            .sheet(item: $editing) { selected in TravelStopEditor(selection: selected, service: service) }
            .sheet(item: $dateEditor) { selected in TravelDateEditor(selection: selected, service: service) }
            .confirmationDialog(travelText("travel.deleteConfirm", "删除资料与草稿？已加入的外部日历活动会保留。"), isPresented: $deletion, titleVisibility: .visible) {
                Button(travelText("travel.delete", "删除这份研究与草稿"), role: .destructive) {
                    do { try service.workspace?.forget(reference.taskID); dismiss() }
                    catch { notice = travelText("travel.saveFailed", "未能保存修改，内容仍保留。请重试。") }
                }
            }
        }
    }
    @ViewBuilder private func sources(_ task: TravelResearchTask) -> some View {
        Section {
            ForEach(task.sources.keys.sorted(), id: \.self) { id in
                let source = task.sources[id]!, doc = source["data"]
                DisclosureGroup {
                    Text(travelStatusLabel(source["coverage"]["kind"].string) + " · " + travelStatusLabel(doc["accessStatus"].string)).font(.footnote).foregroundStyle(.secondary)
                    if let observed = TravelIdentity.instant(source["observedAt"].string) {
                        LabeledContent(travelText("travel.sourceObserved", "读取时间")) { Text(observed, format: .dateTime.year().month().day().hour().minute()) }.font(.footnote)
                    }
                    if doc["contentBlocks"].array.isEmpty { Text(travelText("travel.blocked", "尚未读到正文，不能据此安排活动。")) }
                    ForEach(Array(doc["contentBlocks"].array.prefix(12).enumerated()), id: \.offset) { _, block in Text(block["text"].string).font(.subheadline).textSelection(.enabled) }
                    if let url = URL(string: doc["displayURL"].string), ["https", "http"].contains(url.scheme) { Link(travelText("travel.sourceOpen", "打开来源网站"), destination: url).frame(minHeight: 44) }
                } label: { Text(doc["title"].string.isEmpty ? travelText("travel.source", "来源资料") : doc["title"].string).frame(minHeight: 44) }
            }
        } header: { Text(travelText("travel.sources", "资料与读取范围")) }
    }
    @ViewBuilder private func research(_ task: TravelResearchTask) -> some View {
        if !task.research["candidates"].array.isEmpty {
            Section {
                ForEach(Array(task.research["candidates"].array.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item["title"].string).font(.headline)
                        Text(item["reason"].string).font(.subheadline).foregroundStyle(.secondary)
                        let subject = item["placeRef"].string.isEmpty ? item["clientRef"].string : item["placeRef"].string
                        ForEach(["hours", "booking"], id: \.self) { field in
                            let state = task.research["availability"][subject][field].string
                            Text(travelFieldLabel(field) + " · " + travelStatusLabel(state.isEmpty ? "unknown" : state)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text(travelText("travel.recommendations", "候选建议")) }
        }
        if !task.research["claims"].array.isEmpty {
            Section {
                ForEach(Array(task.research["claims"].array.enumerated()), id: \.offset) { _, claim in
                    VStack(alignment: .leading, spacing: 5) {
                        // Older retained cards may predate save-time normalization.
                        let unknown = task.sources[claim["subjectRef"].string] == nil && TravelResearchWorkspace.isUnknownAvailability(claim)
                        Text(travelFieldLabel(claim["fieldPath"].string) + " · " + travelStatusLabel(unknown ? "unknown" : claim["status"].string)).font(.subheadline.weight(.medium))
                        Text(claim["value"].string.isEmpty ? ((try? claim["value"].encoded()) ?? "") : claim["value"].string).font(.footnote).textSelection(.enabled)
                    }
                }
            } header: { Text(travelText("travel.evidence", "事实与待核实信息")) }
        }
        if !task.research["openQuestions"].array.isEmpty {
            Section {
                ForEach(Array(task.research["openQuestions"].array.enumerated()), id: \.offset) { _, q in Text(q["text"].string) }
            } header: { Text(travelText("travel.questions", "待补充信息")) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { notice = travelText("travel.actionFailed", "这次操作未完成。资料仍保留；如权限或版本已变化，请重新连接或生成预览。") }
        }
    }
}
struct TravelPreviewPresentation: Identifiable { let id = UUID(); var value: TravelJSON; var scopeRef: String? = nil }
struct TravelStopPresentation: Identifiable { let id = UUID(); var taskID: UUID; var scopeRef: String; var draftVersion: Int; var stop: TravelStop; var dayDate: String?; var timezone: String }
struct TravelDatePresentation: Identifiable { let id = UUID(); var taskID: UUID; var scopeRef: String; var draftVersion: Int; var timezone: String }

@MainActor private struct TravelDraftMap: View {
    let plan: TravelPlanInput
    private var pins: [(String, String, CLLocationCoordinate2D)] {
        plan.allStops.compactMap { stop in
            guard let place = stop.place, place.coordinates.count == 2,
                  let coordinate = MapKitCoordinateSpace.shared.mapCoordinate(.init(latitude: place.coordinates[1], longitude: place.coordinates[0])) else { return nil }
            return (stop.id, stop.title, coordinate)
        }
    }
    var body: some View {
        Group {
        if !pins.isEmpty {
            Map { ForEach(pins, id: \.0) { pin in Marker(pin.1, coordinate: pin.2) } }
                .mapStyle(.standard).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(travelText("travel.map", "草稿地点地图；所有地点均可在下方列表操作。"))
        }
        }
                .task(id: TravelIdentity.hash((try? TravelJSON.from(plan).encoded()) ?? "")) {
                    for stop in plan.allStops { if let p = stop.place, p.coordinates.count == 2 { try? await MapKitCoordinateSpace.shared.prepare(near: .init(latitude: p.coordinates[1], longitude: p.coordinates[0])) } }
                }
    }
}
