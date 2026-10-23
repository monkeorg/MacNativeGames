# iPad launcher and saves

The launcher appears before the game starts. Press **Play** after you choose settings or manage saves. Close and reopen the app to return to the launcher.

## Preferences

- **Graphics:** shows this build's 1280×720 game picture. The performance overlay can show all readings, FPS only, or nothing.
- **Apple Metal HUD:** enables Apple’s native performance overlay for this development build. Apply the choice before Play.
- **Controls:** Automatic keeps the existing touch behavior. Off requires a connected controller with an extended gamepad profile.
- **Language:** uses the same preference as the app's pane in iPad Settings. System follows the device language.

Preferences persist between launches and apply before Play. Invalid stored values return to defaults. A developer-supplied `TOTK_LANG` environment value still takes precedence.

This milestone does not add resolution scaling, aspect patches, mouse input, or new MetalFX modes.

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

The launcher UI tests use a separate simulator harness without game content. Neither automated probes nor simulator tests prove a physical-device game-save load.

Apple reference: https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance
