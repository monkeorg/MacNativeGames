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

Only TOTK 1.2.1 (`v121`) and 1.4.3 (`v143`) are currently selected by this recipe.
Their title ID, original ExeFS hashes, rewritten-image hashes, RomFS identity and
shared-font hashes come from the checked-in `games/totk/assets/expected-*.json`
tables. The recipe has no option to replace those tables or choose an arbitrary
title. An encrypted container SHA is never substituted for an original NSO hash.

## Local prerequisites

Use an Apple silicon Mac with an installed Xcode 26+ and iPhoneOS SDK26+. The
builder uses the existing `ios/tools/build_sources.py` toolchain selector. It
downloads nothing. Python must already have the existing runtime generator's
`capstone` dependency installed.

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

The resulting `Canopy.app` contains the original Canopy branding, embedded
private native modules, verified shared fonts and the selected shader seed.
The RomFS image is not bundled: prepare/import the matching private generation
through Canopy's actual preparation flow. Empty optional overlay directories
provide no unverified title patches. Public workflows must never upload this
private app, staging data, command logs or observation file.

The output contains a private build observation with toolchain identity, source
and input hashes, commands, exporter hash, shader manifest pin and executable
hash. Command logs and the observation are local diagnostics, not independently
certified provenance. A failed build leaves diagnostics and no accepted app.
The staging tree is removed when the process unwinds normally.

## Validation and remaining gates

`tests/test_canopy_private_build.py` runs portable original-fixture tests for
profile selection, per-source entry rename, stable input copies, rejection of
modified original/rewrite/RomFS/font/report bytes and explicit seed/map pins.
It does not contain game inputs and does not pretend to compile a private app.

An actual private link has not been run in this environment. The first retained
Mac build must verify the complete generated headers, local codec ABI and link
against the selected SDK. Signing and physical-device native acceptance are
separate gates; existing vm-remap source is not proof of permission on a device.
The host remains single use. CPU pause, safe stop, save-writer teardown and
in-process relaunch are still development work, not solved by producing an app.
