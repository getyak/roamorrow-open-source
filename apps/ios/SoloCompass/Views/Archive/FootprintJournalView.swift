import CoreLocation
import MapKit
import Photos
import SwiftUI
import UIKit

enum FootprintText {
    static func text(_ key: String) -> String {
        let qualifiedKey = "footprints." + key
        return NSLocalizedString(qualifiedKey, comment: "")
    }
}

enum FootprintStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.83, blue: 0.80, alpha: 1)
            : UIColor(red: 0.05, green: 0.40, blue: 0.41, alpha: 1)
    })
}


extension FootprintText {
    static func title(_ entry: FootprintEntry) -> String {
        if entry.kind == .photo { return text("photo") }
        if let label = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        return text("visit")
    }

    static func timeLabel(_ entry: FootprintEntry) -> String {
        let start = entry.date.formatted(date: .omitted, time: .shortened)
        guard entry.displayedMinutes != nil, let end = entry.end else { return start }
        let departure = Date(timeIntervalSince1970: Double(end) / 1000)
        let sameDay = Calendar.current.isDate(entry.date, inSameDayAs: departure)
        let finish = departure.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return String.localizedStringWithFormat(text("timeRange"), start, finish)
    }

    static func durationLabel(_ minutes: Int) -> String {
        let duration = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return String.localizedStringWithFormat(text("estimatedDuration"), duration)
    }

}

extension FootprintStyle {
    static func entryTint(_ entry: FootprintEntry) -> Color { entry.kind == .photo ? .pink : accent }
}

struct FootprintMapDay: Sendable {
    let entries: [FootprintEntry]
    let rows: [FootprintEntry]
    let stops: [FootprintEntry]
    let photos: [FootprintEntry]
    static let photoMarkerLimit = 96
    static let routeLimit = 72
    static let routePointLimit = 128
    private let routeBounds: [MKMapRect]
    let routes: [[CLLocationCoordinate2D]]
    let isolatedPoints: [CLLocationCoordinate2D]
    let routeEndpoint: CLLocationCoordinate2D?
    let calibrationCoordinates: [CLLocationCoordinate2D]

