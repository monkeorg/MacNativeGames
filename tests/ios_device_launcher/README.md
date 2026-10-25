# Installed iPad launcher UI tests

This target builds only a small XCTest runner. It controls the installed `com.smartvelo.totk` app.
It does not build, install, or transfer the game app or its data. It requires a physical iPad.

Build locally:

```sh
xcodegen generate --spec tests/ios_device_launcher/project.yml
xcodebuild build-for-testing \
  -project tests/ios_device_launcher/DeviceLauncherTests.xcodeproj \
  -scheme DeviceLauncherTests \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /path/to/isolated/DerivedData
```

Use `prepare_runner.py --help` to sign the runner with existing local development credentials.
The script validates profile coverage and the matching certificate. It creates a temporary keychain, then deletes it.
Passwords, certificates, profiles, device identifiers, and game saves do not belong in this directory.

The prepared `.xctestrun` uses `UseDestinationArtifacts`. Install only the signed runner, then run:

```sh
xcodebuild test-without-building \
  -xctestrun /path/to/Prepared/InstalledDeviceLauncher.xctestrun \
  -destination 'platform=iOS,id=<connected-iPad-identifier>' \
  -only-testing:DeviceLauncherUI/DeviceLauncherUI/test01PreferencesLayoutAndLifecycle \
  -parallel-testing-enabled NO \
  -resultBundlePath /path/to/results.xcresult
```

Coordinate device ownership before installation or execution. These tests launch and may terminate the installed app.
Select individual tests. Run prelaunch tests before Play; transfer tests need their separate hash checks.
The preference test restores the original language and leaves Apple Metal HUD on and the custom overlay off.
The backup test preserves the active save. The Files export test selects On My iPad and the app folder before it publishes a uniquely named folder.
It requires the browsing-root identifier to show the LocalStorage provider and the current navigation button to name the exact app folder before Save.
The browsing-root title can remain On My iPad after folder navigation; it does not identify the current folder.
If these selectors change, the test stops before Save; inspect the picker instead of dropping the local-destination guard.
The Files import test selects that same folder through On My iPad, then confirms import.
Run export separately. Compare every exported file against a private pre-transfer snapshot before you run import.
Compare the full profile after import, including account identity. Do not substitute a picker screenshot for byte equality.
The prepared run stores its shared export name in `transfer-name.txt` beside the `.xctestrun` file.
The Play test runs last and captures the screen after 30 seconds with native HUD enabled.
Screenshots and accessibility trees remain in the result bundle. Treat them as private device evidence.

The Files tests assume English system labels and the visible folder name `TOTK` or `Tears of the Kingdom`.
`test03dCancelImportPicker` cancels the import picker before confirmation and checks that Play remains available.
`test03eRejectIncompleteLocalSave` selects the externally prepared local folder `TOTKInvalidSave710b23d`.
That fixture must contain only `slot_00/progress.sav`. The test never creates fixture files.
It requires the specific missing-required-files error. Compare the active profile, backup count, and staging folders independently afterward.
Save transfer verification is separate from successful game loading and native HUD visual verification.

If XCTest reports `Timed out while enabling automation mode`, no test action has executed.
Resolve the device-side automation prompt before a narrow retry. Do not treat runner installation as UI acceptance.

The import test requires the exported folder's navigation title and `slot_00` contents before it confirms selection.
This prevents a highlighted folder from being mistaken for the current folder in the Files picker.

Physical evidence from 2026-10-23: preferences, lifecycle, centered layout, backup, and Files export passed.
All 19 exported save files matched the private pre-transfer SHA256 snapshot.
The initial import script selected enclosing Documents and exposed a production copy-stack overflow.
The full 22-file profile matched its immediate pre-transfer hashes, excluding the incomplete import staging directory.
The corrected import script passed on implementation `2dc8c34` after explicit folder navigation confirmation.
All 22 profile files matched the immediate pre-transfer snapshot after import. No staging directories remained.
This comparison does not establish equality with an older milestone backup.
Physical restore of the latest own-save backup also passed, with the same 22-file equality before Play.

