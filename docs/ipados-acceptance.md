# Next physical iPad acceptance run

Target: TOTK 1.4.3 on the existing M4 iPad. Cloud changes are recorded in [the audit](ipados-cloud-audit.md). Do not treat a successful build, install, drawable resize, HUD counter, or locked-device test block as functional acceptance.

The earlier [cloud continuation](ipados-roadmap-status.md) prohibited tests during that cloud phase. The user has authorized Apple builds and preparation for this local continuation. Apply the sequence below to the current candidate, including the [Controls source](ipados-controls.md). No simulator is required.

The revised shared settings overlay has no completed local acceptance result recorded here. Earlier build and device results do not verify this candidate. Record Apple compilation, tests, installation, launch, and gameplay as separate results.

1. **Build and test on the Mac.** Freeze the candidate source and record its commit, local changes, and build options. Reuse the retained inputs, dependencies, shader caches, and Xcode build cache. Build the full physical-iPad app with the intended signed display profile. Run the repository tests, including Foundation save/preferences and input cases. Retain the previous signed app for rollback. A source-object build alone does not establish a complete app build.

2. **Back up the full profile privately.** Before installation, copy the current save/profile and account identity from the unlocked iPad. Record a private immediate snapshot of all files and hashes. Keep saves, device identifiers, signing material, and private manifests outside Git. Preserve the existing bundle identity and signing team.

3. **Install and verify preservation.** Install the candidate only after the build, tests, and backup succeed. Compare every profile file and the account identity with the immediate pre-install snapshot. Investigate unexplained changes before Play. Record installation separately from launch and gameplay.

4. **Verify the pre-launch settings.** Check the full landscape settings card, all Graphics/Controls/Saves/Language sections, scrolling, touch, accessibility labels, and controller navigation. Change implemented preferences and relaunch. Check persistence, malformed-value recovery, System language, and foreground return. Confirm unsupported display controls remain disabled. Test Automatic touch controls and controller-required Off. Restore the intended settings before Play.

5. **Verify the shared live menu and lifecycle.** Press Play once and load the known existing save. Avoid New Game and overwrite prompts. Open the gear/Escape menu and verify all Graphics/Controls/Saves/Language sections plus **Resume game**. Check Full/FPS/Off and native HUD changes live. Verify other preference changes apply only after the next app launch. Keep Saves visible but disabled after Play; no transfer, backup, or restore may run. The menu does not pause gameplay; controller input may still reach the game.

   Open and close the menu with touch buttons/sticks or mouse buttons held. Require no stuck input or mouse camera motion beneath it. Test background/foreground, scene focus loss, pointer-lock denial/loss, and mouse/controller disconnect/reconnect. Mouse camera input requires both focus and actual pointer lock. Check Escape and Resume restore the intended input state. Native HUD may require **Settings → Developer → Graphics HUD → Show Graphics HUD**.

6. **Verify save round trips before Play.** Restart the app before these checks; the previous process sealed its save store. Export through Files and compare all bytes privately. Import that verified folder, then restore a known own backup. After each replacement, compare the active save and account identity with the corresponding immediate snapshot. Check backup creation and staging cleanup. Test canceled/unavailable cloud-provider access and incomplete input. Require a useful error and unchanged save/identity. Keep the original export intact. A synthetic read-denial probe does not replace an actual provider test.

7. **Verify projection and input.** Compare 720-high 16:9 with experimental Full display and 1080 high in separate app launches. At 4:3, Full display requests 960×720 or 1440×1080. Confirm actual scene render targets with GPU capture; record drawable dimensions separately. Check camera proportions/FOV, HUD, world markers, map, menus, cutscenes, effects, and touch layout. Verify mouse direction, sensitivity, inversion, and button mappings on hardware. Keys 3/4 must not change the iPad canvas/projection. Known world-marker and pixel-snapped UI limitations keep Full display experimental.

8. **Measure performance separately.** Select and warm three real scenes, agree numerical stability thresholds, and follow the [30-minute baseline protocol](ipados-baseline.md). Distinguish native rendered, interpolated, and presented frames. Capture synchronized frame times, memory, and thermal state. Use the [graphics inventory and trace analyzer](ipados-graphics.md) for supporting evidence. Partial TSV readback and present-call cadence cannot establish stable native 60 FPS.

Keep raw captures, saves, account/device identifiers and signing material private. Record pass/fail/unavailable for each step with the actual tested commit. A blocked test has no functional result. Leave hardware-dependent issue acceptance open until the corresponding evidence exists.
