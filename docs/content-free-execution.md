# Content-free native execution: feasibility gate

Audit date: 2026-10-25. Source baseline: `c4552cd593bc42e5f9d3d5e38d6dc3465e433763`.
Scope: source inspection without private inputs, Apple tools, signing material or device execution. This document does not establish new gameplay or Apple permission results.

## Decision

The existing iOS runtime cannot execute an imported game with a content-free public executable. It requires game-derived code already embedded in its signed executable. Removing the embedded code and adding a folder importer does not preserve Play.

Keep that runtime and the installed Track A app intact. First build an independent, original-source ARM64 fixture that exercises the real ahead-of-time rewrite, signed-section layout, relocation and host-call mechanism. Use it to establish exactly which mechanisms work under an identified Apple signing mode. This is a native execution component proof, not a substitute for exact-title gameplay or proof of standalone iPad preparation.

No interpreter, JIT, dynamic binary translation or CPU emulator belongs in the product or this proposed native proof. Existing emulator-based differential tests remain verification tools outside the product; they are not native-execution evidence.

## Source evidence

Paths and line numbers refer to the baseline above.

| Observation | Evidence | Consequence |
| --- | --- | --- |
| The iOS module mapper ignores the supplied directory. | `games/totk/runtime/loader.c:156–157` | Importing executable files into Documents does not change what this loader executes. |
| It requires `__TOTKX` executable sections and per-module writable sections, checks layout and SHA-256, then remaps them. | `games/totk/runtime/loader.c:158–180` | Both original text and generated patch instructions must already be signed app contents on this path. |
| Executable remaps share the signed pages; writable data is copied on write. | `games/totk/runtime/loader.c:140–145`, `172–174` | This is not a facility for converting newly imported bytes into signed executable memory. |
| The non-iOS path instead reads `*.patched.bin` into anonymous writable memory and later makes text/patch areas executable. | `games/totk/runtime/loader.c:183–199`, `245–258` | Copying the Mac loader into iOS is not an established solution. The iOS implementation explicitly avoids this approach. |
| The embed generator emits `.incbin` from the rewritten images and exported text, with 16 KiB alignment and executable segment flags. | `games/totk/ios/tools/gen_embed.py:20–53` | Those generated app sections contain private game-derived bytes, not merely loader metadata. |
| The iOS build executes a prepared Mac host to export patched code before generating the embed assembly. | `games/totk/ios/tools/build_ipa.py:59–70`; `games/totk/runtime/loader.c:201–211`, `540–544` | Current preparation needs the Mac host, rewritten modules and version-specific runtime. It is not on-device preparation. |
| Runtime relocations are bounded to writable module data and dispatch supported relocation kinds. | `games/totk/runtime/loader.c:214–232` | The current signed-text design deliberately avoids executable-text relocation at load time. A new format must preserve this property or prove another permission path. |
| Rewriting converts reserved-register/TLS/system-call uses into host gates; this is machine-code rewriting, not recovery of C/C++ source. | `games/totk/third_party/d2r/patch_nso.py:12–22` | A source recompile is not available simply by importing an NSO. |
| Call-window safety rejects unsupported or ambiguous control flow, including entry into an unprepared call. | `games/totk/third_party/d2r/patch_nso.py:739–784`; `games/totk/third_party/d2r/call_window.py:16–47` | Supporting one fixture or title does not establish arbitrary-title rewriting. |
| Declared app entitlement is the increased-memory-limit entitlement. | `games/totk/ios/Sources/TOTK.entitlements:5–8` | There is no declared executable-memory entitlement to unlock imported native code. Memory capacity and code execution permissions are distinct. |
| The private installer obtains provisioning and re-signs the app on the Mac. | `games/totk/ios/tools/install_device.py:165–172` | Private signing is an existing workflow; it does not demonstrate signing imported code on iPad. |
| The build still packages game icons, shader seed data, RomFS overlays and firmware fonts. | `games/totk/ios/tools/build_ipa.py:82–91`, `100–129`, `144–151` | Solving native code loading alone does not produce a content-free public IPA. |

The source comment at `runtime/loader.c:140` states that runtime-written iOS code cannot execute. That is the implementation's stated constraint, not an independently repeated platform experiment in this audit. No universal claim about every Apple distribution, entitlement or development mode is inferred from it.

## Options and their evidence limits

| Option | Current finding | Required proof |
| --- | --- | --- |
| Original-source fixture embedded and signed at build time | Matches the existing loader's architecture and can be publicly distributed without game content. | Build and physical-device execution of the fixture using the actual remap and host-call mechanism. This tests the mechanism only. |
| Mac-assisted private preparation and app signing | Existing pipeline provides a credible intermediate route for privately supplied exact-title bytes. | Reproducible private build, provenance checks, provisioning and device gameplay for one exact version. The resulting private app contains game code and is not the content-free public artifact. |
| Public launcher plus separately signed, privately prepared native module | Hypothesis only. Current loader has no such backend. A signed file is not automatically loadable/executable by another iOS app. | Identify a supported distribution/signing mode and demonstrate sandbox access, code-signature acceptance, executable mapping/loading and update behavior on a physical device. Do not promise this route before that result. |
| Rewrite imported modules on iPad, then execute them | Blocked in the current design: output is new executable code without the existing build-time signature. | A permitted executable-loading/signing mechanism, independently demonstrated without JIT or an emulator. Import and decryption success are insufficient. |
| Rewrite or compile on a Mac and load the output as data on iPad | Preparation alone does not change executable permissions. | The same external-module loading proof as above. |

