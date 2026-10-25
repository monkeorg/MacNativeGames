# iPad source object build

The manual **iPhoneOS source objects** workflow compiles production iPad source into arm64 object files using the Apple SDK already installed on a GitHub-hosted Mac. It does not require proprietary game data, generated game modules, extracted resources, signing credentials, or replacement headers. It does not link, sign, install, launch, run tests, or use a simulator.

This is build scaffolding, not successful Apple build evidence. The current Linux workspace has no Xcode. At preparation time, the repository's GitHub API returned no registered workflows, so this new workflow has not run. `workflow_dispatch` requires registration of the workflow on the default branch and Actions availability. An unrun workflow, a successful script edit, or a Linux compiler cannot establish that the iPad sources compile with Apple SDKs.

The attempted local command `python games/totk/ios/tools/build_sources.py --jobs 4 --output <new-output>` stopped at the macOS/Xcode preflight with exit status 2. It produced no object files or app. This is an environment blocker, not an Apple compiler result. The build script and workflow received parent and independent source review; no tests or simulators ran.

## Scope

The script compiles these nine Objective-C production files twice, for 18 object files:

- `games/totk/ios/Sources/main.m`
- `games/totk/ios/Sources/launcher.m`
- `games/totk/ios/Sources/launcher_settings.m`
- `games/totk/ios/Sources/save_store.m`
- `games/totk/ios/Sources/game_menu.m`
- `games/totk/ios/Sources/mouse_input.m`
- `games/totk/ios/Sources/touch_pad.m`
- `games/totk/runtime/frontend_ios.m`
- `games/totk/runtime/gamepad.m`

Both profiles define `TOTK_GAME_V143=1`. The `v143-display-settings` profile additionally defines `TOTK_IOS_DISPLAY_SETTINGS=1`; `v143-default` leaves it absent. Compilation targets `arm64-apple-ios26.0`, uses ARC and blocks, and enables the normal Apple framework modules. No compile result is substituted for a missing source.

The required headers are checked in. In particular, `dmsh_chain.h`, `fps_overlay.h`, and `include/totk_ui_lang.h` come from `games/totk/third_party/d2r_gfx/gfx/nvn`; `runtime.h`, `fs_host.h`, and controller/mouse headers come from `games/totk/runtime`. Standard SDK headers supply UIKit, Foundation, GameController, QuartzCore, AVFAudio, and Metal.

## Run on a Mac

Use Xcode 26 or newer with an installed iPhoneOS SDK 26 or newer:

```sh
python3 games/totk/ios/tools/build_sources.py --jobs 4 --output /tmp/totk-ios-source-build
```

`--output` must be new or empty and must not contain production sources; stale object files are never reused. `--jobs` accepts 1 through 8. `--developer-dir /Applications/Xcode.app/Contents/Developer` selects an explicit installed Xcode. Otherwise the script respects an existing `DEVELOPER_DIR`, or selects the newest supported stable Xcode among the active installation and `/Applications/Xcode*.app`. No SDK is downloaded. An absent or too-old Apple toolchain fails the build.

The workflow uses the same command on `macos-15`, clearing any runner `DEVELOPER_DIR` override so the script selects a supported installed Xcode. It only exposes manual dispatch; it does not add push or pull-request test execution. The existing test workflow is unchanged.

## Evidence and limits

`report.json` records the source revision, clean-tree/tracked-dirty/untracked-present flags without filenames, selected Xcode/SDK/compiler, exact compile commands, each source hash, return status, elapsed time, and successful object sizes/hashes. Each source/profile pair has a compiler log. The workflow uploads the report, object files, and logs; it excludes the compiler module cache. A failed compile fails the job and retains its diagnostics.

A successful result establishes only that these 18 production source/profile combinations compiled to objects with the recorded Apple toolchain. It does not cover every runtime/renderer translation unit, symbol resolution, frameworks at link time, generated game modules, signed display-profile construction, application packaging, signing, installation, or physical-device behavior. A complete app build still needs the retained local game inputs and Apple build/signing environment described in the roadmap. Device and gameplay acceptance remain separate.
