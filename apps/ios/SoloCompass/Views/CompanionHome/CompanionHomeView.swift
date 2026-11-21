import SwiftUI
import UIKit
import CoreLocation
import OSLog

/// One persistent conversation and one map, with four independently reachable surfaces.
@MainActor
struct CompanionHomeView: View {
    @Environment(AIService.self) private var aiService
    @Environment(ExperienceService.self) private var experiences
    @Environment(UserPreferences.self) private var preferences
    @Environment(LiveActivityService.self) private var liveActivities
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = CompanionHomeStore()
    @State private var surface: CompanionPrimaryTab = .now
    @State private var visitedTabs: Set<CompanionPrimaryTab> = [.now]
    @State private var sheet: CompanionHomePresentation?
    @State private var didConfigure = false
    @State private var toolRouter: VoiceAgentToolRouter?
    @State private var mapModel: MapViewModel?
    @State private var mapRevealToken = 0
    @State private var composerID = UUID()
    @State private var focusComposer = false
    @State private var keyboardVisible = false
    @State private var composerFocused = false
    @State private var mediaAudio = CompanionAudioSession()
    @State private var messageTranscriber = CompanionAudioTranscriber()
    @State private var recordAfterDismiss = false
    @State private var routeSession = CompanionRouteSession()
    @State private var returnNotice: String?

    private var isEditingConversation: Bool {
        surface == .now && (keyboardVisible || composerFocused)
    }

