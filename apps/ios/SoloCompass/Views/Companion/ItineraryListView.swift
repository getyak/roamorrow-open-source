import SwiftUI
import SwiftData

/// List of the user's saved itineraries, ordered by creation date (newest first).
public struct ItineraryListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    private let store: ItineraryStore
    private let travel = TravelResearchService.shared
    private var onClose: (() -> Void)? = nil
    private var sourceCityCode: String? = nil

    @State private var itineraries: [Itinerary] = []
    @State private var showingCreateForm = false
    @State private var showingMuse = false
    @State private var plannerScenario: TripAgentScenario?
    @State private var pendingSavedTripID: String?
    @State private var openedTripID: String?
    @State private var tripStore: TripWorkspace?
    @State private var sampleFailed = false
    @State private var tripToDelete: TripRecord?
    @State private var tripDeletionFailed = false
    @State private var lastDeleted: Itinerary?
    @State private var undoDismissTask: Task<Void, Never>?
    @State private var undoProgress: CGFloat = 1
    @State private var undoDragOffset: CGFloat = 0
    @State private var mutationFailed = false
    @State private var failedDeletion: Itinerary?

    /// Production init using the shared on-disk container.
    public init(sourceCityCode: String? = nil, onClose: (() -> Void)? = nil) {
        self.store = ItineraryStore()
        self.sourceCityCode = sourceCityCode
        self.onClose = onClose
    }

    /// Testable/preview init accepting an injected store.
    init(store: ItineraryStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                if itineraries.isEmpty && trips.isEmpty {
                    EmptyItineraryView(
                        canPlan: workspace != nil,
                        onPlan: startPlanning,
                        onManual: { showingCreateForm = true }
                    )
                } else {
                    List {
                        if let workspace {
                            ForEach(trips) { trip in
                                NavigationLink {
                                    TripDetailView(workspace: workspace, id: trip.id)
                                } label: {
                                    TripListRow(record: trip)
                                }
                                .accessibilityIdentifier("trip.list.\(trip.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        tripToDelete = trip
                                    } label: {
                                        Label(tripText("delete", "Delete trip"), systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                        ForEach(itineraries) { itinerary in
                            NavigationLink {
                                ItineraryDetailView(itinerary: itinerary, store: store)
                            } label: {
                                ItineraryRow(itinerary: itinerary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(itinerary)
                                } label: {
                                    Label(
                                        NSLocalizedString("itinerary.action.delete", comment: "Delete itinerary"),
                                        systemImage: "trash"
                                    )
                                }
                                .disabled(lastDeleted != nil)
                            }
                        }
                        NavigationLink { TravelResearchLibrary() } label: { researchLibraryLabel }
                        NavigationLink { TripDetailView(preview: TripExamples.preview) } label: {
                            Label(tripText("example.open", "Explore a sample itinerary"), systemImage: "map")
                        }
                        .accessibilityIdentifier("trip.example.open")
                    }
                    .listStyle(.plain)
                    .animation(.easeInOut, value: itineraries.count)
                    .refreshable { await MainActor.run { loadItineraries() } }
                }
            }
            .animation(.easeInOut, value: itineraries.isEmpty)
            .navigationTitle(NSLocalizedString("itinerary.list.title", comment: "My Itineraries nav title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done"), action: onClose)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            startPlanning(.nearby)
                        } label: {
                            Label(tripText("agent.open", "Plan with Roamorrow"), systemImage: "sparkles")
                        }
                        .disabled(workspace == nil)
                        Button {
                            showingCreateForm = true
                        } label: {
                            Label(tripText("agent.manual", "Create manually"), systemImage: "square.and.pencil")
                        }
                        Button {
                            showingMuse = true
                        } label: {
                            Label(tripText("muse.title", "Plan with Muse"), systemImage: "arrow.up.right")
                        }
                        .disabled(workspace == nil)
                        #if DEBUG
                        Button {
                            seedTrips()
                        } label: {
                            Label(tripText("examples", "Load sample trips"), systemImage: "suitcase.rolling")
                        }
                        .disabled(workspace == nil)
                        #endif
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("itinerary.action.create.a11y", comment: "Create new itinerary"))
                    .accessibilityIdentifier("trip.create")
                }
            }
            .sheet(isPresented: $showingCreateForm, onDismiss: loadItineraries) {
                ItineraryFormView(store: store, sourceCityCode: sourceCityCode)
            }
            .sheet(item: $plannerScenario, onDismiss: showSavedTrip) { scenario in
                if let workspace {
                    TripAgentPlannerView(workspace: workspace, sourceCity: sourceCityCode, scenario: scenario, onSaved: noteSavedTrip)
                }
            }
            .sheet(isPresented: $showingMuse, onDismiss: showSavedTrip) {
                if let workspace { TripMuseHandoffView(workspace: workspace, onSaved: noteSavedTrip) }
            }
            .navigationDestination(item: $openedTripID) { id in
                if let workspace { TripDetailView(workspace: workspace, id: id) }
            }
        }
        .task(id: travel.currentScope) {
            tripStore = try? TripWorkspace.open(scope: travel.currentScope)
            #if DEBUG
            if !Task.isCancelled, workspace?.scope.owner == "device",
               ProcessInfo.processInfo.arguments.contains("-roamorrow-trip-examples") {
                seedTrips()
            }
            #endif
        }
        .onChange(of: travel.currentScope) { _, _ in
            showingMuse = false
            plannerScenario = nil
            pendingSavedTripID = nil
            openedTripID = nil
            tripToDelete = nil
        }
        .onAppear(perform: loadItineraries)
        .overlay(alignment: .bottom) {
            if lastDeleted != nil {
                undoBar
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: lastDeleted != nil)
        .onChange(of: lastDeleted == nil) { _, isNil in
            if isNil { undoDragOffset = 0 }
        }
        .onDisappear { undoDismissTask?.cancel() }
        .onChange(of: voiceOverOn) { _, enabled in
            if enabled { undoDismissTask?.cancel() }
        }
        .alert(NSLocalizedString("itinerary.mutation.failed", comment: "Changes could not be saved. Your previous state is kept."), isPresented: $mutationFailed) {
            Button(NSLocalizedString("common.retry", comment: "Retry")) {
                if let failedDeletion { delete(failedDeletion) } else { performUndo() }
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel"), role: .cancel) { }
        }
        .alert(tripText("delete.confirm", "Delete this trip?"), isPresented: Binding(
            get: { tripToDelete != nil },
            set: { if !$0 { tripToDelete = nil } }
        ), presenting: tripToDelete) { trip in
            Button(tripText("delete", "Delete trip"), role: .destructive) {
                do {
                    guard let workspace else { throw TravelResearchError.scopeChanged }
                    try workspace.deleteTrip(trip.id, expectedVersion: trip.version)
                } catch {
                    tripDeletionFailed = true
                }
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel"), role: .cancel) { }
        } message: { trip in
            Text(trip.plan.title)
        }
        .alert(tripText("delete.failed", "Couldn’t delete the trip"), isPresented: $tripDeletionFailed) {
            Button(tripText("done", "Done"), role: .cancel) { }
        }
        .alert(tripText("examples.error", "Couldn’t load sample trips"), isPresented: $sampleFailed) {
            Button(tripText("done", "Done"), role: .cancel) { }
        }
    }

    private var workspace: TripWorkspace? {
        guard tripStore?.scope == travel.currentScope else { return nil }
        return tripStore
    }

    private var trips: [TripRecord] { workspace?.trips ?? [] }

    private func startPlanning(_ scenario: TripAgentScenario) {
        guard workspace != nil else { return }
        Haptics.selection()
        plannerScenario = scenario
    }

    private func noteSavedTrip(_ record: TripRecord) {
        pendingSavedTripID = record.id
    }

    private func showSavedTrip() {
        openedTripID = pendingSavedTripID
        pendingSavedTripID = nil
    }

    #if DEBUG
    private func seedTrips() {
        do { try workspace?.addTripExamples() }
        catch { sampleFailed = true }
    }
    #endif

    private func loadItineraries() {
        itineraries = store.loadAll()
    }

    private func delete(_ itinerary: Itinerary) {
        let captured = itinerary
        do {
            try store.delete(id: itinerary.id)
        } catch {
            failedDeletion = itinerary
            mutationFailed = true
            return
        }
        failedDeletion = nil
        withAnimation(reduceMotion ? nil : .easeInOut) {
            itineraries.removeAll { $0.id == itinerary.id }
        }
        Haptics.notify(.warning)
        undoProgress = 1
        undoDragOffset = 0
        lastDeleted = captured
        undoDismissTask?.cancel()
        guard !voiceOverOn else { return }
        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .easeInOut) {
                    lastDeleted = nil
                }
            }
        }
    }

    private func performUndo() {
        guard let saved = lastDeleted else { return }
        undoDismissTask?.cancel()
        undoDismissTask = nil
        do {
            try store.save(saved)
        } catch {
            failedDeletion = nil
            mutationFailed = true
            return
        }
        Haptics.impact(.light)
        withAnimation(reduceMotion ? nil : .easeInOut) {
            lastDeleted = nil
        }
        loadItineraries()
    }

    private var countdownLineColor: Color {
        guard !reduceMotion else { return CT.accent }
        if #available(iOS 18, *) {
            return CT.accent.mix(with: .orange, by: 1 - undoProgress)
        } else {
            return CT.accent
        }
    }

    private var undoBar: some View {
        ZStack(alignment: .bottom) {
            Button {
                performUndo()
            } label: {
                HStack {
                    Text(String(
                        format: NSLocalizedString("itinerary.undo.named", comment: "Removed named itinerary undo banner"),
                        lastDeleted?.title ?? ""
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer()
                    Text(NSLocalizedString("action.undo", comment: "Undo action"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CT.accent)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !reduceMotion && !voiceOverOn {
                GeometryReader { geo in
                    Capsule()
                        .fill(countdownLineColor)
                        .frame(width: geo.size.width * undoProgress, height: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2)
                .padding(.horizontal, 2)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        // Shared drag-to-dismiss (down). Replaces the hand-rolled `* 0.85` +
        // `translation > 80` code with the app's reference gesture model:
        // 1:1 tracking, momentum projection (a quick flick dismisses), and a
        // velocity-continuous settle.
        .dismissibleBanner(
            offset: $undoDragOffset,
            edge: .down,
            onDismiss: {
                undoDismissTask?.cancel()
                undoDismissTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut) { lastDeleted = nil }
                    undoDragOffset = 0
                }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(
            format: NSLocalizedString("itinerary.undo.named.a11y", comment: "Accessibility label for itinerary undo banner"),
            lastDeleted?.title ?? ""
        )))
        .accessibilityAction(named: Text(NSLocalizedString("action.undo", comment: "Undo action"))) {
            performUndo()
        }
        .onAppear {
            undoProgress = 1
            undoDragOffset = 0
            if !reduceMotion && !voiceOverOn {
                withAnimation(.linear(duration: 10)) {
                    undoProgress = 0
                }
            }
        }
    }
}

// MARK: - TripStatus

private enum TripStatus {
    case active
    case today
    case soon(Int)
    case upcoming(Int)
    case past

    static func from(startDate: String, endDate: String, now: Date = Date()) -> TripStatus {
        guard
            let start = iso8601Date(startDate),
            let end = iso8601Date(endDate)
        else { return .upcoming(0) }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)

        if today >= startDay && today <= endDay {
            if startDay == today { return .today }
            return .active
        }
        if today > endDay { return .past }

        let daysUntil = cal.dateComponents([.day], from: today, to: startDay).day ?? 0
        if daysUntil <= 7 { return .soon(daysUntil) }
        return .upcoming(daysUntil)
    }

    var label: String {
        switch self {
        case .active:
            return NSLocalizedString("itinerary.status.active", comment: "Trip status: active now")
        case .today:
            return NSLocalizedString("itinerary.status.today", comment: "Trip status: starts today")
        case .soon(let d):
            return String(format: NSLocalizedString("itinerary.status.soon", comment: "Trip status: in N days (≤7)"), d)
        case .upcoming(let d):
            return String(format: NSLocalizedString("itinerary.status.upcoming", comment: "Trip status: in N days (>7)"), d)
        case .past:
            return NSLocalizedString("itinerary.status.past", comment: "Trip status: past")
        }
    }

    var color: Color {
        switch self {
        case .active, .today: return .green
        case .soon: return CT.accent
        case .upcoming, .past: return Color(.tertiaryLabel)
        }
    }
}

// MARK: - Row

private struct ItineraryRow: View {
    let itinerary: Itinerary

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var dateRangeText: String {
        guard
            let start = iso8601Date(itinerary.startDate),
            let end = iso8601Date(itinerary.endDate)
        else { return "\(itinerary.startDate) – \(itinerary.endDate)" }
        return "\(Self.dateFormatter.string(from: start)) – \(Self.dateFormatter.string(from: end))"
    }

    private var cityName: String {
        let code = itinerary.cityCode.lowercased()
        let canonical = MapViewModel.cityCodeAliases[code] ?? code
        return MapViewModel.cityNameMap[itinerary.cityCode]
            ?? MapViewModel.cityNameMap[canonical]
            ?? MapViewModel.cityNameMap.first { $0.key.caseInsensitiveCompare(canonical) == .orderedSame }?.value
            ?? itinerary.cityCode
    }

    private var tripStatus: TripStatus {
        TripStatus.from(startDate: itinerary.startDate, endDate: itinerary.endDate)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(CT.accent.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "map")
                    .font(.body)
                    .foregroundStyle(CT.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(itinerary.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(cityName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(dateRangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let status = tripStatus
                    Text(status.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(status.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(status.color)
                        .accessibilityHidden(true)
                }

                Text(String(
                    format: NSLocalizedString("itinerary.experienceCount", comment: "N experiences"),
                    itinerary.experienceIds.count
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(itinerary.title), \(cityName), \(dateRangeText), \(tripStatus.label)"
        ))
    }
}

// MARK: - Empty state

private var researchLibraryLabel: some View {
    Label(travelText("travel.library", "研究与草稿"), systemImage: "text.book.closed")
}

private struct EmptyItineraryView: View {
    let canPlan: Bool
    let onPlan: (TripAgentScenario) -> Void
    let onManual: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button {
                    onPlan(.nearby)
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(tripText("agent.open", "Plan with Roamorrow"), systemImage: "sparkles")
                                .font(.system(.title3, design: .serif, weight: .semibold))
                            Text(tripText("agent.emptyHint", "Sketch a day out with places from our catalog."))
                                .font(.subheadline)
                                .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                    .background(CompanionHomeStyle.outgoing, in: .rect(cornerRadius: 19))
                    .contentShape(.rect(cornerRadius: 19))
                }
                .buttonStyle(.plain)
                .disabled(!canPlan)
                .accessibilityIdentifier("trip.agent.open")

                VStack(alignment: .leading, spacing: 8) {
                    Text(tripText("agent.scenarios", "Ideas to start with"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(TripAgentScenario.allCases) { scenario in
                        Button {
                            onPlan(scenario)
                        } label: {
                            scenarioRow(scenario)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlan)
                        .accessibilityIdentifier("trip.scenario.\(scenario.id)")
                    }
                }

                NavigationLink {
                    TripDetailView(preview: TripExamples.preview)
                } label: {
                    HStack(spacing: 13) {
                        if let image = TripDetailView.kyotoCover {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 57)
                                .clipped()
                                .clipShape(.rect(cornerRadius: 9))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tripText("example.open", "Explore a sample itinerary")).font(.subheadline.weight(.semibold))
                            Text(tripText("example.route", "Osaka, Kyoto and Kobe"))
                                .font(.caption)
                                .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }
                    .padding(10)
                    .frame(minHeight: 63)
                    .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 15))
                    .contentShape(.rect(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trip.example.open")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { manualLink; researchLink }
                    VStack(alignment: .leading, spacing: 3) { manualLink; researchLink }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CompanionHomeStyle.accent)
            }
            .frame(maxWidth: 580, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
    }

    private func scenarioRow(_ scenario: TripAgentScenario) -> some View {
        HStack(spacing: 11) {
            Image(systemName: scenario.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 38)
                .foregroundStyle(CompanionHomeStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(scenario.title).font(.subheadline.weight(.semibold))
                Text(scenario.subtitle).font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CompanionHomeStyle.secondaryInk)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 55)
        .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var manualLink: some View {
        Button(action: onManual) {
            Label(tripText("agent.manual", "Create manually"), systemImage: "square.and.pencil")
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private var researchLink: some View {
        NavigationLink { TravelResearchLibrary() } label: { researchLibraryLabel.frame(minHeight: 44) }
            .buttonStyle(.plain)
    }
}

// MARK: - Helpers

private func iso8601Date(_ string: String) -> Date? {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.date(from: string)
}

// MARK: - Preview

#Preview("With itineraries") {
    let container = SoloCompassModelContainer.makeInMemory()
    let store = ItineraryStore(context: ModelContext(container))
    // Active now: spans today (2026-06-02)
    try? store.save(Itinerary(
        id: ItineraryId(rawValue: "itin_preview_active"),
        ownerId: "user_preview",
        title: "Tokyo Spring 2026",
        cityCode: "TYO",
        startDate: "2026-05-30",
        endDate: "2026-06-05",
        experienceIds: [],
        note: "Focus on cherry blossom spots and quiet cafes.",
        openToCompanions: true,
        createdAt: "2026-01-15T09:00:00Z",
        updatedAt: "2026-01-15T09:00:00Z"
    ))
    // Upcoming: starts in 10 days (2026-06-12), shows gray "In 10 days" pill
    try? store.save(Itinerary(
        id: ItineraryId(rawValue: "itin_preview_2"),
        ownerId: "user_preview",
        title: "Kyoto Autumn",
        cityCode: "KYT",
        startDate: "2026-06-12",
        endDate: "2026-06-18",
        experienceIds: ["exp_1", "exp_2", "exp_3"],
        openToCompanions: false,
        createdAt: "2026-02-01T09:00:00Z",
        updatedAt: "2026-02-01T09:00:00Z"
    ))
    return ItineraryListView(store: store)
        .environment(ExperienceService(seed: []))
        .environment(UserPreferences())
}

#Preview("Empty state") {
    NavigationStack {
        EmptyItineraryView(canPlan: true, onPlan: { _ in }, onManual: { })
    }
}

#Preview("Empty state — no CTA") {
    EmptyItineraryView(canPlan: false, onPlan: { _ in }, onManual: { })
}
