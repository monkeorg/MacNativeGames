# Canopy local validation — 2026-10-26

## Scope and source

This local Mac phase starts from draft #170, branch
`feat/canopy-pinned-runtime-data`, commit
`f91f58253778aca0764f9bd0c36bb60bdcacf259`.
The repair branch is `fix/canopy-local-validation` and depends on #170.
No merge, release, signing-account change or device installation occurred.

The original working TOTK checkout remained at
`ad432e9e3a8f45a8252be2bb8501fdd22505233b`; its existing untracked tool files were
preserved. Source edits and builds used a separate worktree and private snapshots.
The source fixes are `4376ecc` and
`9b91ed478375691fde6ffc8ff649f1acc5f5de3e`. Later documentation commits do not
change the validated source bytes.

The user's local goal explicitly authorizes tests and Apple builds. Historical
cloud-only prohibitions below the recovery cursor do not apply to this phase.
This report validates the selected v143 build lane, not the full D0–D14 product.

## Repairs and their reasons

- Direct Runtime harnesses now link `CanopyRuntimeRegistry.m` and
  `CanopyCacheFS.m`; shader-cache harnesses link `CanopyCacheFS.m`; Storage links
  `CanopyCacheFS.m` and `CanopyProviderCache.m`; controllers link
  `CanopySettings.m` and `mng_keyboard.c`. Production inventories already had them.
- Packaging fixtures now provide and inspect the selected four-file runtime-data
  directory. Private compiler fixtures supply exact synthetic manifest/index
  identities and retained rewriter provenance. Original and ABI3 coverage remains;
  the loader SDK matrix also covers resource-v4 for v121/v143 and both Apple SDKs.
- The sampler-border probe passes its actual pipeline key to both updated vertex
  function paths. The original iPhoneOS shader reader declares the existing
  `runtime_fail` function. Both were actual Apple compilation failures.
- Shader seed expectations now match #168 vertex retyping. Texture, image and
  fragment-output mismatches still refuse.
- Actual v143 metadata exposed a valid, zero-size `STT_NOTYPE` ELF end marker at
  the module boundary. The reader now accepts exactly that metadata case; typed,
  positive-size, beyond-boundary and overflow cases refuse. Loader lookup and
  relocation retain strict in-image dereference bounds.
- The private builder's font verifier now matches the producer's exact
  type-prefixed `.bfttf` basename and retains the compiled font SHA check.

An independent non-author review covered the harness and compile changes. Two
independent non-author reviews covered the reader/font verification changes.
The metadata regression probes compile with undefined-behavior checks.

## Validation evidence

Toolchain: Apple silicon Mac, Python 3.14.8, Xcode 27.1 / iPhoneOS SDK 27.1.
A separate Python environment uses the repository's pinned requirements,
including capstone 5.0.9. The working TOTK Python environment was not changed.

| Check | Result and scope |
|---|---|
| Initial full suite after harness setup | 977 run; 7 failures, 6 errors, 9 skipped. Failure evidence retained privately. |
| Full suite after compile/fixture repairs | 977 run; 968 passed, 9 skipped; 96.520 s. |
| Final full suite after actual metadata fixes | 978 run; 969 passed, 9 skipped; 87.920 s. |
| RomFS path UBSan probe | 27 cases passed. |
| Controller layout UBSan probe | Passed. |
| Public Canopy iPhoneOS app | Full build passed; public provider remains unavailable. |
| Original iPhoneOS source matrix | Both v143 profiles passed; 38 objects (36 production and two isolated mouse fixtures). This is compilation, not fixture execution. |
| Mac Canopy CLI | CMake Release configure and build passed. |
| Mac v143 native host | Full `binary-v143` build passed after the renderer probe correction. |
| Original-source iPhoneOS execution fixture | App build passed; no signing, installation or iOS execution. |
| Original-source Mac call probe | 20,000 calls across four threads; zero errors. This is synthetic native execution. |
| Affected Mac sampler-border GPU probe | 13,818 checks passed with production sampler variants and GPU readback. No commercial game scene ran. |
| Actual private runtime-data reader | Three modules, 554,281 relocations, 58 service gates and 43 timer gates accepted. Wrong manifest/RomFS/index pins and cancellation refused. |
| Actual Canopy shader import/reuse | 95,219 files / 1,202,299,206 bytes imported; full verified reuse copied zero bytes and retained the same identity. This uses the selected Mac Metal device, not the iPad. |
| Private v143 stock Canopy | Full unsigned build/link passed, 124 recorded commands. Strong v4 accessor and all five runtime-data files verified. |
| Private v143 display Canopy | Full unsigned build/link passed, 126 recorded commands. Display resource profile and runtime-data files verified. |
| Original v143 iPad app | Complete display-profile package build passed. Build-only/ad-hoc preparation does not supply a provisioning identity or device acceptance. |

