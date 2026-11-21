import MapKit
import SwiftUI
#if DEBUG
import OSLog
#endif

/// Map, camera and browsing state stay mounted across the four primary tabs.
@MainActor
struct CompanionNearbyView: View {
    @Binding var sheet: CompanionHomePresentation?
    let store: CompanionHomeStore
    let routeSession: CompanionRouteSession
    var isActive = true
    var onModelReady: ((MapViewModel) -> Void)? = nil
    var onConversation: () -> Void
    var onReturnToSource: () -> Void = {}
    var onAskPlace: (Experience) -> Void = { _ in }
    var onAskArea: (CompanionHomeAreaScope) -> Void = { _ in }
    var messageRevealToken = 0
    @Environment(LocationService.self) private var location
    @Environment(ExperienceService.self) private var experiences
    @Environment(AIService.self) private var ai
    @Environment(UserPreferences.self) private var preferences
    @State private var model: MapViewModel?

    var body: some View {
        Group {
            if let model {
                CompanionNearbyMap(sheet: $sheet, store: store, routeSession: routeSession,
                    isActive: isActive, location: location, model: model,
                    onModelReady: onModelReady, onConversation: onConversation,
                    onReturnToSource: onReturnToSource, onAskPlace: onAskPlace, onAskArea: onAskArea,
                    messageRevealToken: messageRevealToken)
            } else { Color(.systemGroupedBackground) }
        }
        .task {
            guard model == nil else { return }
            model = MapViewModel(locationService: location, experienceService: experiences,
                                 aiService: ai, preferences: preferences)
        }
    }
}

@MainActor
private struct CompanionNearbyMap: View {
    @Binding var sheet: CompanionHomePresentation?
    let store: CompanionHomeStore
    let routeSession: CompanionRouteSession
    let isActive: Bool
    let location: LocationService
    @Bindable var model: MapViewModel
    var onModelReady: ((MapViewModel) -> Void)?
    var onConversation: () -> Void
    var onReturnToSource: () -> Void = {}
    var onAskPlace: (Experience) -> Void = { _ in }
    var onAskArea: (CompanionHomeAreaScope) -> Void = { _ in }
    var messageRevealToken = 0
    @State private var didReportModel = false
    @State private var hasActivatedMap = false
    @State private var consumedMessageRevealToken = 0
    @State private var viewport = MapInteractionCoordinator()
    @State private var coordinateSpace = MapKitCoordinateSpace.shared
    @State private var nearbyPresentation = MapCoordinatePresentation()
    @State private var footprintPresentation = MapCoordinatePresentation()
    @State private var locationRequested = false
    @State private var hasOpenedNearby = false
    @State private var pendingLocationCenter: LocationCenter?
    @State private var locationClock = Date.distantPast
    @State private var explicitLocationRequest = false
    @State private var locationTimedOut = false
    @State private var areaLabels: [AreaCell: String] = [:]
    private enum LocationCenter { case nearby, footprints }
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var lastCamera: MapCamera?
    @State private var currentRegion: MKCoordinateRegion?
    @State private var searchQuery = ""
    @State private var showsSearch = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showFootprints = false
    @State private var footprintsActive = false
    @State private var footprintFilter = FootprintFilter()
    @State private var footprintHistory = FootprintHistory()
    @State private var footprintDays: [FootprintHistory.Day] = []
    @State private var footprintVisibleCities: [FootprintCity] = []
    @State private var footprintHistoryRevision: Int?
    @State private var loadedFootprintFilter: FootprintFilter?
    @State private var footprintLoadFailed = false
    @State private var loadingFootprintPhotos = false
    @State private var footprintRetry = 0
    @State private var footprintDay = FootprintMapDay()
    @State private var footprintCamera: MapCameraPosition = .automatic
    @State private var footprintDrawingBounds = MKMapRect.world
    @State private var footprintDrawing = ProjectedFootprintDrawing.empty
    @State private var footprintFitFrame: FootprintMapDay.CameraFrame?
    @State private var footprintRecentFrame: FootprintMapDay.CameraFrame?
    @State private var footprintDrawingRevision = 0
    @State private var lastFootprintCamera: MapCamera?
    @State private var footprintNeedsRecenter = false
    @State private var footprintSelection: UUID?
    @State private var showFootprintFilters = false
    @State private var footprintRecorder = FootprintRecorder.shared
    @State private var workspaceHeaderHeight: CGFloat = 160
    @State private var mapControlsHeight: CGFloat = 44
    @State private var selectedPlaceID: String?
    @State private var level: CompanionPanelLevel = .collapsed
    @State private var page: PanelPage = .browse
    @State private var controlsVisible = true
    @State private var keyboardVisible = false
    @State private var filterOptions = false
    @State private var endingRoute = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(UserPreferences.self) private var preferences
    @Environment(ExperienceService.self) private var experiences

    private enum PanelPage { case browse, place, route }
    private var place: Experience? {
        selectedPlaceID.flatMap { id in model.allExperiences.first { $0.id == id } ?? experiences.getExperience(id: id) }
    }
    private var panelHeight: CGFloat {
        if keyboardVisible { return 290 }
        switch page {
        case .browse: return 370
        case .place: return 290
        case .route: return 335
        }
    }

    private var showsMapChrome: Bool {
        controlsVisible || voiceOver || typeSize.isAccessibilitySize || keyboardVisible
    }

    @ViewBuilder private var mapSurface: some View {
        if footprintsActive { footprintMap } else { map }
    }

