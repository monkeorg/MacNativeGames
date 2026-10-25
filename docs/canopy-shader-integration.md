# Canopy private shader seed and cache

`CanopyShaderCache` imports an authenticated private seed into a separate namespace before native entry. `CanopyRuntime.m` obtains identity from the selected Metal device, supplies the compiled host's manifest SHA and chain, and retains the returned shared lease through the native session. `canopy_host.m` passes the immutable seed to `TOTK_SHADER_SEED_DIR`/`DM_NVN_SHMAP` and the separate writable directory to `TOTK_SHADER_CACHE`. These paths are distinct from the general game-slot/RomFS cache and from saves.

This checkpoint is source implementation plus original component fixtures. The Foundation/Metal component suite requires macOS; its Linux result is explicitly skipped. Neither these fixtures nor successful import would demonstrate translation, GPU execution, complete shader coverage, or title gameplay.

## Trust and identity

The host's compiled `shader_seed_manifest_sha256` and `shader_chain` are trusted input. Imported JSON never establishes its own approval. The approved generation provides the title and actual source RomFS SHA. The canonical private namespace hashes:

- title and source RomFS SHA;
- compiled manifest SHA and chain;
- manifest-bound translator, SPIRV-Cross and preparation SHA values;
- selected Metal device name, registry value, supported families, OS compile identity, safe math mode and Metal language recipe.

Device details remain in the private receipt. Public metrics and diagnostics contain only an opaque identity hash, byte counts, and fixed error text. OS/device changes conservatively create a different namespace. A canonical physical private root is required; no symlink component is followed.

The manifest is the existing schema 1 seed envelope with a required additional `shader_map_sha256`. The legacy `files` map excludes `shader_map.tsv`, because `totk_shader_seed.h` deliberately accepts a narrower filename grammar. Canopy separately hashes and imports this actual runtime input. Private producers must add that field and then rebuild the trusted manifest pin; there is no unchecked old-map fallback. Source hardlinks produced by the existing preparation script are accepted only as stable regular input. Every destination is a fresh private single-link file.

All listed file bytes are SHA-256 checked while streaming. Cached immutable seeds are rehashed before reuse, including the manifest and map. Metal/reflection pairs, variant indices and matching dependency answers are structurally checked; optional scope metadata is checked when present. This does not validate Metal program semantics or authenticate mutable runtime output. Safe filename grammar prevents paths in the manifest.

Limits are 100,000 listed files, 64 MiB per file, 32 MiB manifest, and 16 GiB total seed bytes. Reflection/index JSON reads have a 16 MiB limit; each variant index has at most 4,096 rows. Streaming uses 64 KiB chunks. Cancellation polls hashing and metadata walks, including immediately before publication. Callbacks run on the serialized worker, are nonreentrant, and must not mutate inputs or storage.

## Publication, reuse and controls

New imports are written under a newly owned UUID staging directory with 0700 directories and 0400 files, flushed, then published using an exclusive rename. Validation failure or cancellation cleans only this operation's staging directory. Existing published data is never replaced to hide corruption. An IO error after rename may leave a complete published identity; retry verifies it. A process crash can leave a private UUID stage; this implementation does not sweep historical stages or claim general crash recovery.

A shared per-identity lease remains held during native use. Clear and remove require the exclusive lease plus the root operation lock. They verify the identity receipt/title and traverse through descriptor-relative no-follow operations with bounded depth/count/bytes. They reject special files, symlinks and external hardlinks. Clear preserves the authenticated seed; remove targets only the exact identity. Neither operation traverses saves or other identities. Interrupted removal can leave an unusable partial identity and requires explicit recovery; it never follows external paths.

The writable renderer directory remains inside private ancestors. Renderer-created descendant files/directories can retain their normal modes; the importer does not treat these bytes as authenticated seed material. A zero-byte `.canopy-private-cache` marker prevents the legacy empty-folder clone branch from changing the writable root to 0755. The current legacy per-file seed importer may still perform additional copies/verification; metrics do not claim to eliminate this work.

`seedCopiedBytes` and `seedReusedBytes` count actual importer seed bytes, including the manifest and map. Reuse verifies bytes and preserves seed inodes. `metadataWrittenBytes` counts the private identity receipt. Usage reports logical file lengths, not physical disk allocation or clone savings. No performance or GPU compilation savings are inferred from these counters.

## Grounded native translation route

Current sources already contain the translator rather than a reason to invent another one:

- `games/totk/tools/totk_xlate/Program.cs`: patched Ryujinx translator produces SPIR-V and reflection from shader bytes and bind answers.
- `games/totk/tools/totk_xlate/Service.cs`, especially `SpirvCross`: invokes an external SPIRV-Cross executable with `Process.Start`, then applies the project's MSL/reflection pipeline.
- `games/totk/tools/totk_xlate/publish_native.sh`: publishes a standalone `osx-arm64` NativeAOT executable. That executable is not an iOS in-process bridge.
- `games/totk/third_party/d2r_gfx/gfx/nvn/totk_shader_rt.m`: spawned service on desktop; the iOS `no_translator` path records misses instead. Existing Metal source compilation uses the platform GPU compiler API.
- `games/totk/ios/tools/compile_seed.py`: device metallib preparation and SDK/compiler/source-sensitive reuse, with safe math flags.

The bounded implementation route is to expose the existing translator through a static NativeAOT library and a versioned C ABI accepting bounded shader bytes, stage/bind answers and recipe, returning bounded SPIR-V/reflection/error buffers. Replace only the service's subprocess SPIRV-Cross boundary with the pinned in-process C/C++ API (`aa217aeb6c9f0ace7a0ab233b28807edf45eb165`, as recorded in `build_app.py`), retaining the existing postprocessing. Then compile MSL with `newLibraryWithSource` on the selected device. No CPU emulator or executable-memory JIT is involved.

Before crediting that route, actually build a device static library, prove its exported C ABI and managed exception containment, test quotas/cancellation and ownership, and run wholly original synthetic shader/bind cases through both existing desktop and new in-process paths. Changing a runtime identifier alone does not establish iOS NativeAOT availability or deployability. No working iOS static translator build is claimed here. Translator/vendor code is MIT and SPIRV-Cross is Apache-2.0; preserve existing notices and pinned patches. No game shader inputs are needed to start this source/build work.

## Verification gates

Run the component suite on an Apple runner:

```sh
python -m unittest discover -s tests -p test_canopy_shader_cache.py -v
python -m unittest discover -s tests -p test_canopy_runtime.py -v
```

The shader fixture generator is `write_shader_seed` in `tests/test_canopy_shader_cache.py`. It writes original tiny Metal code, invented reflection/bind indices and authenticated map bytes; its invented tool hashes are test identity only. The component probe uses a synthetic device dictionary, while production calls `deviceIdentityForDevice` with the actual selected device.

Review gates are two independent source reviews, actual Apple compilation/test evidence, the connected Runtime consumer suite, and eventually selected-device Metal compilation/execution evidence. A valid seed only covers its supplied variants. Missing shaders, native translator deployment, runtime behavior and exact-title gameplay remain separately measurable work.
