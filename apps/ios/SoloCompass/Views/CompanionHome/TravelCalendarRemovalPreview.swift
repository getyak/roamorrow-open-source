import SwiftUI

@MainActor struct TravelCalendarRemovalPreview: View {
    let proposal: TravelJSON
    let scopeRef: String
    let service: TravelResearchService
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var receipt: TravelJSON?
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            List {
                if service.currentScope.reference == scopeRef {
                    Text(travelText("travel.calendarRemovalWarning", "确认后只删除下面这项外部日历活动，不会删除其他资料。请核对它是否被手动修改过。"))
                    ForEach(Array(proposal["calendar"]["items"].array.enumerated()), id: \.offset) { _, item in
                        let event = item["before"]
                        Section {
                            Text(event["title"].string).font(.headline)
                            Text(travelTimeLabel(.object(["kind": .string("fixed"), "instant": event["start"], "timezone": event["timezone"]])))
                            Text(travelTimeLabel(.object(["kind": .string("fixed"), "instant": event["end"], "timezone": event["timezone"]])))
                            if !event["location"].string.isEmpty { Text(event["location"].string) }
                            Text(travelText("travel.after", "修改后") + ": " + travelText("travel.none", "无"))
                        }
                    }
                    if let receipt { Text(travelStatusLabel(receipt["state"].string)) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    Button(role: .destructive) {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { receipt = try await service.confirmCalendarRemoval(proposal, scopeRef: scopeRef) }
                            catch { notice = travelText("travel.confirmFailed", "尚未确认结果。请保留此预览并核对原操作；不要另外创建同样活动。") }
                        }
                    } label: { Text(travelText("travel.calendarRemoveConfirm", "确认移除这项日历活动")).frame(minHeight: 44) }.disabled(busy || receipt != nil)
                    Button(travelText("travel.cancel", "取消")) { dismiss() }.frame(minHeight: 44).disabled(busy)
                }
            }
            .onChange(of: service.currentScope) { _, _ in receipt = nil; dismiss() }
            .navigationTitle(travelText("travel.preview", "变更预览")).navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled(busy)
    }
}
