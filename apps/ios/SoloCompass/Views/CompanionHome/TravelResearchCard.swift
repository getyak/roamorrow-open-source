import SwiftUI

@MainActor struct TravelResearchCard: View {
    let reference: TravelResearchReference
    @State private var selected: TravelResearchReference?
    private let service = TravelResearchService.shared
    var body: some View {
        Group {
            if let task = service.visibleTask(reference) {
                Button { selected = reference } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(task.draft?.plan.title ?? travelText("travel.research", "旅行研究"), systemImage: "map")
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(task.state == "completed" ? travelText("travel.ready", "查看资料与行程草稿") : (task.state == "running" ? travelText("travel.running", "正在读取资料与整理草稿") : travelText("travel.paused", "研究已暂停 · 已保存的内容仍可查看")))
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Label(travelText("travel.open", "打开并修改"), systemImage: "chevron.right").font(.subheadline)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("travel.card.\(reference.taskID)")
            } else if reference.scopeRef == service.currentScope.reference {
                if service.workspace == nil {
                    Text(travelText("travel.restoring", "正在恢复研究。暂不可用时可稍后重试。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(travelText("travel.retryRestore", "重新读取已保存研究")) { Task { await service.refreshIdentity() } }.frame(minHeight: 44)
                } else { Text(travelText("travel.deleted", "这份研究已删除。")) .font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text(travelText("travel.scopeUnavailable", "登录此研究所属账号后可查看资料。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selected) { ref in TravelResearchDetail(reference: ref, service: service) }
    }
}
extension TravelResearchReference: Identifiable { var id: UUID { taskID } }
func travelText(_ key: String, _ fallback: String) -> String { NSLocalizedString(key, value: fallback, comment: "Travel research") }

func travelTimeLabel(_ time: TravelJSON) -> String {
    let zone = time["timezone"].string
    if time["kind"].string == "window" { return time["startLocal"].string + " – " + time["endLocal"].string + " · " + zone }
    if time["kind"].string == "fixed", let instant = TravelIdentity.instant(time["instant"].string), let tz = TimeZone(identifier: zone) {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.timeZone = tz
        return f.string(from: instant) + " · " + zone
    }
    return travelText("travel.timeUnknown", "时间待定")
}

func travelStatusLabel(_ value: String) -> String {
    let labels = ["ok": "已读取", "empty": "未找到结果", "complete": "读取完整", "partial": "部分可用", "metadata_only": "仅有元信息", "unknown": "尚未核实", "blocked": "读取受限", "unavailable": "暂不可用", "supported": "有来源依据", "imported": "原文提及，尚未核实", "disputed": "来源有冲突", "uncertain": "结果待核对", "executing": "正在执行", "pending": "等待处理", "failed": "未完成", "succeeded": "已完成", "cancelled": "已取消", "verified": "已读回核验", "mismatch": "内容不一致", "system_reported_saved": "系统报告已保存", "read": "已读取"]
    guard let fallback = labels[value] else { return travelText("travel.status.unknown", "尚未核实") }
    return travelText("travel.status." + value, fallback)
}

func travelFieldLabel(_ raw: String) -> String {
    let field = raw.lowercased()
    for (needle, key, fallback) in [("hour", "hours", "营业时间"), ("address", "address", "地址"), ("booking", "booking", "预约"), ("price", "price", "价格"), ("accessibility", "accessibility", "无障碍设施"), ("route", "route", "交通"), ("safety", "safety", "安全信息"), ("date", "dates", "日期"), ("identity", "identity", "地点信息")] where field.contains(needle) {
        return travelText("travel.field." + key, fallback)
    }
    return travelText("travel.field.note", "资料说明")
}
