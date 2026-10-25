import XCTest

final class DeviceLauncherUI: XCTestCase {
    private var app: XCUIApplication!
    private var transferName: String {
        ProcessInfo.processInfo.environment["TOTK_TEST_EXPORT_NAME"] ?? "LauncherRoundtrip-20261023"
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.smartvelo.totk")
        if name.contains("test05ExistingGameTouch") || name.contains("test06") {
            XCTAssertNotEqual(app.state, .notRunning, "Keep the existing game process for this input")
            app.activate()
            if name.contains("test06") {
                XCTAssertFalse(app.navigationBars["Tears of the Kingdom"].exists, "Start the game before live menu tests")
            }
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
                if app.cells["Play"].isHittable || app.cells["Resume game"].isHittable { break }
                app.tables.firstMatch.swipeDown()
            }
        }
        for _ in 0..<8 {
            if element.exists && (element.isHittable || (!element.isEnabled && element.frame.intersects(app.tables.firstMatch.frame))) { return element }
            app.tables.firstMatch.swipeUp()
        }
        XCTFail("Missing launcher row: \(title)")
        return element
    }

    private func top() {
        for _ in 0..<8 {
            if app.cells["Play"].isHittable || app.cells["Resume game"].isHittable { return }
            app.tables.firstMatch.swipeDown()
        }
    }

    private func expectHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func openGameMenu() {
        let gear = app.buttons["Game menu"]
        expectHittable(gear)
        gear.tap()
        expectHittable(app.buttons["Close game menu"])
    }

    private func closeGameMenu() {
        app.buttons["Close game menu"].tap()
        expectHittable(app.buttons["Game menu"])
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    private func choose(_ title: String, for row: String) {
        cell(row).tap()
        let choice = app.buttons[title]
        expectHittable(choice)
        choice.tap()
        XCTAssertEqual(cell(row).value as? String, title)
    }

    func test00CompactPrelaunchGlass() {
        let card = app.otherElements["TOTKPrelaunchCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(card.frame.width, 961)
        XCTAssertLessThanOrEqual(card.frame.height, 761)
        XCTAssertEqual(card.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(app.tables.firstMatch.frame.width, 961)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        record("Compact prelaunch glass card")
    }

    func test01PreferencesLayoutAndLifecycle() {
        let table = app.tables.firstMatch
        XCTAssertLessThanOrEqual(table.frame.width, 961)
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

    func test01bDisplayPreferencesPersistWhenSupported() throws {
        let resolution = cell("Render resolution")
        let aspect = cell("Aspect ratio")
        guard resolution.isEnabled && aspect.isEnabled else {
            XCTAssertEqual(resolution.value as? String, "1280 × 720")
            XCTAssertEqual(aspect.value as? String, "16:9")
            throw XCTSkip("This signed build does not expose display settings")
        }
        let frame = app.windows.firstMatch.frame
        guard max(frame.width, frame.height) / min(frame.width, frame.height) <= 16.0 / 9.0 else {
            throw XCTSkip("Full display requires a supported screen aspect")
        }
        resolution.tap()
        app.buttons["720 high"].tap()
        XCTAssertEqual(cell("Render resolution").value as? String, "720 high")
        cell("Render resolution").tap()
        app.buttons["1080 high"].tap()
        cell("Aspect ratio").tap()
        app.buttons["16:9"].tap()
        cell("Aspect ratio").tap()
        app.buttons["Full display"].tap()
        app.terminate()
        app.launch()
        XCTAssertEqual(cell("Render resolution").value as? String, "1080 high")
        XCTAssertEqual(cell("Aspect ratio").value as? String, "Full display")
        record("1080 full-display preferences persist")
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

    func test06aExistingGameMenuOpenCloseRestoresHitTesting() {
        let touch = app.otherElements["TOTKTouchControls"]
        expectHittable(touch)
        openGameMenu()
        let close = app.buttons["Close game menu"]
        defer { if close.isHittable { close.tap() } }
        let card = app.otherElements["TOTKGameMenuCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(card.frame.width, 1009)
        XCTAssertLessThan(card.frame.height, app.windows.firstMatch.frame.height)
        XCTAssertLessThanOrEqual(app.tables.firstMatch.frame.width, 961)
        XCTAssertFalse(touch.isHittable)
        XCTAssertFalse(app.cells["Play"].exists)
        for title in ["Render resolution", "Aspect ratio", "Performance overlay", "Apple Metal HUD",
                      "Touch controls", "Controller type", "Mouse sensitivity", "Invert mouse Y", "Button mappings"] {
            XCTAssertTrue(cell(title).exists)
        }
        cell("Button mappings").tap()
        let mappings = app.navigationBars["Button mappings"]
        XCTAssertTrue(mappings.waitForExistence(timeout: 5))
        XCTAssertFalse(touch.isHittable)
        XCTAssertTrue(cell("South face button").isEnabled)
        record("Shared settings button mappings shield game input")
        mappings.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for title in ["Import save folder", "Export save folder", "Back up save", "Restore backup"] {
            XCTAssertFalse(cell(title).isEnabled, "Save transfers must stay sealed during play")
        }
        XCTAssertTrue(cell("Game language").isEnabled)
        XCTAssertTrue(app.staticTexts["Language changes apply next launch."].exists)
        record("Full game settings with sealed saves and next-launch language")
        top()
        cell("Resume game").tap()
        expectHittable(app.buttons["Game menu"])
        expectHittable(touch)
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        record("Resume restores game touch hit testing")
    }

    func test06bExistingGameMenuLiveHUDPersistence() {
        openGameMenu()
        let close = app.buttons["Close game menu"]
        defer { if close.isHittable { close.tap() } }
        for title in ["Full", "FPS only", "Off"] {
            choose(title, for: "Performance overlay")
            closeGameMenu()
            record("Live custom overlay " + title)
            openGameMenu()
            XCTAssertEqual(cell("Performance overlay").value as? String, title)
        }
        choose("On", for: "Apple Metal HUD")
        choose("Off", for: "Apple Metal HUD")
        closeGameMenu()
        record("Native HUD disabled live")
        openGameMenu()
        XCTAssertEqual(cell("Apple Metal HUD").value as? String, "Off")
        choose("On", for: "Apple Metal HUD")
        closeGameMenu()
        record("Native HUD enabled live")
        openGameMenu()
        XCTAssertEqual(cell("Performance overlay").value as? String, "Off")
        XCTAssertEqual(cell("Apple Metal HUD").value as? String, "On")
        closeGameMenu()
        record("Live HUD preferences retained after reopening shared settings")
    }

    func test06cExistingGameNextLaunchControlPreference() {
        openGameMenu()
        let original = cell("Invert mouse Y").value as? String ?? "Off"
        defer {
            if !app.buttons["Close game menu"].isHittable { openGameMenu() }
            choose(original, for: "Invert mouse Y")
            closeGameMenu()
        }
        let changed = original == "On" ? "Off" : "On"
        choose(changed, for: "Invert mouse Y")
        XCTAssertTrue(app.staticTexts["Control changes apply next launch. Current input is unchanged. Developer overrides take precedence."].exists)
        record("Control preference explicitly applies next launch")
        closeGameMenu()
        openGameMenu()
        XCTAssertEqual(cell("Invert mouse Y").value as? String, changed)
    }
}
