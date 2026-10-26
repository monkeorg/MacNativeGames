# Private Canopy native build

`tools/launcher/build_private_canopy.py` provides a separate, unsigned iPhoneOS
build route. It keeps the public Canopy app entry and identity and links the
opt-in native host into that app. It does not change the standalone Mac or TOTK
iOS builders. Nothing in this recipe grants compatibility, execution permission,
signing acceptance or safe native teardown.

The portable plan needs no private inputs or Apple tools:

```sh
python tools/launcher/build_private_canopy.py --plan --version v121
```

For the explicitly compiled experimental 1.4.3 display profile:

```sh
python tools/launcher/build_private_canopy.py --plan --version v143 --display-settings
```

`--display-settings` is opt-in and rejected for `v121` before private inputs or
Apple tools are accessed. Stock plans and builds retain their existing behavior.
The portable display plan describes required generation; it contains no invented
resource hashes or assertion that a private exporter has produced signed code.

Only TOTK 1.2.1 (`v121`) and 1.4.3 (`v143`) are currently selected by this recipe.
Their title ID, original ExeFS hashes, rewritten-image hashes, RomFS identity and
shared-font hashes come from the checked-in `games/totk/assets/expected-*.json`
tables. The recipe has no option to replace those tables or choose an arbitrary
title. An encrypted container SHA is never substituted for an original NSO hash.

The reviewed [game registry](canopy-game-profiles.md) now supplies the default,
version aliases, manifest paths, ordered modules, patch source and compiler
define used by this actual builder. Its compiled generated table must match the
registry and referenced manifests. The existing default `v121`, both version
aliases and resulting version-specific commands are preserved. Metadata cannot
register a native implementation or grant execution/editor authority; BOTW and
mod management remain outside this recipe. The private observation also records
the selected game, registry metadata fingerprint and registry-helper source hash,
and staging must retain the same selected metadata before private inputs run.

## Local prerequisites

Use an Apple silicon Mac with an installed Xcode 26+ and iPhoneOS SDK26+. The
builder uses the existing `ios/tools/build_sources.py` toolchain selector. It
downloads nothing. Python must already have the existing runtime generator's
`capstone` dependency installed. The display generators additionally use Python's
`compression.zstd` module (Python 3.14+); use that interpreter for display builds.

Keep an isolated, trusted private `games/totk` work tree prepared by the existing
native-port workflow. For the selected version it must retain:

- Original `extracted/<version>/exefs/` files, ELF inventory JSON, the full
  `romfs/romfs.bin` and its extraction `index.json`.
- `rewritten/<version>/{main,subsdk0,sdk}.patched.bin`, fixups and gates, and the
  passing `analysis/<version>-port/phase12-validation.json` report.
- Verified `extracted/firmware/shared-fonts/` files and extraction manifest.
- Its trusted, executable `build/totk-native-<version>` Mac host. This is executed
  only in its existing `export-ios` mode, which maps verified rewritten images,
  applies the existing original-word-checked runtime patches and exports text.
  Its executable is copied into private staging, hashed, and only that snapshot is executed. This local executable is an explicit trust
  prerequisite; the builder does not authenticate a binary's origin from a hash
  it just observed. Use an exporter built from reviewed matching sources.

Also supply a local iPhoneOS codec prefix with `include/`, `lib/libopus.a` and
`lib/libvpx.a`; Mac libraries cannot replace device libraries. Their libraries and header tree are copied into private staging and hashed; compilation and linking consume those snapshots. The Apple linker checks architecture. No dependency builder or
network fetch is invoked automatically.

The shader seed must already be prepared for the selected source RomFS and
current checked-in `DMSH_CHAIN`. Supply a separately reviewed SHA256 of the final
`seed-manifest.json`. The manifest must bind translator, SPIRV-Cross and
preparation identities and `shader_map_sha256` as documented in
[the shader integration contract](canopy-shader-integration.md). A seed with an
old manifest lacking the authenticated map is refused. The builder first copies and verifies the pinned manifest, parses only that private snapshot, and copies and hash-checks its listed seed files and map. The native runtime performs its full
structural and content verification again before invoking the host. This recipe
does not translate shaders, guess tool pins, add metallibs or rewrite that
manifest after pinning it.

## Build without signing

Replace the example local directories and manifest pin with your own retained
inputs. The output directory must not exist:

