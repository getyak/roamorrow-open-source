import SwiftUI
import MapKit
import Observation

extension MapKitCoordinateSpace {
    func mapRect(_ rect: MKMapRect, style: Style = .standard) -> MKMapRect? {
        Self.translate(rect) { mapCoordinate($0, style: style) }
    }

    func canonicalRect(_ rect: MKMapRect, style: Style = .standard) -> MKMapRect? {
        Self.translate(rect) { canonicalMapCoordinate($0, style: style) }
    }

    private static func translate(_ rect: MKMapRect, convert: (CLLocationCoordinate2D) -> CLLocationCoordinate2D?) -> MKMapRect? {
        guard !rect.isNull, rect.midX.isFinite, rect.midY.isFinite else { return nil }
        let center = rectCenter(rect)
        guard let converted = convert(center.coordinate) else { return nil }
        let target = MKMapPoint(converted)
        return rect.offsetBy(dx: target.x - center.x, dy: target.y - center.y)
    }

    nonisolated fileprivate static func rectCenter(_ rect: MKMapRect) -> MKMapPoint {
        let world = MKMapRect.world.width
        let x = rect.midX.truncatingRemainder(dividingBy: world)
        return MKMapPoint(x: x < 0 ? x + world : x, y: rect.midY)
    }

    func mapRegion(_ canonical: MKCoordinateRegion, style: Style = .standard) -> MKCoordinateRegion? {
        guard let center = mapCoordinate(canonical.center, style: style) else { return nil }
        return .init(center: center, span: canonical.span)
    }

    func canonicalRegion(_ raw: MKCoordinateRegion, style: Style = .standard) -> MKCoordinateRegion? {
        guard let center = canonicalMapCoordinate(raw.center, style: style) else { return nil }
        return .init(center: center, span: raw.span)
    }

    /// The ViewModel keeps a WGS84 camera; MapKit owns its presentation space.
    func mapPosition(_ canonical: MapCameraPosition, style: Style = .standard) -> MapCameraPosition? {
        if let region = canonical.region { return mapRegion(region, style: style).map(MapCameraPosition.region) }
        if let camera = canonical.camera {
            guard let center = mapCoordinate(camera.centerCoordinate, style: style) else { return nil }
            return .camera(.init(centerCoordinate: center, distance: camera.distance, heading: camera.heading, pitch: camera.pitch))
        }
        if let rect = canonical.rect { return mapRect(rect, style: style).map(MapCameraPosition.rect) }
        return canonical
    }

    func canonicalPosition(_ raw: MapCameraPosition, style: Style = .standard) -> MapCameraPosition? {
        if let region = raw.region { return canonicalRegion(region, style: style).map(MapCameraPosition.region) }
        if let camera = raw.camera {
            guard let center = canonicalMapCoordinate(camera.centerCoordinate, style: style) else { return nil }
            return .camera(.init(centerCoordinate: center, distance: camera.distance, heading: camera.heading, pitch: camera.pitch))
        }
        if let rect = raw.rect { return canonicalRect(rect, style: style).map(MapCameraPosition.rect) }
        return raw
    }
}

/// Deduplicates public anchor calibration as the viewport, fix and archive move.
struct MapCalibrationTarget: Equatable {
    let region: MapKitCoordinateSpace.Region

    @MainActor static func targets(for coordinates: [CLLocationCoordinate2D]) -> [Self] {
        let regions = Set(coordinates.compactMap { MapKitCoordinateSpace.region(for: $0) })
        return regions.sorted { $0.rawValue < $1.rawValue }.map(Self.init)
    }

