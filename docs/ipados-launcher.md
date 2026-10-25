# iPad launcher and saves

The full Liquid Glass settings menu appears before the game starts. Press **Play** after you choose settings or manage saves. During play, the floating gear opens the same Graphics, Controls, Saves, and Language sections as an overlay.

## Preferences

Tap a settings row to open its choices. Tap a choice to apply it.

- **Render resolution:** selects **720 high** or **1080 high** in a build with the signed display profile. The default is 720 high.
- **Aspect ratio:** selects **16:9** or experimental **Full display** on supported displays. The default is 16:9.
- **Target frame rate:** requests a native 30, 40, or 60 FPS ceiling. Only device-supported choices appear; 40 FPS requires a compatible display. The default is 60. This is a pacing limit, not a measurement of achieved FPS.
- **Anti-aliasing (TAA):** requests temporal anti-aliasing when the runtime reports support. It defaults off. On is labelled requested; capability and preference state alone do not prove a frame used TAA.
- **Performance overlay:** selects Full, FPS only, or Off.
- **Apple Metal HUD:** selects Apple’s native performance overlay. Enable device-level support once as described below.
- **Touch controls:** Automatic keeps the existing touch behavior. Off asks for confirmation and leaves the bottom-left game-menu button visible. Before Play, Off needs a connected extended gamepad, a keyboard, or explicit confirmation of keyboard-only input.
- **Controller type:** Automatic, Xbox, PlayStation, or Switch selects the existing face-button convention.
- **Mouse:** persistent sensitivity from 1–100 and vertical inversion reuse the existing mouse-look settings.
- **Button mappings:** choose Default, a Switch button, or None for controller buttons and up to five mouse buttons. Custom bindings use hold behavior; Default retains existing modes, including bow/left-click fire.
- **Keyboard mappings:** change movement, camera and Switch-button keys. WASD moves, arrow keys turn the camera, and Escape opens the game menu. These mappings apply to the next key press.
- **Language:** uses the same preference as the app's pane in iPad Settings. System follows the device language.

Preferences persist between launches. Resolution, aspect ratio, controller type, mouse preferences, controller/mouse button mappings, and language apply at Play. The generated controller files must be prepared successfully before the save store is sealed; a write failure keeps Play available for retry. They are selected only in the successful Play callback. Invalid stored values return to defaults. A developer-supplied `TOTK_LANG` environment value still takes precedence.

The controller/mouse settings compiled with the Apple SDK. Physical behavior remains unverified. See [Controls implementation and limits](ipados-controls.md) for environment precedence, optional auxiliary buttons and the later local acceptance steps. Controller type, mouse preferences and controller/mouse button mappings do not apply live during gameplay; touch visibility does.

Resolution and aspect controls require the TOTK 1.4.3 build option `--ios-display-settings`. It adds `TOTKIOSDisplaySettingsVersion = 1`, backed by the signed `TOTK_IOS_DISPLAY_SETTINGS` profile. Other builds disable these choices and retain 1280×720 at 16:9. A saved preference cannot add this capability.

The height label refers to the requested game render and output canvas, not the Metal drawable or physical screen resolution. At 16:9, the choices request 1280×720 or 1920×1080. Full display requires a 4:3 display and the bundled 4:3 layout profile; it requests 960×720 or 1440×1080. Other aspects, or a missing profile, fall back to 16:9. Confirm actual render targets and drawable dimensions separately.

**Full display is experimental.** The signed profile reuses the existing Vert+ camera patch: it preserves the 16:9 horizontal view and expands the vertical field of view at 4:3. A separate layout overlay corrects UI proportions and positions instead of applying the older draw-time UI squeeze. Its generator passed against the local original TOTK 1.4.3 archive; physical appearance remains unverified. World-object markers, pixel-snapped positions, UI effects, inventory, lighting and cutscenes need visual checks. Prerendered movies have no separate aspect correction. This is not a claim of complete graphics parity or stable native 60 FPS. See the [baseline protocol](ipados-baseline.md).

On the tested iPad, the native HUD appeared with `MTL_HUD_ENABLED=1` supplied at process launch. The saved preference alone did not activate it. Enable **Settings → Developer → Graphics HUD → Show Graphics HUD** once. The user confirmed the in-app switch works after this device setting was enabled.

## During gameplay

Tap the floating **gear** or press **Escape** on a connected keyboard to open the Liquid Glass game menu. Use **Resume game**, the close button, Escape, or a tap outside the settings card to dismiss it. Outside taps do not pass through to the game. An open choice sheet or alert keeps its own dismissal behavior.

The menu does **not pause the game**. It blocks touch input to the game and releases mouse capture while open. Controller input can still reach the game.

