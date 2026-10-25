# Canopy native session integration

`launcher/src/mng_session.c` is a production POSIX native module loader. It uses
`dlopen(RTLD_NOW | RTLD_LOCAL)` and `dlsym("canopy_native_module_v1")`, not CPU
emulation, rewriting at runtime, JIT, streaming or a subprocess. A module must
already be a native shared library for the current host. The public application
must never contain a private game-derived module.

## Trust and prepared binding

`mng_session_manifest.version == 1` describes a single approved module: exact
64-bit title ID, title version, prepared root, bounded relative module path,
module byte length (1–512 MiB), SHA-256, save root, and a 1–64 character account
profile identifier restricted to ASCII letters, digits, dash and underscore.
`execution_capability` is a **trusted host policy decision**, supplied only after
an independently reviewed title/version/native-host profile allows execution.
It must never be copied from imported JSON, a package header, extraction success,
a filename, or a user-facing preparation-complete flag. SHA-256 establishes byte
integrity against this approved expectation; it does not establish authorship,
RSA authenticity, signing or title compatibility. Unknown titles stay unavailable.

All source path components are opened with `openat` and `O_NOFOLLOW`; absolute
module paths, `.`/`..`, empty components, symlinks, nonregular files and oversized
files are rejected. The loader holds a prepared-generation lease through host
`retain_prepared`/`release_prepared` callbacks. The application wraps
`mng_store_pin(store,title,generation,&lease_fd)` and keeps the returned descriptor
until release. Failed open paths also release the lease. The module is streamed
into a fresh mode-0700 private temporary directory while hashing, checked for
exact length/hash, then loaded from that snapshot. Replacing or modifying the
source during hashing cannot cause unchecked bytes to execute. The temporary
image is unlinked after loading; `dlclose` releases the loaded image.

Approved modules must be self-contained with respect to private dependencies;
copying a module does not preserve its original relative dependency directory.
The platform's normal system-library resolution and signing policy still apply.
An approved module is trusted native code, with all privileges of its host;
this is not a sandbox for untrusted plugins. The host must use a private,
immutable generation and a separate per-title/profile save directory. Asset tree
verification and account/save authorization remain the generation/save layer's
responsibility. A path or hash supplied by an untrusted source is insufficient.

## Original host ABI v1

The complete C ABI is in `launcher/include/mng_session.h`. The exported function
returns a descriptor with ABI version, exact structure size, exact title/version
identity, and six mandatory functions: `create`, `settings`, `input`, `pause`,
`tick`, and `destroy`. Missing entry, size/version/identity mismatch or missing
function refuses startup. Dynamic-library constructors necessarily run during
`dlopen`, before descriptor inspection; only approved bytes may reach that call.

`create` receives stable copied paths/profile, initial settings, host callbacks
and an opaque graphics surface (a `CAMetalLayer` on Apple, or NULL for a headless
module). Settings carry output width/height, frame limit, language, controller
layout and volume. Basic ranges and finite floats are checked before native
callbacks; title-specific support is the module's responsibility, reported by a
callback failure. Successful live changes are applied through `settings`, not
merely persisted by the library UI. Startup-only settings must be rejected live
by a title module and offered as relaunch changes by its caller.

Input uses complete snapshots for eight independent players: physical device
ID, buttons, four normalized axes and connection state. Each submission carries
a strictly increasing nonzero sequence and host-monotonic nanosecond timestamp.
Samples older than 250 ms, future timestamps, regressions, duplicate connected
device assignments, invalid axes and nonneutral disconnected snapshots are
refused. The caller continues sending snapshots/disconnects and pauses on loss
of focus or controller routing. Pause first delivers an all-neutral input
snapshot (sequence/timestamp zero is the reserved host cancellation), then calls
the native pause hook. Tick refuses while paused. No guest Npad structure or
Switch ABI is inferred from this portable host snapshot.

The owner serializes all calls on one thread; native callbacks cannot reenter.
The module must clean up itself on failed `create`. On successful create, all
subsequent failure results preserve a closable session. Close calls `destroy`,
which must stop and join every native worker and stop all callbacks before
returning, then unloads the module and releases the generation lease. The caller
seals saves only after close returns and can then open a new session. The ABI
cannot safely unload a module that violates its thread teardown contract.

## Existing TOTK host: concrete remaining integration

The existing TOTK runtime is deliberately preserved. This generic module loader
does not make that executable into a reentrant shared library or establish any
commercial game's compatibility. Inspection of the real source identifies these
separate hooks that must be refactored and privately validated before a TOTK
module can implement ABI v1:

- `games/totk/runtime/loader.c`: `main(argc,argv)` receives module root in `argv[1]`
  and `"boot"` in `argv[2]`, maps/relocates ahead-of-time-rewritten modules, applies
  checked patches and eventually calls `boot` through `runtime_front_run`.
  `runtime_fail` currently exits the process. A session wrapper needs recoverable
  startup errors and ownership/reset of module mappings, TLS and signal handlers.
  It must preserve existing original-input/version pins and checked patches.
- `games/totk/ios/Sources/main.m`: `run_host` invokes `totk_host_main` on a host
  thread and supplies `TOTK_ROMFS` and related resource paths through environment
  variables. Per-session startup must bind verified prepared paths explicitly
  rather than mutate global environment across simultaneous sessions.
- `games/totk/runtime/frontend_ios.m`: `runtime_ios_attach_layer(layer,host)` is
  the real Metal surface attachment; `runtime_ios_set_fps_limit` and the matching
  supported query are real FPS hooks. Its `runtime_front_request_close` only
  logs an iOS close request. The Mac implementation in `frontend.m` closes an
  NSWindow. Neither proves guest thread cancellation/join or safe relaunch.
- `games/totk/runtime/input.c`: `runtime_input_clear` clears keyboard/gamepad
  state. The current `pad_states` routes only `pad_id()` and is not an eight-player
  adapter. Diagnostic input constructors detach threads. These need explicit
  session ownership, cancellation/join, and per-player guest routing before
  `destroy` or multiplayer claims can be supported.
- `games/totk/runtime/fs_host.c`: `M_SAVE` mounts use `save_root`; session/profile
  identity must bind that mount and commit/drain writers before save sealing.
  Native service and NVN/Metal ownership also require reset/join evidence.

Calling `totk_host_main` from `create` and providing a no-op `destroy` would be
unsafe and is intentionally not implemented. These are exact remaining runtime
source changes, not evidence that a dummy backend completes D8. They require
explicit shared-runtime ownership approval plus private pinned input validation;
there are no invented game addresses, title profiles or checked words here.

## Platform and verification status

Linux/macOS support native shared-library loading under their normal loader
policy. `TARGET_OS_IPHONE` explicitly returns `MNG_SESSION_UNSUPPORTED` for this
external-module path, even when the trusted manifest marks execution approved.
No executable entitlement or sideloading permission is guessed. A future embedded
signed-module capability needs a separate reviewed API and real device evidence.

Run `python -m unittest discover -s tests -p test_canopy_session.py -v`.
The test compiles an original-source shared library and the actual production
loader, then exercises native create, settings, distinct simultaneous players,
tick, pause cancellation, profile save writes, destroy and lease release. It
also rejects bad hashes, missing entry, ABI/title-version mismatch, traversal,
symlinks, unapproved modules, stale input and duplicate physical assignment.
The fixture contains no game code. Linux execution has passed; Apple CI and real
Mac/iPad graphics/gameplay acceptance remain separate evidence. No fixture
counter is reported as gameplay FPS or commercial compatibility.