Play reached the real title screen. Three separately reviewed touch-A presses selected Continue, the existing save,
and its Load confirmation. A physical screenshot then showed Link in Beneath Hyrule Castle.
No New Game or save-overwrite command was selected.
The native HUD preference was on, but no native HUD appeared in the captured title or gameplay screenshots.
A later launch with `MTL_HUD_ENABLED=1` displayed the native HUD. The user then enabled the device Developer setting and confirmed the in-app switch works.

The Play test enables the existing timing-only `DM_NVN_TSV` diagnostic and `TOTK_AUTOLOAD=1` in the launched app's environment.
Autoload attempts to open the newest existing save; a passed Play test alone does not establish successful save loading.
Inspect the game log for actual save reads and the screenshot for gameplay before making that claim.
The optional existing-process touch test skips unless explicit normalized coordinates are supplied.
It sends one reviewed 0.15-second coordinate press in landscape. A transparent touch view need not report itself hittable.
It first requires the game touch view to exist and the prelaunch navigation bar to be absent. A stale game screenshot cannot authorize a settings tap.
Review a current screenshot before each such touch. Use it only for a known control; never select New Game.

## Shared settings overlay regression tests

These tests require the updated app. Build and sign the small runner locally, then wait for device ownership before installation.

| Test | Checks | App lifecycle |
|---|---|---|
| `test00CompactPrelaunchGlass` | Centered card, maximum 960-point width and 760-point height, landscape, screenshot | Launch |
| `test01bDisplayPreferencesPersistWhenSupported` | Capability gate, 720/1080 choice, 16:9/full-display choice, persisted 1080/full display | Relaunch |
| `test06aExistingGameMenuOpenCloseRestoresHitTesting` | Full settings rows, mapping navigation, disabled save transfers, input shield, Resume restores touch hit testing | Activate existing game |
| `test06bExistingGameMenuLiveHUDPersistence` | Full/FPS-only/Off action sheets, native HUD action sheet, retained values and screenshots after menu reopen | Activate existing game |
| `test06cExistingGameNextLaunchControlPreference` | Restart badge/prompt, same-value/cancel behavior, pending state across menu reopen, revert clears pending state | Activate existing game |
| `test06dExistingGameOutsideDismissalProtectsModal` | Outside tap closes settings, active modal keeps input shield, dismissal restores hit testing | Activate existing game |
| `test07ExistingGameSnapshot` | Screenshot and accessibility tree without input or game relaunch | Activate existing app |

The display preference test skips when the signed capability is absent or the screen is wider than supported.
It leaves 1080/full-display selected when supported. It does not prove projection correctness or actual render dimensions.

The live tests require an existing game process. They call `activate()`, never `launch()` or `terminate()`.
The hit-testing test requires touch controls enabled. It verifies routing without a game-input tap.
The HUD test leaves the custom overlay off, native HUD on, and the menu closed.
Menu reopen checks verify persisted row values. Screenshots require visual inspection to establish live HUD behavior.
The next-launch control test changes only a preference; it cannot prove runtime input remained unchanged.
Screenshots provide separate evidence of native HUD visibility and the glass appearance.

Stable accessibility identifiers required by the tests:

- `TOTKPrelaunchCard` on the prelaunch glass card.
- `TOTKGameMenuCard` on the live navigation container.
- `Close game menu` as the live settings close button accessibility label.
- `TOTKTouchControls` on the touch-control view.
- `TOTKSettingTiming.<row title>` on an accessible Live/Restart/Restart required badge.

These shared-overlay regression tests have not run on a device yet. They do not import, export, back up, or restore saves.

The restart tests require the badge/prompt implementation. Do not run them against the older installed build.
Only the snapshot test has passed on the current game process; the new live/restart and outside-dismissal checks remain unexecuted.

`test03fImportPostGSIFixture` skips unless the runner environment explicitly supplies `TOTK_TEST_POST_GSI_FOLDER`.
For the reviewed public fixture, stage `PostGSI-ParagliderGear` in the app's local Documents folder and supply that exact name.
The test requires local storage, the current folder title, and `slot_00` before normal import confirmation.
It uses the production import backup. It does not create a full profile backup or synthesize save files.
Verify the staged fixture against its private provenance manifest before this test. Do not run it as part of an unfiltered suite.