    init(entries: [FootprintEntry] = [], breakBefore: Set<UUID> = [], allowedEntryIDs: Set<UUID>? = nil) {
        self.entries = allowedEntryIDs.map { ids in entries.filter { ids.contains($0.id) } } ?? entries
        rows = self.entries.filter { $0.kind != .point }
        stops = rows.filter { $0.kind == .visit }
        photos = rows.filter { $0.kind == .photo && $0.coordinate != nil }
        var segments: [[CLLocationCoordinate2D]] = []
        var previous: FootprintEntry?
        for entry in entries where entry.kind == .point {
            if let allowedEntryIDs, !allowedEntryIDs.contains(entry.id) {
                previous = nil
                continue
            }
            guard let coordinate = entry.coordinate else { continue }
            if !breakBefore.contains(entry.id), let old = previous, let oldCoordinate = old.coordinate,
               old.segment == entry.segment,
               !FootprintEntry.startsNewSegment(elapsed: entry.date.timeIntervalSince(old.date),
                     distance: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                         .distance(from: CLLocation(latitude: oldCoordinate.latitude, longitude: oldCoordinate.longitude))) {
                segments[segments.count - 1].append(coordinate)
            } else {
                segments.append([coordinate])
            }
            previous = entry
        }
        routes = segments.filter { $0.count > 1 }
        routeBounds = routes.map { segment in
            segment.reduce(MKMapRect.null) { bounds, coordinate in
                let point = MKMapPoint(coordinate)
                return bounds.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
        }
        isolatedPoints = segments.compactMap { $0.count == 1 ? $0.first : nil }
        routeEndpoint = segments.last.flatMap { $0.count > 1 ? $0.last : nil }
        var cells: Set<String> = []
        calibrationCoordinates = entries.compactMap(\.coordinate).filter { coordinate in
            let cell = "\(Int(floor(coordinate.latitude * 10)))|\(Int(floor(coordinate.longitude * 10)))"
            return cells.insert(cell).inserted
        }
    }

    /// Keep a single representative per part of the visible map. Zooming or
    /// panning recalculates these cells against the full photo catalogue.
    func photoMarkers(in bounds: MKMapRect) -> [FootprintEntry] {
        let columns = 8
        let rows = Self.photoMarkerLimit / columns
        let world = MKMapRect.world.width
        let width = min(bounds.width, world)
        guard width > 0, bounds.height > 0, bounds.minX.isFinite, bounds.minY.isFinite else { return [] }
        var visible: [FootprintEntry] = []
        var cells = Set<Int>()
        for photo in photos.reversed() {
            if Task.isCancelled { return [] }
            guard let coordinate = photo.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let point = MKMapPoint(coordinate)
            let wrapped = (point.x - bounds.minX).truncatingRemainder(dividingBy: world)
            let x = wrapped < 0 ? wrapped + world : wrapped
            let y = point.y - bounds.minY
            guard x < width, y >= 0, y < bounds.height else { continue }
            let column = min(columns - 1, Int(x / width * Double(columns)))
            let row = min(rows - 1, Int(y / bounds.height * Double(rows)))
            if cells.insert(row * columns + column).inserted {
                visible.append(photo)
                if visible.count == Self.photoMarkerLimit { break }
            }
        }
        return visible
    }

    struct Drawing: Sendable {
        struct Trail: Identifiable, Sendable {
            let id: Int
            let coordinates: [CLLocationCoordinate2D]
            let isLatest: Bool
        }

        let trails: [Trail]
        let isolatedPoints: [CLLocationCoordinate2D]
        let stops: [FootprintEntry]
        let photos: [FootprintEntry]
        let endpoint: CLLocationCoordinate2D?

        static let empty = Self(trails: [], isolatedPoints: [], stops: [], photos: [], endpoint: nil)
    }

    func drawing(in bounds: MKMapRect) -> Drawing {
        let world = MKMapRect.world.width
        let viewportCopies = [bounds, bounds.offsetBy(dx: -world, dy: 0), bounds.offsetBy(dx: world, dy: 0)]
        func isVisible(_ point: CLLocationCoordinate2D) -> Bool {
            let nativePoint = MKMapPoint(point)
            return viewportCopies.contains { $0.contains(nativePoint) }
        }
        let maximum = Self.routePointLimit
        let trails = routes.indices.reversed().lazy.filter { index in
            viewportCopies.contains { $0.intersects(routeBounds[index]) }
        }.prefix(Self.routeLimit).map { index in
            let route = routes[index]
            let points = route.count <= maximum ? route : (0..<maximum).map {
                route[$0 * (route.count - 1) / (maximum - 1)]
            }
            return Drawing.Trail(id: index, coordinates: points, isLatest: index == routes.indices.last)
        }
        let dots = Array(isolatedPoints.reversed().lazy.filter(isVisible).prefix(96))
        let visits = Array(stops.reversed().lazy.filter { $0.coordinate.map(isVisible) ?? false }.prefix(96))
        let endpoint = routeEndpoint.flatMap { isVisible($0) ? $0 : nil }
        return Drawing(trails: Array(trails.reversed()), isolatedPoints: dots, stops: visits,
                       photos: photoMarkers(in: bounds), endpoint: endpoint)
    }

    func liveRegion(centeredOn position: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let here = CLLocation(latitude: position.latitude, longitude: position.longitude)
        let nearby = routes.last?.suffix(Self.routePointLimit).reduce(CLLocationDistance.zero) { furthest, point in
            let distance = here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            return distance <= 2_000 ? max(distance, furthest) : furthest
        } ?? 0
        let span = max(1_200, min(4_800, nearby * 2.7))
        return MKCoordinateRegion(center: position, latitudinalMeters: span, longitudinalMeters: span)
    }

    var latestTrailFrame: CameraFrame? {
        guard let latest = routes.last else { return nil }
        return Self.frame(latest, focus: nil)
    }

    var hasMap: Bool {
        !routes.isEmpty || !isolatedPoints.isEmpty || !photos.isEmpty || stops.contains { $0.coordinate != nil }
    }

    var cameraPosition: MapCameraPosition? {
        cameraPosition(focusRecent: false)
    }

    func cameraPosition(focusRecent: Bool) -> MapCameraPosition? {
        cameraFrame(focusRecent: focusRecent)?.position
    }

    enum CameraFrame: Sendable {
        case rect(MKMapRect)
        case region(MKCoordinateRegion)

        var position: MapCameraPosition {
            switch self {
            case .rect(let rect): .rect(rect)
            case .region(let region): .region(region)
            }
        }
    }

    func cameraFrame(focusRecent: Bool) -> CameraFrame? {
        let coordinates = routes.flatMap { $0 } + rows.compactMap(\.coordinate) + isolatedPoints
        guard !coordinates.isEmpty else { return nil }
        let focus = focusRecent
            ? rows.lazy.reversed().compactMap(\.coordinate).first ?? entries.lazy.reversed().compactMap(\.coordinate).first
            : nil
        return Self.frame(coordinates, focus: focus)
    }

    private static func frame(_ coordinates: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D?) -> CameraFrame {
        let points = coordinates.map(MKMapPoint.init)
        let world = MKMapRect.world.width
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let crossesDateLine = maxX - minX > world / 2
        var cut = 0.0
        if crossesDateLine {
            let longitudes = points.map(\.x).sorted()
            var largestGap = minX + world - maxX
            for (left, right) in zip(longitudes, longitudes.dropFirst()) where right - left > largestGap {
                largestGap = right - left
                cut = right
            }
        }
        var rect = MKMapRect.null
        for point in points {
            let x = point.x < cut ? point.x + world : point.x
            rect = rect.union(.init(x: x, y: point.y, width: 1, height: 1))
        }
        // At world scale the portrait map can make every recorded place hard
        // to see. Start over recent activity while leaving the full map live.
        if let focus, rect.width > world / 4 || rect.height > world / 3 {
            let center = CLLocation(latitude: focus.latitude, longitude: focus.longitude)
            let nearby = coordinates.filter {
                abs($0.latitude - focus.latitude) < 0.7 &&
                    center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= 75_000
            }
            return Self.frame(nearby.isEmpty ? [focus] : nearby, focus: nil)
        }
        let padded = rect.insetBy(dx: -max(rect.width * 0.15, 1_600), dy: -max(rect.height * 0.17, 1_600))
        if crossesDateLine {
            let center = MKMapPoint(x: padded.midX.truncatingRemainder(dividingBy: world), y: padded.midY).coordinate
            let north = MKMapPoint(x: 0, y: max(0, padded.minY)).coordinate.latitude
            let south = MKMapPoint(x: 0, y: min(world, padded.maxY)).coordinate.latitude
            let span = MKCoordinateSpan(latitudeDelta: min(170, north - south),
                                        longitudeDelta: min(359, padded.width / world * 360))
            return .region(MKCoordinateRegion(center: center, span: span))
        }
        return .rect(padded)
    }
}

struct ProjectedFootprintDrawing: Sendable {
    struct Marker: Identifiable, Sendable {
        let entry: FootprintEntry
        let coordinate: CLLocationCoordinate2D
        var id: UUID { entry.id }
    }

    let trails: [FootprintMapDay.Drawing.Trail]
    let isolatedPoints: [CLLocationCoordinate2D]
    let markers: [Marker]
    let endpoint: CLLocationCoordinate2D?

    static let empty = Self(trails: [], isolatedPoints: [], markers: [], endpoint: nil)

