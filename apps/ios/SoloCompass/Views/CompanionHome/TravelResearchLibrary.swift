import SwiftUI

@MainActor struct TravelResearchLibrary: View {
    private let service = TravelResearchService.shared
    @State private var notice: String?
    @State private var bindings: [TravelJSON] = []
    @State private var recoverable: [TravelJSON] = []
    @State private var removalPreview: TravelPreviewPresentation?
    @State private var busy = false
    private var authorized: Bool { service.workspace?.scope == service.currentScope }
    var body: some View {
        List {
            if authorized, let workspace = service.workspace {
                Section {
                    ForEach(workspace.tasks) { task in
                        NavigationLink { TravelResearchDetail(reference: .init(taskID: task.id, scopeRef: task.scopeRef), service: service) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.draft?.plan.title ?? travelText("travel.research", "旅行研究"))
                                Text(task.state == "completed" ? travelText("travel.ready", "查看资料与行程草稿") : travelText("travel.paused", "研究已暂停 · 已保存的内容仍可查看")).font(.footnote).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                    }
                    if workspace.tasks.isEmpty { Text(travelText("travel.empty", "把旅行链接发到聊天，即可开始研究并保留草稿。")) }
                } header: { Text(travelText("travel.research", "旅行研究")) }
                Section {
                    ForEach(workspace.devicePlans) { plan in
                        formalRow(plan: (try? .from(plan.plan)) ?? .null, id: plan.id, scopeRef: workspace.scope.reference, tasks: workspace.tasks)
                    }
                    ForEach(Array(workspace.cachedAccountPlans.enumerated()), id: \.offset) { _, plan in
                        formalRow(plan: plan, id: plan["id"].string, scopeRef: workspace.scope.reference, tasks: workspace.tasks)
                    }
                } header: { Text(travelText("travel.formalPlans", "已采用的研究行程")) }
            } else { Text(travelText("travel.scopeUnavailable", "登录此研究所属账号后可查看资料。")) }
            if authorized, !bindings.isEmpty {
                Section {
                    ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                        Button {
                            guard !busy else { return }; busy = true
                            let scope = service.currentScope
                            Task {
                                defer { busy = false }
                                do { removalPreview = .init(value: try await service.previewCalendarRemoval(binding), scopeRef: scope.reference) }
                                catch { notice = travelText("travel.actionFailed", "这次操作未完成。资料仍保留；如权限或版本已变化，请重新连接或生成预览。") }
                            }
                        } label: { Label(travelText("travel.calendarBinding", "预览移除关联的日历活动") + " · " + String(binding["stopId"].string.prefix(12)), systemImage: "calendar.badge.minus").frame(minHeight: 44) }.disabled(busy)
                    }
                } header: { Text(travelText("travel.calendarBindings", "日历关联（含已删除的草稿）")) }
            }
            if authorized, !recoverable.isEmpty {
                Section {
                    ForEach(Array(recoverable.enumerated()), id: \.offset) { _, operation in
                        Button {
                            guard !busy else { return }; busy = true
                            Task {
                                defer { busy = false }
                                do { let result = try await (operation["id"].string.isEmpty ? service.resolveDetachedProposalReceipt(operation["proposalId"].string) : service.reconcileServerOperation(operation["id"].string)); notice = travelStatusLabel(result["state"].string); await refresh() }
                                catch { notice = travelText("travel.actionFailed", "这次操作未完成。资料仍保留；如权限或版本已变化，请重新连接或生成预览。") }
                            }
                        } label: { Label(travelText("travel.reconcile", "核对原操作结果") + " · " + travelStatusLabel(operation["state"].string), systemImage: "arrow.clockwise").frame(minHeight: 44) }.disabled(busy)
                    }
                } header: { Text(travelText("travel.pendingOperations", "待核对的账号操作")) }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .onChange(of: service.currentScope) { _, _ in bindings = []; recoverable = []; removalPreview = nil }
        .sheet(item: $removalPreview) { value in TravelCalendarRemovalPreview(proposal: value.value, scopeRef: value.scopeRef ?? "", service: service) }
        .navigationTitle(travelText("travel.library", "研究与草稿"))
        .task(id: service.currentScope.reference) { await refresh() }
        .refreshable { await refresh() }
    }
    @ViewBuilder private func formalRow(plan: TravelJSON, id: String, scopeRef: String, tasks: [TravelResearchTask]) -> some View {
        NavigationLink {
            List {
                if service.currentScope.reference == scopeRef, authorized {
                Text(plan["title"].string).font(.headline)
                Text(plan["dateScope"]["kind"].string == "undated" ? travelText("travel.undated", "日期未定") : plan["dateScope"]["startDate"].string + " – " + plan["dateScope"]["endDate"].string)
                ForEach(Array(plan["days"].array.enumerated()), id: \.offset) { _, day in
                    Section {
                        ForEach(Array(day["stops"].array.enumerated()), id: \.offset) { _, stop in Text(stop["title"].string).frame(minHeight: 44) }
                    } header: { Text(day["label"].string + " " + day["date"].string) }
                }
                if let task = tasks.first(where: { $0.draft?.baseItinerary?["id"].string == id }) {
                    NavigationLink(travelText("travel.editDraft", "修改对应草稿并预览更新")) {
                        TravelResearchDetail(reference: .init(taskID: task.id, scopeRef: task.scopeRef), service: service)
                    }.frame(minHeight: 44)
                }
                }
            }.navigationTitle(travelText("travel.formalPlan", "正式行程"))
        } label: { Text(plan["title"].string).frame(minHeight: 44) }
    }
    private func refresh() async {
        await service.refreshIdentity()
        do { try await service.refreshFormalPlans(); bindings = try await service.calendarBindings(); recoverable = try await service.recoverableOperations(); notice = nil }
        catch { notice = travelText("travel.offlinePlans", "未能刷新正式行程，显示本账号已保存的资料。草稿仍可修改；联网后请重新预览再采用。") }
    }
}
