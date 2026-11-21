import SwiftUI

@MainActor struct TravelDateEditor: View {
    let selection: TravelDatePresentation
    let service: TravelResearchService
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var timezone = ""
    @State private var previousZone = TimeZone.current.identifier
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if service.currentScope.reference == selection.scopeRef {
                DatePicker(travelText("travel.startDate", "第一天日期"), selection: $start, displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
                TextField(travelText("travel.timezone", "时区，例如 Asia/Tokyo"), text: $timezone).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(travelText("travel.dateWarning", "日期按行程天数依次安排。修改日期会清除未锁定活动的固定时间；已锁定活动需先解锁。")) .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .onChange(of: service.currentScope) { _, _ in dismiss() }
            .navigationTitle(travelText("travel.setDates", "设置日期与时区")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(travelText("travel.cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(travelText("travel.save", "保存")) {
                    do {
                        guard service.currentScope.reference == selection.scopeRef, let workspace = service.workspace, workspace.scope == service.currentScope else { throw TravelResearchError.scopeChanged }
                        try workspace.setDates(taskID: selection.taskID, start: start, timezone: timezone, expectedVersion: selection.draftVersion); dismiss()
                    }
                    catch { self.error = travelText("travel.invalidDate", "请核对时区，并先解锁已有活动。") }
                }.frame(minHeight: 44) }
            }
        }.onAppear {
            timezone = selection.timezone; previousZone = selection.timezone
            if let raw = service.workspace?.task(selection.taskID)?.draft?.plan.dateScope.startDate {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: timezone); f.dateFormat = "yyyy-MM-dd HH:mm"
                if let selected = f.date(from: raw + " 12:00") { start = selected }
            }
        }
            .onChange(of: timezone) { _, new in
                guard let oldZone = TimeZone(identifier: previousZone), let newZone = TimeZone(identifier: new) else { return }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = oldZone
                var components = calendar.dateComponents([.year, .month, .day], from: start); components.hour = 12
                calendar.timeZone = newZone
                if let date = calendar.date(from: components) { start = date; previousZone = new }
            }
    }
}

@MainActor struct TravelStopEditor: View {
    let selection: TravelStopPresentation
    let service: TravelResearchService
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var locked = false
    @State private var instant = Date()
    @State private var duration = 60
    @State private var setTime = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if service.currentScope.reference == selection.scopeRef {
                TextField(travelText("travel.stopTitle", "活动名称"), text: $title).accessibilityIdentifier("travel.stop.title")
                Toggle(travelText("travel.lock", "锁定活动，保留我的修改"), isOn: $locked).frame(minHeight: 44)
                if let day = selection.dayDate {
                    Toggle(travelText("travel.chooseTime", "选择固定时间与时长"), isOn: $setTime).frame(minHeight: 44)
                    if setTime {
                        Text(day + " · " + selection.timezone).font(.footnote)
                        DatePicker(travelText("travel.startTime", "开始时间"), selection: $instant, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: selection.timezone) ?? .gmt)
                        Stepper(value: $duration, in: 5...1440, step: 5) { Text(String(format: travelText("travel.duration", "时长 %d 分钟"), duration)) }.frame(minHeight: 44)
                    }
                } else { Text(travelText("travel.timeNeedsDates", "先为行程设置日期，再选择活动时间。")) .font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .onChange(of: service.currentScope) { _, _ in title = ""; dismiss() }
            .navigationTitle(travelText("travel.editStop", "修改或锁定")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(travelText("travel.cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(travelText("travel.save", "保存")) {
                    do {
                        guard service.currentScope.reference == selection.scopeRef, let workspace = service.workspace, workspace.scope == service.currentScope else { throw TravelResearchError.scopeChanged }
                        // Scheduling and title edits are one trusted user action; invalid schedules are checked before title mutation.
                        let schedule = setTime ? TravelStopTime(kind: "fixed", instant: instant.ISO8601Format(), timezone: selection.timezone) : nil
                        try workspace.editStop(taskID: selection.taskID, stopID: selection.stop.id, title: title, locked: locked || setTime, schedule: schedule, durationMinutes: setTime ? duration : nil, expectedVersion: selection.draftVersion)
                        dismiss()
                    } catch { self.error = travelText("travel.invalidStop", "请核对活动名称，开始时间须在该行程日内。修改尚未全部保存，请检查后重试。") }
                }.frame(minHeight: 44).accessibilityIdentifier("travel.stop.save") }
            }
        }.onAppear {
            title = selection.stop.title; locked = !selection.stop.lockedFields.isEmpty
            duration = selection.stop.durationMinutes ?? 60
            if let raw = selection.stop.time.instant, let date = TravelIdentity.instant(raw) { instant = date }
            else if let day = selection.dayDate {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: selection.timezone); f.dateFormat = "yyyy-MM-dd HH:mm"
                if let value = f.date(from: day + " 09:00") { instant = value }
            }
        }
    }
}