    var body: some View {
        mapLifecycle
            .onChange(of: location.latestForegroundSample) { _, _ in centerOnPendingLocation() }
            .onChange(of: location.accuracyAuthorization) { _, _ in centerOnPendingLocation() }
            .onChange(of: location.authorizationStatus) { _, status in
                if status == .denied || status == .restricted {
                    locationTimedOut = explicitLocationRequest && pendingLocationCenter != nil
                    pendingLocationCenter = nil
                    return
                }
                if isActive && scenePhase == .active && locationRequested && locationAuthorized {
                    location.startUpdating()
                    centerOnPendingLocation()
                }
            }
            .task(id: foregroundFix?.expiresAt) {
                guard let deadline = foregroundFix?.expiresAt else { return }
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                catch { return }
                locationClock = deadline
            }
            .task(id: scenePhase == .active && locationAuthorized ? pendingLocationCenter : nil) {
                guard let target = pendingLocationCenter, locationAuthorized, scenePhase == .active else { return }
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
                guard pendingLocationCenter == target else { return }
                centerOnPendingLocation(allowApproximate: explicitLocationRequest)
                if pendingLocationCenter == target {
                    locationTimedOut = explicitLocationRequest
                    pendingLocationCenter = nil
                }
            }
            .onChange(of: model.selectedCity) { _, _ in
                // GPS may adopt a catalog city. This event does not revoke the map's location session.
                searchTask?.cancel()
                mapCenter = model.cameraPosition.region?.center
                currentRegion = model.cameraPosition.region
                selectedPlaceID = nil
                page = .browse
            }
            .onChange(of: model.mapBrowseMode) { _, _ in
                searchTask?.cancel()
            }
            .onChange(of: preferences.favoritedExperiences) { _, _ in
                model.refreshFavorites()
            }
            .onChange(of: messageRevealToken) { _, _ in
                consumeMessageReveal()
            }
            .onChange(of: model.selectedExperience?.id) { _, id in
                selectedPlaceID = id
                page = id == nil ? .browse : .place
                if id != nil && isActive { expand() }
            }
            .onChange(of: model.messageResultIDs) { _, ids in
                if ids != nil {
                    selectedPlaceID = model.selectedExperience?.id
                    page = selectedPlaceID == nil ? .browse : .place
                    if isActive { expand() }
                }
            }
            .onChange(of: model.visibleExperiences.map(\.id)) { _, ids in
                if let selectedPlaceID, !ids.contains(selectedPlaceID) {
                    self.selectedPlaceID = nil; page = .browse
                }
            }
            .onChange(of: experiences.allExperiences.map(\.id)) { _, _ in
                if let center = distanceOrigin { model.refreshForLocation(center) }
            }
            .onChange(of: routeSession.revealRequest) { _, _ in
                consumeRouteReveal()
            }
            .onChange(of: routeSession.active?.contextID) { _, value in
                if value == nil && page == .route { page = .browse; collapse() }
                else { consumeRouteReveal() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                guard isActive else { return }
                keyboardVisible = true
                if showsSearch { level = .collapsed } else { expand() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private var mapWorkspace: some View {
        Group {
        if hasActivatedMap || isActive {
        mapSurface
            .ignoresSafeArea(edges: [.top, .bottom])
            .overlay { GeometryReader { proxy in
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        if footprintsActive { footprintToolbar } else { workspaceHeader }
                        locationStatus
                    }
                        .opacity(showsMapChrome ? 1 : 0)
                        .allowsHitTesting(showsMapChrome)
                        .accessibilityHidden(!showsMapChrome)
                        .background { GeometryReader { geometry in
                            Color.clear.preference(key: CompanionMapHeaderHeight.self, value: geometry.size.height)
                        } }
                    Spacer(minLength: 0)
                    if footprintsActive {
                        footprintPanel
                            .opacity(showsMapChrome ? 1 : 0)
                            .allowsHitTesting(showsMapChrome)
                            .accessibilityHidden(!showsMapChrome)
                    } else if !keyboardVisible {
                    mapControls
                        .background { GeometryReader { geometry in
                            Color.clear.preference(key: CompanionMapControlsHeight.self, value: geometry.size.height)
                        } }
                        .opacity(showsMapChrome ? 1 : 0)
                        .allowsHitTesting(showsMapChrome)
                        .accessibilityHidden(!showsMapChrome)
                    CompanionMapPanel(level: $level, expandedHeight: panelHeight,
                                      availableHeight: max(86, proxy.size.height - workspaceHeaderHeight - mapControlsHeight - 24)) {
                        collapsedSummary
                    } header: {
                        panelHeader
                    } content: {
                        panelContent
                    }
                    .opacity(showsMapChrome || page == .route ? 1 : 0)
                    .allowsHitTesting(showsMapChrome || page == .route)
                    .accessibilityHidden(!showsMapChrome && page != .route)
                    }
                }
                .onPreferenceChange(CompanionMapHeaderHeight.self) { workspaceHeaderHeight = $0 }
                .onPreferenceChange(CompanionMapControlsHeight.self) { mapControlsHeight = $0 }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(sheet == nil ? 1 : 0)
                .allowsHitTesting(sheet == nil)
                .accessibilityHidden(sheet != nil)
            } }
        } else { Color.clear }
        }
    }

    private var mapLifecycle: some View {
        mapWorkspace
            .task {
                if isActive { hasActivatedMap = true; activateLocationIfNeeded() }
                if !didReportModel {
                    didReportModel = true
                    onModelReady?(model)
                    if routeSession.active != nil { page = .route }
                }
                consumeRouteReveal()
                consumeMessageReveal()
            }
            .onChange(of: isActive) { _, active in
                if !active {
                    pendingLocationCenter = nil
                    #if DEBUG
                    traceGlobalResign("inactive", phase: "before")
                    #endif
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    #if DEBUG
                    traceGlobalResign("inactive", phase: "after")
                    #endif
                    controlsVisible = true
                    if sheet?.isMapTask == true { sheet = nil }
                    if locationRequested { location.stopUpdating() }
                } else {
                    hasActivatedMap = true
                    consumeRouteReveal()
                    consumeMessageReveal()
                    activateLocationIfNeeded()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard locationRequested else { return }
                if phase == .active && isActive { activateLocationIfNeeded() } else {
                    if phase == .background { pendingLocationCenter = nil }
                    location.stopUpdating()
                }
            }
            .onChange(of: model.cameraPosition, initial: true) { _, position in
                nearbyPresentation.request(position, fallback: model.exploreAnchorCoordinate, space: coordinateSpace)
            }
            .onChange(of: footprintCamera) { _, position in
                footprintPresentation.request(position, fallback: model.exploreAnchorCoordinate, space: coordinateSpace)
            }
            .onChange(of: coordinateSpace.revision) { _, _ in recoverPresentedMaps() }
            .task(id: calibrationTargets) {
                await MapCalibrationTarget.refresh(calibrationTargets, using: coordinateSpace)
            }
            .task(id: viewportAreaCell) {
                if let cell = viewportAreaCell { await readAreaLabel(cell) }
            }
            .sheet(isPresented: $showFootprints) { footprintJournal }
            .sheet(isPresented: $showFootprintFilters) {
                FootprintFilterSheet(history: footprintHistory, filter: footprintFilter, apply: setFootprintFilter)
            }
            .task(id: footprintQuery) {
                if let query = footprintQuery { await loadFootprints(query) }
            }
            .task(id: footprintDrawingQuery) {
                if let query = footprintDrawingQuery { await projectFootprintDrawing(query) }
            }
            .onChange(of: footprintRecorder.historyScope) { _, _ in clearFootprintHistory() }
            .onDisappear { searchTask?.cancel(); if locationRequested { location.stopUpdating() } }
    }

    private var map: some View {
        Map(position: Binding(get: { nearbyPresentation.position }, set: { position in
            if let canonical = nearbyPresentation.receive(position, space: coordinateSpace),
               position.positionedByUser, canonical.coordinateCenter != nil {
                model.cameraPosition = canonical
            }
        })) {
            ForEach(Array(model.clusteredMapItems.prefix(50))) { item in
                if let coordinate = item.coordinate.flatMap({ coordinateSpace.mapCoordinate($0) }) {
                    Annotation(annotationTitle(item), coordinate: coordinate) {
                        Button { select(item) } label: {
                            marker(item).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(annotationTitle(item))
                        .accessibilityIdentifier(annotationID(item))
                    }
                }
            }
            mapUserLocation
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityIdentifier("companion.nearby.map")
        .onMapCameraChange(frequency: .continuous) { context in
            guard isActive, !footprintsActive else { return }
            let changed = lastCamera != context.camera
            lastCamera = context.camera
            // positionedByUser describes the last camera owner. A duplicate
            // MapKit callback while opening controls is not a new gesture.
            guard changed else { return }
            if nearbyPresentation.isGestureCamera {
                pendingLocationCenter = nil
                searchTask?.cancel()
                hideMapChrome()
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard isActive, !footprintsActive else { return }
            revealMapChrome()
            freezeNativeLocationCamera(nearbyPresentation, at: context.camera)
            let userInteraction = nearbyPresentation.isGestureCamera
            guard let canonical = nearbyPresentation.finish(context.region, space: coordinateSpace) else {
                if userInteraction {
                    mapCenter = nil
                    currentRegion = nil
                    model.invalidateWorkspaceViewport()
                    searchTask?.cancel()
                }
                return
            }
            settleNearby(canonical, userInteraction: userInteraction)
        }
    }

    private func settleNearby(_ region: MKCoordinateRegion, userInteraction: Bool) {
        mapCenter = region.center
        currentRegion = region
        if userInteraction || viewport.consumeRefresh(for: region) {
            model.settleWorkspaceViewport(region, userInteraction: userInteraction)
        } else {
            model.noteWorkspaceViewport(region, userInteraction: false)
        }
    }

    private var calibrationTargets: [MapCalibrationTarget] {
        guard isActive, scenePhase == .active else { return [] }
        let target = footprintsActive ? footprintPresentation.target : nearbyPresentation.target
        let footprintRegions = footprintsActive ? footprintDay.calibrationCoordinates : []
        return MapCalibrationTarget.targets(for: [target, foregroundFix?.location.coordinate].compactMap { $0 } + footprintRegions)
    }

    private func recoverPresentedMaps() {
        if footprintsActive {
            if let region = footprintPresentation.recover(footprintCamera, fallback: model.exploreAnchorCoordinate, space: coordinateSpace) {
                footprintDrawingBounds = region.mapRectForDrawing
            }
        } else if let region = nearbyPresentation.recover(model.cameraPosition, fallback: model.exploreAnchorCoordinate, space: coordinateSpace) {
            if let position = nearbyPresentation.receive(nearbyPresentation.position, space: coordinateSpace),
               position.coordinateCenter != nil {
                model.cameraPosition = position
            }
            settleNearby(region, userInteraction: true)
        }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if keyboardVisible {
                    cityButton.companionGlass(in: Capsule())
                } else {
                    MapWorkspaceControls(viewModel: model, context: cityButton,
                        sourceLabel: store.mapSource == nil ? nil : companionText("companion.map.sourceKept", "原对话与草稿已保留"),
                        onReturnToConversation: store.mapSource == nil ? nil : onReturnToSource,
                        onOpenFootprints: openFootprintsOnMap)
                }
                Spacer(minLength: 0)
                searchButton
            }
            if showsSearch {
                HStack {
                    TextField(companionText("companion.map.searchPlaceholder", "地点、咖啡馆、书店…"), text: $searchQuery)
                        .font(.body).submitLabel(.search).onSubmit(performSearch)
                        .accessibilityIdentifier("companion.map.searchField")
                    if model.isSearchingWeb { ProgressView() }
                    else {
                        Button(action: performSearch) {
                            Image(systemName: "arrow.up.right").frame(width: 44, height: 44)
                        }.disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(companionText("companion.map.search", "搜索地点"))
                    }
                }.padding(.leading, 14).companionGlass(in: Capsule())
            }
        }.padding(.top, 8)
    }

    private var searchButton: some View {
        Button {
            showsSearch.toggle()
            if !showsSearch {
                #if DEBUG
                traceGlobalResign("search-toggle-close", phase: "before")
                #endif
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #if DEBUG
                traceGlobalResign("search-toggle-close", phase: "after")
                #endif
            }
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 20))
                .frame(width: 44, height: 44).companionGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(companionText("companion.map.search", "搜索地点"))
        .accessibilityIdentifier("companion.map.search")
    }

    private var footprintMap: some View {
        Map(position: Binding(get: { footprintPresentation.position }, set: { position in
            _ = footprintPresentation.receive(position, space: coordinateSpace)
        })) {
            FootprintMapContent(drawing: footprintDrawing, selectedID: footprintSelection,
                                title: FootprintText.title, selectionHint: "showOnMap") { id in
                footprintSelection = footprintSelection == id ? nil : id
            }
            mapUserLocation
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityIdentifier("companion.map.footprintLayer")
        .onMapCameraChange(frequency: .continuous) { context in
            guard isActive, footprintsActive, lastFootprintCamera != context.camera else { return }
            lastFootprintCamera = context.camera
            if footprintPresentation.isGestureCamera {
                pendingLocationCenter = nil
                footprintNeedsRecenter = footprintDay.hasMap
                hideMapChrome()
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard isActive && footprintsActive else { return }
            freezeNativeLocationCamera(footprintPresentation, at: context.camera)
            if footprintPresentation.finish(context.region, space: coordinateSpace) != nil,
               let bounds = coordinateSpace.canonicalRect(context.rect) {
                footprintDrawingBounds = bounds
            }
            revealMapChrome()
        }
    }

    private var footprintToolbar: some View {
        HStack(spacing: 0) {
            Button {
                pendingLocationCenter = nil
                footprintsActive = false
                revealMapChrome()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.backward").font(.caption.weight(.semibold))
                    Text(companionText("companion.tab.map", "地图"))
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FootprintText.text("backToMap"))
            .accessibilityIdentifier("companion.map.footprints.back")

            Divider().frame(height: 14).accessibilityHidden(true)
            Button { showFootprintFilters = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal.decrease").font(.footnote.weight(.medium))
                    Text(footprintHistory.title(for: footprintFilter))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(footprintFilter.isActive ? FootprintStyle.accent : CompanionHomeStyle.ink)
            .accessibilityLabel(FootprintText.text("filterTitle"))
            .accessibilityValue(footprintHistory.title(for: footprintFilter))
            .accessibilityIdentifier("companion.map.footprints.filter")

            if footprintFilter.isActive {
                Button { setFootprintFilter(FootprintFilter()) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(FootprintText.text("filterReset"))
                .accessibilityIdentifier("companion.map.footprints.reset")
            }
            if footprintRecorder.syncIndicator != nil {
                Divider().frame(height: 14).accessibilityHidden(true)
                FootprintSyncControl()
            }
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .companionGlass(in: Capsule(), interactive: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var footprintPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if footprintVisibleCities.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(footprintVisibleCities) { city in
                            Button {
                                var filter = footprintFilter
                                filter.cityID = city.id
                                setFootprintFilter(filter)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "mappin").font(.caption2.weight(.semibold))
                                    Text(city.name).font(.footnote.weight(.semibold))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .foregroundStyle(FootprintStyle.accent)
                                .companionGlass(in: Capsule(), interactive: false)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("companion.map.footprints.city.\(city.id)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 44)
            }
            footprintResultActions
        }
    }

    private var footprintResultActions: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                if footprintLoadFailed { footprintRetry += 1 }
                else if footprintFilter.isActive && footprintDays.isEmpty && footprintRecorder.hasStarted { showFootprintFilters = true }
                else { showFootprints = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(FootprintStyle.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        footprintSummary
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loadedFootprintFilter != footprintFilter && !footprintLoadFailed)
            .companionGlass(in: RoundedRectangle(cornerRadius: 17), interactive: false)
            .accessibilityIdentifier("companion.map.footprints.journal")
            Spacer(minLength: 0)
            Button { requestLocationCenter(.footprints) } label: {
                Image(systemName: "location").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .companionGlass(in: Circle())
            .accessibilityLabel(companionText("companion.nearby.locate", "定位到我"))
            .accessibilityIdentifier("companion.map.footprints.locate")
            if !footprintDay.routes.isEmpty {
                Button {
                    pendingLocationCenter = nil
                    footprintSelection = nil
                    if let latest = footprintRecentFrame {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { footprintCamera = latest.position }
                    }
                    footprintNeedsRecenter = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .companionGlass(in: Circle())
                .accessibilityLabel(FootprintText.text("recentTrail"))
                .accessibilityIdentifier("companion.map.footprints.recent")
            }
            if footprintNeedsRecenter {
                Button {
                    pendingLocationCenter = nil
                    footprintSelection = nil
                    if let position = footprintFitFrame?.position {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { footprintCamera = position }
                    }
                    footprintNeedsRecenter = false
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .companionGlass(in: Circle())
                .accessibilityLabel(FootprintText.text("filterFit"))
                .accessibilityIdentifier("companion.map.footprints.fullDay")
            }
        }
        .foregroundStyle(CompanionHomeStyle.ink)
    }

    @ViewBuilder private var footprintSummary: some View {
        if let footprintSelection,
           let selection = footprintDay.rows.first(where: { $0.id == footprintSelection }) {
            Text(FootprintText.title(selection))
                .font(.subheadline.weight(.semibold))
            let time = FootprintText.timeLabel(selection)
            let duration = selection.displayedMinutes.map(FootprintText.durationLabel)
            let date = footprintDays.count > 1 ? selection.date.formatted(.dateTime.month(.abbreviated).day()) : nil
            Text([date, time, duration].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(CompanionHomeStyle.secondaryInk)
        } else {
            Text(FootprintText.text(footprintLoadFailed ? "filterRetry" : (footprintRecorder.hasStarted ? "mapJournal" : "enable")))
                .font(.subheadline.weight(.semibold))
            Text(footprintSummaryDetail)
                .font(.caption)
                .foregroundStyle(CompanionHomeStyle.secondaryInk)
        }
    }

    private var footprintSummaryDetail: String {
        if footprintLoadFailed { return FootprintText.text("storageError") }
        if loadedFootprintFilter != footprintFilter { return FootprintText.text("filterLoading") }
        let visits = footprintDays.reduce(0) { $0 + $1.stops }
        let photos = footprintDays.reduce(0) { $0 + $1.photos }
        let segments = footprintDay.routes.count
        let metrics = [
            footprintDays.count > 1
                ? String.localizedStringWithFormat(FootprintText.text("filterDays"), footprintDays.count) : nil,
            visits > 0 ? String.localizedStringWithFormat(FootprintText.text("visitCount"), visits) : nil,
            photos > 0 ? String.localizedStringWithFormat(FootprintText.text("photoCount"), photos) : nil,
            segments > 0 ? String.localizedStringWithFormat(FootprintText.text("segmentCount"), segments) : nil,
            segments == 0 && !footprintDay.isolatedPoints.isEmpty
                ? String.localizedStringWithFormat(FootprintText.text("pointCount"), footprintDay.isolatedPoints.count) : nil
        ].compactMap { $0 }
        if loadingFootprintPhotos || footprintRecorder.importingFavorites {
            return (metrics + [FootprintText.text("loadingPhotos")]).joined(separator: " · ")
        }
        return metrics.isEmpty ? FootprintText.text(footprintFilter.isActive ? "filterNoMatches" : "filterEmpty")
            : metrics.joined(separator: " · ")
    }

    private func openFootprintsOnMap() {
        guard !footprintsActive else { return }
        pendingLocationCenter = nil
        searchTask?.cancel()
        revealMapChrome()
        lastFootprintCamera = nil
        footprintCamera = footprintDay.cameraPosition(focusRecent: true) ?? model.cameraPosition
        footprintNeedsRecenter = false
        footprintsActive = true
    }

    private struct FootprintQuery: Equatable {
        let scope: String
        let filter: FootprintFilter
        let today: Date
        let retry: Int
    }

    private var footprintQuery: FootprintQuery? {
        guard footprintsActive, isActive, scenePhase == .active else { return nil }
        return FootprintQuery(scope: footprintRecorder.historyScope,
                              filter: footprintFilter, today: Calendar.current.startOfDay(for: Date()), retry: footprintRetry)
    }

    private func setFootprintFilter(_ filter: FootprintFilter) {
        guard footprintFilter != filter else { return }
        pendingLocationCenter = nil
        footprintSelection = nil
        footprintDay = FootprintMapDay()
        footprintDrawing = .empty
        footprintFitFrame = nil
        footprintRecentFrame = nil
        footprintDrawingRevision += 1
        footprintDays = []
        footprintVisibleCities = []
        footprintNeedsRecenter = false
        footprintLoadFailed = false
        footprintFilter = filter
    }

    private func clearFootprintHistory() {
        footprintFilter = FootprintFilter()
        footprintHistory = FootprintHistory()
        footprintDays = []
        footprintVisibleCities = []
        footprintDay = FootprintMapDay()
        footprintDrawing = .empty
        footprintFitFrame = nil
        footprintRecentFrame = nil
        footprintDrawingBounds = .world
        footprintDrawingRevision += 1
        footprintSelection = nil
        footprintHistoryRevision = nil
        loadingFootprintPhotos = false
        loadedFootprintFilter = nil
        footprintCamera = model.cameraPosition
        footprintNeedsRecenter = false
        showFootprints = false
        showFootprintFilters = false
    }

    private func loadFootprints(_ query: FootprintQuery) async {
        var attemptedRevision: Int?
        while !Task.isCancelled && footprintQuery == query {
            let revision = footprintRecorder.revision
            if attemptedRevision != revision {
                attemptedRevision = revision
                let cities = footprintCities
                do {
                    footprintLoadFailed = false
                    if footprintHistoryRevision == nil {
                        loadingFootprintPhotos = true
                        let movement = try await footprintRecorder.history(cities: cities, includePhotos: false)
                        await publishFootprintHistory(movement, query: query)
                    }
                    guard !Task.isCancelled, footprintQuery == query else { return }
                    let history: FootprintHistory
                    if footprintHistoryRevision == revision {
                        history = footprintHistory
                    } else {
                        history = try await footprintRecorder.history(cities: cities, includePhotos: true)
                    }
                    await publishFootprintHistory(history, query: query)
                    guard !Task.isCancelled, footprintQuery == query else { return }
                    footprintHistoryRevision = revision
                    loadingFootprintPhotos = false
                } catch {
                    guard !Task.isCancelled, footprintQuery == query else { return }
                    footprintLoadFailed = true
                    loadingFootprintPhotos = false
                }
            }
            // A photo batch arriving during a read cannot cancel that read.
            // Refresh only when the visible journal has a new stored revision.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func publishFootprintHistory(_ history: FootprintHistory, query: FootprintQuery) async {
        let reframe = loadedFootprintFilter != query.filter || !footprintDay.hasMap
        let task = Task.detached(priority: .userInitiated) {
            let selection = history.select(query.filter)
            let fit = selection.map.cameraFrame(focusRecent: false)
            let recent = selection.map.latestTrailFrame
            let camera = reframe ? (query.filter.isActive ? fit : (recent ?? fit)) : nil
            return (selection, camera, fit, recent)
        }
        let (selection, camera, fit, recent) = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, footprintQuery == query else { return }
        footprintHistory = history
        loadedFootprintFilter = query.filter
        footprintDay = selection.map
        footprintDays = selection.days
        footprintVisibleCities = selection.cities
        footprintFitFrame = fit
        footprintRecentFrame = recent
        footprintDrawingRevision += 1
        if let footprintSelection, !selection.map.rows.contains(where: { $0.id == footprintSelection }) {
            self.footprintSelection = nil
        }
        if reframe {
            footprintNeedsRecenter = false
            if !query.filter.isActive, !footprintPresentation.isGestureCamera, let coordinate = reliableLocationCoordinate {
                footprintCamera = .region(selection.map.liveRegion(centeredOn: coordinate))
            } else if !footprintPresentation.isGestureCamera || query.filter.isActive {
                footprintCamera = camera?.position ?? model.cameraPosition
            }
        }
    }

    private struct FootprintDrawingQuery: Equatable, Sendable {
        let revision: Int
        let calibration: UInt
        let bounds: MKMapRect

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.revision == rhs.revision && lhs.calibration == rhs.calibration && lhs.bounds.minX == rhs.bounds.minX && lhs.bounds.minY == rhs.bounds.minY &&
                lhs.bounds.width == rhs.bounds.width && lhs.bounds.height == rhs.bounds.height
        }
    }

    private var footprintDrawingQuery: FootprintDrawingQuery? {
        guard footprintsActive, isActive, scenePhase == .active else { return nil }
        return FootprintDrawingQuery(revision: footprintDrawingRevision, calibration: coordinateSpace.revision, bounds: footprintDrawingBounds)
    }

    private func projectFootprintDrawing(_ query: FootprintDrawingQuery) async {
        let day = footprintDay
        let projection = coordinateSpace.renderProjection()
        let task = Task.detached(priority: .userInitiated) {
            ProjectedFootprintDrawing(day.drawing(in: query.bounds), projection: projection)
        }
        let drawing = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, footprintDrawingQuery == query else { return }
        footprintDrawing = drawing
    }

    private var footprintCities: [FootprintCity] {
        let available = model.availableCities
        var cities = available.filter { !$0.code.hasPrefix("custom_") }.map {
            FootprintCity(id: $0.code, name: CompanionPlacePresentation.cityName(code: $0.code, fallback: $0.name), center: $0.center)
        }
        for code in MapViewModel.knownCityCenters.keys.sorted() {
            guard let center = MapViewModel.knownCityCenters[code],
                  !cities.contains(where: { MapViewModel.cityCodeMatches($0.id, selected: code) ||
                      ($0.center.latitude == center.latitude && $0.center.longitude == center.longitude) }) else { continue }
            let fallback = code.replacingOccurrences(of: "-", with: " ").capitalized
            let name = CompanionPlacePresentation.cityName(code: code, fallback: fallback)
            cities.append(FootprintCity(id: code, name: name, center: center))
        }
        return cities
    }

    @ViewBuilder private var footprintJournal: some View {
        let selectedDate = footprintDay.rows.first { $0.id == footprintSelection }?.date
        let singleDate = footprintDays.count == 1 ? footprintDays.first?.date : nil
        let constraints: ((Date) -> Set<UUID>)? = footprintFilter.cityID == nil ? nil : { date in
            entries(on: date)
        }
        if footprintRecorder.hasStarted, let date = selectedDate ?? singleDate {
            FootprintJournalView(date: date, selectedID: footprintSelection, fixedDay: true,
                                 allowedEntryIDs: constraints?(date))
        } else if footprintRecorder.hasStarted, !footprintDays.isEmpty {
            FootprintHistoryJournal(days: footprintDays, scope: footprintHistory.title(for: footprintFilter),
                                    allowedEntryIDs: constraints)
        } else {
            FootprintJournalView()
        }
    }

    private func entries(on date: Date) -> Set<UUID> {
        Set(footprintDay.entries.lazy.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }.map(\.id))
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let origin = model.agentSearchOrigin else { return }
        model.searchThisArea()
        #if DEBUG
        traceGlobalResign("search-submit", phase: "before")
        #endif
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #if DEBUG
        traceGlobalResign("search-submit", phase: "after")
        #endif
        let previous = searchTask
        previous?.cancel()
        searchTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await model.webSearchPOIs(query: query, near: origin.coordinate, constrainWorkspaceResults: true)
        }
    }

    private func consumeMessageReveal() {
        guard isActive, messageRevealToken != consumedMessageRevealToken else { return }
        consumedMessageRevealToken = messageRevealToken
        footprintsActive = false
        pendingLocationCenter = nil
        searchTask?.cancel()
        searchQuery = ""; showsSearch = false
        model.lastWebSearchResult = nil
        selectedPlaceID = model.selectedExperience?.id
        page = selectedPlaceID == nil ? .browse : .place
        expand()
    }

    private func askCurrentArea() {
        guard let origin = model.agentSearchOrigin else { return }
        let area = CompanionHomeSearchArea(
            name: origin.source == "selected_city" ? currentCityName : companionText("companion.map.area", "这片地图"),
            latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude,
            cityCode: origin.source == "selected_city" ? (model.selectedCity ?? "map_area") : "map_area")
        let region = currentRegion ?? model.cameraPosition.region
        onAskArea(CompanionHomeAreaScope(area: area,
            query: searchQuery.isEmpty ? nil : searchQuery, category: model.selectedCategory?.rawValue,
            experienceIDs: Array(model.visibleExperiences.prefix(100)).map(\.id),
            latitudeDelta: region?.span.latitudeDelta, longitudeDelta: region?.span.longitudeDelta))
    }

    private var mapControls: some View {
        CompanionGlassGroup {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    filterOptions = level == .collapsed || page != .browse ? true : !filterOptions
                    page = .browse
                    expand()
                } label: {
                    Label(companionText("companion.panel.filters", "展开筛选"), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .companionGlass(in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if model.selectedCategory != nil {
                                Circle().fill(CompanionHomeStyle.accent).frame(width: 7, height: 7)
                                    .padding(3).accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filterOptions ? .isSelected : [])
                .accessibilityIdentifier("companion.panel.filters")
                Spacer(minLength: 0)
                Button { requestLocationCenter(.nearby) } label: {
                    Image(systemName: "location").font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44).companionGlass(in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel(companionText("companion.nearby.locate", "定位到我"))
                .accessibilityIdentifier("companion.nearby.locate")
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
    }

    private var collapsedSummary: some View {
        HStack(spacing: 8) {
            summaryOpen
            expandControl
        }
    }

    private var summaryOpen: some View {
        Button {
                if routeSession.active != nil && page == .route { page = .route }
                else if place != nil { page = .place }
                else { page = .browse }
                expand()
            } label: {
                Text(collapsedTitle).font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("companion.panel.open")
    }

    private var expandControl: some View {
        Button { expand() } label: {
                Image(systemName: "chevron.up").font(.system(size: 17))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(companionText("companion.panel.expand", "展开附近面板"))
            .accessibilityIdentifier("companion.panel.expand")
    }

    private var collapsedTitle: String {
        if page == .route, let active = routeSession.active { return active.placeName }
        if let place { return place.shortName }
        return store.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? companionText("companion.panel.prompt", "想去哪里…")
            : companionText("companion.panel.resumeDraft", "继续编辑草稿")
    }

    private var cityButton: some View {
        Button {
            sheet = .cities(model, onSelect: {
                pendingLocationCenter = nil
            })
        } label: {
            HStack(spacing: 4) {
                Text(currentCityName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .foregroundStyle(CompanionHomeStyle.ink)
            .frame(minWidth: 44, maxWidth: typeSize.isAccessibilitySize ? nil : 124, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentCityName)
        .accessibilityIdentifier("companion.nearby.city")
    }

    @ViewBuilder private var panelContent: some View {
        if typeSize.isAccessibilitySize || filterOptions {
            ScrollView(.horizontal, showsIndicators: false) {
                CompanionMapFilters(selected: model.selectedCategory, isFavoriteFilter: model.isFavoriteFilter, onSelect: selectCategory)
            }.frame(height: typeSize.isAccessibilitySize ? 72 : 44).padding(.vertical, 6)
        }
        switch page {
        case .place:
            if let place { placePeek(place) } else { browseContent }
        case .route:
            if let active = routeSession.active { routeContent(active) } else { browseContent }
        case .browse: browseContent
        }
        if let error = routeSession.errorMessage {
            HStack(alignment: .top, spacing: 6) {
                Text(error).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Button { routeSession.clearError() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel(companionText("companion.dismiss_notice", "关闭提示"))
            }.foregroundStyle(CompanionHomeStyle.secondaryInk)
        }
        if locationRequested && (location.authorizationStatus == .denied || location.authorizationStatus == .restricted) {
            Text(companionText("companion.nearby.locationDenied", "定位未开启，仍可移动地图查看。可在系统设置中更改权限。"))
                .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk).padding(.vertical, 8)
        }
    }

    private var panelHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { panelTitle; Spacer(minLength: 0); panelActions }
            VStack(alignment: .leading, spacing: 4) { panelTitle; panelActions }
        }
    }

    private var panelTitle: some View {
        Text(companionText(model.mapBrowseMode == .saved ? "map.workspace.saved" : "map.workspace.nearby",
                           model.mapBrowseMode == .saved ? "收藏" : "附近"))
            .font(.headline).frame(minHeight: 44)
    }

    private var panelActions: some View {
        Button { collapse() } label: {
            Image(systemName: "chevron.down").font(.system(size: 17))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CompanionHomeStyle.secondaryInk)
        .accessibilityLabel(companionText("companion.panel.collapse", "收起面板"))
        .accessibilityIdentifier("companion.panel.collapse")
    }

    private var browseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: askCurrentArea) {
                Label(companionText("companion.map.askArea", "问问这片区域"), systemImage: "bubble.left")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("companion.map.askArea")
                .disabled(model.agentSearchOrigin == nil)
            if let active = routeSession.active {
                Button { page = .route; expand() } label: {
                    Label(active.placeName, systemImage: "figure.walk")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("companion.route.open")
            }
            if model.visibleExperiences.isEmpty {
                if model.isSearchingWeb {
                    Text(companionText("companion.progress.search", "正在查找地点…"))
                        .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                } else if model.mapBrowseMode == .nearby,
                          let outcome = model.lastWebSearchResult, outcome.matches(searchQuery) {
                    Text(outcome.message).font(.subheadline)
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        .accessibilityIdentifier("companion.map.searchOutcome")
                    if outcome.status == .failed {
                        Button(companionText("companion.map.retrySearch", "重试这次搜索"), action: performSearch)
                            .frame(minHeight: 44)
                    } else {
                        Button(companionText("companion.map.editSearch", "修改搜索词")) { showsSearch = true }
                            .frame(minHeight: 44)
                    }
                } else if model.mapBrowseMode == .saved {
                    Text(companionText("map.workspace.empty.saved", "这个范围还没有收藏，可以切回附近挑选地点。"))
                        .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    Button(companionText("companion.map.browseNearby", "看看附近")) { model.setMapBrowseMode(.nearby) }
                        .frame(minHeight: 44)
                } else if model.messageResultIDs != nil {
                    Text(companionText("companion.map.sourceMissing", "这条回答的地点资料暂不可用，可回到原对话继续核对。"))
                        .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    if store.mapSource != nil {
                        Button(companionText("map.workspace.source.return", "回到原对话"), action: onReturnToSource)
                            .frame(minHeight: 44)
                    }
                } else {
                    Text(companionText("companion.nearby.empty", "这片区域还没有收录的体验，移动地图看看"))
                        .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    Button(companionText("companion.filter.clear", "清除筛选")) {
                        model.clearFilters(); model.refreshWorkspaceMapPreservingCamera()
                    }.frame(minHeight: 44)
                }
            } else {
                ForEach(model.visibleExperiences) { experience in
                    Button { choose(experience) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: experience.category.symbol).font(.subheadline).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(experience.shortName).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(sourceStatus(experience)).font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("companion.nearby.place.\(experience.id)")
                    Divider().accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.nearby.candidates")
    }

    private func placePeek(_ experience: Experience) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(experience.shortName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(sourceStatus(experience)).font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { askPlaceButton(experience); saveButton(experience) }
            } else {
                HStack(spacing: 12) { askPlaceButton(experience); saveButton(experience) }
            }
            Text(CompanionPlacePresentation.summary(experience.oneLiner,
                chinese: LanguageService.shared.effectiveLocale.language.languageCode?.identifier == "zh"))
                .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk).lineLimit(2)
            if let distance = CompanionPlacePresentation.distance(to: experience.coordinate, from: distanceOrigin, usesGPS: hasFreshGPS) {
                Text(distance).font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
            detailButton(experience)
            Button {
                Task { if await routeSession.start(experience: experience, cityCode: experience.location.cityCode) { page = .route; expand() } }
            } label: {
                Label(companionText("companion.route.start", "开始前往这里"), systemImage: "figure.walk")
                    .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("companion.route.start")
            .disabled(routeSession.isUpdating)
        }.padding(.top, 8)
    }

    private func askPlaceButton(_ experience: Experience) -> some View {
        Button { onAskPlace(experience) } label: {
            Label(companionText("map.workspace.askSelected", "聊聊这里"), systemImage: "bubble.left")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(CompanionHomeStyle.paper)
                .background(CompanionHomeStyle.ink, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("companion.map.askPlace")
    }

    private func detailButton(_ experience: Experience) -> some View {
        Button { sheet = .place(experience, distanceOrigin: distanceOrigin, usesGPS: hasFreshGPS) } label: {
            Text(companionText("companion.panel.detail", "查看地点")).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).frame(minHeight: 44)
                .foregroundStyle(CompanionHomeStyle.paper).background(CompanionHomeStyle.ink, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("companion.panel.detail")
    }
    private func saveButton(_ experience: Experience) -> some View {
        let saved = preferences.favoritedExperiences.contains(experience.id)
        return Button { preferences.toggleFavorite(experience.id) } label: {
            Label(saved ? companionText("companion.place.favorited", "已收藏") : companionText("companion.nearby.saved", "收藏"),
                  systemImage: saved ? "heart.fill" : "heart").font(.subheadline)
                .padding(.horizontal, 12).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier("companion.panel.save")
            .accessibilityAddTraits(saved ? .isSelected : [])
    }

    private func routeContent(_ active: CompanionRouteProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(companionText("companion.route.active", "路线进行中"), systemImage: "figure.walk").font(.subheadline)
                .foregroundStyle(CompanionHomeStyle.secondaryInk)
            Text(active.placeName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(String(format: companionText("companion.route.progress", "第 %d 站，共 %d 站"), active.stopIndex + 1, active.totalStops))
                .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
            Text(companionText("companion.route.timeUnknown", "时间待更新 · 到达后请标记"))
                .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            Button { Task { _ = await routeSession.arrived() } } label: {
                Label(companionText("companion.route.arrived", "标记已到达"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(CompanionHomeStyle.paper)
                    .background(CompanionHomeStyle.ink, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("companion.route.arrived")
                .disabled(routeSession.isUpdating)
            Button(companionText("companion.route.end", "结束这次路线")) { endingRoute = true }
                .disabled(routeSession.isUpdating)
                .frame(minHeight: 44).accessibilityIdentifier("companion.route.end")
                .confirmationDialog(companionText("companion.route.endQuestion", "结束这次路线？"), isPresented: $endingRoute, titleVisibility: .visible) {
                    Button(companionText("companion.route.end", "结束这次路线")) { Task { _ = await routeSession.end() } }
                    Button(companionText("companion.common.cancel", "取消"), role: .cancel) {}
                }
            if !routeSession.islandAvailable {
                Text(companionText("companion.route.islandUnavailable", "实时活动暂不可用，路线仍保留在这里。"))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
        }.padding(.top, 8).accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion.route.active")
    }

    private func selectCategory(_ value: ExperienceCategory) {
        model.selectWorkspaceCategory(model.selectedCategory == value ? nil : value)
        selectedPlaceID = nil; page = .browse
    }
    private func consumeRouteReveal() {
        guard isActive, routeSession.wantsRoutePresentation, routeSession.active != nil else { return }
        footprintsActive = false
        page = .route
        expand()
        routeSession.acknowledgeReveal()
    }
    private func choose(_ experience: Experience) {
        model.selectWorkspaceExperience(experience)
        model.focusOnExperience(experience)
        selectedPlaceID = experience.id; page = .place; expand()
    }
    private func expand() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.94)) {
            controlsVisible = true
            level = .expanded
        }
    }

    private func hideMapChrome() {
        guard controlsVisible, !voiceOver, !keyboardVisible, !typeSize.isAccessibilitySize else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            controlsVisible = false
            if !footprintsActive && page != .route { level = .collapsed }
        }
    }

    private func revealMapChrome() {
        guard !controlsVisible else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            controlsVisible = true
        }
    }
    #if DEBUG
    private func traceGlobalResign(_ reason: String, phase: String) {
        Self.inputLog.debug("event=nearby-global-resign reason=\(reason, privacy: .public) phase=\(phase, privacy: .public) active=\(isActive)")
    }
    private static let inputLog = Logger(subsystem: "com.solocompass.voice-composer", category: "focus")
    #endif
    private func collapse() {
        #if DEBUG
        traceGlobalResign("collapse", phase: "before")
        #endif
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #if DEBUG
        traceGlobalResign("collapse", phase: "after")
        #endif
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.94)) { level = .collapsed }
    }
    private func sourceStatus(_ experience: Experience) -> String {
        experience.sources.contains(where: { $0.url != nil })
            ? companionText("companion.place.sourceAvailable", "附来源链接 · 详情可核对")
            : companionText("companion.place.sourceUnverified", "收录资料 · 出发前请核实")
    }
    private struct AreaCell: Hashable {
        let latitude: Int
        let longitude: Int

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = Int((coordinate.latitude * 100).rounded())
            longitude = Int((coordinate.longitude * 100).rounded())
        }
    }

    private var viewportAreaCell: AreaCell? {
        guard isActive, scenePhase == .active, !footprintsActive,
              !model.workspaceViewportUnverified,
              let region = currentRegion ?? model.cameraPosition.region, region.span.latitudeDelta < 1.5,
              CLLocationCoordinate2DIsValid(region.center) else { return nil }
        return AreaCell(region.center)
    }

    private func readAreaLabel(_ cell: AreaCell) async {
        guard areaLabels[cell] == nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let location = CLLocation(latitude: Double(cell.latitude) / 100, longitude: Double(cell.longitude) / 100)
            // A rounded map viewport is enough for a district/city label.
            let result = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: .current)
            guard !Task.isCancelled, viewportAreaCell == cell, let address = result.first else { return }
            let city = address.locality ?? address.subAdministrativeArea ?? address.administrativeArea
            let district = address.subLocality
            let label = [district == city ? nil : district, city].compactMap { $0 }.joined(separator: " · ")
            guard !label.isEmpty else { return }
            if areaLabels.count >= 40 { areaLabels.removeAll(keepingCapacity: true) }
            areaLabels[cell] = label
        } catch { }
    }

    private var currentCityName: String {
        if let cell = viewportAreaCell, let label = areaLabels[cell] { return label }
        if let coordinate = currentRegion?.center ?? model.cameraPosition.region?.center {
            let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let city = model.availableCities.map { city in
                (city, center.distance(from: CLLocation(latitude: city.center.latitude, longitude: city.center.longitude)))
            }.min { $0.1 < $1.1 }
            if let (city, distance) = city, distance < 45_000 {
                return CompanionPlacePresentation.cityName(code: city.code, fallback: city.name)
            }
        } else if let city = model.availableCities.first(where: { $0.code == model.selectedCity }) {
            return CompanionPlacePresentation.cityName(code: city.code, fallback: city.name)
        }
        return companionText("companion.city.choose", "选择城市")
    }

    private var locationAuthorized: Bool {
        location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways
    }

    private var foregroundFix: LocationService.ForegroundFix? {
        guard locationRequested, isActive, scenePhase == .active else { return nil }
        return location.foregroundFix(now: max(Date(), locationClock))
    }

    private var reliableLocationCoordinate: CLLocationCoordinate2D? {
        guard let fix = foregroundFix, fix.quality == .reliable else { return nil }
        return fix.location.coordinate
    }

    private var hasFreshGPS: Bool { reliableLocationCoordinate != nil }

    @MapContentBuilder private var mapUserLocation: some MapContent {
        if locationRequested, locationAuthorized, isActive, scenePhase == .active {
            if let fix = foregroundFix, let coordinate = coordinateSpace.mapCoordinate(fix.location.coordinate) {
                MapCircle(center: coordinate, radius: fix.location.horizontalAccuracy)
                    .foregroundStyle(Color.blue.opacity(0.12))
                    .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                if fix.quality == .reliable {
                    Annotation("", coordinate: coordinate, anchor: .center) { currentLocationDot }
                }
            } else if !ProcessInfo.processInfo.arguments.contains("-uiTestBypassLocationPrompt") {
                UserAnnotation()
            }
        }
    }

    private var currentLocationDot: some View {
        Circle().fill(.blue)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
            .frame(width: 16, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(companionText("companion.nearby.currentPosition", "当前位置"))
            .accessibilityIdentifier("companion.map.currentPosition")
            .allowsHitTesting(false)
    }

    @ViewBuilder private var locationStatus: some View {
        if showsMapChrome {
            if explicitLocationRequest, pendingLocationCenter != nil {
                locationStatusLabel("companion.location.finding")
            } else if foregroundFix?.quality == .approximate {
                locationStatusLabel("companion.location.approximate")
            } else if locationTimedOut, foregroundFix == nil {
                locationStatusLabel(locationAuthorized ? "companion.location.unavailable" : "companion.nearby.locationDenied")
            } else if model.workspaceViewportUnverified && !footprintsActive {
                locationStatusLabel("map.coordinates.unavailable")
            } else if let target = footprintsActive ? footprintPresentation.target : nearbyPresentation.target,
                      coordinateSpace.mapCoordinate(target) == nil {
                locationStatusLabel("map.coordinates.unavailable")
            }
        }
    }

    private func locationStatusLabel(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: "Status of the location shown on the map"))
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .companionGlass(in: Capsule(), interactive: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("companion.map.locationStatus")
    }

    private func activateLocationIfNeeded() {
        guard isActive, scenePhase == .active else { return }
        if !hasOpenedNearby {
            hasOpenedNearby = true
            locationRequested = true
            if !footprintsActive, model.messageResultIDs == nil, routeSession.active == nil,
               model.mapBrowseMode == .nearby {
                pendingLocationCenter = .nearby
            }
        }
        if locationRequested && locationAuthorized {
            location.startUpdating()
            centerOnPendingLocation()
        }
    }

    private func requestLocationCenter(_ target: LocationCenter) {
        locationRequested = true
        explicitLocationRequest = true
        locationTimedOut = false
        pendingLocationCenter = target
        if location.authorizationStatus == .notDetermined {
            location.requestPermission()
        } else if locationAuthorized {
            location.startUpdating()
            if !hasFreshGPS { location.refreshForegroundFix() }
        } else {
            pendingLocationCenter = nil
            locationTimedOut = true
        }
        if target == .nearby { collapse() }
        centerOnPendingLocation()
    }

    private func centerOnPendingLocation(allowApproximate: Bool = false) {
        guard let target = pendingLocationCenter, scenePhase == .active,
              let fix = foregroundFix else { return }
        let precise = fix.quality == .reliable
        guard precise || (explicitLocationRequest && (allowApproximate || location.accuracyAuthorization == .reducedAccuracy)) else { return }
        let coordinate = fix.location.coordinate
        let broadSpan = max(1_000, fix.location.horizontalAccuracy * 3)
        let broadRegion = MKCoordinateRegion(center: coordinate, latitudinalMeters: broadSpan, longitudinalMeters: broadSpan)
        pendingLocationCenter = nil
        revealMapChrome()
        switch target {
        case .nearby:
            guard !footprintsActive else { return }
            if precise {
                model.followUserLocation(coordinate)
                mapCenter = coordinate
                currentRegion = model.cameraPosition.region
            } else {
                model.cameraPosition = .region(broadRegion)
            }
            nearbyPresentation.request(model.cameraPosition, fallback: coordinate, space: coordinateSpace)
            useNativeLocationCameraIfNeeded(nearbyPresentation, coordinate: coordinate)
        case .footprints:
            guard footprintsActive else { return }
            footprintSelection = nil
            footprintNeedsRecenter = footprintDay.hasMap
            footprintCamera = .region(precise ? footprintDay.liveRegion(centeredOn: coordinate) : broadRegion)
            footprintPresentation.request(footprintCamera, fallback: coordinate, space: coordinateSpace)
            useNativeLocationCameraIfNeeded(footprintPresentation, coordinate: coordinate)
        }
    }

    private func useNativeLocationCameraIfNeeded(_ presentation: MapCoordinatePresentation, coordinate: CLLocationCoordinate2D) {
        guard coordinateSpace.mapCoordinate(coordinate) == nil else { return }
        let position = presentation.position
        presentation.position = .userLocation(followsHeading: false, fallback: position.fallbackPosition ?? position)
    }

    private func freezeNativeLocationCamera(_ presentation: MapCoordinatePresentation, at camera: MapCamera) {
        guard presentation.position.fallbackPosition != nil, let fix = foregroundFix,
              CLLocation(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
                .distance(from: fix.location) <= fix.location.horizontalAccuracy + 1_500 else { return }
        presentation.position = .camera(camera)
    }

    private var distanceOrigin: CLLocationCoordinate2D? {
        if let coordinate = reliableLocationCoordinate { return coordinate }
        if model.workspaceViewportUnverified { return nil }
        return mapCenter ?? model.cameraPosition.coordinateCenter
    }
    private func annotationTitle(_ item: MapItem) -> String {
        switch item { case .single(let value): return value.shortName; case .cluster(let cluster): return "\(cluster.count)" }
    }
    private func annotationID(_ item: MapItem) -> String {
        switch item { case .single(let value): return "companion.nearby.pin.\(value.id)"; case .cluster(let cluster): return "companion.nearby.cluster.\(cluster.id)" }
    }
    private func marker(_ item: MapItem) -> some View {
        let selected: Bool
        if case .single(let value) = item { selected = selectedPlaceID == value.id } else { selected = false }
        return Group {
            switch item {
            case .single(let value): Image(systemName: value.category.symbol)
            case .cluster(let cluster): Text("\(cluster.count)").fontWeight(.semibold)
            }
        }
        .font(selected ? .body : .caption)
        .foregroundStyle(CompanionHomeStyle.paper)
        .frame(width: selected ? 40 : 28, height: selected ? 40 : 28)
        .background(CompanionHomeStyle.ink.opacity(selected ? 1 : 0.7), in: Circle())
        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
    }
    private func select(_ item: MapItem) {
        switch item {
        case .single(let value): choose(value)
        case .cluster(let cluster):
            model.cameraPosition = .region(MKCoordinateRegion(center: cluster.coordinate,
                span: MKCoordinateSpan(latitudeDelta: max(model.currentSpanLatitudeDelta / 3, 0.005),
                                       longitudeDelta: max(model.currentSpanLatitudeDelta / 3, 0.005))))
        }
    }
}

func companionMapText(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, value: fallback, comment: "Continuous companion map and people")
}

private struct CompanionMapHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 160
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CompanionMapControlsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