    init(_ drawing: FootprintMapDay.Drawing, projection: MapKitCoordinateSpace.RenderProjection) {
        var renderedTrails: [FootprintMapDay.Drawing.Trail] = []
        for trail in drawing.trails {
            if Task.isCancelled { break }
            var run: [CLLocationCoordinate2D] = []
            var part = 0
            func finishRun() {
                if run.count > 1 {
                    let id = trail.id * FootprintMapDay.routePointLimit + part
                    renderedTrails.append(.init(id: id, coordinates: run, isLatest: trail.isLatest))
                }
                part += 1
                run.removeAll(keepingCapacity: true)
            }
            for point in trail.coordinates {
                if let coordinate = projection.coordinate(for: point) { run.append(coordinate) }
                else { finishRun() }
            }
            finishRun()
        }
        trails = renderedTrails
        isolatedPoints = drawing.isolatedPoints.compactMap(projection.coordinate)
        markers = (drawing.stops + drawing.photos).compactMap { entry in
            guard let coordinate = entry.coordinate.flatMap(projection.coordinate) else { return nil }
            return Marker(entry: entry, coordinate: coordinate)
        }
        endpoint = drawing.endpoint.flatMap(projection.coordinate)
    }

    private init(trails: [FootprintMapDay.Drawing.Trail], isolatedPoints: [CLLocationCoordinate2D],
                 markers: [Marker], endpoint: CLLocationCoordinate2D?) {
        self.trails = trails
        self.isolatedPoints = isolatedPoints
        self.markers = markers
        self.endpoint = endpoint
    }
}

struct FootprintMapContent: MapContent {
    let drawing: ProjectedFootprintDrawing
    let selectedID: UUID?
    let title: (FootprintEntry) -> String
    let selectionHint: String
    let select: (UUID) -> Void

    var body: some MapContent {
        ForEach(drawing.trails) { trail in
            MapPolyline(coordinates: trail.coordinates)
                .stroke(Color(uiColor: .systemBackground).opacity(0.9),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: trail.coordinates)
                .stroke(FootprintStyle.accent.opacity(trail.isLatest ? 1 : 0.58),
                        style: StrokeStyle(lineWidth: trail.isLatest ? 4 : 2.5, lineCap: .round, lineJoin: .round))
        }
        ForEach(Array(drawing.isolatedPoints.enumerated()), id: \.offset) { _, coordinate in
            Annotation("", coordinate: coordinate, anchor: .center) {
                Circle().fill(FootprintStyle.accent.opacity(0.58))
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground).opacity(0.9), lineWidth: 1))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        if let routeEndpoint = drawing.endpoint {
            Annotation("", coordinate: routeEndpoint, anchor: .center) {
                Circle().fill(FootprintStyle.accent)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground).opacity(0.9), lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
        }
        ForEach(drawing.markers) { marker in
            let entry = marker.entry
            Annotation("", coordinate: marker.coordinate, anchor: .center) {
                Button { select(entry.id) } label: {
                    Image(systemName: entry.kind == .photo ? "heart.fill" : "mappin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selectedID == entry.id ? Color(uiColor: .systemBackground) : FootprintStyle.entryTint(entry))
                        .frame(width: 24, height: 24)
                        .background(selectedID == entry.id ? FootprintStyle.entryTint(entry) : FootprintStyle.entryTint(entry), in: Circle())
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground).opacity(0.38), lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 2, x: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(entry))
                .accessibilityHint(FootprintText.text(selectionHint))
                .accessibilityIdentifier("footprints.marker.\(entry.id.uuidString)")
            }
        }
    }
}