    var body: some View {
        // Hidden tabs keep their state, but must not determine the host's
        // ideal height through a long lazy conversation during tab changes.
        GeometryReader { viewport in
            ZStack {
                CompanionHomeStyle.paper.ignoresSafeArea()
                // The same view/model stay mounted through every tab switch.
                CompanionNearbyView(sheet: $sheet, store: store, routeSession: routeSession,
                    isActive: surface == .nearby, onModelReady: configureTools,
                    onConversation: { selectTab(.now) }, onReturnToSource: returnToSource,
                    onAskPlace: askAboutPlace, onAskArea: askAboutArea, messageRevealToken: mapRevealToken)
                    .opacity(surface == .nearby ? 1 : 0)
                    .allowsHitTesting(surface == .nearby)
                    .accessibilityHidden(surface != .nearby)
                conversationSurface
                    .opacity(surface == .now ? 1 : 0)
                    .allowsHitTesting(surface == .now)
                    .accessibilityHidden(surface != .now)
                if visitedTabs.contains(.itinerary) {
                    ItineraryListView(sourceCityCode: mapModel?.selectedCity)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(companionText("companion.journey.open", "行程与约定")) { sheet = .journey }
                            }
                        }
                        .opacity(surface == .itinerary ? 1 : 0)
                        .allowsHitTesting(surface == .itinerary)
                        .accessibilityHidden(surface != .itinerary)
                }
                if visitedTabs.contains(.me) {
                    MeSheet(embedded: true, onOpenSettings: { sheet = .settings }, onExplore: { selectTab(.nearby) })
                        .opacity(surface == .me ? 1 : 0)
                        .allowsHitTesting(surface == .me)
                        .accessibilityHidden(surface != .me)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible && !isEditingConversation {
                CompanionNavigationBar(selection: surface, onSelect: selectTab)
                    .background(surface == .me || surface == .itinerary ? CompanionHomeStyle.paper : Color.clear)
            }
        }
        .background(CompanionHomeStyle.paper.ignoresSafeArea(edges: .bottom))
        .tint(CompanionHomeStyle.accent)
        .environment(mediaAudio)
        .onChange(of: sheet != nil) { _, presented in
            if presented { store.cancelVoiceTranscription(); messageTranscriber.cancel() }
        }
        .sheet(item: $sheet, onDismiss: {
            let shouldRecord = recordAfterDismiss
            recordAfterDismiss = false
            if shouldRecord && store.canStartRecording { Task { await mediaAudio.startRecording() } }
        }) { destination in
            switch destination {
            case .identity: CompanionIdentitySheet()
            case .addMedia:
                CompanionAttachmentPicker(store: store, onRecord: { recordAfterDismiss = true })
            case .media(let attachment): CompanionMediaPreview(attachment: attachment)
            case .people: CompanionPeopleSheet(store: store)
            case .journey: CompanionJourneySheet(store: store)
            case .settings:
                SettingsView(onClose: { sheet = nil },
                    onClearAdditionalData: {
                        let cleared = store.clearLocalData()
                        if cleared {
                            mediaAudio.stopPlayback(); mediaAudio.cancelPendingPermission()
                            recordAfterDismiss = false; composerID = UUID()
                            mapModel?.searchThisArea()
                        }
                        return cleared
                    },
                    additionalExportFiles: {
                        let data = try store.exportedSnapshotData()
                        return [.init(filename: "roamorrow-companion.json", contents: String(decoding: data, as: UTF8.self))]
                    })
            case .sources(let entry): CompanionSourcesSheet(entry: entry)
            case .place(let experience, let origin, let usesGPS):
                CompanionPlaceSheet(experience: experience, store: store,
                    onInviteSaved: { selectTab(.now) }, distanceOrigin: origin, distanceUsesGPS: usesGPS)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .cities(let model, let onSelect):
                CompanionCitySheet(model: model, onSelectCity: onSelect)
            }
        }
        .task {
            TravelResearchService.shared.setForeground(true)
            await routeSession.refresh(experiences: experiences.allExperiences)
            guard !didConfigure else { return }
            didConfigure = true
            store.configure(aiService: aiService, experienceService: experiences)
            let transcriber = messageTranscriber
            store.configureAudioTranscription { try await transcriber.transcribe($0) }
            configureResearchService()
            await refreshResearchIdentity()
        }
        .onReceive(NotificationCenter.default.publisher(for: TravelResearchService.continueInChat)) { notification in
            guard let reference = notification.object as? TravelResearchReference,
                  TravelResearchService.shared.visibleTask(reference) != nil else { return }
            if store.setNextTurnResearch(reference) { selectTab(.now); focusComposer = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: RouteStore.didChange)) { _ in
            Task { await routeSession.refresh(experiences: experiences.allExperiences) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            keyboardVisible = true
            traceKeyboardFrame("keyboard-will-show", notification: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            keyboardVisible = false
            traceKeyboardFrame("keyboard-will-hide", notification: notification)
        }
        .onChange(of: mediaAudio.completedRecording?.id) { _, id in
            if id != nil, let recording = mediaAudio.takeCompletedRecording() { _ = store.stageAttachment(recording) }
        }
        .onDisappear {
            store.cancelVoiceTranscription(); messageTranscriber.cancel()
            _ = store.savePresentation()
            TravelResearchService.shared.setForeground(false)
            recordAfterDismiss = false
            mediaAudio.cancelPendingPermission()
            mediaAudio.stopPlayback()
            if mediaAudio.isRecording, let recording = mediaAudio.finishRecording() { _ = store.stageAttachment(recording) }
        }
        .onChange(of: EmailAccountService.shared.generation) { _, _ in
            TravelResearchService.shared.invalidate()
            _ = store.setNextTurnResearch(nil)
            Task { await refreshResearchIdentity() }
        }
        .onChange(of: scenePhase) { _, phase in
            TravelResearchService.shared.setForeground(phase == .active)
            // A Speech authorization alert temporarily makes the scene inactive.
            // Revoke only on actual backgrounding, so consent can finish.
            if phase == .background { store.cancelVoiceTranscription(); messageTranscriber.cancel() }
            if phase == .background { _ = store.savePresentation(); mediaAudio.stopPlayback() }
            if phase == .active { Task { await routeSession.refresh(experiences: experiences.allExperiences) } }
        }
        .onChange(of: liveActivities.current?.id) { _, _ in
            Task { await routeSession.refresh(experiences: experiences.allExperiences) }
        }
        .onOpenURL { url in
            guard url.scheme == "solocompass", url.host == "companion", url.path == "/route" else { return }
            selectTab(.nearby)
            sheet = nil
            routeSession.reveal()
        }
    }

    private var conversationSurface: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .simultaneousGesture(dismissKeyboardOnConversationTap)
            if let returnNotice {
                HStack {
                    Text(returnNotice).font(.footnote)
                    Spacer()
                    CompanionIconButton(symbol: "xmark", label: companionText("companion.dismiss_notice", "关闭提示")) { self.returnNotice = nil }
                }.padding(.leading, 16).background(CompanionHomeStyle.incoming)
            }
            // Keep long-history layout inside the space left by the header and composer.
            GeometryReader { viewport in
                CompanionConversation(store: store, isActive: surface == .now && sheet == nil && scenePhase != .background, onSources: { sheet = .sources($0) },
                    onPlace: showMessageOnMap, onCommitments: { sheet = .journey }, onMedia: openMedia,
                    onQuote: { quote in
                        store.setDraftQuote(quote)
                        focusComposer = true
                    })
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(dismissKeyboardOnConversationTap)
            if store.nextTurnResearchReference != nil {
                HStack {
                    Label(travelText("travel.composerScope", "下一条消息用于这份旅行研究"), systemImage: "text.book.closed").font(.footnote)
                    Spacer()
                    Button { _ = store.setNextTurnResearch(nil) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(travelText("travel.clearScope", "取消研究上下文"))
                }.padding(.leading, 16)
            }
            CompanionComposer(text: $store.composerDraft, isWorking: store.isWorking, isActive: surface == .now && sheet == nil,
                onSend: { Task {
                    guard surface == .now, sheet == nil, scenePhase == .active else { return }
                    await store.send()
                } }, onCancel: { store.cancel() }, store: store, companionName: preferences.agentIdentity.displayName,
                onAddMedia: { sheet = .addMedia }, onOpenMedia: openMedia,
                focusOnAppear: focusComposer, onFocusChange: { focused in
                    composerFocused = focused
                    if focused { focusComposer = false }
                })
                .id(composerID)
        }
        .background(CompanionHomeStyle.paper.ignoresSafeArea(edges: .top))
    }

    private var dismissKeyboardOnConversationTap: some Gesture {
        TapGesture().onEnded {
            guard keyboardVisible || composerFocused else { return }
            dismissKeyboard(reason: "conversation-tap")
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                headerActions
                Spacer(minLength: 0)
                if isEditingConversation {
                    Button { dismissKeyboard(reason: "header-keyboard") } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(companionText("companion.keyboard.hide", "收起键盘"))
                    .accessibilityIdentifier("companion.keyboard.dismiss")
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            Button(action: openIdentity) {
                HStack(spacing: 8) {
                    CompanionPortrait(style: preferences.agentIdentity.portrait, size: 30)
                        .frame(width: 36, height: 36)
                        .background(CompanionHomeStyle.ink.opacity(0.06), in: Circle())
                    Text(preferences.agentIdentity.displayName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 5).padding(.trailing, 14)
                .frame(minHeight: 44)
                .companionGlass(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 210)
            .padding(.horizontal, 52)
            .accessibilityLabel(preferences.agentIdentity.displayName)
            .accessibilityValue(preferences.agentIdentity.displayName)
            .accessibilityHint(companionText("companion.identity.edit", "我的旅伴"))
            .accessibilityIdentifier("companion.identity.open")
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier("companion.header")
    }

    private var headerActions: some View {
        Menu {
            Button(companionText("companion.identity.edit", "我的旅伴"), systemImage: "pencil") { openIdentity() }
            Button(companionText("companion.keyboard.hide", "收起键盘"), systemImage: "keyboard.chevron.compact.down") { dismissKeyboard(reason: "menu-hide") }
                .accessibilityIdentifier("companion.keyboard.menuDismiss")
            Button(companionText("companion.people.open", "选择这次的同行人"), systemImage: "person.2") { sheet = .people }
            if let active = routeSession.active {
                Button(active.placeName, systemImage: "figure.walk") { selectTab(.nearby); routeSession.reveal() }
            }
            Button(companionText("companion.journey.open", "行程与约定"), systemImage: "calendar") { sheet = .journey }
            Button(companionText("companion.settings.open", "偏好与设置"), systemImage: "slider.horizontal.3") { sheet = .settings }
        } label: {
            Image(systemName: "line.3.horizontal").font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(companionText("companion.more", "更多")).accessibilityIdentifier("companion.more")
    }

    private func selectTab(_ value: CompanionPrimaryTab) {
        if value != .now { store.cancelVoiceTranscription(); messageTranscriber.cancel() }
        guard value != surface else { return }
        traceHomeInput("select-tab-begin")
        Task {
            traceHomeInput("presentation-save-begin")
            _ = await store.savePresentationAsynchronously()
            traceHomeInput("presentation-save-end")
        }
        dismissKeyboard(reason: "select-tab")
        focusComposer = false
        mediaAudio.stopPlayback()
        visitedTabs.insert(value)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { surface = value }
        if value == .now { store.restorePresentation() }
        traceHomeInput("select-tab-end")
    }

    private func openIdentity() {
        dismissKeyboard(reason: "open-identity")
        sheet = .identity
    }

    private func dismissKeyboard(reason: String) {
        traceHomeInput("dismiss-keyboard-" + reason)
        focusComposer = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        keyboardVisible = false
        composerFocused = false
    }

    private func traceHomeInput(_ event: String) {
        #if DEBUG
        Self.inputLog.debug("event=\(event, privacy: .public) surface=\(String(describing: surface), privacy: .public) sheetPresent=\(sheet != nil) keyboardVisible=\(keyboardVisible)")
        #endif
    }

    private func traceKeyboardFrame(_ event: String, notification: Notification) {
        #if DEBUG
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let known = frame != nil
        let height = Double(frame?.height ?? -1)
        let width = Double(frame?.width ?? -1)
        let minY = Double(frame?.minY ?? -1)
        Self.inputLog.debug("event=\(event, privacy: .public) endFrameKnown=\(known) endHeight=\(height) endWidth=\(width) endMinY=\(minY) surface=\(String(describing: surface), privacy: .public) keyboardVisible=\(keyboardVisible)")
        #endif
    }
    #if DEBUG
    private static let inputLog = Logger(subsystem: "com.solocompass.voice-composer", category: "focus")
    #endif

    private func openMedia(_ attachment: CompanionMediaAttachment) {
        if let place = attachment.place { showPlace(place.experienceID) }
        else { sheet = .media(attachment) }
    }

    private func showPlace(_ id: String) {
        guard let experience = experiences.getExperience(id: id) else { return }
        sheet = .place(experience, distanceOrigin: nil, usesGPS: false)
    }

    private func showMessageOnMap(_ entry: CompanionHomeEntry, _ selectedID: String?) {
        let ids = entry.mapPlaceIDs
        guard store.captureMapSource(messageID: entry.id, experienceIDs: ids) else { return }
        mapModel?.openMessageResults(ids, selectedID: selectedID)
        mapRevealToken &+= 1
        selectTab(.nearby)
    }

    private func returnToSource() {
        guard store.restoreMapSource() else {
            returnNotice = companionText("companion.map.sourceUnavailable", "原消息已不在本机，已保留当前对话和草稿。")
            selectTab(.now)
            return
        }
        selectTab(.now)
    }

    private func askAboutPlace(_ experience: Experience) {
        if store.mapSource != nil { returnToSource() } else { selectTab(.now) }
        guard store.setNextTurnExperience(experience) else { return }
        focusComposer = true
    }

    private func askAboutArea(_ scope: CompanionHomeAreaScope) {
        guard store.setNextTurnArea(scope.area, query: scope.query, category: scope.category,
            experienceIDs: scope.experienceIDs, latitudeDelta: scope.latitudeDelta,
            longitudeDelta: scope.longitudeDelta) else { return }
        if store.mapSource != nil { returnToSource() } else { selectTab(.now) }
        focusComposer = true
    }

    private func refreshResearchIdentity() async {
        await TravelResearchService.shared.refreshIdentity()
        if let reference = store.nextTurnResearchReference, reference.scopeRef != TravelResearchService.shared.currentScope.reference { _ = store.setNextTurnResearch(nil) }
    }

    private func authorizedResearchCityHint() -> TravelLocationHint? {
        guard let model = mapModel else { return nil }
        let location = LocationService.shared
        guard location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways,
              let fix = location.currentLocation, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 5_000,
              Date().timeIntervalSince(fix.timestamp) >= -60, Date().timeIntervalSince(fix.timestamp) <= 900 else { return nil }
        let nearest = model.availableCities.map { city in
            (city, fix.distance(from: CLLocation(latitude: city.center.latitude, longitude: city.center.longitude)))
        }.min { $0.1 < $1.1 }
        guard let (city, distance) = nearest, distance <= 25_000 else { return nil }
        let name = CompanionPlacePresentation.cityName(code: city.code, fallback: city.name)
        return .init(label: "Authorized approximate city estimate: " + name + "; location snapshot: " + fix.timestamp.ISO8601Format() + "; search bias is public city center, not precise GPS.", longitude: city.center.longitude, latitude: city.center.latitude)
    }

    private func configureResearchService() {
        TravelResearchService.shared.configure(aiService: aiService)
        store.configureResearch(responder: { [weak store] entries, area in
            guard let store, let input = entries.last(where: { $0.role == .user }), let admission = store.researchAdmission(for: input.id) else { throw CancellationError() }
            return try await TravelResearchService.shared.respond(entries: entries, area: area, progress: { _ in }, locationHint: { authorizedResearchCityHint() },
                isAdmitted: { [weak store] in store?.researchAdmission(for: input.id) == admission },
                onAccepted: { [weak store] reference in
                    guard await store?.retainResearchCard(reference, replyTo: input.id, admission: admission) == true else { throw CancellationError() }
                })
        }, forget: { try TravelResearchService.shared.forgetAll() })
    }

    private func configureTools(_ model: MapViewModel) {
        mapModel = model
        if !didConfigure {
            store.configure(aiService: aiService, experienceService: experiences)
            let transcriber = messageTranscriber
            store.configureAudioTranscription { try await transcriber.transcribe($0) }
            configureResearchService()
            Task { await refreshResearchIdentity() }
            didConfigure = true
        }
        // Ordinary messages receive only an explicitly selected public city
        // center. Precise map/GPS positions enter a model turn only through the
        // user's explicit one-question place/area action.
        store.configure(searchArea: { [weak model] in
            guard let model, let code = model.selectedCity, !code.hasPrefix("custom_"),
                  let city = model.availableCities.first(where: { $0.code == code }) else { return nil }
            return CompanionHomeSearchArea(
                name: CompanionPlacePresentation.cityName(code: city.code, fallback: city.name),
                latitude: city.center.latitude, longitude: city.center.longitude, cityCode: city.code)
        })
        if let source = store.mapSource { model.openMessageResults(source.experienceIDs) }
        guard toolRouter == nil else { return }
        let router = VoiceAgentToolRouter(mapViewModel: model, preferences: preferences, aiService: aiService)
        toolRouter = router
        store.configure(toolRouter: router)
    }
}

@MainActor
private struct CompanionJourneySheet: View {
    let store: CompanionHomeStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.activeCommitments.isEmpty {
                        Text(companionText("companion.commitments.empty", "还没有记下待办。对话会先问清楚，再把需要做的事留在这里。"))
                            .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    }
                    ForEach(store.activeCommitments) { commitment in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                _ = store.completeCommitment(id: commitment.id)
                            } label: {
                                Image(systemName: "circle").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(companionText("companion.commitments.complete", "标记完成") + "：" + commitment.title)
                            .accessibilityIdentifier("companion.commitment.complete.\(commitment.id)")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(commitment.title).font(.body)
                                if !commitment.note.isEmpty {
                                    Text(commitment.note).font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                                }
                                if let due = commitment.dueAt {
                                    Text(due, format: .dateTime.month().day().hour().minute())
                                        .companionMetadata().foregroundStyle(CompanionHomeStyle.secondaryInk)
                                }
                                Button(companionText("companion.commitments.discuss", "接着说这件事")) {
                                    store.composerDraft += (store.composerDraft.isEmpty ? "" : "\n\n") + commitment.title + "："
                                    dismiss()
                                }.font(.subheadline).frame(minHeight: 44)
                                    .accessibilityIdentifier("companion.commitment.discuss.\(commitment.id)")
                            }.padding(.vertical, 8)
                        }
                    }
                } header: {
                    Text(companionText("companion.commitments.active", "这几天的待办"))
                } footer: {
                    Text(companionText("companion.commitments.boundary", "这里记录要做的事；本机记录不会自动联系商家，也不代表正在后台监控。"))
                }
                Section(companionText("companion.journey.pending", "还在惦记的事")) {
                    let pending = store.entries.filter { $0.role == .user && $0.status != .delivered }
                    if pending.isEmpty {
                        Text(companionText("companion.journey.noPending", "暂时没有等待处理的对话。"))
                            .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    }
                    ForEach(pending) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.text).font(.system(.body, design: .serif))
                            Button(companionText("companion.retry", "继续处理这件事")) {
                                dismiss()
                                Task { await store.retry(id: entry.id) }
                            }.disabled(store.isWorking)
                        }.padding(.vertical, 6)
                    }
                }
                Section(companionText("companion.journey.invites", "这次的约定")) {
                    if store.invites.isEmpty {
                        Text(companionText("companion.journey.noInvites", "在附近选一个地方，记下想一起去的人。"))
                            .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    }
                    ForEach(store.invites) { CompanionInviteCard(invite: $0).listRowBackground(Color.clear) }
                }
                if !store.commitments.filter({ $0.status == .done }).isEmpty {
                    Section(companionText("companion.commitments.finished", "已经完成")) {
                        ForEach(store.commitments.filter { $0.status == .done }) { commitment in
                            Label(commitment.title, systemImage: "checkmark.circle")
                                .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                    }
                }
                if let error = store.errorMessage {
                    Section { Text(error).companionMetadata().foregroundStyle(.red) }
                }
            }
            .navigationTitle(companionText("companion.journey.open", "行程与约定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(companionText("companion.common.done", "完成")) { dismiss() }
            } }
        }
    }
}

private struct CompanionSourcesSheet: View {
    let entry: CompanionHomeEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(entry.sourceTitles.enumerated()), id: \.offset) { _, title in
                        sourceRow(title)
                    }
                } footer: {
                    Text(companionText("companion.sources.hint", "这些是提供给本轮回应的参考资料，不代表营业或交通情况已经实时核实。出发前请再确认。"))
                }
            }
            .navigationTitle(companionText("companion.sources.open", "查看依据"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(companionText("companion.common.done", "完成")) { dismiss() }
            } }
        }.presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func sourceRow(_ title: String) -> some View {
        let parts = title.components(separatedBy: "\n")
        if parts.count > 1, let raw = parts.last, let url = URL(string: raw),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parts.dropLast().joined(separator: "\n")).foregroundStyle(.primary)
                    Label(host, systemImage: "arrow.up.right").companionMetadata()
                }.frame(minHeight: 44, alignment: .leading)
            }
        } else { Text(title).textSelection(.enabled) }
    }
}
