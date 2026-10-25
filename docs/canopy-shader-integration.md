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

Canopy also admits the optional exact filenames `pso_list.tsv` and `pso_title.tsv`, alongside `pso_manifest.tsv`, through the manifest's `files` map. Each present list must have its full SHA-256 recorded there; optional does not permit an unlisted sidecar. Producers must hash the final exported and renamed PSO bytes, then users must regenerate the actual trusted compiled manifest pin. Adding or changing a list changes that pin and the private namespace; an old pin cannot approve the new manifest. The existing exact-tree checks, file/count/total limits, device identity and leases remain in force. Presence of either list grants no shader-translation or native-execution capability. The companion original-runtime filename check admits the same two exact names. Neither change attests a Documents transport pack or adds a signature claim.

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

## In-process source checkpoint

The next source slice now exists under `games/totk/tools/totk_xlate`:

- `Program.cs:TranslateBytes` shares the real patched Ryujinx/SPIR-V translator with the file CLI adapter.
- `Service.cs:TranslateBytes` shares the existing inference retries, FP64 fallback, depth rewrites and reflection construction; the CLI supplies its existing executable Cross adapter, while the library supplies the real in-process adapter.
- `NativeExports.cs` preserves ABI version 1 and `canopy_shader_translate`, and adds `canopy_shader_translate_controlled`. Both entries use the same bounded defaults. `inprocess_cross.h` documents caller-owned buffers, the additive control layout and statuses. The output is bounded UTF-8 JSON containing final SPIR-V as base64, MSL and reflection. No cache publication or subprocess belongs to this ABI. An atomic nonblocking admission gate serializes managed translations and reports busy rather than sharing request state.
- `inprocess_cross.cpp` invokes the exact pinned public `CompilerMSL` with the service's current options. Its C boundary catches C++ exceptions and never writes partial output on insufficient capacity.
- `NativeLibrary.csproj` selects static NativeAOT by default, with direct `__Internal` P/Invoke for the Cross symbol. For plain `net10.0` iOS builds it selects `PublishAotUsingRuntimePack=true` and `AppleMinOSVersion=16.0`. The original executable project remains available.
- `publish_library.py` checks the public Cross commit and requires no modified, untracked or ignored dependency files. It builds only private copies of Cross and the vendor translator. `checked_patches.py` requires exact per-patch input hashes, patch hashes and resulting hashes; changed source and reapplication are refused. The desktop publisher uses the same checks. Restore uses an empty local package source, allowing only packages already in the global cache. It installs neither SDKs nor packages. Missing offline dependencies are a failed build gate. Build metadata hashes the actual copied/patched source trees, managed sources and emitted products; it does not claim a hermetic SDK/package/compiler identity.

Native input caps are 64 KiB shader bytes and 64 KiB request JSON (depth 16); pointers must refer to valid nonoverlapping caller-owned buffers. The decoder accessor validates addresses/alignment and limits reads to one million. Graphics requests must match the actual SPH vertex/fragment stage before decoding. Cross accepts at most 4 MiB SPIR-V with bounded ID space, emits at most 8 MiB MSL, and the final envelope is limited to 16 MiB.

### Cooperative resource controls

One managed request scope remains active across service inference/FP64 retries, Cross calls, reflection and serialization. Its default ceilings are 67,108,864 charged work units, 262,144 tracked nodes, 268,435,456 bytes of instrumented growth and 5,000 ms checked elapsed time. A valid version/size/reserved control structure may lower these ceilings; zero selects the same bounded defaults used by the original ABI entry. Control/callback/context pointers are trusted host-owned memory valid until synchronous return, never addresses parsed from shader JSON. Callbacks are synchronous, serialized and nonreentrant. Status 6 denotes cancellation; status 5 denotes quota/deadline refusal. Failure leaves output untouched and exposes fixed statuses rather than compiler exception text.

The private translator patch contains 368 braced-loop checkpoints covering decoder worklists, CFG/dominance/SSA/optimization, structured IR and SPIR-V generation. It charges selected IR/AST/pool growth and bounds recursive expression generation. The service polls its loops and uses remaining-time regex matching with charged match iteration. A thread allocation counter supplies an additional observed managed allocation check. Aborted SPIR-V generation unregisters its thread-local literal pool at request cleanup; interrupted borrowed pools are discarded rather than returned for reuse. Five fixed, source-defined initialization loops in `InstTable` and `AttributeMap` deliberately have no throwing checkpoint: cancellation during a type initializer would permanently poison that type. The next input-driven checkpoint still checks elapsed time and cancellation after initialization.

