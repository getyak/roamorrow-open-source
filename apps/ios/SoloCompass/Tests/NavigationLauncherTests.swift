import XCTest
import CoreLocation
@testable import SoloCompass

@MainActor
final class NavigationLauncherTests: XCTestCase {

    // Asakusa Senso-ji, Tokyo — chosen as a representative WGS-84 coordinate.
    private let coordinate = CLLocationCoordinate2D(latitude: 35.7148, longitude: 139.7967)

    // MARK: - url(for:coordinate:name:)

    func test_url_appleMaps_returnsNil() {
        // Apple Maps is dispatched through MKMapItem.openInMaps, not a URL scheme.
        XCTAssertNil(NavigationLauncher.url(for: .appleMaps, coordinate: coordinate, name: "Senso-ji"))
    }

    func test_url_googleMaps_buildsExpectedDeepLink() {
        let url = NavigationLauncher.url(for: .googleMaps, coordinate: coordinate, name: "Senso-ji")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("comgooglemaps://"), "got: \(s)")
        XCTAssertTrue(s.contains("daddr=35.7148,139.7967"), "missing daddr; got: \(s)")
        XCTAssertTrue(s.contains("q=Senso-ji"), "missing q; got: \(s)")
        XCTAssertTrue(s.contains("directionsmode=walking"), "missing walking mode; got: \(s)")
    }

    func test_url_amap_buildsExpectedDeepLinkWithWGS84Conversion() {
        let url = NavigationLauncher.url(for: .amap, coordinate: coordinate, name: "Senso-ji")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("iosamap://path"), "got: \(s)")
        XCTAssertTrue(s.contains("dlat=35.7148"), "missing dlat; got: \(s)")
        XCTAssertTrue(s.contains("dlon=139.7967"), "missing dlon; got: \(s)")
        // Official URI contract: dev=1 converts WGS84; dev=0 is GCJ02.
        XCTAssertTrue(s.contains("dev=1"), "missing dev=1; got: \(s)")
        XCTAssertTrue(s.contains("t=2"), "missing walking mode t=2; got: \(s)")
    }

    func test_url_percentEncodesNonAsciiName() {
        let url = NavigationLauncher.url(for: .googleMaps, coordinate: coordinate, name: "浅草寺")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertFalse(s.contains("浅草寺"), "name should be percent-encoded; got: \(s)")
        XCTAssertTrue(s.contains("q=%E6%B5%85%E8%8D%89%E5%AF%BA"), "missing percent-encoded name; got: \(s)")
    }

    func test_url_nilName_producesEmptyQuery() {
        let url = NavigationLauncher.url(for: .googleMaps, coordinate: coordinate, name: nil)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("q=&"), "nil name should yield empty q=; got: \(url!.absoluteString)")
    }

    func testNamesCannotInjectNavigationParameters() throws {
        let name = "店 A&B?dev=0#楼上"
        for app in [NavigationApp.amap, .googleMaps] {
            let url = try XCTUnwrap(NavigationLauncher.url(for: app, coordinate: coordinate, name: name))
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == (app == .amap ? "dname" : "q") }?.value, name)
            if app == .amap { XCTAssertEqual(items.filter { $0.name == "dev" }.map(\.value), ["1"]) }
        }
    }

    func testInvalidDestinationsDoNotProduceThirdPartyURLs() {
        let invalid = [
            CLLocationCoordinate2D(latitude: .nan, longitude: 114),
            CLLocationCoordinate2D(latitude: 32, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 91, longitude: 114),
            CLLocationCoordinate2D(latitude: 32, longitude: 181),
        ]
        for destination in invalid {
            XCTAssertNil(NavigationLauncher.preferredWalkingApp(for: destination) { _ in
                XCTFail("Invalid destinations should not check for installed apps")
                return true
            })
            XCTAssertNil(NavigationLauncher.url(for: .amap, coordinate: destination, name: nil))
            XCTAssertNil(NavigationLauncher.url(for: .googleMaps, coordinate: destination, name: nil))
        }
    }

    func testPreferredWalkingAppChoosesAmapOnlyForMainlandDestinations() {
        let xinyang = CLLocationCoordinate2D(latitude: 32.1469, longitude: 114.0910)
        let hongKong = CLLocationCoordinate2D(latitude: 22.2837, longitude: 114.1581)
        let taipei = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)

        XCTAssertEqual(NavigationLauncher.preferredWalkingApp(for: xinyang) { $0.scheme == "iosamap" }, .amap)
        XCTAssertEqual(NavigationLauncher.preferredWalkingApp(for: xinyang) { _ in false }, .appleMaps)
        for destination in [coordinate, hongKong, taipei] {
            XCTAssertEqual(NavigationLauncher.preferredWalkingApp(for: destination) { _ in
                XCTFail("Outside mainland China, use Apple Maps without probing Amap")
                return true
            }, .appleMaps)
        }
    }

    func testAmapHandoffPreservesCanonicalDestinationAndDelegatesLiveOrigin() async throws {
        let destination = CLLocationCoordinate2D(latitude: 32.1469, longitude: 114.0910)
        var openedURL: URL?
        await NavigationLauncher.openWalkingDirections(
            to: destination,
            name: "信阳市",
            canOpen: { $0.scheme == "iosamap" },
            openURL: { openedURL = $0; return true },
            openAppleMaps: { _, _ in XCTFail("Amap opened successfully") }
        )
        let url = try XCTUnwrap(openedURL)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
        XCTAssertEqual(values["dlat"], String(destination.latitude))
        XCTAssertEqual(values["dlon"], String(destination.longitude))
        XCTAssertEqual(values["dname"], "信阳市")
        XCTAssertEqual(values["dev"], "1")
        XCTAssertEqual(values["t"], "2")
        XCTAssertTrue(Set(values.keys).isDisjoint(with: ["sid", "slat", "slon", "sname", "did"]))
    }

    func testAmapLaunchFailureFallsBackToAppleMapsWithTheSameDestination() async {
        let destination = CLLocationCoordinate2D(latitude: 32.1469, longitude: 114.0910)
        var attemptedAmap = false
        var openedAppleMaps = false
        await NavigationLauncher.openWalkingDirections(
            to: destination,
            name: "信阳市",
            canOpen: { _ in true },
            openURL: { _ in attemptedAmap = true; return false },
            openAppleMaps: { coordinate, name in
                XCTAssertTrue(attemptedAmap)
                XCTAssertEqual(coordinate.latitude, destination.latitude)
                XCTAssertEqual(coordinate.longitude, destination.longitude)
                XCTAssertEqual(name, "信阳市")
                openedAppleMaps = true
            }
        )
        XCTAssertTrue(openedAppleMaps)
    }

    // MARK: - availableApps(canOpen:)

    func test_availableApps_alwaysIncludesAppleMaps_evenWhenNothingInstalled() {
        let apps = NavigationLauncher.availableApps { _ in false }
        XCTAssertEqual(apps, [.appleMaps])
    }

    func test_availableApps_includesGoogleWhenInstalled() {
        let apps = NavigationLauncher.availableApps { url in
            url.scheme == "comgooglemaps"
        }
        XCTAssertEqual(apps, [.appleMaps, .googleMaps])
    }

    func test_availableApps_includesAmapWhenInstalled() {
        let apps = NavigationLauncher.availableApps { url in
            url.scheme == "iosamap"
        }
        XCTAssertEqual(apps, [.appleMaps, .amap])
    }

    func test_availableApps_allInstalled_returnsCanonicalOrder() {
        let apps = NavigationLauncher.availableApps { _ in true }
        XCTAssertEqual(apps, [.appleMaps, .googleMaps, .amap])
    }

    // MARK: - soleApp(canOpen:)

    func test_soleApp_onlyAppleMaps_returnsAppleMaps() {
        // The common case: nothing extra installed → launch Apple Maps directly,
        // no one-option picker.
        XCTAssertEqual(NavigationLauncher.soleApp { _ in false }, .appleMaps)
    }

    func test_soleApp_multipleInstalled_returnsNil() {
        // A real choice exists → caller should present the picker.
        XCTAssertNil(NavigationLauncher.soleApp { url in url.scheme == "comgooglemaps" })
        XCTAssertNil(NavigationLauncher.soleApp { _ in true })
    }
}