Rows marked **Live** apply without a restart: target frame rate, TAA request, Performance overlay, Apple Metal HUD, touch visibility, and keyboard mappings. These choices persist. Resolution, aspect, controller type, mouse preferences, controller/mouse button mappings, and language remain editable but require an app restart. A changed value shows **Restart required** and a prompt. Save game progress, close TOTK from the App Switcher, and reopen it. Reverting to the current session's value clears the pending badge. Saves remain visible but disabled during play; restart the app before any transfer, backup, restore, or save edit.

A connected mouse uses the existing Mac camera controls while the app has focus and the system grants pointer lock. The default bindings use left click to attack, right click to draw the bow, and middle click to target. Left click shoots while right click stays held. Mouse motion uses the existing sensitivity and decay behavior.

Menu opening, focus loss and touch-view removal clear tracked touch buttons and sticks. Late movement from canceled fingers is ignored; mouse clicks do not also operate the virtual touch pad. Mouse capture also releases for scene/key-window changes and keyboard entry. These paths compiled with the Apple SDK and still require a physical regression run.

The game menu releases mouse buttons and camera input. Dismissal restores the prior capture preference; the system decides whether to grant pointer lock again. Background, disconnect, and lock loss also release mouse input. Physical mouse behavior remains unverified.

## Save transfers

The Saves section supports folder import, folder export through Files, local backups, backup restoration, and **Edit this save**. These actions are available only before Play.

### Online save editor

Choose **Edit this save**, then a slot. The app opens [Marc Robledo's TOTK editor](https://www.marcrobledo.com/savegame-editors/zelda-totk/) with a copy of that slot's `progress.sav` already loaded. Use the editor's **Save changes** action, then confirm **Apply edited save** to return the result to the app. Close the editor to discard changes.

The editor needs a network connection. Website scripts can access the selected copy; this is not an offline editor. Save bytes are not placed in the URL. The embedded browser uses a temporary website data store and accepts returned saves only from the editor's main frame and origin.

The app accepts the editor's supported v1.4.x file size and header. This check does not certify every possible edit as compatible with the game. The app changes only the selected `progress.sav` in a complete snapshot, refuses an outdated snapshot, and backs up the current save before atomic replacement. Other slot files and account identity remain unchanged. Restore the backup if the game rejects an edit.

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

Run all repository tests with the existing build virtual environment. The save and controls probes compile production Foundation code on macOS and use synthetic fixtures. The controls probe redirects only the Application Support lookup into a temporary directory; it exercises preference validation, the runtime mapping parser, developer environment precedence and real write-failure/retry before the actual save seal. This does not execute the UIKit Play callback or establish physical input behavior. They verify byte equality, backup/restore, identity preservation, refusal cases, and preferences.

```sh
python -m unittest discover -s tests
```

Use the [physical-device UI runner](../tests/ios_device_launcher/README.md) against the installed app. It does not transfer the game or use a simulator.

| Evidence | State |
|---|---|
| Files import, backup restore, byte equality, and existing-save gameplay load | Passed physically on earlier implementation `2dc8c34`. |
| New display-profile bundle | Build passed; this does not verify installation or gameplay. |
| Liquid Glass launcher and live menu | Earlier physical gear/menu and live HUD checks are recorded separately in the [roadmap checkpoint](ipados-roadmap-status.md); complete current-source physical UI regression remains pending. |
| Live FPS/TAA/touch | Historical physical test `test06fExistingGameGraphicsAndTouchApplyLive` passed in 89.942 seconds after UI Automation was enabled. It checked available FPS choices, TAA preference persistence, touch removal/restoration and outside dismissal; this is not new device acceptance or achieved FPS evidence. |
| 1080-high and Full display | Physical graphics and gameplay checks pending. |
| Mouse capture, direction, sensitivity, and menu release | Physical mouse checks pending. |
| Sustained native 60 FPS | Unverified; requires the sustained benchmark. |

The historical `3d7d6e8` checkpoint installed successfully; all 35 save-directory files matched its immediate pre-install SHA256 snapshot. That attempt could not execute UI checks while the iPad was locked. The later `test06fExistingGameGraphicsAndTouchApplyLive` result above is a separate recorded run, not a test of this documentation/controls-probe change. It restored 60 FPS, the prior TAA preference and Automatic touch. Renderer logs recorded successful temporal scaling frames; quality, cost and sustained performance remain unverified. See the [cloud continuation evidence](ipados-cloud-audit.md), [graphics inventory](ipados-graphics.md) and [next physical acceptance checklist](ipados-acceptance.md).

Apple reference: [Monitor Metal graphics performance](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance).
