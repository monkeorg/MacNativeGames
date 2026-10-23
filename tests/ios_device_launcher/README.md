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
The preference test restores the original language and leaves Apple Metal HUD on and the custom overlay off.
The backup test preserves the active save. The Files export test publishes a uniquely named folder in TOTK Documents.
The Files import test selects that same folder through On My iPad, then confirms import.
Run export separately. Compare every exported file against a private pre-transfer snapshot before you run import.
Compare the full profile after import, including account identity. Do not substitute a picker screenshot for byte equality.
The prepared run stores its shared export name in `transfer-name.txt` beside the `.xctestrun` file.
The Play test runs last and captures the screen after 30 seconds with native HUD enabled.
Screenshots and accessibility trees remain in the result bundle. Treat them as private device evidence.

The Files tests assume English system labels and the app's visible folder name `TOTK`.
Save transfer verification is separate from successful game loading and native HUD visual verification.

If XCTest reports `Timed out while enabling automation mode`, no test action has executed.
Resolve the device-side automation prompt before a narrow retry. Do not treat runner installation as UI acceptance.

The import test requires the exported folder's navigation title and `slot_00` contents before it confirms selection.
This prevents a highlighted folder from being mistaken for the current folder in the Files picker.

Physical evidence from 2026-10-23: preferences, lifecycle, centered layout, backup, and Files export passed.
All 19 exported save files matched the private pre-transfer SHA256 snapshot.
The initial import script selected enclosing Documents and exposed a production copy-stack overflow.
The full 22-file profile remained unchanged, excluding the incomplete import staging directory.
The corrected import script requires folder navigation confirmation. Its successful import result remains unverified.