The nine skips are explicit: three filesystem case-alias cases cannot run on the
current case-insensitive filesystem; two Cross test classes lack their exact
pinned source; three NativeAOT parity methods lack actual linked probe/CLI
products; one non-Apple refusal case intentionally does not run on macOS.
These results do not validate the optional runtime translator. It stays off.

The first private build reproduced `game data invalid` before export; actual
metadata led to the closed ELF-marker correction. A later font staging check
exposed the producer basename mismatch. Do not discard these failed attempts or
substitute earlier CI for their repaired runs.

The isolated original-iOS dependency cache initially retained absolute CMake
paths from the original location. Its cloned build directories were retained
under separate names and reconfigured locally. The two public shared save-core
inputs were also copied into the isolated project's required relative layout.
No original cache or checkout was moved or edited.

## Reproduction and retained evidence

Use an isolated checkout and private output root. Do not copy private artifacts
into the repository. Run the following with the isolated Python environment:

```sh
python -m unittest discover -s tests -v
cmake -S launcher -B "$VALIDATION_OUT/cli" -DCMAKE_BUILD_TYPE=Release
cmake --build "$VALIDATION_OUT/cli" --parallel 2
python tools/launcher/build_canopy.py --out "$VALIDATION_OUT/public-canopy"
python games/totk/ios/tools/build_sources.py --jobs 4 --output "$VALIDATION_OUT/ios-objects"
make -C games/totk binary-v143 PY="$(command -v python)" -j2
python tools/launcher/build_private_canopy.py --plan --version v143 --display-settings
```

Actual private builds follow [the private build recipe](canopy-private-build.md)
with retained verified inputs and a separately reviewed manifest pin. Stock and
`--display-settings` builds must remain separate results. The retained raw seed
was independently hash/structure-audited, cloned, and adapted with the existing
production header-only map plus its hash. Historical producer hashes were
preserved. This was a packaging adaptation, not new translation or a claim of
current-producer provenance. The original seed remained unchanged.

Private logs, compiler observations, exact input pins, owned-reader probes,
seed audit/import/reuse records and artifact checks remain in the local
validation output directory. Repository documentation records sanitized results
only. The successful private artifacts contain private executable sections and
must not be uploaded or presented as a content-free distributable app.

## Remaining gates

No app was installed or launched on the iPad. Before any later installation,
make a fresh backup of saves **and account identity**, with a SHA-256 inventory
outside build/install targets. Compare it again after installation. Historical
backups do not satisfy that gate. No backup was needed for these host-only tests.

Physical UI, input, native entry, save round trips, display correctness,
multiplayer and sustained performance remain unverified. No stable 60 FPS,
shader parity, external-code permission, engine restart or complete teardown is
claimed. The public NULL provider remains separate from the private native
provider. SaveEditor stays candidate-only; translation stays off; BOTW and the
mod manager remain parked.

Real v121/private MK8DX products and optional static NativeAOT products were not
built with private inputs in this v143 lane. Their existing input, controller,
platform, resource and parity gates remain open. A build plan is not execution.
Use the [ordered acceptance checklist](canopy-mac-ipad-checklist.md) for the next
separately recorded device phase.