The private pinned Cross patches contain 396 loop checkpoints: 357 originally braced loops and an additional 39 exact single-statement loops in parser/CFG collections, parent-chain, string and location searches, ten normal IR dependency-invalidation loops, and two dependency-graph child-edge loops. The added checks precede the original statement and preserve its condition/increment/order. Other controls are a 16-pass recompile ceiling, selected traversal/emission depth checks, ID/object-pool growth checks and StringStream append/allocation/final-copy checks. Every throwing stream-allocation checkpoint precedes buffer ownership duplication. Original AddressSanitizer subprocess fixtures exercise second-heap-growth cancellation/quota and cyclic internal type/expression walks, safe unwind and later independent reuse. These internal graph fixtures do not establish which malformed SPIR-V modules reach those graphs through the parser.

These are cooperative controls, **not** a hard process heap limit, preemptive timeout or complete compiler sandbox. `patches/resource-coverage.json` and `cross_patches/resource-coverage.json` record coverage and remaining gates. Of the original 164 pending Cross sites, 39 now have checkpoints and two are reclassified fixed `do/while(false)` macro wrappers. The remaining raw inventory has 123 sites: ten have source-proven literal/array/enum bounds and 113 remain input-dependent or unproven. Original native AddressSanitizer fixtures exercise all ten invalidation-loop cases through the actual methods after constructing mutually exclusive IR collections. They verify exact per-iteration quota/cancellation, preserve trailing clears on interruption, destroy the interrupted compiler, and complete a separate fresh compiler request; these are not full translator or runtime-enablement proofs. Two dependency-handler depth guards now bound variable-scope and combined-image sampler hierarchy traversal. Original native ASan fixtures exercise actual handlers on cycles and acyclic chains beyond the existing 256-frame limit, plus shallow wide graphs with quota/cancellation. They verify controlled failure, actual compiler destruction during unwind, and a separate fresh successful graph with unchanged access/comparison results. This does not establish which SPIR-V inputs can produce those internal graphs. Other input-driven loops, noexcept SmallVector growth, STL allocation/algorithms, other recursive helpers and ParsedIR move/cleanup paths still need assessment. Managed framework/LINQ internals, other recursion and fixed initialization also need separate assessment. Input/output hashes establish identity, not safety or executable trust. Arbitrary untrusted translation jobs and runtime capability remain disabled until coverage review and actual managed/static/iOS/resource/parity gates pass.

### Actual static consumer gate

The [platform-specific .NET NativeAOT guide](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/ios-like-platforms/creating-and-consuming-custom-frameworks) documents plain .NET iOS libraries with `PublishAotUsingRuntimePack=true` and `NativeLib=Static`. This establishes a public toolchain route, not evidence that this project builds or deploys. The publisher aligns Cross, NativeAOT and the consumer with iOS 16, records the SDK-selected native link arguments/runtime-pack paths, links the real C probe against both archives and runtime dependencies, and inspects actual archive members/final Mach-O platform and deployment metadata. It runs original Maxwell self-tests only on a matching desktop host. An iOS/simulator build does not set up or run a simulator, sign an app, execute a shader or establish device acceptance.

Available local evidence is a real GCC 14 build of privately patched pinned Cross and the adapter, original SPIR-V compute-to-MSL execution, exact existing Cross CLI byte parity, malformed-input/exception boundaries, internal cooperative quota/cancellation refusal, concurrent independent compiler calls, no-partial-output behavior and the stream ASan regression. The original Maxwell fixture is authored from the checked-in EXIT/NOP decoder fields, with a scheduling word and local size 1. Its successful translation and first-request interruption followed by successful reuse require the actual linked static NativeAOT probe; opcode bytes alone are not translation proof. No .NET compiler or Apple SDK is installed in this Linux environment, so managed compilation/resource tests, static export/link, full translator CLI parity, iOS deployment and Metal dispatch remain unproven. No runtime capability is enabled by these source files.

Example commands, with an existing exact-pinned public checkout:

```sh
python games/totk/tools/totk_xlate/publish_library.py --inspect
python games/totk/tools/totk_xlate/publish_library.py --cross-source /path/to/pinned/SPIRV-Cross --output /empty/private/build --rid osx-arm64
CANOPY_SPIRV_CROSS_SOURCE=/path/to/pinned/SPIRV-Cross python -m unittest discover -s tests -p test_canopy_shader_native.py -v
```

`--cross-only --rid linux-x64` checks the genuine native adapter without .NET. `tests/canopy_shader_native_probe.c` must actually link against the produced static managed archive and Cross archive before setting `CANOPY_SHADER_NATIVE_PROBE`. Set `CANOPY_SHADER_CLI` and `CANOPY_SPIRV_CROSS_CLI` to actual existing compiler binaries to enable byte/JSON parity on the original Maxwell input. The test suite does not download dependencies or substitute a mock compiler when these binaries are missing.
