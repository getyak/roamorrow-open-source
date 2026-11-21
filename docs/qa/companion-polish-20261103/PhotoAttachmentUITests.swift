import XCTest

/// Local opt-in checks of OS Photos permission states in the separate QA app.
/// These cases never create, delete or upload anything in the shared library.
@MainActor
final class PhotoAttachmentUITests: XCTestCase {
    private var app: XCUIApplication!

    private func configureApp() throws {
        continueAfterFailure = false
        let id = ProcessInfo.processInfo.environment["COMPANION_UI_APP_ID"]
        guard let id, id == "com.solocompass.get373" else {
            throw XCTSkip("This suite requires the isolated GET-373 QA installation")
        }
        app = XCUIApplication(bundleIdentifier: id)
        app.launchArguments = ["-devSkipOnboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["FF_CONTINUOUS_COMPANION"] = "1"
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "photos-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func answerPhotosPermission(allow: Bool) {
        let showRecent = app.buttons["companion.media.showRecent"].firstMatch
        XCTAssertTrue(showRecent.waitForExistence(timeout: 5), "Start from undecided Photos access")
        showRecent.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [springboard.alerts.firstMatch, app.alerts.firstMatch]
        guard let alert = candidates.first(where: { $0.waitForExistence(timeout: 3) }) else {
            XCTFail("Expected the Photos permission prompt"); return
        }
        let prompt = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'photo' OR label CONTAINS '照片'")).firstMatch
        XCTAssertTrue(prompt.exists, "Only handle the requested Photos permission")
        let action: XCUIElement
        if allow {
            action = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Full Access' OR label CONTAINS '完全访问' OR label CONTAINS '所有照片' OR label CONTAINS '全部照片'")).firstMatch
        } else {
            action = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don't Allow", "Don’t Allow", "不允许"])).firstMatch
        }
        XCTAssertTrue(action.exists)
        if action.exists { action.tap() }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !alert.exists }, object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    func testAuthorizedLibraryShowsRecentsOrEmptyState() throws {
        try configureApp()
        app.launch()
        let composer = app.descendants(matching: .any)["companion.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let draft = composer.value as? String
        app.buttons["companion.media.add"].tap()
        XCTAssertTrue(app.buttons["companion.media.allPhotos"].waitForExistence(timeout: 5))
        answerPhotosPermission(allow: true)
        let showRecent = app.buttons["companion.media.showRecent"].firstMatch
        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !showRecent.exists }, object: showRecent)
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 8), .completed)
        let first = app.buttons["companion.media.recent.0"].firstMatch
        if first.exists {
            // PhotoKit may still be generating local thumbnails immediately
            // after the system permission sheet closes. Capture its settled UI.
            Thread.sleep(forTimeInterval: 1)
            capture("authorized-recent-row")
            let messages = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'companion.message.'")).count
            first.tap()
            XCTAssertTrue(app.scrollViews["companion.draft.media"].waitForExistence(timeout: 15))
            XCTAssertEqual(composer.value as? String, draft)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'companion.message.'")).count, messages)
            capture("selected-image-remains-in-draft")
        } else {
            XCTAssertTrue(app.staticTexts["这里还没有可显示的照片。可从所有照片中选择。"].exists)
            capture("authorized-empty-library")
        }
    }

    func testDeniedLibraryStillOffersSystemPickerAndOtherActions() throws {
        try configureApp()
        app.launch()
        XCTAssertTrue(app.buttons["companion.media.add"].waitForExistence(timeout: 20))
        app.buttons["companion.media.add"].tap()
        answerPhotosPermission(allow: false)
        XCTAssertTrue(app.staticTexts["仍可点击所有照片，选择要添加的图片。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["companion.media.allPhotos"].isHittable)
        XCTAssertTrue(app.buttons["companion.media.camera"].exists)
        XCTAssertFalse(app.buttons["companion.media.showRecent"].exists)
        capture("denied-library-actions-retained")
        app.buttons["companion.media.allPhotos"].tap()
        capture("denied-library-system-picker")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }
}
