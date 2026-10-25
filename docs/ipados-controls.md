# iPad keyboard, controller and mouse preferences

Issue: [Adapt Mac controls and mouse input for iPad](https://github.com/monkeorg/MacNativeGames/issues/5).

This source adds persistent controls preferences. Apple compilation and synthetic input checks run during the authorized local continuation. New keyboard and mouse changes still require physical acceptance; earlier device results do not validate them.

## Launcher controls

Open **Controls** before Play:

- **Touch controls:** Automatic keeps the existing controller-dependent touch visibility. Off requires an extended gamepad or a detected GCKeyboard before Play. Keep Automatic for Universal Control if it exposes only UIKit key presses. A mouse alone cannot replace movement controls.
- **Controller type:** Automatic uses the existing device detection. Xbox and PlayStation use face-button positions; Switch uses the existing Nintendo label convention. The default remains Automatic.
- **Mouse sensitivity:** accepts an integer from 1 through 100. The default remains 50. Invalid stored values fall back to 50; the editor disables Save for invalid input.
- **Invert mouse Y:** switches vertical mouse direction. The default remains Off.
- **Button mappings:** opens separate Controller and Mouse lists. Choose a Switch button, None, or Default for each physical button. The controller list includes face positions, sticks, shoulders, triggers, menu/view, D-pad, and supported touchpad click. The mouse list includes left/right/middle and the first two auxiliary buttons exposed by the system.
- **Keyboard mappings:** provides 24 actions for movement, camera and Switch buttons. The default movement keys are WASD; camera keys are arrows. Assign a supported physical key or None. A key already assigned elsewhere must first be freed. Escape and Command remain reserved.

These choices persist. Keyboard mappings apply live to the next press. Other control choices apply at Play and show a restart prompt after changes during gameplay. Reopen the app to apply them. In-game rows distinguish Live, Restart and Restart required.

The keyboard bridge accepts GameController keyboard events and UIKit press events, including the path used when Universal Control exposes UIKit input. It merges duplicate sources, remembers each press's original mapping for release, and clears keys plus queued keyboard edges on menu, focus loss, disconnect, and text entry. It forwards only game actions, so a mapped number key cannot trigger Mac graphics shortcuts. Physical Universal Control behavior remains unverified.

**Default** restores the existing mapping and its existing mode. Default mouse left attacks, right draws the bow, and middle targets. Left click shoots while default right click is held. The two auxiliary buttons are unbound by default. Custom mappings hold the chosen Switch button while the physical button is down; custom right-click mapping replaces the default aim/fire mode. Touch buttons keep their standard Switch layout.

Extra mouse buttons depend on the device profile. Extra 1 and Extra 2 mean the first and second entries in `GCMouseInput.auxiliaryButtons`; their physical positions are not guaranteed. A mouse reporting no extras still works with its available primary buttons. Input continues to require active app/scene/window focus and system-granted pointer lock.

## Backend and developer precedence

The implementation reuses `runtime/controller_map.h` and `runtime/gamepad.m`. It does not add a second input engine or alter the Mac code path.

Validated button preferences produce the existing `button = target` text format. Explicit mappings or a non-Automatic controller type use `Application Support/LauncherControls/controls.txt`; `controller-type.txt` sits beside it as required by the existing backend. The launcher checks the generated map with the production parser and writes both files before sealing saves for Play. Preparation failure keeps the launcher available and does not start the game. The runtime consumes those files after Play. Untouched defaults do not create a controls environment path or sidecar files.

Mouse preferences use the existing `TOTK_MOUSE_SENSITIVITY` and `TOTK_MOUSE_INVERT_Y` settings, applied before game startup. Existing developer environment values win. Rows controlled by those values show **Developer override** and are disabled. An existing `TOTK_CONTROLS` also overrides the generated map and adjacent controller type, so both launcher rows are disabled. It remains the developer's responsibility to provide a valid external file. Advanced `hold`, `tap`, `toggle`, and `aim` syntax remains available through that existing file format.

`TOTK_FACE_BUTTONS` retains its existing backend behavior: it affects Automatic detection; an explicit controller type chooses its own position/label convention. Decay, minimum decay, counterweight, gyro behavior, and all default bindings remain the shared runtime's existing settings.

## Mac input feature inventory

Implementation states below describe source availability. Every device-dependent path remains physically unverified in this continuation.

| Mac feature | iPad state and source boundary |
|---|---|
| Extended controller buttons/sticks and face conventions | Implemented shared `runtime/gamepad.m` GameController path; persistent controller type and mappings added here. Actual accessory models, focus navigation and touchpad-click availability remain unverified. |
| Extra controller support through IOKit/HID | Unavailable: `gamepad.m` compiles its IOKit/HID reader only under `TARGET_OS_OSX`. iPad depends on profiles exposed by GameController; a Mac-supported accessory is not automatically iPad-supported. |
| Controller haptics and controller motion | Unavailable in the current iOS implementation: `runtime/gamepad_feedback.m` uses no-op attach/detach/quiet/rumble functions outside macOS; controller motion attachment is in the macOS branch. No haptic or controller-gyro selector is offered. This is distinct from mouse-generated motion in the shared backend. |
| Relative mouse, buttons, capture and camera look | Implemented iOS adapter plus existing shared mouse-look/right-stick and synthetic-motion paths. Primary/middle and up to two auxiliary buttons are forwarded. Direction, sensitivity, gyro effect, pointer-lock behavior and real extra-button identity remain unverified physically. |
| Mouse sensitivity, inversion and button mapping | Persistent pre-Play choices implemented here. Advanced decay/counterweight/minimum decay/mouse-gyro options remain developer environment settings; no new persistent advanced controls are claimed. |
| Mapping modes and mouse enable shortcut | Default modes are preserved; custom in-app mappings use Hold. Advanced Tap/Toggle/Aim remain available through `TOTK_CONTROLS`. Mac key 7 is not wired as an iPad shortcut; iPad capture is requested during gameplay and released temporarily by the menu/focus policy. |
| Keyboard movement and Mac shortcuts | Native UIKit/GCKeyboard bridge supplies configurable movement, camera and Switch actions. Escape controls the menu; Mac debug/graphics shortcuts are not forwarded. Physical acceptance remains pending. |
| Game text entry | Unavailable: `runtime/frontend_ios.m:runtime_front_text_test` cancels game keyboard requests. Keyboard notifications release capture defensively; they do not implement the desktop entry bar. |
| Touch visibility and interruption release | Implemented iOS Automatic/Off behavior and cancellation policy. Controller input can still reach gameplay while the live menu is open; the menu does not pause. Physical lifecycle acceptance remains pending. |

Controller haptics/motion, Mac debug shortcuts and advanced persistent tuning remain unavailable. The current work does not claim complete Mac input parity.

The iOS mouse adapter ignores zero and nonfinite movement reports. Zero reports otherwise renew the shared mouse-look counterweight and sustain residual camera movement. Regression checks cover that case without changing sensitivity, decay or counterweight. `TOTKMouseInputDiagnostics()` exposes aggregate event counts, focus and pointer-lock state for local debugging; it records no coordinates or device identifiers. This correction does not establish reliable raw mouse input over Universal Control.

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
