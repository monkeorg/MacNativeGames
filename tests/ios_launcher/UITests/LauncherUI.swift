import XCTest

final class LauncherUI: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["--reset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Starts: 0"].waitForExistence(timeout: 10))
    }

    private func cell(_ title: String) -> XCUIElement {
        let element = app.cells[title]
        for _ in 0..<8 {
            if element.exists && element.isHittable { return element }
            app.tables.firstMatch.swipeUp()
        }
        XCTFail("Missing launcher cell: \(title)")
        return element
    }

    private func play() {
        for _ in 0..<8 {
            if app.cells["Play"].isHittable { break }
            app.tables.firstMatch.swipeDown()
        }
        app.cells["Play"].tap()
    }

    func testDeferredStartLandscapeAndSinglePlay() {
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        cell("Performance overlay").tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Starts: 0"].exists)
        app.cells["Play"].doubleTap()
        let started = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Starts: 1;")).firstMatch
        XCTAssertTrue(started.waitForExistence(timeout: 5))
        XCTAssertFalse(app.cells["Play"].isEnabled)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(started.waitForExistence(timeout: 5))
    }

    func testPreferencesSurviveRelaunch() {
        cell("Performance overlay").tap()
        app.buttons["FPS only"].tap()
        cell("Game language").tap()
        app.buttons["Deutsch"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertEqual(cell("Performance overlay").value as? String, "FPS only")
        XCTAssertEqual(cell("Game language").value as? String, "Deutsch")
        play()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "; de; HUD 2;")).firstMatch.waitForExistence(timeout: 5))
    }

    func testInvalidPreferencesRecover() {
        app.terminate()
        app.launchArguments = ["--reset", "--invalid-preferences"]
        app.launch()
        XCTAssertEqual(cell("Performance overlay").value as? String, "Full")
        XCTAssertEqual(cell("Touch controls").value as? String, "Automatic")
        XCTAssertEqual(cell("Game language").value as? String, "System")
    }

    func testTouchOffRequiresController() {
        cell("Touch controls").tap()
        app.buttons["Off"].tap()
        play()
        XCTAssertTrue(app.alerts.staticTexts["Enable touch controls or connect a compatible controller before Play."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Starts: 0"].exists)
    }

    func testBackupRestoreThroughMenu() {
        cell("Back up save").tap()
        XCTAssertTrue(app.alerts.staticTexts["Backup created. You can select it under Restore backup."].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        app.terminate()
        app.launchArguments = ["--mutate-save"]
        app.launch()
        cell("Restore backup").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save-")).firstMatch.tap()
        app.alerts.buttons["Restore"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Save ready. Press Play to load it."].waitForExistence(timeout: 10), app.debugDescription)
        app.alerts.buttons["OK"].tap()
        play()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "fixture-original")).firstMatch.waitForExistence(timeout: 5))
    }
}
