import XCTest
import UIKit

final class DeviceLauncherUI: XCTestCase {
    private var app: XCUIApplication!
    private var transferName: String {
        ProcessInfo.processInfo.environment["TOTK_TEST_EXPORT_NAME"] ?? "LauncherRoundtrip-20261023"
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.smartvelo.totk")
        if name.contains("test05ExistingGameTouch") || name.contains("test06") || name.contains("test07ExistingGameSnapshot") {
            XCTAssertNotEqual(app.state, .notRunning, "Keep the existing game process for this input")
            app.activate()
            if name.contains("test06") {
                XCTAssertFalse(app.navigationBars["Tears of the Kingdom"].exists, "Start the game before live menu tests")
            }
            return
        }
        if name.contains("test04PlayAndNativeHUD") {
            let timings = ProcessInfo.processInfo.environment["TOTK_TEST_TIMINGS_FILE"] ?? "milestone-1-timings.tsv"
            XCTAssertFalse(timings.isEmpty || timings.contains("/") || timings.contains("\\"))
            app.launchEnvironment = ["DM_NVN_TSV": timings, "DM_NVN_TSV_CALLS": "0", "TOTK_AUTOLOAD": "1"]
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
        let close = app.buttons["Close game menu"]
        if close.exists && close.isHittable { return }
        let gear = app.buttons["Game menu"]
        expectHittable(gear)
        gear.press(forDuration: 0.15)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            close.exists && close.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        if result != .completed { record("Game menu did not open after one gear press") }
        XCTAssertEqual(result, .completed)
    }

    private func closeGameMenu() {
        app.buttons["Close game menu"].tap()
        expectHittable(app.buttons["Game menu"])
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    private func expectRestartPending(_ pending: Bool) {
        let footer = app.staticTexts["TOTKRestartFooter"]
        for _ in 0..<8 {
            if footer.exists && footer.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(footer.exists)
        XCTAssertEqual(footer.label.hasPrefix("Restart required"), pending)
    }

    private func cancelSettingsPopover() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        expectHittable(back)
        back.tap()
        expectHittable(app.buttons["Close game menu"])
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertFalse(app.otherElements["TOTKTouchControls"].isHittable)
    }

    private func choose(_ title: String, for row: String, restartRequired: Bool = false, expectedValue: String? = nil) {
        cell(row).tap()
        let choice = app.buttons[title]
        expectHittable(choice)
        choice.tap()
        let restart = app.alerts["Restart required"]
        if restartRequired {
            XCTAssertTrue(restart.waitForExistence(timeout: 5))
            record("Restart required after changing " + row)
            restart.buttons["Keep playing"].tap()
        } else {
            XCTAssertFalse(restart.exists, "Live, same-value, and reverted settings must not require restart confirmation")
        }
        XCTAssertEqual(cell(row).value as? String, expectedValue ?? title)
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

    func test00bSharedPanelBoundsWithoutPlay() {
        let card = app.otherElements["TOTKPrelaunchCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let original = card.frame
        cell("Resolution & scaling").tap()
        XCTAssertTrue(app.navigationBars["Resolution"].waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(card.frame.height, original.height, accuracy: 1)
        cell("Mode").tap()
        XCTAssertTrue(app.navigationBars["Mode"].waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(card.frame.height, original.height, accuracy: 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Resolution"].waitForExistence(timeout: 5))
        app.buttons["Back to main menu"].tap()
        XCTAssertTrue(app.navigationBars["Tears of the Kingdom"].waitForExistence(timeout: 5))
        XCTAssertTrue(cell("Play").exists)
        XCTAssertFalse(app.buttons["Game menu"].exists)
        record("Shared panel bounds and integrated navigation without Play")
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
        let resolution = cell("Resolution & scaling")
        guard resolution.isEnabled else { throw XCTSkip("This signed build does not expose display settings") }
        let frame = app.windows.firstMatch.frame
        guard abs(max(frame.width, frame.height) / min(frame.width, frame.height) - 4.0 / 3.0) < 0.001 else {
            throw XCTSkip("Full display requires a supported 4:3 screen")
        }
        resolution.tap()
        cell("Mode").tap()
        app.buttons["Input + output"].tap()
        cell("Input").tap()
        app.buttons["720 high"].tap()
        XCTAssertEqual(cell("Input").value as? String, "720 high")
        cell("Input").tap()
        app.buttons["1080 high"].tap()
        cell("Aspect").tap()
        app.buttons["16:9"].tap()
        cell("Aspect").tap()
        app.buttons["Full display"].tap()
        app.terminate()
        app.launch()
        cell("Resolution & scaling").tap()
        XCTAssertEqual(cell("Input").value as? String, "1080 high")
        XCTAssertEqual(cell("Aspect").value as? String, "Full display")
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
        let local = app.cells["DOC.sidebar.item.On My iPad"]
        XCTAssertTrue(local.waitForExistence(timeout: 10), "Stop before export if local storage is unavailable")
        local.tap()
        let documents = app.collectionViews.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["TOTK", "Tears of the Kingdom"])
        ).firstMatch
        XCTAssertTrue(documents.waitForExistence(timeout: 10), "Choose this app's local Documents folder")
        documents.tap()
        let localProvider = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: ")).firstMatch
        let localFolder = app.buttons.matching(NSPredicate(format: "label IN %@", [
            "TOTK, Actions Menu", "Tears of the Kingdom, Actions Menu"
        ])).firstMatch
        record("Local export picker before destination verification")
        XCTAssertTrue(localProvider.waitForExistence(timeout: 10), "Stop before Save unless the provider is local storage")
        XCTAssertTrue(localFolder.waitForExistence(timeout: 10), "Stop before Save unless the local app folder is current")
        filename.tap()
        let old = filename.value as? String ?? "TOTK Save"
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + transferName)
        XCTAssertEqual(filename.value as? String, transferName)
        record("Own save export destination")
        XCTAssertTrue(localProvider.exists && localFolder.exists, "The verified local destination must remain current before Save")
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(filename.waitForNonExistence(timeout: 30))
        record("Own save exported through Files")
    }

    private func enterLocalImportFolder(_ folderName: String) {
        cell("Import save folder").tap()
        let local = app.cells["DOC.sidebar.item.On My iPad"]
        XCTAssertTrue(local.waitForExistence(timeout: 15))
        local.tap()
        let documents = app.collectionViews.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["TOTK", "Tears of the Kingdom"])
        ).firstMatch
        XCTAssertTrue(documents.waitForExistence(timeout: 10))
        documents.tap()
        let localProvider = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: ")).firstMatch
        XCTAssertTrue(localProvider.waitForExistence(timeout: 10), "Import source must be local storage")
        let folder = app.staticTexts[folderName].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30), app.debugDescription)
        folder.doubleTap()
        let location = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folderName + ",")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10), "Enter the exported folder before selecting it")
        XCTAssertTrue(app.staticTexts["slot_00"].firstMatch.waitForExistence(timeout: 10))
    }

    func test03bImportOwnExportThroughFiles() {
        enterLocalImportFolder(transferName)
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
        let specified = ProcessInfo.processInfo.environment["TOTK_TEST_RESTORE_BACKUP_NAME"]
        let backup: XCUIElement
        if let name = specified {
            XCTAssertTrue(name.hasPrefix("Save-") && !name.contains("/") && !name.contains("\\"))
            backup = app.buttons[name]
        } else {
            backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save-")).firstMatch
        }
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        record(specified == nil ? "Latest own backup chosen for restore" : "Exact named backup chosen for restore")
        backup.tap()
        XCTAssertTrue(app.alerts["Restore backup?"].waitForExistence(timeout: 10))
        app.alerts.buttons["Restore"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Save ready. Press Play to load it."].waitForExistence(timeout: 30))
        record("Own backup restored")
        app.alerts.buttons["OK"].tap()
    }

    func test03dCancelImportPicker() {
        cell("Import save folder").tap()
        let select = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        record("Import picker before cancellation")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(select.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Import save?"].exists)
        XCTAssertTrue(cell("Play").isEnabled)
        record("Import cancelled without replacement")
    }

    func test03eRejectIncompleteLocalSave() {
        enterLocalImportFolder("TOTKInvalidSave710b23d")
        record("Incomplete local save selected")
        app.buttons["DOCPicker.actionButton"].tap()
        let confirmation = app.alerts["Import save?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Import"].tap()
        let error = "Each slot needs progress.sav, caption.sav, footprint.sav, and direct_file_save_related.sav."
        XCTAssertTrue(app.alerts.staticTexts[error].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts.staticTexts["Save ready. Press Play to load it."].exists)
        record("Incomplete save rejected with required-file error")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(cell("Play").isEnabled)
    }

    func test03fImportPostGSIFixture() throws {
        guard let folder = ProcessInfo.processInfo.environment["TOTK_TEST_POST_GSI_FOLDER"], !folder.isEmpty else {
            throw XCTSkip("An explicitly staged post-GSI fixture folder is required")
        }
        XCTAssertFalse(folder.contains("/"))
        XCTAssertFalse(folder.contains("\\"))
        enterLocalImportFolder(folder)
        record("Verified local post-GSI fixture before import")
        app.buttons["DOCPicker.actionButton"].tap()
        let confirmation = app.alerts["Import save?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Import"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Save ready. Press Play to load it."].waitForExistence(timeout: 30))
        record("Post-GSI fixture import completed before Play")
        app.alerts.buttons["OK"].tap()
    }

    func test03gOpenEditorAndCancelBeforePlay() {
        cell("Edit this save").tap()
        let slot = app.buttons["slot_00"]
        XCTAssertTrue(slot.waitForExistence(timeout: 10))
        slot.tap()
        let close = app.buttons["Close save editor"]
        defer { if close.exists { close.tap() } }
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Save editor"].exists)
        let rupees = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rupees")).firstMatch
        XCTAssertTrue(rupees.waitForExistence(timeout: 45), "Require readable editor web content, not only its native title")
        record("Online save editor content loaded before cancellation")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Apply edited save?"].exists)
        XCTAssertTrue(cell("Play").isEnabled)
        record("Save editor cancelled without apply")
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
        let thermal = app.staticTexts["TOTKThermalHUD"]
        XCTAssertTrue(thermal.waitForExistence(timeout: 10))
        XCTAssertTrue(["Nominal", "Fair", "Serious", "Critical"].contains(thermal.value as? String ?? ""))
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
        XCTAssertFalse(app.navigationBars["Tears of the Kingdom"].exists, "A reviewed game control must not become a prelaunch settings tap")
        XCTAssertTrue(app.otherElements["TOTKTouchControls"].exists, "Require the game touch-control view before a coordinate press")
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).press(forDuration: 0.15)
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
        for title in ["Resolution & scaling", "Performance overlay", "Apple Metal HUD",
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
        for title in ["Import save folder", "Export save folder", "Back up save", "Restore backup", "Edit this save"] {
            XCTAssertFalse(cell(title).isEnabled, "Save transfers must stay sealed during play")
        }
        XCTAssertTrue(cell("Game language").isEnabled)
        XCTAssertTrue(app.staticTexts["Language changes require an app restart."].exists)
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
        XCTAssertFalse(app.staticTexts["TOTKThermalHUD"].exists)
        record("Native HUD disabled live")
        openGameMenu()
        XCTAssertEqual(cell("Apple Metal HUD").value as? String, "Off")
        choose("On", for: "Apple Metal HUD")
        closeGameMenu()
        XCTAssertTrue(app.staticTexts["TOTKThermalHUD"].waitForExistence(timeout: 5))
        record("Native HUD enabled live")
        openGameMenu()
        XCTAssertEqual(cell("Performance overlay").value as? String, "Off")
        XCTAssertEqual(cell("Apple Metal HUD").value as? String, "On")
        closeGameMenu()
        record("Live HUD preferences retained after reopening shared settings")
    }

    func test06cExistingGameNextLaunchControlPreference() {
        openGameMenu()
        let row = "Invert mouse Y"
        let original = cell(row).value as? String ?? "Off"
        expectRestartPending(false)
        defer {
            if app.alerts["Restart required"].exists { app.alerts["Restart required"].buttons["Keep playing"].tap() }
            if !app.buttons["Close game menu"].isHittable { openGameMenu() }
            choose(original, for: row)
            closeGameMenu()
        }
        choose(original, for: row)
        expectRestartPending(false)
        cell(row).tap()
        expectHittable(app.buttons["On"])
        cancelSettingsPopover()
        XCTAssertFalse(app.buttons["On"].exists)
        XCTAssertEqual(cell(row).value as? String, original)
        XCTAssertFalse(app.alerts["Restart required"].exists)
        let changed = original == "On" ? "Off" : "On"
        choose(changed, for: row, restartRequired: true)
        expectRestartPending(true)
        choose(changed, for: row)
        closeGameMenu()
        openGameMenu()
        XCTAssertEqual(cell(row).value as? String, changed)
        expectRestartPending(true)
        choose(original, for: row)
        expectRestartPending(false)
        record("Reverted preference clears pending restart without a prompt")
    }

    func test06dExistingGameOutsideDismissalProtectsModal() {
        let touch = app.otherElements["TOTKTouchControls"]
        expectHittable(touch)
        openGameMenu()
        let close = app.buttons["Close game menu"]
        defer {
            if app.alerts["Mouse sensitivity"].exists { app.alerts["Mouse sensitivity"].buttons["Cancel"].tap() }
            if close.isHittable { close.tap() }
        }
        let window = app.windows.firstMatch
        let card = app.otherElements["TOTKGameMenuCard"]
        XCTAssertGreaterThan(card.frame.minX - window.frame.minX, 4)
        let outside = window.coordinate(withNormalizedOffset: CGVector(
            dx: (card.frame.minX - window.frame.minX) / window.frame.width / 2, dy: 0.5))
        outside.tap()
        expectHittable(app.buttons["Game menu"])
        expectHittable(touch)
        openGameMenu()
        cell("Mouse sensitivity").tap()
        let editor = app.alerts["Mouse sensitivity"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        outside.tap()
        XCTAssertTrue(editor.exists, "Outside dismissal must not bypass an active modal")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertFalse(touch.isHittable)
        record("Settings modal retains input shield after outside tap")
        editor.buttons["Cancel"].tap()
        outside.tap()
        expectHittable(app.buttons["Game menu"])
        expectHittable(touch)
        record("Outside dismissal restores game hit testing")
    }

    func test06eKeyboardMappingsApplyLive() {
        openGameMenu()
        expectRestartPending(false)
        cell("Keyboard mappings").tap()
        let mappings = app.navigationBars["Keyboard mappings"]
        XCTAssertTrue(mappings.waitForExistence(timeout: 5))
        var remapped = false
        defer {
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            if remapped && mappings.exists {
                cell("Move forward").tap()
                app.buttons["W"].tap()
            }
            if mappings.exists { mappings.buttons["Settings"].tap() }
            if app.buttons["Close game menu"].isHittable { closeGameMenu() }
        }
        for (action, key) in [("Move forward", "W"), ("Move left", "A"), ("Move backward", "S"), ("Move right", "D"),
                              ("Camera up", "Up arrow"), ("Camera left", "Left arrow"), ("Camera down", "Down arrow"), ("Camera right", "Right arrow")] {
            XCTAssertEqual(cell(action).value as? String, key)
        }
        cell("Move forward").tap()
        XCTAssertTrue(app.buttons["A"].exists)
        XCTAssertFalse(app.buttons["A"].isEnabled, "A already belongs to Move left")
        for reserved in ["Escape", "Command", "Left Command", "Right Command"] {
            XCTAssertFalse(app.buttons[reserved].exists)
        }
        XCTAssertTrue(app.buttons["R"].isEnabled, "R must be unbound before this reversible test")
        app.buttons["R"].tap()
        remapped = true
        XCTAssertFalse(app.alerts["Restart required"].exists)
        XCTAssertEqual(cell("Move forward").value as? String, "R")
        XCTAssertFalse(app.otherElements["TOTKTouchControls"].isHittable)
        record("Live keyboard mapping changed without game key input")
        cell("Move forward").tap()
        app.buttons["W"].tap()
        remapped = false
        XCTAssertEqual(cell("Move forward").value as? String, "W")
        XCTAssertFalse(app.alerts["Restart required"].exists)
        mappings.buttons["Settings"].tap()
        expectRestartPending(false)
        closeGameMenu()
        record("Keyboard defaults restored after live mapping test")
    }

    func test06fExistingGameGraphicsAndTouchApplyLive() throws {
        openGameMenu()
        let fpsRow = "Target frame rate"
        let taaRow = "Anti-aliasing (TAA)"
        guard cell(fpsRow).isEnabled else {
            closeGameMenu()
            throw XCTSkip("The installed game lacks the supported real-time frame-cap profile")
        }
        let taaSupported = cell(taaRow).isEnabled
        let originalTAA = (cell(taaRow).value as? String)?.hasPrefix("On") == true ? "On" : "Off"
        defer {
            if app.alerts["Hide touch controls?"].exists { app.alerts["Hide touch controls?"].buttons["Cancel"].tap() }
            if app.buttons["30 FPS"].isHittable || app.buttons["On"].isHittable { cancelSettingsPopover() }
            if !app.buttons["Close game menu"].isHittable { openGameMenu() }
            choose("60 FPS", for: fpsRow)
            if taaSupported {
                choose(originalTAA, for: taaRow, expectedValue: originalTAA == "On" ? "On" : "Off")
            }
            choose("Automatic", for: "Touch controls")
            closeGameMenu()
        }

        cell(fpsRow).tap()
        expectHittable(app.buttons["30 FPS"])
        XCTAssertTrue(app.buttons["60 FPS"].isEnabled)
        let offers40 = app.buttons["40 FPS"].exists
        let maximumRefresh = UIScreen.main.maximumFramesPerSecond
        XCTAssertEqual(offers40, maximumRefresh > 0 && maximumRefresh % 40 == 0,
                       "40 FPS requires a display whose maximum refresh is divisible by 40")
        cancelSettingsPopover()
        for rate in offers40 ? ["30 FPS", "40 FPS", "60 FPS"] : ["30 FPS", "60 FPS"] {
            choose(rate, for: fpsRow)
        }
        record("Supported live target frame-rate choices retained")

        if taaSupported {
            choose("On", for: taaRow, expectedValue: "On")
            closeGameMenu()
            let frames = expectation(description: "Allow requested TAA to reach subsequent gameplay frames")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { frames.fulfill() }
            wait(for: [frames], timeout: 5)
            record("Gameplay two seconds after TAA On request")
            openGameMenu()
            XCTAssertEqual(cell(taaRow).value as? String, "On")
            XCTAssertFalse(app.alerts["Restart required"].exists)
            choose(originalTAA, for: taaRow, expectedValue: originalTAA == "On" ? "On" : "Off")
        } else {
            XCTAssertEqual(cell(taaRow).value as? String, "Unavailable")
        }

        cell("Touch controls").tap()
        expectHittable(app.buttons["Off"])
        app.buttons["Off"].tap()
        let hide = app.alerts["Hide touch controls?"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.buttons["Hide controls"].tap()
        XCTAssertEqual(cell("Touch controls").value as? String, "Off")
        XCTAssertFalse(app.alerts["Restart required"].exists)
        XCTAssertFalse(app.otherElements["TOTKTouchControls"].exists)
        let window = app.windows.firstMatch
        let card = app.otherElements["TOTKGameMenuCard"]
        XCTAssertGreaterThan(card.frame.minX - window.frame.minX, 4)
        let outside = window.coordinate(withNormalizedOffset: CGVector(
            dx: (card.frame.minX - window.frame.minX) / window.frame.width / 2, dy: 0.5))
        outside.tap()
        expectHittable(app.buttons["Game menu"])
        XCTAssertFalse(app.otherElements["TOTKTouchControls"].exists)
        record("Touch controls removed live while bottom-left menu stays available")

        openGameMenu()
        XCTAssertEqual(cell("Touch controls").value as? String, "Off")
        choose("Automatic", for: "Touch controls")
        XCTAssertTrue(app.otherElements["TOTKTouchControls"].exists)
        XCTAssertFalse(app.otherElements["TOTKTouchControls"].isHittable)
        outside.tap()
        expectHittable(app.buttons["Game menu"])
        expectHittable(app.otherElements["TOTKTouchControls"])
        record("Automatic touch controls restored after outside dismissal")
    }

    func test07ExistingGameSnapshot() {
        record("Current existing game without input or relaunch")
    }

}