```sh
python tools/launcher/build_private_canopy.py --build --version v121 \
  --tree /absolute/private/totk \
  --deps /absolute/private/iphoneos-codecs \
  --shader-seed /absolute/private/reviewed-shader-seed \
  --shader-manifest-sha256 REVIEWED_64_LOWERCASE_HEX_SHA256 \
  --bundle-id org.example.canopy \
  --out /absolute/private/new-canopy-build
```

Use `--developer-dir /Applications/Xcode.app` to choose an installed toolchain.
The bundle ID must end in `.canopy`. No signing, ad hoc signature, IPA packaging,
entitlement modification, device installation or launch is performed.

The builder creates a private staging tree under the new output directory. It
copies the required retained inputs while hashing stable, regular files and
rejecting symlink traversal, mismatches and existing destinations. In particular,
it copies and hashes the full RomFS; reserve room for that additional copy and
allow time for the read. It does not modify the retained input tree.

In that staging tree it runs the existing `prepare_runtime.py`,
`prepare_romfs_backend.py` and `prepare_shared_fonts.py`, then the retained host's
`export-ios` mode and the existing `gen_embed.py`. These retain the original
native port's module metadata and executable-section hash checks. The existing
RomFS generator consumes the retained, trusted extraction inventory. At launch,
Canopy independently regenerates the native index from the fully verified
prepared image and requires its SHA to match the compiled pin; a stale or
incorrect retained inventory causes refusal rather than native execution.

Compilation reuses the production runtime/NVN/texture directory selections and
Canopy public source list. It excludes the old `ios/Sources/main.m`, Mac frontend,
and the other version's patch source. Only `runtime/loader.c` receives
`-Dmain=totk_host_main`; `CanopyApp.m` remains the application entry. Sources use
`CANOPY_HOST_RUNTIME`, the selected version macro, the recipe's exact original
main pin, and the explicit final shader manifest pin. `gen_embed.py` supplies the
existing writable module and executable text segment flags. The general runtime
cache is not substituted for the separately verified shader cache.

The private builder reuses the public build's reviewed `sips`/`actool` recipe in
a separate staging directory containing only icon inputs and outputs. It copies
the compiled icon assets into the private app and records actual tool versions,
derivative geometry/hashes and compiled inventory in the private observation.
No game payload is an asset-compiler input, and the approved source artwork is
unchanged. Real private-app packaging and SpringBoard appearance remain local
checks even when the public icon recipe has passed Apple CI.

The resulting `Canopy.app` contains the original Canopy branding, embedded
private native modules, verified shared fonts and the selected shader seed.
The RomFS image is not bundled: prepare/import the matching private generation
through Canopy's actual preparation flow. Stock builds leave optional overlay
directories empty; display builds add only the generated, validated profiles
described below. Public workflows must never upload this
private app, staging data, command logs or observation file.

The output contains a private build observation with toolchain identity, source
and input hashes, commands, exporter hash, shader manifest pin and executable
hash. Command logs and the observation are local diagnostics, not independently
certified provenance. A failed build leaves diagnostics and no accepted app.
The staging tree is removed when the process unwinds normally.

## Opt-in 1.4.3 display resources

Add `--display-settings` to the private `--build --version v143` command only
when using a trusted exporter built from matching reviewed display-profile
sources. The builder passes the existing `build_ipa.py` exporter settings:
`TOTK_IOS_DISPLAY_SETTINGS=1`, initial `TOTK_RENDER_RES=1280x720` and
`TOTK_OUTPUT_RES=1280x720`, `TOTK_FIXED_RES=1`, `TOTK_ASPECT=0`,
`TOTK_ASPECT_VERT=1` and `TOTK_IOS_ASPECT_VERT=1`. These are applied before
`gen_embed.py` seals executable sections. No new addresses or patches are
introduced by this builder. An arbitrary older exporter binary is not made
display-capable by setting these variables.

After staging and checking original inputs, the builder runs existing generators
against that private staged tree:

- `make_output_res_overlay.py 1920x1080 --scene 1920x1080 --version v143`
  writes `GameData/romfs-patches-out/1920x1080-scene-1920x1080`.
- `make_romfs_patches.py --version v143 --aspect 1440x1080` writes
  `GameData/romfs-patches-4x3`.

Both output roots are explicitly supplied to the generators. The 1080 resource
reserves existing maximum-scene heap capacity; it does not force every session
to start at 1080. The 4:3 layout belongs to the existing Vert+ profile, which
retains known experimental UI-effect limitations. It is not an arbitrary aspect
ratio or gameplay-quality claim.

