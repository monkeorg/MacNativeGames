# iPad graphics inventory and measurement

Issue: [remaining Mac graphics settings and stable 60 FPS](https://github.com/monkeorg/MacNativeGames/issues/6).

This is a source inventory and an offline analysis tool, not a device performance result. TOTK 1.4.3 is the target. Native 60 FPS at 1080 high remains unverified. On a 4:3 display the requested canvas is 1440×1080; Full display is experimental, with known marker and pixel-snapped UI limitations. Actual render targets, projection, UI and drawable dimensions require separate device checks. See the [launcher](ipados-launcher.md) and [baseline protocol](ipados-baseline.md).

## Existing controls and iOS availability

Paths below are relative to `games/totk/`. Source inclusion establishes an implementation path, not successful compilation, supported hardware, visual correctness or acceptable performance. `ios/project.yml` includes the shared NVN directory and runtime, excluding the Mac `frontend.m` and BOTW patches. No graphics defaults or UI controls are added by this work.

| Feature | Mac implementation and control | iPad state / acceptance gap |
|---|---|---|
| Picture modes | `runtime/input.c`, `runtime/game_patches_v143.c:runtime_output_mode_cycle`: key 3 cycles MetalFX 2K, native 2K, off. `TOTK_OUTPUT_RES` configures canvas capacity. | Launcher offers 720/1080 high only with the signed display profile. Stock iOS retains 720p. Mac key 3 picture/output cycling is explicitly unavailable on iOS; the launcher owns the canvas until app restart. Additional settings require Apple build and physical visual checks. |
| Spatial MetalFX | `third_party/d2r_gfx/gfx/nvn/totk_mfx_up.m`: `TOTK_MFX_UPSCALE` replaces selected scene upscale draws; `TOTK_MFX_OUTPUT` upscales the final output region. Both default off, require Metal 4 FX support and suitable texture usage. | Shared source is included. No persistent launcher selector. Capability checks and fallback do not prove target-device rendering correctness. Upscaling does not establish native render resolution. |
| Interpolation | `third_party/d2r_gfx/gfx/nvn/totk_mfx.m`, `totk_mfx_mode.h`: key 2 / `TOTK_MFX=0,interp30,interp,interpmax` selects off, 30+30, half-refresh, or uncapped interpolation. Uses camera-derived motion, depth and separate scene/UI inputs. | Shared source is included; hardware capability and inputs must be verified. No persistent launcher selector. Generated pictures never count toward native 60 FPS. Validate moving objects, camera cuts, UI and history resets separately. |
| Temporal AA | `third_party/d2r_gfx/gfx/nvn/totk_taa.m`: key 5 / `TOTK_TAA=1`, off by default. MetalFX temporal scaler at scene size (1:1), geometry jitter and camera-derived motion. | Shared source is included; no persistent launcher selector. Confirm Metal 4 FX availability and image quality, especially moving objects, before offering it. |
| Texture filtering | `third_party/d2r_gfx/gfx/nvn/nvn_mtl.m:samp_by_id` (search `TOTK_ANISO`): optional 2–16× floor for repeating, linearly filtered mipmapped material samplers. Clamped, point, shadow-compare and reduction samplers retain game settings. | Shared implementation; no persistent launcher selector. Keep sampler restrictions: the source records inventory outline artifacts from changing clamped samplers. Visual and GPU-cost comparison pending. |
| FXAA | `third_party/d2r_gfx/gfx/nvn/nvn_mtl.m` (`DM_NVN_NOFXAA=1`): disabled-by-default experiment skipping a full-screen FXAA draw and redirecting consumers. | Diagnostic experiment, not an accepted quality preset. No iOS quality reduction is justified by current measurements. |
| Overlays | `runtime/frontend.m` describes key 1; shared `fps_overlay.h` distinguishes game FPS and generated frames. | Persistent Full/FPS/Off and live game-menu selection exist. Apple Metal HUD is separate; the tested device required Settings → Developer → Graphics HUD → Show Graphics HUD. See launcher evidence. Neither overlay alone closes sustained native FPS acceptance. |
| Aspect / pacing | `runtime/input.c` key 4; `runtime/game_patches_v143.c` display/frame-controller patches; `third_party/d2r_gfx/gfx/nvn/hle_nvn.c:present_period` and `nvnQueuePresentTexture` implement pacing. `TOTK_FPS60`, `TOTK_UNCAPPED` and interpolation affect cadence. | Launcher aspect uses the signed display profile until app restart; Mac key 4 aspect cycling is explicitly unavailable on iOS. Record actual refresh rate and interpolation state. A requested 60 FPS controller, 120 Hz display-link cadence or scheduled present is not measured native throughput. |

## Measure before changing rendering

Use Instruments Metal System Trace / Game Performance, Time Profiler, Xcode GPU capture and Metal HUD first, as required by [CONTRIBUTING.md](../CONTRIBUTING.md#picture-quality-and-performance). GPU captures should be outside timed sessions. Existing repository diagnostics include:

- `DM_NVN_TSV=<writable path>` and `DM_NVN_TSV_CALLS=0`: existing per-frame timing-only TSV in `hle_nvn.c`; avoids the much larger call-count rows, but still has collection and file-I/O overhead.
- `DM_SLOWFRAME=1` and `TOTK_LONGFRAME_DETAIL=1`: long-frame attribution with shader/pipeline creation, upload and optional draw/pass/variant details in `hle_nvn.c`.
- `DM_NVN_PROF=1`: NVN recording/submission timing wrappers in `hle_nvn.c`; use deliberately because instrumentation changes CPU work.
- `TOTK_PASS_GPU=<first>[:<count>[:<stride>]]` and `TOTK_PASS_GPU_FILE`: bounded encoder GPU timestamps in `nvn_mtl.m`.
- The existing 300-frame timing/presentation summaries in `hle_nvn.c:tsummary` include footprint and thermal hook readings. Unknown hook values are not a nominal thermal result. Capture synchronized resident/footprint and thermal evidence with available device tools.

`scripts/mac_v143_soak.py` explicitly refuses per-frame TSV for long Mac sessions. Respect that operational limit; a timing-only trace still needs a bounded capture and reliable private readback. The earlier iPad TSV readback was partial. Do not extend it into a claimed 30-minute result. No measured bottleneck is established by this checkout, so renderer optimization and new graphics UI settings remain deferred.

## Offline timing summary

`scripts/summarize_frame_trace.py` reads the existing plain or gzip TSV using Python's standard library. It does not launch the app, alter saves, change instrumentation or import private captures into the repository. Select explicit inclusive frame IDs for one prepared scene; do not combine different settings, loading intervals or scene transitions into an unlabeled result.

```sh
python games/totk/scripts/summarize_frame_trace.py /private/path/frames.tsv \
  --first-frame 1000 --last-frame 3000 > /private/path/summary.json
```

The JSON reports these independent sample definitions:

- `@frame_ms`: elapsed wall time between guest `nvnQueuePresentTexture` calls, measured at `t0` in `hle_nvn.c`. Its inverse mean is **guest present-call cadence**, not independently verified native rendered FPS. It includes pacing and waits between those calls.
- `@gpu_ms`: runtime GPU duration per game frame, retrieved eight frames later and attributed by frame ID. Its inverse is not FPS.
- `@presented_ms`: callback-time difference between adjacent game presents, retrieved eight presents later. `-1` means discarded; zero means no usable interval. It is not an enumeration of every generated/interpolated picture.

`@call_ms`, when available, supplies a separate wall-clock span between the first and last valid selected call timestamps. The report gives those endpoint IDs and missing/invalid/duplicate timestamp counts; a missing endpoint means the span covers only part of the requested range. Non-increasing timestamps suppress the span. It excludes the interval preceding its first timestamp and is not interchangeable with the sum of interval samples. Explicit frame bounds exclude warm-up; the analyzer does not identify warm-up or scenes automatically.

The reader matches IDs despite delayed/out-of-order rows. It ignores unselected metrics and reports malformed lines, missing IDs, invalid values and duplicate IDs. Duplicate samples are excluded entirely, so the last value cannot silently overwrite evidence. Positive finite samples form each distribution; discarded presentation samples also appear in the invalid count. Missing IDs include possible startup/late-readback tails, not necessarily dropped screen frames. The script cannot detect an unrecorded wall-clock gap with contiguous IDs, quantify profiler overhead, or certify capture completeness beyond the requested ID range.

Median averages the middle pair for even counts; p95 and p99 use nearest rank (`ceil(q*N)`). The defined 1% low is `1000 / mean(slowest ceil(N*0.01) intervals)`; it is not the inverse p99. The interval summary includes counts strictly above 1000/60 and 1000/30 ms and the sum of valid sampled intervals. With missing/invalid samples that sum is not full session duration. GPU time receives duration statistics only. Memory, thermal state and native rendered FPS stay explicitly unverified by this tool.

## Remaining acceptance

Select and warm the three real scenes in the baseline protocol, agree numerical stability thresholds, and capture a continuous physical-device session of at least 30 minutes. Report each scene, full session, first five minutes and last five minutes using synchronized tools, with overhead and gaps disclosed. Confirm render targets at 1080 high and actual display aspect, correct world/UI projection, image quality, native rendered versus presented/interpolated frames, memory and thermal transitions. Pair any later iOS-only quality tradeoff with before/after screenshots and measured work saved, added cost and whole-frame change. Mac picture quality must remain unchanged.

Linux validation covers only the offline analyzer and repository tests. Apple SDK compilation, installation, MetalFX probes, physical graphics checks and sustained gameplay are pending; this environment has no Apple SDK, game content, device, private build caches or signing material.
