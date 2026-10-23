import XCTest

final class DeviceLauncherUI: XCTestCase {
    private var app: XCUIApplication!
    private var transferName: String {
        ProcessInfo.processInfo.environment["TOTK_TEST_EXPORT_NAME"] ?? "LauncherRoundtrip-20261023"
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.smartvelo.totk")
        if name.contains("test05ExistingGameTouch") {
            XCTAssertNotEqual(app.state, .notRunning, "Keep the existing game process for this input")
            app.activate()
            return
        }
        if name.contains("test04PlayAndNativeHUD") {
            app.launchEnvironment = ["DM_NVN_TSV": "milestone-1-timings.tsv", "DM_NVN_TSV_CALLS": "0"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Tears of the Kingdom"].waitForExistence(timeout: 20))
    }

    private func record(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func cell(_ title: String) -> XCUIElement {
        let element = app.cells[title]
        if !element.isHittable {
            for _ in 0..<6 {
                if app.cells["Play"].isHittable { break }
                app.tables.firstMatch.swipeDown()
            }
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return element }
            app.tables.firstMatch.swipeUp()
        }
        XCTFail("Missing launcher row: \(title)")
        return element
    }

    private func top() {
        for _ in 0..<8 {
            if app.cells["Play"].isHittable { return }
            app.tables.firstMatch.swipeDown()
        }
    }

    func test01PreferencesLayoutAndLifecycle() {
        let table = app.tables.firstMatch
        XCTAssertLessThanOrEqual(table.frame.width, 621)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        record("Prelaunch centered menu")
        let oldLanguage = cell("Game language").value as? String
        defer {
            cell("Performance overlay").tap()
            app.buttons["Off"].tap()
            cell("Game language").tap()
            app.buttons[oldLanguage ?? "System"].tap()
            cell("Apple Metal HUD").tap()
            app.buttons["On"].tap()
        }
        cell("Performance overlay").tap()
        app.buttons["FPS only"].tap()
        cell("Game language").tap()
        app.buttons["Deutsch"].tap()
        cell("Apple Metal HUD").tap()
        app.buttons["On"].tap()
        app.terminate()
        app.launch()
        XCTAssertEqual(cell("Performance overlay").value as? String, "FPS only")
        XCTAssertEqual(cell("Game language").value as? String, "Deutsch")
        XCTAssertEqual(cell("Apple Metal HUD").value as? String, "On")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Tears of the Kingdom"].waitForExistence(timeout: 10))
        record("Preferences persist after relaunch and foreground")
    }

    func test02BackupOwnSave() {
        cell("Back up save").tap()
        XCTAssertTrue(app.alerts.staticTexts["Backup created. You can select it under Restore backup."].waitForExistence(timeout: 30))
        record("Physical backup complete")
        app.alerts.buttons["OK"].tap()
    }

    func test03aExportOwnSaveThroughFiles() {
        cell("Export save folder").tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 30))
        filename.tap()
        let old = filename.value as? String ?? "TOTK Save"
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + transferName)
        XCTAssertEqual(filename.value as? String, transferName)
        record("Own save export destination")
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(filename.waitForNonExistence(timeout: 30))
        record("Own save exported through Files")
    }

    func test03bImportOwnExportThroughFiles() {
        cell("Import save folder").tap()
        let local = app.cells["DOC.sidebar.item.On My iPad"]
        XCTAssertTrue(local.waitForExistence(timeout: 15))
        local.tap()
        let documents = app.collectionViews.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["TOTK", "Tears of the Kingdom"])
        ).firstMatch
        XCTAssertTrue(documents.waitForExistence(timeout: 10))
        documents.tap()
        let folder = app.staticTexts[transferName].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30), app.debugDescription)
        folder.doubleTap()
        let location = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", transferName + ",")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10), "Enter the exported folder before selecting it")
        XCTAssertTrue(app.staticTexts["slot_00"].firstMatch.waitForExistence(timeout: 10))
        let select = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        record("Own exported folder selected for import")
        select.tap()
        XCTAssertTrue(app.alerts["Import save?"].waitForExistence(timeout: 10))
        app.alerts.buttons["Import"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Save ready. Press Play to load it."].waitForExistence(timeout: 30))
        record("Own save import complete")
        app.alerts.buttons["OK"].tap()
    }

    func test03cRestoreLatestOwnBackup() {
        cell("Restore backup").tap()
        let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save-")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        record("Latest own backup chosen for restore")
        backup.tap()
        XCTAssertTrue(app.alerts["Restore backup?"].waitForExistence(timeout: 10))
        app.alerts.buttons["Restore"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Save ready. Press Play to load it."].waitForExistence(timeout: 30))
        record("Own backup restored")
        app.alerts.buttons["OK"].tap()
    }

    func test04PlayAndNativeHUD() {
        cell("Performance overlay").tap()
        app.buttons["Off"].tap()
        cell("Apple Metal HUD").tap()
        app.buttons["On"].tap()
        cell("Touch controls").tap()
        app.buttons["Automatic"].tap()
        top()
        app.cells["Play"].doubleTap()
        let menu = app.navigationBars["Tears of the Kingdom"]
        XCTAssertTrue(menu.waitForNonExistence(timeout: 15))
        // Metal's HUD is a compositor overlay and may not appear in the accessibility tree.
        let ready = NSPredicate { _, _ in !menu.exists }
        expectation(for: ready, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        let frames = expectation(description: "Allow the game renderer to present frames")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { frames.fulfill() }
        wait(for: [frames], timeout: 35)
        record("Game after Play with native HUD enabled")
    }

    func test05ExistingGameTouch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let x = Double(environment["TOTK_TEST_TOUCH_X"] ?? ""),
              let y = Double(environment["TOTK_TEST_TOUCH_Y"] ?? "") else {
            throw XCTSkip("A reviewed screenshot and explicit touch coordinates are required")
        }
        XCTAssertTrue((0...1).contains(x) && (0...1).contains(y))
        record("Existing game before reviewed touch")
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        let response = expectation(description: "Allow the existing game to respond")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { response.fulfill() }
        wait(for: [response], timeout: 15)
        record("Existing game after reviewed touch")
    }
}
