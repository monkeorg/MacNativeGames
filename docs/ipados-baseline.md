# TOTK iPad baseline and benchmark protocol

Issue: [Establish TOTK 1.4.3 iPad baseline and repeatable benchmark](https://github.com/monkeorg/MacNativeGames/issues/1).

Evidence review date: 2026-10-23. This record establishes a startup baseline. It does not establish sustained gameplay performance.

## Baseline identity and evidence

| Item | Recorded value | Evidence and limit |
|---|---|---|
| Source baseline | `a988b5ee95645c083b3330815ed764824a55e31f` | Commit exists locally. The runtime log does not attest the installed binary's source revision. |
| Game | TOTK 1.4.3 | Private runtime log, line 12. |
| Target device | Physical iPad Pro 13-inch (M4), product type `iPad16,6` | Private device report, `result.properties.hardware`. |
| OS | iPadOS 27.0.1, build `24A446` | Private device report, `result.properties.software`. |
| Current game image | 1280×720 | Runtime `WindowCrop 0,0 1280x720`, line 5861. Render-target dimensions still need GPU capture confirmation. |
| Current drawable | 1280×960 | Runtime `view drawable 1280x960`, line 1. |
| Resolution patch | Game's own resolution; no build-time resolution patch | Runtime log, line 8. |
| Shader state | Existing bundled shaders and pipeline archives; startup warm-up enabled | Runtime log, lines 6614–6623. Full scene warm-up completion is unverified. |
| Save backup | 22 regular files, 9,562,585 bytes; no empty files or symbolic links | Local filesystem inspection. Physical API export/import/restore preserves all 22 file hashes. Gameplay save load remains unverified. |

The current 720-high game image and 960-high drawable are separate measurements. Neither establishes correct full-aspect projection or the roadmap's 1080-high target.

The following evidence stays private under `/Users/philipp/Downloads/iPad-Feather-TOTK/`:

- `Logs/baseline-device.log`: startup and graphics diagnostics.
- `Reports/milestone-1-device.json`: successful `devicectl device info details` result.
- `device-backups/milestone-1/save/`: save backup inspected without publication.

Do not commit these files, game content, saves, keys, account identifiers, device identifiers, signing material, or private manifests. Publish only sanitized results.

## Observed startup and cache state

Times below are elapsed values from the runtime's boot log. They are not an independently measured tap-to-gameplay duration.

| Event | Elapsed time | Private log reference |
|---|---|---|
| Runtime start | 0.226 s | Line 13 |
| Game-data verification record valid | 0.253 s | Line 26 |
| Metal device preparation | 0.270 s | Line 60 |
| Shader-cache preparation | 1.214 s | Line 5865 |
| Shader cache ready; warm-up starts | 1.571 s | Line 6615 |
| First presented frame | 3.041 s | Line 6632 |

The log records 33,264 bundled shaders with zero files imported. It records 2,183 pipeline archive files, totaling 129.6 MB.

Startup used one precompiled shader library and compiled zero libraries at that stage. Critical pipelines required a 39 ms wait.

At that point, 24 shaders and 26 render pipelines were available. Other warm-up work continued in the background.

These facts establish cache reuse at startup. They do not establish a fully warm gameplay scene or exclude later shader stalls.

The log records MetalFX spatial upscaling and temporal anti-aliasing as off. Asynchronous pipeline creation is on.

The log also describes a 120 Hz presentation cadence and an uncapped clock limit. Those settings are not measurements of native gameplay FPS.

## Verification boundary

| Stage | Status | Remaining evidence |
|---|---|---|
| Source revision | Verified commit exists | Attest source revision and build options for the next tested app. |
| Launcher build | Physical-device build succeeded for `6d896fc` | Cached Xcode build; dedicated development signature verified. This is a candidate, not the original baseline binary. |
| Installation | Candidate installed under the existing app identifier | Physical launch succeeds; all 22 original save-profile hashes match after installation. |
| Runtime launch | Log establishes startup and first presentation | Repeat with the tested build and retain its sanitized log. |
| Save backup | Physical production API backup, export, import, and restore succeeded | All 22 profile hashes match afterward. External Files picker transfer and gameplay save load require separate verification. |
| Gameplay and visual correctness | Unverified | Record the actual save, scene, controls, and observed image correctness privately. |
| Gameplay frame times and FPS | Unverified | Capture rendered-frame intervals during a sustained session. |
| Memory and thermal behavior | Unverified | Capture a synchronized 30-minute trace and report tool availability. |

There is no robust gameplay frame-time series or sustained 30-minute result in the reviewed log. A title-screen counter or presentation overlay cannot close this gap.

## Repeatable manual benchmark

Follow [CONTRIBUTING.md](../CONTRIBUTING.md#picture-quality-and-performance) and the [iPad roadmap](ipados-roadmap.md#acceptance).

### Prepare the test record

1. Record the exact source commit, game version, build options, and installation result for the tested app.
2. Record the device model, OS build, orientation, display refresh setting, render size, drawable size, and graphics settings.
3. Confirm the render-target size with Xcode GPU frame capture before the timed session.
4. Record interpolation state separately from the game's rendered-frame rate and presentation rate.
5. Record battery level, charger state, Low Power Mode, room temperature, case use, and initial thermal state.
6. Keep these conditions constant between baseline and candidate runs.
7. Confirm a private save backup before any test that can change the save.

Scene selection remains pending access to the actual save and physical hardware. Do not substitute invented save locations or routes.

Choose three available scenes: a quiet fixed view, a repeatable traversal, and a busy view with repeatable actions. Record the exact choices privately.

For each scene, record the save slot, load point, camera direction, route, controls, time, weather, and reset steps. Use existing save state.

Do not alter player or world state to obtain a benchmark result. Report unavoidable scene variation with the result.

### Establish cache state

1. Preserve the existing shader caches for the primary warm-cache benchmark.
2. Visit all three scenes once and complete their routes before measurement.
3. Record cache reuse and compilation evidence from existing diagnostics.
4. Label incomplete warm-up explicitly if compilation continues or the tools cannot establish completion.
5. Record startup time separately from gameplay measurements.

A fresh process with existing caches is not a cold-cache run. Label it as a warm-cache relaunch.

If a cold-cache comparison becomes necessary, preserve the cache first and use a separate authorized test procedure. Do not delete the baseline cache.

### Capture a sustained session

1. Use Instruments Metal System Trace or Game Performance for frame pacing and GPU activity where the target supports them.
2. Use Time Profiler to identify CPU work and the available Instruments memory view to record process memory.
3. Use the Metal HUD (`MTL_HUD_ENABLED=1`) as supporting evidence where available.
4. Use existing repository diagnostics before adding instrumentation.
5. Capture thermal-state transitions with available device profiling tools and record their timestamps.
6. Mark unavailable measurements as unverified and name the missing tool or access.
7. Start the timed capture after scene preparation and record a continuous session of at least 30 minutes.
8. Run each chosen scene for ten minutes in the same fixed order.
9. Retain scene-transition intervals in the trace and label them separately in scene summaries.
10. Repeat the complete session for each tested configuration under the same initial conditions.

Record profiler overhead. Separate GPU frame captures from the timed session because capture can disturb frame times.

Count newly rendered game frames separately from presented or interpolated frames. If the trace cannot distinguish them, native FPS remains unverified.

Do not infer process memory from virtual allocation log totals. Record resident or footprint measurements and state which metric the tool supplies.

### Report and compare

Report one row per scene and one row for the full session:

| Run / scene | Duration | Rendered FPS | Frame time p50 / p95 / p99 | Longest frame | Frames >16.67 / >33.33 ms | Memory start / peak / end | Thermal transitions |
|---|---|---|---|---|---|---|---|
| Pending physical-device measurement | — | Unverified | Unverified | Unverified | Unverified | Unverified | Unverified |

State the frame-time definition, sample count, dropped samples, trace gaps, and diagnostic settings. Report first-five-minute and last-five-minute results to expose sustained degradation.

Record visual defects, crashes, save-load failures, and input failures beside the performance result. Keep picture correctness ahead of speed.

Agree numerical stability thresholds before any claim of stable native 60 FPS. The 16.67 ms budget alone does not define acceptable percentile or thermal behavior.

Issue #1 remains incomplete until the selected scenes, physical-device gameplay, sustained traces, memory, and thermal results are recorded.
