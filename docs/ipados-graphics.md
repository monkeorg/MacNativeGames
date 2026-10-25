# iPad graphics inventory and measurement

Issue: [remaining Mac graphics settings and stable 60 FPS](https://github.com/monkeorg/MacNativeGames/issues/6).

This is a source inventory and an offline analysis tool, not a device performance result. TOTK 1.4.3 is the target. Native 60 FPS at 1080 high remains unverified. On a 4:3 display the requested canvas is 1440×1080; Full display is experimental, with known marker and pixel-snapped UI limitations. Actual render targets, projection, UI and drawable dimensions require separate device checks. See the [launcher](ipados-launcher.md) and [baseline protocol](ipados-baseline.md).

## Existing controls and iOS availability

Paths below are relative to `games/totk/`. Source inclusion establishes an implementation path, not supported hardware, visual correctness or acceptable performance. `ios/project.yml` includes the shared NVN directory and runtime, excluding the Mac `frontend.m` and BOTW patches. The current iPad menu exposes output resolution, scene render scale and spatial upscaling without changing the native-resolution defaults.

### Resolution controls — 2026-10-25

- **Setup modes:** Input + output, Input + multiplier, or Output + multiplier. The page shows only the controls needed by that mode and a configured input-to-output summary. Input + output also shows the effective linear multiplier after aspect-fit and supported input rounding.
- **Input:** 540/720/900/960/1080-high presets or a custom slider and numeric entry from 360 to 1080 in steps of six. Width follows Full display or 16:9. The signed game canvas remains within 1920×1080. Legacy scene-scale preferences remain readable; selecting a mode or input normalizes them to a direct input size.
- **Final display output:** match game, 720/900/1080/1440/2160-high, 50% native, 75% native, native active-window pixels, or custom even content height with aspect-derived width. Full-display 1440 high is 1920×1440 at 4:3, rather than 2560×1440. Native dimensions use window size and the active screen's native scale. The presentation surface is separate from the signed game canvas; its guard is 8192 pixels per axis.
- **Multiplier:** a 1–4× slider with 1/1.25/1.5/2/3/4× presets. Output + multiplier derives an input rounded to the supported six-pixel height grid. Combinations outside the signed game profile are reported and refused before Play. Input + multiplier derives the presentation size. Selecting native output does not make game rendering native-resolution.
- **Scaler:** Game scaling, Game → final MetalFX, or Scene MetalFX + final MetalFX. Game → final MetalFX can retain an intermediate game canvas at Match input, 900 high or 1080 high. This permits 960×720 input → 1440×1080 game canvas → native 2752×2064 output on the tested geometry model. The iOS final-stage gate is independent of scene replacement; the Mac gate is unchanged. A canvas smaller than input is refused. TAA remains separate. Unsupported or unready MetalFX keeps the renderer fallback; a selected stage does not prove an encode.
- **Status:** recent MetalFX activity comes from successful encode paths within two seconds, not saved preferences. It does not prove GPU completion, image correctness or an FPS gain. The Metal HUD and runtime logs remain the tools for actual buffer/presentation evidence.
- **Menu:** prelaunch and in-game navigation share a bounded glass panel (maximum 720×760 points). Submenus and slider editors retain those bounds. Back and Close are integrated in the panel; checkmarked native popovers anchor to their setting rows and scroll long lists. Back or Close discards an unfinished multiplier edit. Reduced-transparency/contrast preferences use solid backgrounds. Resolution changes retain the restart footer/prompt.

The user explicitly requested optional lower rendering resolutions. This overrides the upstream no-resolution-reduction guideline for these opt-in iPad settings. Existing defaults, Mac rendering behavior, signed code and private inputs remain unchanged. The final-output option adds GPU work; no native-resolution-equivalent quality or performance gain is claimed. Frame interpolation was not added. External-screen routing and physical 4K display acceptance remain unchecked; a valid 3840×2160 calculation is not proof of TV operation.

Verification for `7ffa57b`: 364 repository tests passed, both iPhoneOS source profiles compiled (24 objects), and the cached Mac host, full iPad app and test-runner builds passed. No simulator or automated Play/save-load cycle ran. Physical appearance, actual spatial output encodes, output dimensions, image quality and sustained FPS remain open. An experimental in-app restart is tracked in [issue #55](https://github.com/monkeorg/MacNativeGames/issues/55). The user accepts loss of unsaved progress and requests a red action with two confirmations. A callable engine reload request remains unidentified; warnings alone do not supply that mechanism.

Verification for `9700dd7`: 364 repository tests passed, both iPhoneOS source profiles compiled (28 objects), and the full Apple app and device-runner builds passed. The signed app installed; account identity remained byte-identical; the device launch command succeeded. No simulator, automated Play or save-load cycle ran. Panel navigation, appearance and multiplier display remain physically unchecked.

### Shader preparation indicator

Graphics → Shader compilation indicator enables a separate live toggle, off by default. A native label shows “Preparing shaders” with active, completed and failed request counts. A 100 ms UI timer runs independently of render submission; the label hides two seconds after the last completed request. The counter excludes explicit pipeline archive hits and precompiled library loads. Metal may still use its private cache internally, so this measures source-library and archive-miss pipeline build requests, not a compiler percentage or a known total shader count. No pipeline timing or FPS improvement is claimed.

Verification for `3b0888e`: 366 repository tests and 710 overlay/probe checks passed. Both iPhoneOS profiles compiled (28 objects), and the Mac v143 host, full iPad app and device-runner builds passed. Independent review found and corrected the final-stage gate and an aspect-rounding bug at custom input heights 366/372. The final signed app installed, account identity remained byte-identical and the device launch command succeeded. Device shader visibility, actual final MetalFX encodes, quality and performance remain separate acceptance checks. No simulator or automated Play/save-load cycle ran.

| Feature | Mac implementation and control | iPad state / acceptance gap |
|---|---|---|
| Picture modes | `runtime/input.c`, `runtime/game_patches_v143.c:runtime_output_mode_cycle`: key 3 cycles MetalFX 2K, native 2K, off. `TOTK_OUTPUT_RES` configures canvas capacity. | The conditional Resolution page separates signed game input/canvas from final presentation output. Native and aspect-aware 1440/2160-high display presets do not enlarge the signed guest canvas. Physical rendering and external display checks remain open. |
| Spatial MetalFX | `third_party/d2r_gfx/gfx/nvn/totk_mfx_up.m`: `TOTK_MFX_UPSCALE` replaces selected scene upscale draws; `TOTK_MFX_OUTPUT` upscales the final output region. Both default off, require Metal 4 FX support and suitable texture usage. | The persistent scaler selector configures scene and final-display hooks. Recent encode activity is visible. Capability checks and fallback do not prove target-device rendering correctness. |
| Interpolation | `third_party/d2r_gfx/gfx/nvn/totk_mfx.m`, `totk_mfx_mode.h`: key 2 / `TOTK_MFX=0,interp30,interp,interpmax` selects off, 30+30, half-refresh, or uncapped interpolation. Uses camera-derived motion, depth and separate scene/UI inputs. | Shared source is included; hardware capability and inputs must be verified. No persistent launcher selector. Generated pictures never count toward native 60 FPS. Validate moving objects, camera cuts, UI and history resets separately. |
| Temporal AA | `third_party/d2r_gfx/gfx/nvn/totk_taa.m`: key 5 / `TOTK_TAA=1`, off by default. MetalFX temporal scaler at scene size (1:1), geometry jitter and camera-derived motion. | A capability-gated live selector exists. Earlier device logs recorded temporal scaling, but quality/cost comparisons remain open. |
| Texture filtering | `third_party/d2r_gfx/gfx/nvn/nvn_mtl.m:samp_by_id` (search `TOTK_ANISO`): optional 2–16× floor for repeating, linearly filtered mipmapped material samplers. Clamped, point, shadow-compare and reduction samplers retain game settings. | Shared implementation; no persistent launcher selector. Keep sampler restrictions: the source records inventory outline artifacts from changing clamped samplers. Visual and GPU-cost comparison pending. |
| FXAA | `third_party/d2r_gfx/gfx/nvn/nvn_mtl.m` (`DM_NVN_NOFXAA=1`): disabled-by-default experiment skipping a full-screen FXAA draw and redirecting consumers. | Diagnostic experiment, not an accepted quality preset. No iOS quality reduction is justified by current measurements. |
| Overlays | `runtime/frontend.m` describes key 1; shared `fps_overlay.h` distinguishes game FPS and generated frames. | Persistent Full/FPS/Off and live game-menu selection exist. Apple Metal HUD is separate; the tested device required Settings → Developer → Graphics HUD → Show Graphics HUD. See launcher evidence. Neither overlay alone closes sustained native FPS acceptance. |
| Aspect / pacing | `runtime/input.c` key 4; `runtime/game_patches_v143.c` display/frame-controller patches; `third_party/d2r_gfx/gfx/nvn/hle_nvn.c:present_period` and `nvnQueuePresentTexture` implement pacing. `TOTK_FPS60`, `TOTK_UNCAPPED` and interpolation affect cadence. | Launcher aspect uses the signed display profile until app restart; Mac key 4 aspect cycling is explicitly unavailable on iOS. Record actual refresh rate and interpolation state. A requested 60 FPS controller, 120 Hz display-link cadence or scheduled present is not measured native throughput. |

## Menu and scaling research — 2026-10-25

Apple's [menu guidance](https://developer.apple.com/design/human-interface-guidelines/menus), [popover guidance](https://developer.apple.com/design/human-interface-guidelines/popovers) and [disclosure guidance](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) support familiar controls, selected-state checkmarks, limited nesting and conditional advanced controls. The bounded navigation stack keeps the full settings menu available without a cascade of popovers. Physical usability remains unchecked for this revision.

Game composition and final MetalFX output are separate renderer stages, so they can occur in one frame. The stage selector now separates game composition followed by final MetalFX from scene replacement plus final MetalFX. Extra scaling can add GPU work and softness; no performance improvement follows from stacking stages. The existing TAA path operates at 1:1 size, rather than reducing scene resolution through temporal upscaling. [MetalFX](https://developer.apple.com/documentation/metalfx) offers spatial and temporal approaches; [FSR 1](https://gpuopen.com/fidelityfx-superresolution/) is another spatial approach. No additional upscaler was integrated.

[NX Optimizer's official README](https://github.com/MaxLastBreath/nx-optimizer/blob/main/README.md) describes dynamic FPS, draw-distance and graphics controls, but its listed TOTK support ends at 1.4.2. That does not establish compatibility with this native 1.4.3 port. No external mod or source was imported.

## Measure before changing rendering

Use Instruments Metal System Trace / Game Performance, Time Profiler, Xcode GPU capture and Metal HUD first, as required by [CONTRIBUTING.md](../CONTRIBUTING.md#picture-quality-and-performance). GPU captures should be outside timed sessions. Existing repository diagnostics include:

- `DM_NVN_TSV=<writable path>` and `DM_NVN_TSV_CALLS=0`: existing per-frame timing-only TSV in `hle_nvn.c`; avoids the much larger call-count rows, but still has collection and file-I/O overhead.
- `DM_SLOWFRAME=1` and `TOTK_LONGFRAME_DETAIL=1`: long-frame attribution with shader/pipeline creation, upload and optional draw/pass/variant details in `hle_nvn.c`.
- `DM_NVN_PROF=1`: NVN recording/submission timing wrappers in `hle_nvn.c`; use deliberately because instrumentation changes CPU work.
- `TOTK_PASS_GPU=<first>[:<count>[:<stride>]]` and `TOTK_PASS_GPU_FILE`: bounded encoder GPU timestamps in `nvn_mtl.m`.
- The existing 300-frame timing/presentation summaries in `hle_nvn.c:tsummary` include footprint and thermal hook readings. Unknown hook values are not a nominal thermal result. Capture synchronized resident/footprint and thermal evidence with available device tools.

`scripts/mac_v143_soak.py` explicitly refuses per-frame TSV for long Mac sessions. Respect that operational limit; a timing-only trace still needs a bounded capture and reliable private readback. The earlier iPad TSV readback was partial. Do not extend it into a claimed 30-minute result. No measured bottleneck is established by this checkout. The optional graphics controls above do not establish a renderer optimization or close the sustained-performance gate.

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

The signed display build now includes the existing Vert+ camera stubs and a separately generated 4:3 UI overlay. `build_ipa.py` generates the overlay from the original verified v143 RomFS with `make_romfs_patches.py --aspect 1440x1080`; its manifest pins overlay and original bytes. The app selects it only for an exact 4:3 requested canvas and `TOTKIOSFourThreeLayoutVersion = 1`. Missing profiles and unsupported aspects fall back to 16:9. The 720-high and 1080-high modes share the same proportional layout. The 16:9 mode retains the generic overlay and a zero Vert+ factor.

At 4:3, Vert+ multiplies the half-angle tangent by 4/3 before the existing camera code derives its projection values. This preserves the 16:9 horizontal view and expands the vertical view. Device startup validates the signed branch, displaced load, surrounding setFovy pattern and complete stub body; it writes only the reserved data page. Portable tests cover corrupted stubs/branches/patterns and read-only device text. Actual original-archive generation passed for 328 layout members; arm64 object compilation passed. Physical camera, HUD/title/menu, world-marker, inventory, lighting/effect and cutscene behavior remain unverified. Prerendered movies have no dedicated aspect-fit path.

Select and warm the three real scenes in the baseline protocol, agree numerical stability thresholds, and capture a continuous physical-device session of at least 30 minutes. Report each scene, full session, first five minutes and last five minutes using synchronized tools, with overhead and gaps disclosed. Confirm render targets at 1080 high and actual display aspect, correct world/UI projection, image quality, native rendered versus presented/interpolated frames, memory and thermal transitions. Pair any later iOS-only quality tradeoff with before/after screenshots and measured work saved, added cost and whole-frame change. Mac picture quality must remain unchanged.

The original cloud phase covered only the offline analyzer and repository tests. The later local Apple build evidence is recorded above; physical graphics and sustained gameplay checks remain separate gates.
