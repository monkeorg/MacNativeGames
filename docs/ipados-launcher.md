# iPad launcher and saves

The compact Liquid Glass launcher appears before the game starts. Press **Play** after you choose settings or manage saves. Close and reopen the app to return to the launcher.

## Preferences

Tap a settings row to open its choices. Tap a choice to apply it.

- **Render resolution:** selects **720 high** or **1080 high** in a build with the signed display profile. The default is 720 high.
- **Aspect ratio:** selects **16:9** or experimental **Full display** on supported displays. The default is 16:9.
- **Performance overlay:** selects Full, FPS only, or Off.
- **Apple Metal HUD:** selects Apple’s native performance overlay. Enable device-level support once as described below.
- **Controls:** Automatic keeps the existing touch behavior. Off requires a connected controller with an extended gamepad profile.
- **Language:** uses the same preference as the app's pane in iPad Settings. System follows the device language.

Preferences persist between launches. Resolution, aspect ratio, controls, and language apply at Play. Invalid stored values return to defaults. A developer-supplied `TOTK_LANG` environment value still takes precedence.

Resolution and aspect controls require the TOTK 1.4.3 build option `--ios-display-settings`. It adds `TOTKIOSDisplaySettingsVersion = 1`, backed by the signed `TOTK_IOS_DISPLAY_SETTINGS` profile. Other builds disable these choices and retain 1280×720 at 16:9. A saved preference cannot add this capability.

The height label refers to the requested game render and output canvas, not the Metal drawable or physical screen resolution. At 16:9, the choices request 1280×720 or 1920×1080. Full display uses the actual landscape aspect; a 4:3 display requests 960×720 or 1440×1080. Other display aspects produce different widths. Confirm actual render targets and drawable dimensions separately.

**Full display is experimental.** It applies the existing camera-aspect patch. World-object markers and pixel-snapped UI positions have known limitations. The default preserves vertical field of view; a narrower aspect shows less at the sides. This is not a claim of complete graphics parity or stable native 60 FPS. See the [baseline protocol](ipados-baseline.md).

On the tested iPad, the native HUD appeared with `MTL_HUD_ENABLED=1` supplied at process launch. The saved preference alone did not activate it. Enable **Settings → Developer → Graphics HUD → Show Graphics HUD** once. The user confirmed the in-app switch works after this device setting was enabled.

## During gameplay

Tap the floating **gear** or press **Escape** on a connected keyboard to open the Liquid Glass game menu. Use **Close menu**, the close button, or Escape to dismiss it.

The menu does **not pause the game**. It blocks touch input to the game and releases mouse capture while open. Controller input can still reach the game.

Change **Game overlay** between Full, FPS, and Off, or toggle **Metal performance HUD**, without a restart. These choices also persist. Resolution, aspect ratio, and language changes require a return to the launcher after an app restart.

A connected mouse uses the existing Mac camera controls while the app has focus and the system grants pointer lock. The default bindings use left click to attack, right click to draw the bow, and middle click to target. Left click shoots while right click stays held. Mouse motion uses the existing sensitivity and decay behavior.

Menu opening, focus loss and touch-view removal clear tracked touch buttons and sticks. Late movement from canceled fingers is ignored; mouse clicks do not also operate the virtual touch pad. Mouse capture also releases for scene/key-window changes and keyboard entry. These paths still require the next Apple build and physical regression run.

The game menu releases mouse buttons and camera input. Dismissal restores the prior capture preference; the system decides whether to grant pointer lock again. Background, disconnect, and lock loss also release mouse input. Physical mouse behavior remains unverified.

## Save transfers

The Saves section supports folder import, folder export through Files, local backups, and backup restoration. These actions are available only before Play.

Select the console save directory containing complete slots, rather than the entire app profile or one slot:

```text
TOTK Save/
  slot_00/
    progress.sav
    caption.sav
    footprint.sav
    direct_file_save_related.sav
  slot_01/                 # optional; slot_00 through slot_05 are supported
    ...
  album/                   # optional
  storage/                 # optional
```

Each present slot must contain the four nonempty files above. Other regular files and directories are copied, including album and storage data. Import checks layout and transfer limits; it does not parse or repair game-save contents or guarantee compatibility with every game version. Keep the source export unchanged.

Use **Export save folder** to save a complete copy in Files. The exported folder can be selected again for import. Export does not include `account.uid`, shader caches, or other app-profile files.

Import and restore first copy the incoming folder into a private stage. They reject links, special files, excessive nesting, incomplete slots, and oversized input. Limits are 64 MiB per file, 512 MiB total, 10,000 entries, and 12 nested directory levels.

Before replacement, the app backs up the current save under `Documents/SaveBackups`. It then atomically swaps the active save directory. A failed copy, validation, backup, or swap leaves the current save unchanged. The app's account identity stays outside the replaced directory.

**Restore backup** selects a previous local backup. Restore also backs up the current save before replacement. Backups remain until you remove them through Files; automatic retention is not implemented.

A first import can populate a new account with no existing save. An empty account cannot be exported or manually backed up until it has a complete slot.

Do not modify save files from Files while the game runs. The launcher seals its save store before Play and stays unavailable for the remainder of that app process.

## Development checks

Run all repository tests with the existing build virtual environment. The save probes compile the production Foundation code on macOS and use synthetic fixtures. They verify byte equality, backup/restore, identity preservation, refusal cases, and preferences.

```sh
python -m unittest discover -s tests
```

Use the [physical-device UI runner](../tests/ios_device_launcher/README.md) against the installed app. It does not transfer the game or use a simulator.

| Evidence | State |
|---|---|
| Files import, backup restore, byte equality, and existing-save gameplay load | Passed physically on earlier implementation `2dc8c34`. |
| New display-profile bundle | Build passed; this does not verify installation or gameplay. |
| Liquid Glass launcher and live menu | Implemented and compiled; new physical UI checks pending. |
| 1080-high and Full display | Physical graphics and gameplay checks pending. |
| Mouse capture, direction, sensitivity, and menu release | Physical mouse checks pending. |
| Sustained native 60 FPS | Unverified; requires the sustained benchmark. |

The `3d7d6e8` checkpoint subsequently installed successfully; all 35 save-directory files matched their immediate pre-install SHA256 snapshot. New physical checks did not execute because the iPad was locked. See the [cloud continuation evidence](ipados-cloud-audit.md), [graphics inventory](ipados-graphics.md) and [next physical acceptance checklist](ipados-acceptance.md).

Apple reference: [Monitor Metal graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance).