Before compilation the builder validates each generated manifest row, declared
file length and SHA256, and original-member SHA256 by rereading its range in the
fully verified staged RomFS image. It refuses linked or hardlinked files,
unsafe/duplicate paths, unlisted files/directories, missing members and
out-of-range originals. Each tree is bounded to 128 members, 64MiB per member
and 256MiB including bounded manifest/overlay metadata. Generated heap metadata
must identify the staged generator, exact version and 1920x1080 scene/output,
without a substituted mod HeapDef.

Original-member range rehash uses the explicitly trusted retained extraction
index; it does not independently reconstruct RomFS path-to-range binding and
must not authorize untrusted imported-folder metadata. Runtime checks of the
actual original bytes and hashes remain mandatory.

Only then are actual manifest hashes compiled as
`CANOPY_HOST_DISPLAY_HEAP_SHA256` and `CANOPY_HOST_DISPLAY_LAYOUT_SHA256`, with
`TOTK_IOS_DISPLAY_SETTINGS=1` and `TOTK_IOS_ASPECT_VERT=1`. The ABI2 host's
versioned display subrecord advertises the corresponding capability. Runtime
preflight and the existing overlay consumer must verify those resources again;
preferences alone grant no display capability. The private build observation
records manifest/member hashes, heap metadata hash, generator hashes and the
existing public-source/private-input/exporter/toolchain identities.
The validated `overlay.json` provenance is retained with its hash in that private
observation, then removed from the installed app resource tree. Installed
overlay trees contain only the pinned manifest and its listed payloads; runtime
validation must reject extra files.

Portable tests exercise the real verifier with original synthetic bytes and an
explicit synthetic generator-output runner. They do not execute generators,
the private exporter or Apple linker with game inputs. Actual trusted-exporter
output, Apple linking, signing and device rendering/quality checks remain
required; orchestration tests do not establish display-profile acceptance.

## Validation and remaining gates

`tests/test_canopy_private_build.py` runs portable original-fixture tests for
profile selection, per-source entry rename, stable input copies, rejection of
modified original/rewrite/RomFS/font/report bytes and explicit seed/map pins.
It does not contain game inputs and does not pretend to compile a private app.

**Local validation — 2026-10-26:** actual private v143 stock and display-profile
unsigned builds passed. The actual Mac NativeAOT publisher and original-shader
parity checks also passed. See [the local validation evidence](canopy-local-validation.md)
for exact source revisions, build scopes and platform limits. No app was installed
or accepted on a device; the iOS linked-translator route remains a separate gate.

**Historical cloud checkpoint:** no actual private link ran during that phase.
Generated headers, local codec ABI and the selected SDK link still required a
local Mac build then. Signing and physical-device native acceptance remain
separate gates; existing vm-remap source is not proof of permission on a device.
The host remains single use. CPU pause, safe stop, save-writer teardown and
in-process relaunch are still development work, not solved by producing an app.

### Optional linked native shader provider (historical source-only checkpoint)

Seed-only remains the default. To request the actual in-process consumer, add both `--shader-native-products /trusted/local/publish-output` and `--shader-native-build-sha256 <independently-reviewed-native-build.json-sha256>` to the private build. The directory must be real `publish_library.py --rid ios-arm64 --kind Static` output with a completed static-consumer link, current source recipe, both archives, native dependency plan/properties and license texts. This option never downloads or builds the translator.

The builder verifies captured bytes and each actual archive object's arm64/iPhoneOS identity, rejects unsupported linker arguments, and links captured runtime-pack dependencies into the unsigned app. Every actual dependency package must provide its local LICENSE.TXT and third-party notices, captured and distributed with hashes; no package download or arbitrary ancestor search supplies missing notices. The exact framework package suffix runtimes/ios-arm64/native and declared host root are supported; unknown layouts refuse. The compiled provider recipe includes actual archives and consumer sources; runtime shader payloads/indexes use a separate recipe directory inside the retained shader-cache lease. Renderer PSO/observed/patched-variant files keep their existing directory. Neither report metadata nor a user preference grants runtime provider authority. Missing or incompatible products cause a failed build, not a seed-only substitution disguised as native translation.

The strict reader currently supports explicit platform-bearing Mach-O archives and a closed set of .NET10 static link arguments; an unknown SDK/runtime-pack spelling refuses until inspected on its actual toolchain. The resulting source path is unbuilt and unexecuted here. NativeAOT static linking, managed/Cross parity and resource behavior, Metal compilation, signing/external-code permission and actual iPad gameplay require their own evidence. This cohort ran no tests, probes, builds or CI.
