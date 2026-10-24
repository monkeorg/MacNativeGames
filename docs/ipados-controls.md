# iPad controller and mouse preferences

Issue: [Adapt Mac controls and mouse input for iPad](https://github.com/monkeorg/MacNativeGames/issues/5).

This source adds persistent pre-Play controls preferences. It has not been compiled, installed, or exercised on a device. No tests, probes, or simulators were run for this change, following the current task instruction. The prior launcher/save and input acceptance records do not validate these new controls.

## Launcher controls

Open **Controls** before Play:

- **Touch controls:** Automatic keeps the existing controller-dependent touch visibility. Off still requires an extended gamepad before Play; a mouse alone cannot replace all movement controls.
- **Controller type:** Automatic uses the existing device detection. Xbox and PlayStation use face-button positions; Switch uses the existing Nintendo label convention. The default remains Automatic.
- **Mouse sensitivity:** accepts an integer from 1 through 100. The default remains 50. Invalid stored values fall back to 50; the editor disables Save for invalid input.
- **Invert mouse Y:** switches vertical mouse direction. The default remains Off.
- **Button mappings:** opens separate Controller and Mouse lists. Choose a Switch button, None, or Default for each physical button. The controller list includes face positions, sticks, shoulders, triggers, menu/view, D-pad, and supported touchpad click. The mouse list includes left/right/middle and the first two auxiliary buttons exposed by the system.

These choices persist and apply at Play. Reopen the app to change them for another session. The in-game menu continues to handle overlays and temporary input release; it does not apply new mappings or sensitivity during gameplay.

**Default** restores the existing mapping and its existing mode. Default mouse left attacks, right draws the bow, and middle targets. Left click shoots while default right click is held. The two auxiliary buttons are unbound by default. Custom mappings hold the chosen Switch button while the physical button is down; custom right-click mapping replaces the default aim/fire mode. Touch buttons keep their standard Switch layout.

Extra mouse buttons depend on the device profile. Extra 1 and Extra 2 mean the first and second entries in `GCMouseInput.auxiliaryButtons`; their physical positions are not guaranteed. A mouse reporting no extras still works with its available primary buttons. Input continues to require active app/scene/window focus and system-granted pointer lock.

## Backend and developer precedence

The implementation reuses `runtime/controller_map.h` and `runtime/gamepad.m`. It does not add a second input engine or alter the Mac code path.

Validated button preferences produce the existing `button = target` text format. Explicit mappings or a non-Automatic controller type use `Application Support/LauncherControls/controls.txt`; `controller-type.txt` sits beside it as required by the existing backend. The launcher checks the generated map with the production parser and writes both files before sealing saves for Play. Preparation failure keeps the launcher available and does not start the game. The runtime consumes those files after Play. Untouched defaults do not create a controls environment path or sidecar files.

Mouse preferences use the existing `TOTK_MOUSE_SENSITIVITY` and `TOTK_MOUSE_INVERT_Y` settings, applied before game startup. Existing developer environment values win. Rows controlled by those values show **Developer override** and are disabled. An existing `TOTK_CONTROLS` also overrides the generated map and adjacent controller type, so both launcher rows are disabled. It remains the developer's responsibility to provide a valid external file. Advanced `hold`, `tap`, `toggle`, and `aim` syntax remains available through that existing file format.

`TOTK_FACE_BUTTONS` retains its existing backend behavior: it affects Automatic detection; an explicit controller type chooses its own position/label convention. Decay, minimum decay, counterweight, gyro behavior, and all default bindings remain the shared runtime's existing settings.

## Requirement-to-code map

| Requirement | Production implementation |
|---|---|
| Persisted validated sensitivity and inversion | `TOTKLauncherMouseSensitivity` / `TOTKLauncherMouseInvertY` in `ios/Sources/launcher_settings.m`; numeric editor and choice rows in `launcher.m` |
| Controller type and physical button mappings | `TOTKLauncherControllerType`, `TOTKLauncherControlButtons`, `TOTKLauncherControlTargets`, `TOTKLauncherControlBinding`; `TOTKButtonMappings` in `launcher.m` |
| Reuse existing parser and mode defaults | `TOTKLauncherPrepareControls` serializes only explicit bindings and validates with `controller_map_parse`; omitted bindings keep `controller_map_default` modes |
| Prepare before save seal, apply at Play | Launcher Play handler prepares before `sealForPlay`; `main.m` calls `TOTKLauncherApplyControls` in the successful Play callback |
| Supported auxiliary mouse buttons | `mouse_buttons` in `mouse_input.m` uses public `GCMouseInput.auxiliaryButtons`, forwards at most two extras to existing runtime slots 3 and 4, and disconnect clears their handlers |
| Lifecycle release and touch visibility | Existing `mouse_input.m`, `mouse_capture.h`, and `touch_pad.m` behavior retained |

Apple documents [`auxiliaryButtons`](https://developer.apple.com/documentation/gamecontroller/gcmouseinput/auxiliarybuttons) as a nullable, read-only `NSArray<GCControllerButtonInput *> *`, available on iOS/iPadOS 14 and later. The app's current deployment target is newer. This API evidence does not establish physical accessory behavior.

## Manual source review and remaining acceptance

Source review traced the launcher row indices, preference validation, parser names, environment precedence, pre-seal failure return, deferred startup, unchanged default modes, optional-button bounds, and disconnect cleanup. This is source review only.

Future acceptance requires an authorized Apple build and an unlocked physical iPad with an extended controller and a supported mouse. Verify persistence across app relaunch; sensitivity endpoints and inversion; custom controller and mouse mappings; restoration of Default including bow/fire behavior; extra-button identity; zero stuck input across menu, background, focus loss, disconnect, and reconnection; and controller-dependent touch visibility. Inspect the generated map and type sidecar with synthetic preferences before gameplay. Existing private saves must remain backed up, and no save replacement is allowed after Play.

No new device, gameplay, or performance result is claimed. Physical mouse/controller support, Apple compilation, and new preference acceptance remain external blockers to closing issue #5.