The repository does not establish whether an Apple-supported external-module solution exists for the intended distribution. `get-task-allow` in development provisioning (`install_device.py:167–168`) must not be presented as a production entitlement or a complete executable-loading solution. Do not add speculative entitlements and claim success.

## Bounded implementation and remaining integration

1. `tools/launcher/fixture/build_fixture.py` now authors a tiny ARM64 program entirely from repository-owned source. Cover arithmetic, writable data, an indirect call, a relocated pointer and one host service. Record expected results and the source hash. Give it its own neutral module/profile; do not borrow game binaries, keys, fonts, shaders or game-specific patch addresses.
2. Feed that fixture through the production rewrite mechanism. Existing `scripts/emit_native_call_fixture.py:9–14` already reuses `call_window.prepare_call`; extend coverage through the actual NSO rewrite rather than treating hand-authored output as a complete rewrite proof. Any NSO wrapper must contain only this original program and generated metadata.
3. Generate real executable sections with `ios/tools/gen_embed.py`. Verify section boundaries, padding, names, expected digests and linker protections with portable tests. Include failures for malformed layout, wrong hashes and truncated artifacts. These tests prove artifact properties, not Apple permission behavior.
4. Add an isolated Apple harness using the production mapper/relocation logic, refactoring only the smallest common core needed. Call the fixture as native ARM64; check its observed return value, memory effects, host call, mapped permissions and return address. Run without a debugger as well as in development, and record the actual signing mode.
5. Only after a valid external-module permission path is identified, run the same harness with a separately prepared fixture absent from the public app's executable sections. A build-time embedded fixture cannot pass this gate by itself.
6. Apply the successful mechanism to one declared supported title/version using local private inputs. Complete exact-title gameplay, graphics, input and save acceptance. Keep these private artifacts and logs that contain private bytes out of the repository and cloud.

Do not build a fake Play operation around the fixture. A fixture result belongs in diagnostics and engineering acceptance, and must never mark an imported commercial title playable.

## Existing commands and new-harness acceptance

Existing commands, to run only where their prerequisites exist:

```sh
# Portable suite; exclusions and native skips must remain visible.
python tests/run_portable.py

# Existing differential verification (Unicorn reference, not native proof).
make -C games/totk test-call-window

# Existing original-source call-window hardware probe: Apple silicon Mac.
# Uses runtime-created executable memory; does not prove the iOS signed mapper.
make -C games/totk probe-call
```

`probe-call` builds an original-source fixture and executes 20,000 calls across four pthreads, checks real Darwin TLS and observed return addresses (`scripts/native_call_probe.c:34–78`). Its `mprotect` executable-memory path (`:56–67`) differs from iOS's signed remap. The separate `probe` target reads private TOTK v0 ELF data (`Makefile:29–35`, `scripts/native_leaf_probe.c:1–3`, `42–80`); do not use it in the cloud or label it content-free.

An isolated platform-permission probe and unsigned builder now exist in `tools/launcher/fixture/`; see its [README](../tools/launcher/fixture/README.md) for build and local signing/install commands. It shares generated artifacts and the Apple compatibility header, not the production loader or relocation implementation. It has since compiled in public macOS CI (see the [Canopy build record](canopy-inspection.md)); physical execution remains unperformed. A shared production runtime harness is still pending. Use a distinct probe identity and keep the working app intact. Record Xcode/SDK versions, device/OS, source revision, distribution/provisioning mode, public artifact hashes, fixture hashes, mapped protections, computed results and negative-control failures. Keep signing credentials local.

## Gates

- [x] Portable original-source rewrite and executable-section tests pass; branch/call-prefix/MOD0/truncated-text negative controls fail as expected. See the checkpoint results in [validation](content-free-launcher-validation.md).
- [ ] Production-loader integration harness builds for iPhoneOS; no proprietary input is needed. The separate platform probe has compiled.
- [ ] Signed embedded fixture executes natively on a physical device with observed permissions and results; run without debugger.
- [ ] Content-free public artifact inventory excludes all prohibited game-derived content.
- [ ] External private fixture, absent from public executable sections, executes through a demonstrated permitted native mechanism under the intended distribution mode.
- [ ] One exact supported title/version completes private import, preparation and real gameplay through that mechanism.
- [ ] Private data survives supported app updates; input, graphics, saves and required multiplayer acceptance pass separately.

Only the portable artifact gate is evidenced; Apple execution and product gates remain pending. Historical Track A device success remains attached to its recorded revision and packaged-code architecture. It does not satisfy the external-code or content-free artifact gates here.


## Apple compilation follow-up — 2026-10-25

At `e8c5be9`, the isolated original-source permission probe compiled for arm64
iPhoneOS with Xcode 16.4 / iPhoneOS 18.5 after 14 fixture tests passed on macOS.
The separate Canopy inspection app also compiled. See the [build record](canopy-inspection.md).
This resolves source compilation for those two targets only. No signing,
installation, actual permission observation, production-loader integration,
external native-code loading or title gameplay was performed. The open execution
and physical acceptance gates above remain open.

## Native Mac call-window follow-up

CI at `923a775` executed the existing original-source `probe-call` target on an
Apple-silicon Mac: 20,000 calls, four threads, zero errors, with real Darwin TLS
and return-address checks. See the [evidence record](canopy-inspection.md).
This narrows the Mac-side call-window uncertainty but leaves the separate
physical-iPad signed mapper, external module loading and exact-title gameplay
requirements unverified. No emulator or private game input was used.
