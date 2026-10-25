# Native multiplayer service checkpoint

`mng_multiplayer` is a real native FullKey HID service with up to four independent controller IDs. It receives complete portable session snapshots and exposes the known guest `nn::hid` function signatures already used by the repository. It does not assign controllers, merge seats, decode CPU instructions, emulate IPC, or supply a title profile.

The connected original fixture follows the actual production route: `mng_players` assignment/input → `mng_session` verified native-module loader and generation lease → original native module input callback → this HID service → resolved guest `GetNpadStates`/`GetNpadStyleSet` calls. Four independently routed physical-device IDs produce four distinct guest states. The fixture also swaps seats, disconnects/reconnects a device and exercises owner pause-neutral/resume. This is native service execution with original C code, not Mario Kart gameplay or physical controller acceptance.

## Grounded contracts

- `games/totk/runtime/input.c` defines the 40-byte FullKey state and exact guest C++ symbol strings. Its existing `pad_id`, `pad_states` and `show_controller_support` implementation is deliberately single-player.
- `launcher/include/mng_players.h` supplies four seats, device identities and stale-token protection. The multiplayer service consumes snapshots rather than duplicating this assignment logic.
- `launcher/include/mng_session.h` defines the real host/module input boundary. `mng_session.c` verifies and loads the original test module, holds its generation lease, and delivers neutral owner cancellation on pause.
- `launcher/apple/Sources/CanopyRuntime.m` converts the same portable button schema to native Npad bits, but its current private TOTK adapter rejects connected seats beyond Player 1. `games/totk/runtime/canopy_host.h` has a single-pad callback. Neither is changed by this checkpoint.
- Public [libnx HID declarations](https://github.com/switchbrew/libnx/blob/master/nx/include/switch/services/hid.h), read 2026-10-25, confirm IDs 0..7, Other 0x10, Handheld 0x20; FullKey style bit 0; connected attribute bit 0; and the FullKey/common 40-byte state fields. Observed header SHA-256: `bc6c130ed742984d70b820f213e902b7ce179a1ca14369b9503868ad8ecf91ba`. libnx is ISC licensed; no implementation is copied.

The resolver implements only InitializeNpad, supported ID/style setters, FullKey style/states and DisconnectNpad. Unknown symbols return NULL. Controller support applet arguments, Joy-Con styles, motion/vibration, accounts and LDN/online services are not fabricated. A title needing these still requires real service implementations matched to its observed imports/contracts.

## Safety and lifecycle

Storage is fixed at four seats and 16 historical samples per seat. Native FullKey fields have compile-time size/offset assertions; reads return newest samples first and never exceed caller capacity. Only the 16 known portable gameplay buttons are converted. Home/capture are system actions, not invented Npad gameplay bits.

Normal snapshots require increasing sequence, nonregressing timestamp and age no more than 250 ms relative to the supplied host clock. Duplicate device IDs, unsupported seats, nonfinite/out-of-range axes, invalid connection state and unsupported button bits are rejected before mutation. Zero sequence/time is accepted only for entirely neutral owner cancellation and never resets replay protection. Sample-counter exhaustion fails explicitly.

Supported ID/style filters never advertise unsupported styles or extra seats. A guest disconnect remains latched while the same physical device occupies that seat, including across owner pause-neutral/resume; an explicit disconnect/reassignment changes identity and permits reconnection. Replacement and owner cancellation clear historical held input so another device never inherits previous presses.

Guest callbacks use a binding mutex; detach waits for in-flight guest calls and later calls return no states/absent style. One binding is permitted per linked implementation. The host separately enforces one active native title in its process. Stop direct host API callers before destroying a service; this API does not stop guest CPU threads. No callbacks reenter the host under a service lock.

## Mario Kart inventory and remaining integration

The available game source directories are `games/totk`, `games/botw` and `games/by3`. No Mario Kart native profile, exact title/version, original main/SDK hashes, rewritten module inventory, native patch map or import/service inventory is present. A franchise/name or imported JSON cannot create those facts. Generic CNMT/content preparation can identify an actual package, but that is separate from a verified executable adapter.

A real Mario Kart route still needs:

1. Identify the exact Switch title and base/update version from verified CNMT and observed module hashes, then map its original module layout, imports, relocations and execution entry through the existing native rewrite/loader approach. No addresses are guessed here.
2. Supply the exact-version graphics/shader adapter and native patches, grounded in the actual module contracts. The new generic service cannot substitute for those native title changes.
3. Bind the observed guest HID calls to this four-seat service. Implement any actual controller support applet, account or additional required services with their verified argument layouts and semantics. Do not turn missing network/local-wireless operations into success stubs; split-screen local players and network multiplayer are separate capabilities.
4. Add a compiled trusted per-title host descriptor exposing real capacity and an actual multi-seat callback. The current TOTK descriptor and input route must remain one-player.
5. Run an actual local multiplayer session on the identified native title/version: independent controls, distinct players/viewports, disconnect/reassignment/reconnect, overlay capture and save lifecycle. Record physical Apple controller/device evidence separately.

These are concrete source/integration gaps, not a claim that another title is impossible. This checkpoint establishes reusable guest HID/service infrastructure and its native caller; it does not complete roadmap D11 or advertise a supported Mario Kart release.

## Verification

```sh
python -m unittest discover -s tests -p test_canopy_multiplayer.py -v
```

The suite compiles the real service and original dynamic module with undefined-behavior sanitization, executes the production native loader route, and checks routing, ABI, filters, rejection atomicity, historical input isolation and concurrent detach. No private game bytes, SDK binaries, game keys or network services are used. Linux native execution is not an Apple build/signing/controller or title compatibility result.
