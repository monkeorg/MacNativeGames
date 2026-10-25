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

## Existing TOTK host: opt-in private integration

`CanopyRuntime.h/.m` now owns a real, separate adapter to the existing compiled
TOTK host. `games/totk/runtime/canopy_host.h/.m` supplies the original native host
control descriptor only when explicitly built with `CANOPY_HOST_RUNTIME` into a
private title host. The public launcher links a weak provider that returns NULL,
with no descriptor or private payload, and therefore no approved executable
profile. The private host supplies the strong provider; native host builds
require that provider at link time. Descriptor
exposure additionally requires an explicit `CANOPY_HOST_TITLE_ID`, reviewed
`CANOPY_HOST_ORIGINAL_MAIN_SHA256` and `CANOPY_HOST_SHADER_SEED_MANIFEST_SHA256`;
their defaults expose no profile. The original-main pin
is the original plaintext ExeFS `main` NSO hash, **not** an encrypted-container
SHA, rewritten image SHA or invented title-version approval. The host's existing
`game_version.h`, generated `runtime_tables.h`, embedded-code checks and
`romfs_config.h` pins remain unchanged.

The real call chain is library selection → `CanopySessionController` save seal →
`CanopyRuntime` background preflight → `mng_store_pin` (verified generation and
kernel lease) → original-main/RomFS compiled-pin comparison →
`mng_romfs_runtime_index_fd` → exact compiled runtime-index-pin comparison →
main-thread native layer/settings attachment → owned worker → `totk_host_main`
→ the existing loader's map/relocate/checked-patch/seal/`boot` path. This is a
separate route from the unloadable shared-module ABI above: the existing TOTK
host cannot honestly implement that ABI's reusable `destroy` contract yet.

