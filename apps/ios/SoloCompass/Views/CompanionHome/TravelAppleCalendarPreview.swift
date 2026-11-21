import SwiftUI
import EventKit
import EventKitUI

/// EventKitUI owns permission and final editing. A saved callback is not a verified readback.
@MainActor struct TravelAppleCalendarPreview: View {
    let reference: TravelResearchReference
    let stop: TravelStop
    let draftVersion: Int
    let service: TravelResearchService
    @State private var editor: TravelAppleEditorSelection?
    @State private var outcome: String?
    @State private var confirmDuplicate = false
    private var valid: Bool { service.visibleTask(reference)?.draft?.version == draftVersion }
    var body: some View {
        List {
            if service.currentScope.reference == reference.scopeRef {
            Text(stop.title).font(.headline)
            Text((stop.time.instant ?? "") + " · " + (stop.time.timezone ?? ""))
            if let minutes = stop.durationMinutes { Text(String(format: travelText("travel.duration", "时长 %d 分钟"), minutes)) }
            if let place = stop.place { Text(place.name) }
            Text(travelText("travel.appleExplanation", "系统编辑器会让你选择日历并最终保存。你可以在系统中修改内容；本 App 无法读回核验，不会自动更新该活动。"))
                .font(.subheadline).foregroundStyle(.secondary)
            Button(travelText("travel.appleOpen", "打开系统日历编辑器")) {
                let previous = service.visibleTask(reference)?.operations.values.contains { receipt in
                    receipt["stopId"].string == stop.id && ["uncertain", "system_reported_saved"].contains(receipt["state"].string)
                } ?? false
                if previous { confirmDuplicate = true } else { openEditor() }
            }.frame(minHeight: 44)
                .disabled(!valid || outcome != nil).accessibilityIdentifier("travel.apple.editor")
            if let outcome { Text(outcome).accessibilityIdentifier("travel.apple.outcome") }
            }
        }.onChange(of: service.currentScope) { _, _ in editor = nil; outcome = nil }
            .navigationTitle(travelText("travel.preview", "变更预览"))
            .confirmationDialog(travelText("travel.appleDuplicate", "之前的系统保存尚未核验，重新打开可能创建重复活动。"), isPresented: $confirmDuplicate, titleVisibility: .visible) {
                Button(travelText("travel.appleReopen", "仍然打开系统编辑器")) { openEditor() }
            }
            .sheet(item: $editor, onDismiss: {
                if outcome == nil { outcome = travelText("travel.appleUnknown", "编辑器已关闭，尚未确认是否保存。重新打开可能创建重复活动。") }
            }) { selection in
                TravelAppleEventEditor(stop: stop) { action in
                    editor = nil
                    let state = action == .saved ? "system_reported_saved" : "cancelled"
                    outcome = action == .saved ? travelText("travel.appleSaved", "系统报告已保存，最终内容未读回核验。") : travelText("travel.appleCancelled", "已取消系统编辑。")
                    try? selection.workspace.update(reference.taskID) { task in
                        let id = selection.operationID
                        var receipt = task.operations[id]?.object ?? [:]
                        receipt["state"] = .string(state); receipt["readbackStatus"] = .string("unavailable")
                        task.operations[id] = .object(receipt)
                    }
                }
            }
    }
    private func openEditor() {
        guard valid, let workspace = service.workspace, workspace.scope == service.currentScope else { return }
        let id = "apple-" + UUID().uuidString
        do {
            try workspace.update(reference.taskID) { $0.operations[id] = .object(["id": .string(id), "state": .string("uncertain"), "readbackStatus": .string("unavailable"), "stopId": .string(stop.id)]) }
            outcome = nil; editor = .init(workspace: workspace, operationID: id)
        } catch { outcome = travelText("travel.saveFailed", "未能保存修改，内容仍保留。请重试。") }
    }

}
@MainActor private struct TravelAppleEditorSelection: Identifiable { let id = UUID(); var workspace: TravelResearchWorkspace; var operationID: String }
@MainActor private struct TravelAppleEventEditor: UIViewControllerRepresentable {
    let stop: TravelStop
    let completion: @MainActor (EKEventEditViewAction) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController(); let store = EKEventStore()
        let event = EKEvent(eventStore: store); event.title = stop.title
        if let raw = stop.time.instant, let date = TravelIdentity.instant(raw), let duration = stop.durationMinutes {
            event.startDate = date; event.endDate = date.addingTimeInterval(Double(duration) * 60)
        }
        event.timeZone = stop.time.timezone.flatMap(TimeZone.init(identifier:)); event.location = stop.place?.name
        controller.eventStore = store; controller.event = event; controller.editViewDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) { }
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let completion: @MainActor (EKEventEditViewAction) -> Void
        init(completion: @escaping @MainActor (EKEventEditViewAction) -> Void) { self.completion = completion }
        nonisolated func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            Task { @MainActor in completion(action) }
        }
    }
}