    @MainActor static func refresh(_ targets: [Self], using space: MapKitCoordinateSpace) async {
        guard !targets.isEmpty else { return }
        while !Task.isCancelled {
            var delay = MapKitCoordinateSpace.lifetime
            for target in targets {
                // Calibrate from public anchors. A personal fix or archive
                // point never leaves the device for datum discovery.
                guard let anchor = MapKitCoordinateSpace.anchors(for: target.region).first else { continue }
                do {
                    try await space.prepare(near: anchor.coordinate)
                    let verified = space.profile(for: anchor.coordinate).verifiedAt
                    delay = min(delay, max(1, verified.addingTimeInterval(MapKitCoordinateSpace.lifetime).timeIntervalSinceNow))
                }
                catch is CancellationError { return }
                catch { delay = min(delay, 30) }
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
    }
}

extension MapCameraPosition {
    var coordinateCenter: CLLocationCoordinate2D? {
        region?.center ?? camera?.centerCoordinate ?? rect.map { MapKitCoordinateSpace.rectCenter($0).coordinate }
    }
}

extension MKCoordinateRegion {
    var mapRectForDrawing: MKMapRect {
        let point = MKMapPoint(center)
        let width = MKMapRect.world.width * min(360, span.longitudeDelta) / 360
        let north = MKMapPoint(CLLocationCoordinate2D(latitude: min(85, center.latitude + span.latitudeDelta / 2),
                                                     longitude: center.longitude))
        let south = MKMapPoint(CLLocationCoordinate2D(latitude: max(-85, center.latitude - span.latitudeDelta / 2),
                                                     longitude: center.longitude))
        return .init(x: point.x - width / 2, y: north.y, width: width, height: south.y - north.y)
    }
}

/// Owns the camera actually handed to MapKit. Unknown calibration retains that
/// camera instead of accidentally sending a canonical WGS84 camera as raw input.
@MainActor @Observable
final class MapCoordinatePresentation {
    var position: MapCameraPosition = .automatic
    private(set) var target: CLLocationCoordinate2D?
    private(set) var pendingUserRegion: MKCoordinateRegion?
    private(set) var isGestureCamera = false
    private var userMoved = false
    private var echoedCanonical: MapCameraPosition?

    func request(_ canonical: MapCameraPosition, fallback: CLLocationCoordinate2D,
                 space: MapKitCoordinateSpace, style: MapKitCoordinateSpace.Style = .standard) {
        // A MapKit binding update is echoed through the canonical ViewModel.
        // Keep the actual gesture camera instead of turning that echo into a
        // new programmatic move that fights the ongoing pan.
        if echoedCanonical == canonical { echoedCanonical = nil; return }
        echoedCanonical = nil
        pendingUserRegion = nil
        userMoved = false
        isGestureCamera = false
        target = canonical.coordinateCenter ?? fallback
        if let rendered = space.mapPosition(canonical, style: style) { position = rendered }
    }
    func receive(_ raw: MapCameraPosition, space: MapKitCoordinateSpace,
                 style: MapKitCoordinateSpace.Style = .standard) -> MapCameraPosition? {
        if raw.positionedByUser, position != raw { noteGesture() }
        position = raw
        let canonical = space.canonicalPosition(raw, style: style)
        echoedCanonical = canonical
        return canonical
    }
    func noteGesture() {
        userMoved = true
        isGestureCamera = true
    }

    func finish(_ raw: MKCoordinateRegion, space: MapKitCoordinateSpace,
                style: MapKitCoordinateSpace.Style = .standard) -> MKCoordinateRegion? {
        let moved = userMoved
        userMoved = false
        // A programmatic/automatic camera settling must not replace a pending
        // city selection with an unverified viewport from the previous city.
        if moved { target = raw.center }
        if !isGestureCamera, let target, space.mapCoordinate(target, style: style) == nil { return nil }
        if let canonical = space.canonicalRegion(raw, style: style) {
            if moved { target = canonical.center }
            pendingUserRegion = nil
            return canonical
        }
        if moved { pendingUserRegion = raw }
        return nil
    }
    func recover(_ canonical: MapCameraPosition, fallback: CLLocationCoordinate2D,
                 space: MapKitCoordinateSpace, style: MapKitCoordinateSpace.Style = .standard) -> MKCoordinateRegion? {
        if userMoved { return nil }
        if let pending = pendingUserRegion {
            guard let result = space.canonicalRegion(pending, style: style) else { return nil }
            pendingUserRegion = nil
            target = result.center
            return result
        }
        if isGestureCamera { return nil }
        if let rendered = space.mapPosition(canonical, style: style) { position = rendered }
        return nil
    }
}

/// Unknown positions remain a usable list; retry is explicit and bounded.
struct MapCoordinateStatus: View {
    let messageKey: String
    let actionKey: String
    let retry: () -> Void
    init(messageKey: String = "map.coordinates.unavailable", actionKey: String = "common.retry", retry: @escaping () -> Void) {
        self.messageKey = messageKey
        self.actionKey = actionKey
        self.retry = retry
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString(messageKey, comment: "Unverified map coordinates"))
                .font(.caption)
            Button(NSLocalizedString(actionKey, comment: "Coordinate action"), action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
