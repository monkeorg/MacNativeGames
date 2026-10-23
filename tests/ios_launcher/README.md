# Launcher simulator UI tests

This harness compiles the production launcher, preferences, and save store directly. It requires Xcode and XcodeGen.
It contains synthetic text fixtures only. It does not link the game runtime or use game data.

Optional regression harness. Do not run it during the current device-only workflow.

From the repository root when simulator tests are explicitly wanted:

```sh
xcodegen generate --spec tests/ios_launcher/project.yml
xcodebuild test \
  -project tests/ios_launcher/LauncherUITests.xcodeproj \
  -scheme LauncherUITests \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath /tmp/macnativegames-launcher-tests \
  -parallel-testing-enabled NO
```

The tests cover deferred Play, duplicate Play prevention, landscape, foreground return, preference persistence,
invalid preference recovery, the controller requirement, and backup/restore through the real menu.
The restore test changes the active synthetic save after a backup, then checks the restored bytes through the Play callback.

The harness uses its own simulator bundle identity. It resets only its own preferences and synthetic save directory.
The Play callback records its call count and validated preferences. It does not start a game thread.
These tests do not verify production `main.m`, controller hardware, external Files providers, signing, or physical-device save loads.

On 2026-10-23, the targeted backup/restore test passed. The full five-test suite did not complete. Temporary simulator build results were removed at the user's request.