@MainActor struct TravelChangePreview: View {
    let reference: TravelResearchReference
    let proposal: TravelJSON
    let service: TravelResearchService
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var receipt: TravelJSON?
    @State private var error: String?
    private var valid: Bool {
        guard let task = service.visibleTask(reference) else { return false }
        return task.draft?.version == proposal["draftVersion"].int && task.contextRevision == proposal["contextRevision"].int && task.proposals[proposal["id"].string] == proposal
    }
    var body: some View {
        NavigationStack {
            List {
                if service.currentScope.reference == reference.scopeRef {
                Section {
                    Text(proposal["kind"].string == "calendar" ? travelText("travel.calendarConfirm", "确认后会修改 Google 主日历。请核对每项活动。") : travelText("travel.planConfirm", "确认后会保存为正式行程。请核对以下内容。"))
                    Text(travelText("travel.expires", "预览有效期至") + " " + proposal["expiresAt"].string).font(.footnote).foregroundStyle(.secondary)
                }
                if proposal["kind"].string == "calendar" {
                    ForEach(Array(proposal["calendar"]["items"].array.enumerated()), id: \.offset) { _, item in
                        Section {
                            Text(travelText("travel.before", "修改前")).font(.caption).foregroundStyle(.secondary)
                            calendarEvent(item["before"])
                            Text(travelText("travel.after", "修改后")).font(.caption).foregroundStyle(.secondary)
                            calendarEvent(item["after"])
                        }
                    }
                } else {
                    Section { plan(proposal["before"]) } header: { Text(travelText("travel.before", "修改前")) }
                    Section { plan(proposal["after"]) } header: { Text(travelText("travel.after", "修改后")) }
                }
                if !valid { Text(travelText("travel.stale", "草稿、账号或上下文已变化，请重新生成预览。")) }
                if let receipt {
                    Text(travelText("travel.operation", "操作状态") + ": " + travelStatusLabel(receipt["state"].string))
                    Text(travelText("travel.readback", "读回状态") + ": " + travelStatusLabel(receipt["readbackStatus"].string))
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if busy { ProgressView() }
                Section {
                    Button {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { receipt = try await service.confirm(taskID: reference.taskID, displayed: proposal) }
                            catch { self.error = travelText("travel.confirmFailed", "尚未确认结果。请保留此预览并核对原操作；不要另外创建同样活动。") }
                        }
                    } label: { Text(travelText("travel.confirm", "确认这些变更")).frame(minHeight: 44) }
                        .disabled(!valid || busy || receipt != nil).accessibilityIdentifier("travel.confirm")
                    Button(travelText("travel.reject", "保留草稿，暂不采用")) { dismiss() }.frame(minHeight: 44).disabled(busy).accessibilityIdentifier("travel.reject")
                }
            }
                }
            .onChange(of: service.currentScope) { _, _ in receipt = nil; dismiss() }
            .navigationTitle(travelText("travel.preview", "变更预览")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(travelText("travel.done", "完成")) { dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy)
    }
    @ViewBuilder private func calendarEvent(_ event: TravelJSON) -> some View {
        if event.isNull { Text(travelText("travel.none", "无")) }
        else {
            VStack(alignment: .leading, spacing: 6) {
                Text(event["title"].string).font(.headline)
                Text(event["start"].string + " – " + event["end"].string)
                Text(event["timezone"].string).font(.footnote)
                if !event["location"].string.isEmpty { Text(event["location"].string) }
                Text(travelText("travel.reminders", "提醒（提前分钟）") + ": " + (event["reminderMinutes"].array.isEmpty ? travelText("travel.none", "无") : event["reminderMinutes"].array.map { String($0.int) }.joined(separator: ", "))).font(.footnote)
            }.textSelection(.enabled)
        }
    }
    @ViewBuilder private func plan(_ value: TravelJSON) -> some View {
        if value.isNull { Text(travelText("travel.newPlan", "新行程")) }
        else {
            Text(value["title"].string).font(.headline)
            Text(value["dateScope"]["kind"].string == "undated" ? travelText("travel.undated", "日期未定") : value["dateScope"]["startDate"].string + " – " + value["dateScope"]["endDate"].string + " · " + value["dateScope"]["timezone"].string).font(.subheadline)
            ForEach(Array(value["days"].array.enumerated()), id: \.offset) { _, day in
                Text(day["label"].string + " " + day["date"].string).font(.subheadline.weight(.medium))
                ForEach(Array(day["stops"].array.enumerated()), id: \.offset) { _, stop in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stop["title"].string)
                        if !stop["lockedFields"].array.isEmpty { Label(travelText("travel.locked", "已锁定"), systemImage: "lock.fill").font(.footnote) }
                        Text(travelTimeLabel(stop["time"])).font(.footnote).foregroundStyle(.secondary)
                        if !stop["place"].isNull { Text(stop["place"]["name"].string).font(.footnote) }
                        if !stop["durationMinutes"].isNull { Text(String(format: travelText("travel.duration", "时长 %d 分钟"), stop["durationMinutes"].int)).font(.footnote) }
                    }
                }
            }
            ForEach(Array(value["assumptions"].array.enumerated()), id: \.offset) { _, assumption in Text(assumption.string).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