Private runtime assets resolve from the compiled descriptor's approved resource
location (normally the private signed bundle's GameData). Imported JSON cannot
select the host or approve an executable. Prepared ExeFS and `romfs.bin` stay in
the verified immutable generation. Shader preparation calls the actual `CanopyShaderCache` worker API with the
compiled whole seed-manifest SHA, translation chain, approved RomFS SHA and actual
selected Metal device/OS identity. The extended manifest authenticates
`shader_map.tsv` separately from the legacy shader-file table, so native shader
map reads do not escape verification. Immutable verified seed and mutable runtime
cache URLs bind separate `shader_seed`/`shader_cache` native-start fields. The
runtime retains the shared shader-cache lease for the full single-use process;
no save or general cache directory is repurposed as the shader cache. An exact
host attestation is established only from that verified lease-backed path.
Under the explicit flag, the existing shader consumer then reads it in place
without rehashing/copying every shader again. Its result reports `verifiedPrivate`
and `readInPlace`; `sealed` remains false for this Documents cache. Unattested
seeds follow normal hash/import behavior, and environment overrides do not turn
Documents data into a signed bundle. Missing private seed/tool identity refuses
startup; extraction never approves it. Private producers must add and authenticate
`shader_map_sha256` before a new manifest pin can be compiled; there is no fallback
to an old unverified map.

Native index production writes only a fresh
private staging file under `cache/totk-runtime-index-v1/<expected-index-sha>/`,
checks the produced SHA against the compiled expectation, and atomically links
`runtime-index.bin` without replacing an existing published file. A valid cache
is rehashed and reused; a corrupt or linked cache refuses startup and is retained
for explicit recovery. Recipe/hash identity survives unrelated app updates.

The adapter binds actual existing consumers:

- `TOTK_ROMFS` names the verified derived index directory; `TOTK_ROMFS_DATA`
  names the pinned generation containing the original image. Runtime image/index
  hashes are still checked by `runtime/romfs.c`.
- `TOTK_PROFILE_DIR` names `CanopySaveStore.accountIdentityDirectoryURL`;
  the guarded `CANOPY_SAVE_DIR` override in `fs_host.c` binds the actual writable
  save mount to `activeDirectoryURL`. The original UID-derived standalone layout
  is unchanged outside the compile flag. New Canopy save diagnostics omit paths.
- Resource, shader/cache, proof, game-slot and language paths bind the existing
  host consumers. `runtime_ios_attach_layer` receives the actual CAMetalLayer and
  UIView; the native host owns its existing render/display loop.
- FPS and TAA changes call the existing supported queries, setters and effective
  getters. HUD changes use `fps_overlay_hud_mode`/`fps_overlay_toggle_hints`.
  Language binds `TOTK_LANG` before service initialization and later changes
  report `restartRequired`. Settings without a real hook report `unsupported`;
  persisted desire is not reported as successful runtime application.
- Capture clears actual keyboard/gamepad/touch state, releases native mouse
  input and routes through the same iOS graphics/focus path used on backgrounding.
  The Canopy router must also clear its own input state. Overlay focus remains
  captured across OS foreground notifications until the host explicitly restores
  input; OS focus and host focus are combined. Native guest input reads
  only the routed Canopy snapshot under the compile flag, avoiding a second OR
  of legacy physical mappings. Exactly one guest pad is supported. Additional
  players refuse; this is not Mario Kart multiplayer support.
- The two diagnostic input constructors return immediately under the explicit
  flag. The legacy physical-controller startup also returns before installing
  observers or replacing any GameController valueChangedHandler; CanopyControllers
  is the sole physical event owner. Existing standalone behavior remains unchanged.
  Portable button semantics are explicitly converted to the existing Npad bit
  layout (the shoulder, stick, menu and directional bits differ). Home/Capture
  are refused. Routed physical input and native focus suppression remain active.
- Before worker creation, attachment samples actual OS activity and starts with
  host input/GPU focus captured. The UI restores it only for an active key window
  with the overlay closed, so background preflight completion cannot briefly
  submit GPU work. Native graphics gating and focus-message queues use initialized
  static locks/atomics and are safe at that preboot point.
- The worker preserves the existing iOS host's 64 MiB stack. Audio uses the real
  AVAudioSession playback/activation path and calls runtime_audio_output_restart
  after interruptions/media-service resets. Audio recovery never restores input
  focus behind an open overlay. Relative native shader requests stay inside the
  identity-scoped mutable cache. The Canopy flag excludes the legacy unpinned
  fill-pack importer; verified seed updates use the native cache contract instead.

The Objective-C adapter validates and hashes on a background queue; native UI
attachment and completion run on main. Full stat identity/size/link/mtime/ctime
checks bind each hash, with interrupted reads retried. `cancelPreparation` requests
cancellation before native entry; the store, hash loops and native index parser
poll its atomic flag. Completion remains the authority for releasing the seal.
The final main-thread entry decision checks cancellation again. Preflight failures return
without invoking native code, close the generation lease and allow the caller to
release the save seal. `nativeEntryInvoked` becomes true **before** entering the
native start callback. After that point, the runtime retains its process owner
and lease even on startup failure. The caller must retain its save seal.

This initial existing-host route is explicitly **single use per process**.
`runtime_fail` can still exit the process, the SDK entry normally never returns,
and there is no complete stop/join/reset implementation. `close` and CPU `pause`
therefore refuse. Focus deactivation stops GPU submission and changes native
focus; it does not promise suspension of guest CPUs. Runtime state `active`
means the native host worker started, not that a first game frame was verified.
No tick, fixture counter or display-link callback is exposed as gameplay FPS.

Safe thread teardown/relaunch, recoverable post-entry loader failures, complete
service/NVN ownership reset are remaining source work. The input guards establish a single controller owner but do
not pretend that process-global host resources became a reusable session. These
are development gaps, not hardware or signing blockers. Private original inputs,
exact private generated pins and physical graphics/gameplay/save acceptance are
separate validation debt; no commercial title is accepted by these fixture tests.

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
The fixture contains no game code. Linux shared-module execution has passed. `test_canopy_runtime.py` additionally
executes the actual guarded `fs_host.c` mount/create path on synthetic private
folders, checks active-save/identity isolation and preserves the unflagged layout.
Its macOS Foundation consumer exercises real preflight/index/cache/settings/input
calls with an original-source native provider, including wrong-pin refusal and
post-entry failure lifetime. It also compiles all five guarded existing-host
sources for iPhoneOS, both flagged/unflagged where applicable. Those Apple checks
visibly skip on Linux until Apple CI runs; they are not device acceptance. A Mac
without an actual Metal device skips only device-dependent consumer scenarios;
independent wrong-pin/private-cache/cancellation and iPhoneOS compilation checks
still run, with no fake GPU fallback. `test_canopy_shader_inplace.py` separately
executes the actual guarded seed consumer with original fixtures: real SHA calls
are counted, private read-in-place performs only the metadata fingerprint, no
shader payload is copied, and the result never claims the private cache is signed.
Unattested and unflagged imports remain exercised. The actual host/device helper
fixture tests nil/no-fallback without a GPU and uses actual Metal objects when
available. Renderer source checks run with and without the explicit flag. Full
Metal4 renderer/frontend checks require iPhoneOS SDK26 and explicitly report a
skip when only an older SDK is selected; other available source checks continue.
No SDK version is fabricated or downloaded by these tests. Real
Mac/iPad graphics/gameplay acceptance remains separate evidence. No fixture
counter is reported as gameplay FPS or commercial compatibility.

## Unexpected SDK return in the private host

For TOTK with `CANOPY_HOST_RUNTIME` (and not `GAME_BOTW`), the loader forwards its existing five-argument
`nn::init::Start` call through `canopy_sdk_return.h`. The handle, zero argument
and original ready/init/fini callback pointers are unchanged. Only if that native
call actually returns does the adapter produce
`CANOPY_LOADER_UNEXPECTED_SDK_RETURN` (70). This is a loader-wrapper error, not
an observed guest program exit code.

The existing iOS frontend callback then returns normally and `totk_host_main`
returns that result to the ABI3 worker observer. Runtime treats the ended main
worker as failure, captures input/focus and retains generation, shader, save,
device and module protections. No finalizer, unmap, service destruction or thread
exit is injected. The unflagged loader and all BOTW branches retain their existing fatal return path.
`module_finis` is still an unimplemented fatal path; this change does not make
normal SDK shutdown, whole-runtime teardown or relaunch supported.

`test_canopy_sdk_return.py` executes the actual return adapter with an original
native C signature fixture, checking exact argument/callback forwarding and the
named nonzero result. A real pthread-exit/TLS-destructor/join case confirms the
adapter cannot manufacture a fallthrough result or finalizer call when the
native call does not return. On Apple hosts a separate production-loader syntax
check uses explicitly original, nonexecutable module metadata for macOS and
iPhoneOS, both Canopy and unflagged variants. That metadata supplies no accepted
game pins, instructions or private payload. Two native fixture cases pass on
Linux; Apple compilation and actual private SDK/device behavior remain separate
gates here.