@MainActor
struct FootprintCalendar: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date

    private func t(_ key: String) -> String { FootprintText.text(key) }

    var body: some View {
        NavigationStack {
            ScrollView {
                DatePicker(t("day"), selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal, 16)
            }
            .navigationTitle(t("day"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("today")) {
                        date = Date()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("done")) { dismiss() }
                        .accessibilityIdentifier("footprints.calendarDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

@MainActor
struct FootprintSession: ViewModifier {
    var ready: Bool
    @Environment(\.scenePhase) private var phase
    @State private var recorder = FootprintRecorder.shared
    @State private var account = EmailAccountService.shared
    @State private var network = NetworkMonitor.shared
    @State private var showSetup = false

    func body(content: Content) -> some View {
        content
            .onChange(of: ready, initial: true) { _, _ in update() }
            .onChange(of: phase) { _, _ in update() }
            .onChange(of: account.identityGeneration) { _, _ in
                guard ready else { return }
                recorder.refresh(foreground: phase == .active)
            }
            .onChange(of: network.isConnected) { _, online in
                if ready && online { recorder.networkRestored() }
            }
            .sheet(isPresented: $showSetup, onDismiss: { recorder.deferSetup() }) {
                FootprintJournalView()
            }
    }

    private func update() {
        guard ready else { return }
        recorder.refresh(foreground: phase == .active)
        if phase == .active && recorder.scopeNeedsSetup { showSetup = true }
    }
}

@MainActor
struct FootprintJournalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recorder = FootprintRecorder.shared
    @State private var date: Date
    @State private var day = FootprintMapDay()
    @State private var drawingRevision = 0
    @State private var renderedDrawing = ProjectedFootprintDrawing.empty
    @State private var loadingDay = true
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraPresentation = MapCoordinatePresentation()
    @State private var coordinateSpace = MapKitCoordinateSpace.shared
    @State private var framedDay = false
    @State private var selectedID: UUID?
    @State private var favorites = true
    @State private var showingCalendar = false
    @State private var showingSettings = false
    @State private var selectedPhoto: FootprintEntry?
    @State private var namingStop: FootprintEntry?
    private let fixedDay: Bool
    private let allowedEntryIDs: Set<UUID>?

    private enum Target: Hashable { case map, entry(UUID) }

    private func t(_ key: String) -> String { FootprintText.text(key) }
    init(date: Date = Date(), selectedID: UUID? = nil, fixedDay: Bool = false,
         allowedEntryIDs: Set<UUID>? = nil) {
        _date = State(initialValue: date)
        _selectedID = State(initialValue: selectedID)
        self.fixedDay = fixedDay
        self.allowedEntryIDs = allowedEntryIDs
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if recorder.hasStarted {
                            journal(scroll: scroll)
                        } else {
                            setup
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 660)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(t("title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    FootprintSyncControl()
                    Button(t("recordSettings"), systemImage: "slider.horizontal.3") { showingSettings = true }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("footprints.recordSettings")
                }
            }
            .sheet(item: $namingStop) { entry in
                FootprintStopEditor(entry: entry)
            }
            .sheet(isPresented: $showingCalendar) { FootprintCalendar(date: $date) }
            .sheet(isPresented: $showingSettings) { FootprintSettingsView() }
            .sheet(item: $selectedPhoto) { photo in
                photoPreview(photo)
            }
        }
        .tint(FootprintStyle.accent)
        .onChange(of: camera, initial: true) { _, position in
            guard let anchor = position.coordinateCenter else {
                cameraPresentation.position = .automatic
                return
            }
            cameraPresentation.request(position, fallback: anchor, space: coordinateSpace)
        }
        .onChange(of: coordinateSpace.revision) { _, _ in
            guard let anchor = camera.coordinateCenter else { return }
            _ = cameraPresentation.recover(camera, fallback: anchor, space: coordinateSpace)
        }
        .task(id: calibrationTargets) {
            await MapCalibrationTarget.refresh(calibrationTargets, using: coordinateSpace)
        }
        .task(id: drawingKey) { await projectDrawing() }
        .task(id: scenePhase == .active ? JournalQuery(date: date, scope: recorder.historyScope) : nil) {
            if scenePhase == .active { await refreshEntries() }
        }
        .onChange(of: date) { old, new in
            guard !Calendar.current.isDate(old, inSameDayAs: new) else { return }
            showDay(FootprintMapDay())
            loadingDay = true
            selectedID = nil
            framedDay = false
            camera = .automatic
        }
        .onChange(of: recorder.historyScope) { _, _ in
            showDay(FootprintMapDay())
            selectedPhoto = nil
            selectedID = nil
            namingStop = nil
            framedDay = false
            camera = .automatic
        }
    }

    @ViewBuilder private func journal(scroll: ScrollViewProxy) -> some View {
        let dayRows = day.rows
        dayHeader
        if day.hasMap {
            routeMap { id in
                selectedID = id
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    scroll.scrollTo(Target.entry(id), anchor: .center)
                }
            }
            .id(Target.map)
        }
        if day.entries.isEmpty && loadingDay {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 14)
        } else if day.entries.isEmpty {
            ContentUnavailableView(t("empty"), systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                   description: Text(t(isToday ? "emptyDetail" : "emptyPast")))
                .padding(.vertical, 14)
        } else if dayRows.isEmpty {
            if recorder.isEnabled && isToday {
                Label(t("pointsOnly"), systemImage: "mappin")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(dayRows) { entry in
                    journalRow(entry) {
                        guard let coordinate = entry.coordinate else { return }
                        selectedID = entry.id
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            camera = .region(.init(center: coordinate, latitudinalMeters: 550, longitudinalMeters: 550))
                            scroll.scrollTo(Target.map, anchor: .top)
                        }
                    }
                    .id(Target.entry(entry.id))
                    if entry.id != dayRows.last?.id { Divider().padding(.leading, 54) }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 21))
        }
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if fixedDay {
                    dateHeading
                } else {
                    Button {
                        showingCalendar = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            dateHeading
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("day"))
                    .accessibilityValue(date.formatted(date: .complete, time: .omitted))
                    .accessibilityIdentifier("footprints.date")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        dayArrow(-1, icon: "chevron.left", label: "previous")
                        Divider().frame(height: 16)
                        dayArrow(1, icon: "chevron.right", label: "next").disabled(isToday)
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }
            }
            if recorder.storageFailed {
                Label(t("storageError"), systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if isToday {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { recordingControls }
                    VStack(alignment: .leading, spacing: 5) { recordingControls }
                }
            } else if !day.entries.isEmpty {
                daySummary
            }
        }
    }

    private var dateHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.year().month(.abbreviated).day()))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder private var recordingControls: some View {
        Button { showingSettings = true } label: {
            Label(recorder.recordingStatus, systemImage: recorder.isEnabled ? "location.fill" : "pause.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(recorder.authorization == .authorizedAlways && recorder.isEnabled ? FootprintStyle.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityHint(t("recordSettings"))
        if recorder.isEnabled && recorder.favoritesEnabled && recorder.photosAuthorization == .notDetermined &&
            (recorder.authorization == .authorizedAlways || recorder.authorization == .authorizedWhenInUse) {
            Button(t("allowPhotos")) { Task { await recorder.requestPhotos() } }
                .font(.footnote.weight(.medium))
        }
    }

    private var daySummary: some View {
        let visits = day.rows.count { $0.kind == .visit }
        let photos = day.rows.count { $0.kind == .photo }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(spacing: 13))
        return layout {
            if !day.routes.isEmpty { metric(day.routes.count, key: "segmentCount", icon: "point.topleft.down.to.point.bottomright.curvepath") }
            if day.routes.isEmpty && !day.isolatedPoints.isEmpty {
                metric(day.isolatedPoints.count, key: "pointCount", icon: "circle.dotted")
            }
            if visits > 0 { metric(visits, key: "visitCount", icon: "mappin") }
            if photos > 0 { metric(photos, key: "photoCount", icon: "heart") }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func metric(_ count: Int, key: String, icon: String) -> some View {
        Label(String.localizedStringWithFormat(t(key), count), systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private func dayArrow(_ delta: Int, icon: String, label: String) -> some View {
        Button {
            if let target = Calendar.current.date(byAdding: .day, value: delta, to: date) {
                date = min(Date(), target)
            }
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(t(label))
    }

    private var calibrationTargets: [MapCalibrationTarget] {
        guard scenePhase == .active else { return [] }
        return MapCalibrationTarget.targets(for: day.calibrationCoordinates)
    }

    private func routeMap(select: @escaping (UUID) -> Void) -> some View {
        Map(position: Binding(get: { cameraPresentation.position }, set: { position in
            _ = cameraPresentation.receive(position, space: coordinateSpace)
        })) {
            FootprintMapContent(drawing: renderedDrawing, selectedID: selectedID, title: title,
                                selectionHint: "showInJournal", select: select)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 307)
        .overlay(alignment: .bottom) {
            if let anchor = camera.coordinateCenter, coordinateSpace.mapCoordinate(anchor) == nil {
                Text(t("mapUnavailable")).font(.caption)
                    .padding(8).background(.regularMaterial, in: Capsule()).padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                selectedID = nil
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { frameDay() }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel(t("showFullDay"))
            .accessibilityIdentifier("footprints.fullDay")
        }
        .clipShape(.rect(cornerRadius: 23))
    }

    private func title(_ entry: FootprintEntry) -> String {
        FootprintText.title(entry)
    }

    private func journalRow(_ entry: FootprintEntry, focus: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button {
                if entry.kind == .photo { selectedPhoto = entry } else { focus() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.kind == .photo ? "heart.fill" : "mappin")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FootprintStyle.entryTint(entry))
                        .frame(width: 32, height: 32)
                        .background(FootprintStyle.entryTint(entry).opacity(0.11), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title(entry))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(FootprintText.timeLabel(entry))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let minutes = entry.displayedMinutes {
                            Text(FootprintText.durationLabel(minutes))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(FootprintStyle.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(FootprintStyle.accent.opacity(0.09), in: Capsule())
                        } else if entry.kind == .photo && entry.coordinate == nil {
                            Text(t("noPhotoLocation")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.kind == .photo {
                        FootprintPhotoImage(entry: entry, isThumbnail: true)
                            .frame(width: 64, height: 53)
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.kind != .photo && entry.coordinate == nil)
            .accessibilityHint(t(entry.kind == .photo ? "openPhoto" : "locate"))
            .accessibilityIdentifier("footprints.entry.\(entry.id.uuidString)")

            if entry.kind == .visit || entry.coordinate != nil {
                Menu {
                    if entry.coordinate != nil { Button(t("locate"), systemImage: "location", action: focus) }
                    if entry.kind == .visit {
                        Button(t("nameStop"), systemImage: "pencil") { namingStop = entry }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(t("entryActions"))
                .accessibilityIdentifier("footprints.actions.\(entry.id.uuidString)")
            }
        }
        .padding(.trailing, 4)
        .background(selectedID == entry.id ? FootprintStyle.entryTint(entry).opacity(0.08) : .clear)
        .clipShape(.rect(cornerRadius: 17))
    }

    private func photoPreview(_ entry: FootprintEntry) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                FootprintPhotoImage(entry: entry, isThumbnail: false)
                    .accessibilityLabel(t("photo"))
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(18)
            .navigationTitle(t("photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("done")) { selectedPhoto = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 21) {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(FootprintStyle.accent)
                    .frame(width: 60, height: 60)
                    .background(FootprintStyle.accent.opacity(0.11), in: .rect(cornerRadius: 19))
                    .accessibilityHidden(true)
                Text(t("setupTitle"))
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(t("setupDetail"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 17)

            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: $favorites) {
                    Label(t("favorites"), systemImage: "heart")
                }
                .padding(14)

                if !recorder.hasAccount {
                    Divider().padding(.leading, 14)
                    NavigationLink {
                        AccountSetupView(isSettings: true)
                    } label: {
                        Label(t("signIn"), systemImage: "envelope")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .accessibilityIdentifier("footprints.signIn")
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))

            VStack(spacing: 9) {
                Button {
                    recorder.enable(favorites: favorites, cloud: recorder.cloudEnabled)
                } label: {
                    Text(t("enable")).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("footprints.enable")

                Button(t("later")) { recorder.deferSetup(); dismiss() }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private struct JournalQuery: Equatable {
        let date: Date
        let scope: String
    }

    private func refreshEntries() async {
        let query = JournalQuery(date: date, scope: recorder.historyScope)
        if !framedDay { showDay(FootprintMapDay()) }
        loadingDay = true
        var loadedRevision: Int?
        while !Task.isCancelled {
            let revision = recorder.revision
            if loadedRevision != revision {
                if loadedRevision == nil && day.entries.isEmpty {
                    if let movement = try? await recorder.journalDay(on: query.date, allowedEntryIDs: allowedEntryIDs, includePhotos: false),
                       !Task.isCancelled, query == JournalQuery(date: date, scope: recorder.historyScope) {
                        showDay(movement)
                        if !framedDay { frameDay() }
                    }
                }
                let completed = try? await recorder.journalDay(on: query.date, allowedEntryIDs: allowedEntryIDs, includePhotos: true)
                guard !Task.isCancelled, query == JournalQuery(date: date, scope: recorder.historyScope) else { return }
                if let completed {
                    showDay(completed)
                    if !framedDay { frameDay() }
                }
                loadingDay = false
                loadedRevision = revision
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private struct DrawingKey: Equatable {
        let day: Int
        let calibration: UInt
    }

    private var drawingKey: DrawingKey { .init(day: drawingRevision, calibration: coordinateSpace.revision) }

    private func showDay(_ value: FootprintMapDay) {
        day = value
        if !value.hasMap { renderedDrawing = .empty }
        drawingRevision &+= 1
    }

    private func projectDrawing() async {
        let key = drawingKey
        let day = day
        let projection = coordinateSpace.renderProjection()
        if !day.hasMap { return }
        let task = Task.detached(priority: .userInitiated) {
            ProjectedFootprintDrawing(day.drawing(in: .world), projection: projection)
        }
        let drawing = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, key == drawingKey else { return }
        renderedDrawing = drawing
    }

    private func frameDay() {
        if let position = day.cameraPosition {
            camera = position
            framedDay = true
        }
    }

}

@MainActor
struct FootprintStopEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ExperienceService.self) private var experiences
    @State private var recorder = FootprintRecorder.shared
    @State private var scope = FootprintRecorder.shared.historyScope
    @State private var name: String
    @State private var selectedID: String?
    @State private var previouslyNamed: [FootprintEntry] = []
    @State private var saveFailed = false
    let entry: FootprintEntry

    init(entry: FootprintEntry) {
        self.entry = entry
        _name = State(initialValue: entry.label ?? "")
    }

    private var candidates: [FootprintPlaceCandidate] {
        guard let radius = entry.placeSearchRadius, let coordinate = entry.coordinate else { return [] }
        return entry.placeCandidates(from: experiences.getExperiences(near: coordinate, radiusKm: radius / 1000),
                                     previouslyNamed: previouslyNamed)
    }

    var body: some View {
        NavigationStack {
            Form {
                let suggestions = candidates
                if !suggestions.isEmpty {
                    Section(FootprintText.text("suggestedPlaces")) {
                        ForEach(suggestions) { candidate in
                            Button {
                                name = candidate.name
                                selectedID = candidate.id
                                saveFailed = false
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.name).foregroundStyle(.primary)
                                        let distance = Measurement(value: candidate.distance.rounded(), unit: UnitLength.meters)
                                        let detail = [candidate.address, distance.formatted(.measurement(width: .abbreviated))]
                                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedID == candidate.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                                }
                            }
                            .accessibilityAddTraits(selectedID == candidate.id ? .isSelected : [])
                        }
                    }
                }

                Section {
                    TextField(FootprintText.text("placeName"), text: Binding(get: { name }, set: { value in
                        name = value
                        selectedID = nil
                        saveFailed = false
                    }))
                    .accessibilityIdentifier("footprints.stopName")
                    .submitLabel(.done)
                    .onSubmit(save)
                    if saveFailed {
                        Text(FootprintText.text("storageError")).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(FootprintText.text("nameStop"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FootprintText.text("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FootprintText.text("save"), action: save).accessibilityIdentifier("footprints.saveStop")
                }
            }
        }
        .task {
            if entry.placeSearchRadius != nil { previouslyNamed = await recorder.namedVisits(before: entry) }
        }
        .onChange(of: recorder.historyScope) { _, current in if current != scope { dismiss() } }
    }

    private func save() {
        if recorder.nameStop(entry, name: name, scope: scope) { dismiss() }
        else { saveFailed = true }
    }
}

private struct FootprintPhotoImage: View {
    let entry: FootprintEntry
    let isThumbnail: Bool
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
                    .aspectRatio(contentMode: isThumbnail ? .fill : .fit)
            } else if !finished && !isThumbnail {
                ProgressView()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FootprintStyle.accent.opacity(0.08))
            }
        }
        .task(id: entry.version) {
            image = nil
            finished = false
            let data = await FootprintRecorder.shared.photoPreview(for: entry)
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
            finished = true
        }
    }
}

@MainActor
private extension FootprintRecorder {
    var recordingStatus: String {
        guard isEnabled else { return FootprintText.text("paused") }
        return switch authorization {
        case .authorizedAlways: FootprintText.text("background")
        case .authorizedWhenInUse: FootprintText.text("foreground")
        case .denied, .restricted: FootprintText.text("locationOff")
        default: FootprintText.text("awaiting")
        }
    }
}

@MainActor
struct FootprintSyncControl: View {
    @State private var service = FootprintRecorder.shared
    @State private var showsDetails = false

    var body: some View {
        if let status = service.syncIndicator {
            Button { showsDetails = true } label: {
                Image(systemName: status.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FootprintText.text("syncTitle"))
            .accessibilityValue(FootprintText.text(status.labelKey))
            .accessibilityIdentifier("footprints.syncStatus")
            .sheet(isPresented: $showsDetails) { FootprintSyncDetail() }
        }
    }
}

private extension FootprintSyncIndicator {
    var symbol: String {
        switch self {
        case .syncing: "icloud.and.arrow.up"
        case .synced: "checkmark.icloud"
        case .waitingForNetwork, .paused: "icloud.slash"
        case .retrying, .needsLogin, .partial: "exclamationmark.icloud"
        }
    }

    var labelKey: String {
        switch self {
        case .syncing: "syncing"
        case .synced: "syncComplete"
        case .waitingForNetwork: "syncOffline"
        case .retrying: "syncRetrying"
        case .paused: "syncPaused"
        case .needsLogin: "syncNeedsLogin"
        case .partial: "syncPartial"
        }
    }
}

@MainActor
private struct FootprintSyncDetail: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = FootprintRecorder.shared
    @State private var account = EmailAccountService.shared

    private func t(_ key: String) -> String { FootprintText.text(key) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let status = service.syncIndicator {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 9) {
                            Image(systemName: status.symbol)
                                .font(.title2).foregroundStyle(CompanionHomeStyle.accent)
                                .accessibilityHidden(true)
                            Text(t(status.labelKey))
                                .font(.system(.largeTitle, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text(t(status.labelKey + "Detail"))
                                .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                        VStack(alignment: .leading, spacing: 13) {
                            detailRow(t("syncDevice"), value: t("thisiPhone"))
                            if let email = account.identity?.email {
                                Divider()
                                detailRow(t("syncAccount"), value: email)
                            }
                            if let date = service.lastSyncedAt {
                                Divider()
                                detailRow(t("lastSync"), value: date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 16))

                        if status == .needsLogin {
                            NavigationLink(t("syncSignInAgain")) {
                                AccountSetupView(isSettings: true, reauthenticate: true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
                }
            }
            .background(CompanionHomeStyle.paper.ignoresSafeArea())
            .foregroundStyle(CompanionHomeStyle.ink)
            .tint(CompanionHomeStyle.accent)
            .navigationTitle(t("syncTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).foregroundStyle(CompanionHomeStyle.secondaryInk)
                Spacer(minLength: 0)
                Text(value)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundStyle(CompanionHomeStyle.secondaryInk)
                Text(value)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct FootprintSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = FootprintRecorder.shared
    @State private var status: FootprintCloudStatus?
    @State private var statusOwner: String?
    @State private var statusUnavailable = false
    @State private var statusRefresh = 0

    private struct StatusQuery: Equatable {
        let scope: String
        let owner: String?
        let lastSync: Date?
        let grantRevision: Int
        let refresh: Int
    }

    private func t(_ key: String) -> String { FootprintText.text(key) }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("recording")) {
                    Label(recorder.recordingStatus, systemImage: recorder.isEnabled ? "location.fill" : "pause.circle")
                    if recorder.isEnabled {
                        if recorder.authorization == .authorizedWhenInUse {
                            Button(t("always")) { recorder.requestAlways() }
                        }
                        if recorder.authorization == .denied || recorder.authorization == .restricted || recorder.authorization == .authorizedWhenInUse {
                            Button(t("settings"), action: openSystemSettings)
                        }
                        Button(t("pause")) { recorder.pause() }
                            .accessibilityIdentifier("footprints.pause")
                    } else {
                        Button(t("enable")) {
                            recorder.enable(favorites: recorder.favoritesEnabled, cloud: recorder.cloudEnabled)
                        }
                        .accessibilityIdentifier("footprints.resume")
                    }
                }
                Section(t("photosSection")) {
                    if recorder.favoritesEnabled && CompanionPhotoLibrary.canRead(recorder.photosAuthorization) {
                        Label(t("favorites"), systemImage: "heart.fill")
                    } else if recorder.isEnabled {
                        if recorder.photosAuthorization == .denied || recorder.photosAuthorization == .restricted {
                            Button(t("settings"), action: openSystemSettings)
                        } else {
                            Button(t("allowPhotos")) { Task { await recorder.requestPhotos() } }
                        }
                    }
                    if recorder.favoritesEnabled && recorder.photosAuthorization == .limited {
                        Button(t("settings"), action: openSystemSettings)
                    }
                    Text(t("photosDetail")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(t("syncSection")) {
                    if recorder.hasAccount {
                        Toggle(t("cloud"), isOn: .init(get: { recorder.cloudEnabled }, set: { recorder.setCloud($0) }))
                        Text(t("cloudDetail")).font(.footnote).foregroundStyle(.secondary)
                        if recorder.cloudEnabled {
                            Button(t("syncNow")) {
                                recorder.syncNow()
                                statusRefresh += 1
                            }
                            .disabled(recorder.isSyncing)
                            .accessibilityIdentifier("footprints.syncNow")
                        }
                        NavigationLink {
                            FootprintConnectionView()
                        } label: {
                            Label(t("agent"), systemImage: "link")
                        }
                        .accessibilityIdentifier("footprints.agentLink")
                    } else {
                        Label(t("deviceOnly"), systemImage: "iphone").foregroundStyle(.secondary)
                        NavigationLink {
                            AccountSetupView(isSettings: true)
                        } label: {
                            Text(t("signIn"))
                        }
                        .accessibilityIdentifier("footprints.signIn")
                    }
                }
                if let owner = recorder.accountID, owner == statusOwner {
                    Section(t("cloudHistory")) {
                        if let status {
                            LabeledContent(t("cloudTrackPoints"), value: status.trackPoints.formatted())
                            LabeledContent(t("cloudVisits"), value: status.visits.formatted())
                            LabeledContent(t("cloudPhotos"), value: status.favoritePhotos.formatted())
                            if let received = status.latestUpload {
                                LabeledContent(t("lastSync"), value: received.formatted(date: .abbreviated, time: .shortened))
                            }
                            if status.agentAccess { Text(t("grantActive")) }
                        } else if statusUnavailable {
                            Button(t("retryCloudStatus")) { statusRefresh += 1 }
                        }
                    }
                    .accessibilityIdentifier("footprints.cloudHistory")
                }
            }
            .task(id: StatusQuery(scope: recorder.historyScope, owner: recorder.accountID, lastSync: recorder.lastSync,
                                  grantRevision: recorder.grantRevision, refresh: statusRefresh)) {
                await refreshCloudStatus()
            }
            .tint(FootprintStyle.accent)
            .navigationTitle(t("recordSettings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("done")) { dismiss() }
                        .accessibilityIdentifier("footprints.settingsDone")
                }
            }
        }
    }

    private func refreshCloudStatus() async {
        let owner = recorder.accountID
        if statusOwner != owner {
            status = nil
            statusUnavailable = false
            statusOwner = owner
        }
        guard let owner else { return }
        do {
            let value = try await recorder.cloudStatus()
            guard !Task.isCancelled, recorder.accountID == owner else { return }
            status = value
            statusUnavailable = false
        } catch {
            guard !Task.isCancelled, recorder.accountID == owner else { return }
            status = nil
            statusUnavailable = true
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

@MainActor
private struct FootprintConnectionView: View {
    private enum Operation: String, Identifiable {
        case issue, revoke, revokeOAuth
        var id: Self { self }

        var titleKey: String {
            switch self {
            case .issue: "issueGrant"
            case .revoke: "revoke"
            case .revokeOAuth: "codexDisconnect"
            }
        }

        var detailKey: String {
            switch self {
            case .issue: "rotateDetail"
            case .revoke: "revokeDetail"
            case .revokeOAuth: "codexDisconnectDetail"
            }
        }
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = FootprintRecorder.shared
    @State private var account = EmailAccountService.shared
    @State private var raw = false
    @State private var previews = false
    @State private var token: String?
    @State private var tokenOwner: String?
    @State private var message: String?
    @State private var operation: Operation?
    @State private var working = false
    @State private var status: FootprintCloudStatus?
    @State private var statusUnavailable = false
    @State private var statusRefresh = 0
    @State private var endpointCopied = false

    private struct StatusQuery: Equatable {
        let generation: UInt64
        let grantRevision: Int
        let refresh: Int
        let foreground: Bool
    }

    private func t(_ key: String) -> String { FootprintText.text(key) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("codex"))
                        .font(.system(.largeTitle, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(t("codexScope"))
                        .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    if status?.oauthConnected == true {
                        Label(t("codexConnected"), systemImage: "checkmark.circle")
                            .font(.footnote.weight(.medium)).foregroundStyle(CompanionHomeStyle.accent)
                            .accessibilityIdentifier("footprints.codexConnected")
                    }
                }
                .padding(.vertical, 8)
            }
            if status?.oauthAvailable == true, let endpoint = service.endpoint {
                if status?.oauthConnected == true {
                    Section {
                        DisclosureGroup(t("codexAnotherClient")) { codexSetup(endpoint) }
                        Button(t("codexDisconnect"), role: .destructive) { operation = .revokeOAuth }
                            .accessibilityIdentifier("footprints.revokeOAuth")
                    }
                } else {
                    Section {
                        codexSetup(endpoint)
                    } header: { Text(t("codexSetup")) }
                }
            } else if statusUnavailable {
                Section {
                    Button(t("retryCloudStatus")) { statusRefresh += 1 }
                } footer: { Text(t("connectionError")) }
            } else if status == nil && service.endpoint != nil && service.hasAccount {
                Section { ProgressView().accessibilityLabel(t("codexLoading")) }
            } else {
                Section { Text(t("codexUnavailable")).foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup(t("agentLegacy")) {
                    legacyControls
                }
            } footer: {
                if let message { Text(message).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
        .foregroundStyle(CompanionHomeStyle.ink)
        .tint(CompanionHomeStyle.accent)
        .disabled(working || !service.hasAccount)
        .task(id: StatusQuery(generation: account.identityGeneration, grantRevision: service.grantRevision,
                              refresh: statusRefresh, foreground: scenePhase == .active)) {
            if scenePhase == .active { await refreshOAuthStatus() }
        }
        .onChange(of: account.identityGeneration) { _, _ in
            token = nil; tokenOwner = nil; message = nil; operation = nil
            status = nil; statusUnavailable = false; endpointCopied = false
            raw = false; previews = false
        }
        .navigationTitle(t("agent"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $operation) { action in
            Alert(title: Text(t(action.titleKey)), message: Text(t(action.detailKey)),
                  primaryButton: action == .issue
                      ? .default(Text(t(action.titleKey))) { perform(action) }
                      : .destructive(Text(t(action.titleKey))) { perform(action) },
                  secondaryButton: .cancel(Text(t("cancel"))))
        }
    }

    @ViewBuilder private func codexSetup(_ endpoint: URL) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(t("codexAddTitle")).font(.headline)
            Text(t("codexAddDetail")).font(.subheadline).foregroundStyle(.secondary)
        }
        serverAddress(endpoint)
        VStack(alignment: .leading, spacing: 7) {
            Text(t("codexSignInTitle")).font(.headline)
            Text(t("codexSignInDetail")).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func serverAddress(_ endpoint: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(endpoint.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
            Button(t(endpointCopied ? "endpointCopied" : "copyEndpoint"),
                   systemImage: endpointCopied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.setItems([["public.url": endpoint, "public.utf8-plain-text": endpoint.absoluteString]],
                                               options: [.localOnly: true])
                endpointCopied = true
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("footprints.copyEndpoint")
        }
    }

    @ViewBuilder private var legacyControls: some View {
        Text(t("agentDetail")).font(.footnote).foregroundStyle(.secondary)
        if let endpoint = service.endpoint, status?.oauthAvailable != true { serverAddress(endpoint) }
        Toggle(t("raw"), isOn: $raw)
        Toggle(t("previews"), isOn: $previews)
        if let token, tokenOwner == service.accountID {
            Button(t("copyToken"), systemImage: "key") {
                UIPasteboard.general.setItems([["public.utf8-plain-text": token]], options: [
                    .localOnly: true, .expirationDate: Date().addingTimeInterval(300)
                ])
                message = t("tokenCopied")
            }
            .accessibilityIdentifier("footprints.copyToken")
            Text(t("tokenDetail")).font(.footnote).foregroundStyle(.secondary)
        }
        Button(t("issueGrant"), systemImage: "key.horizontal") { operation = .issue }
            .disabled(service.endpoint == nil)
            .accessibilityIdentifier("footprints.issueGrant")
        Button(t("revoke"), role: .destructive) { operation = .revoke }
            .accessibilityIdentifier("footprints.revokeGrant")
    }

    private func refreshOAuthStatus() async {
        let generation = account.identityGeneration
        guard service.hasAccount else { return }
        do {
            let value = try await service.cloudStatus()
            guard !Task.isCancelled, account.identityGeneration == generation else { return }
            status = value; statusUnavailable = false
        } catch {
            guard !Task.isCancelled, account.identityGeneration == generation else { return }
            statusUnavailable = true
        }
    }

    private func perform(_ action: Operation) {
        guard let owner = service.accountID else { return }
        let generation = account.identityGeneration
        working = true
        message = nil
        Task {
            defer { working = false }
            guard account.identityGeneration == generation else { return }
            do {
                switch action {
                case .issue:
                    let issued = try await service.issueGrant(raw: raw, previews: previews)
                    guard account.identityGeneration == generation else { return }
                    token = issued
                    tokenOwner = owner
                    message = t("grantReady")
                case .revoke:
                    try await service.revokeGrant()
                    guard account.identityGeneration == generation else { return }
                    token = nil
                    tokenOwner = nil
                    message = t("revoked")
                case .revokeOAuth:
                    try await service.revokeOAuth()
                    guard account.identityGeneration == generation else { return }
                    message = t("codexDisconnected")
                }
            } catch {
                if account.identityGeneration == generation { message = t("connectionError") }
            }
        }
    }
}
