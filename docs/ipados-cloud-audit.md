# iPad cloud continuation — 2026-10-24

Started from `feat/ipad-live-menu` at `3d7d6e888844c4514ce6126a0faddf33c1f3409c`. Read CONTRIBUTING.md, the roadmap, launcher and baseline documents, and issues #1–#6. No AGENTS.md exists in the tracked checkout or its parent directories. Four gpt-6.1-sol workers at Medium reasoning used separate worktrees with explicit file ownership. The existing #10 → #11 → #12 → #13 → #14 dependencies remain intact; follow-up work adds draft PRs above #14.

## Changes and evidence

| Commit | Change | Verification boundary |
|---|---|---|
| `b10f4b8` | Reject save directory changes detected by post-traversal mtime/ctime/link-count checks. Add deterministic optional-file removal, provider read-denial import rollback and failed-export cleanup probes. | All 16 Foundation save/preferences tests are unavailable on Linux. Source reviewed; Apple compilation and execution pending. Metadata checks are not a filesystem-wide snapshot against arbitrary concurrent writers. |
| `03c827e` | Validate the preserved/continuation instructions in the signed output patch. Disable iOS runtime output/aspect keyboard toggles so canvas and projection stay paired until restart. | Portable production signed-text probe passes with read-only text, corruption refusals, 1440×1080 render/canvas values and a 4:3 projection slot. Mac/export and actual ARM64 stub execution need Apple tools/hardware. |
| `1ff9735` | Clear virtual touch tracking on menu disable, focus loss and view removal; ignore late canceled moves and indirect pointer touches. Gate mouse capture/input on explicit app, scene, key-window and text-entry state plus actual pointer lock. Make menu close idempotent. | Portable production capture-policy sequence passes. UIKit compilation and touch/mouse/controller behavior remain unverified physically. |
| `5dbf57a` | Inventory existing Mac graphics controls and add an offline analyzer for existing TSV diagnostics, including percentiles, defined 1% low cadence, timestamp spans and sample-integrity counts. | Seven synthetic analyzer tests pass, including plain/gzip CLI equivalence. No renderer defaults changed and no runtime bottleneck or FPS gain is claimed. |

Save account identity remains outside the replaced directory. Transfer serialization, pre-Play sealing, backups, staging and atomic replacement are retained. The new provider probes simulate filesystem read denial; actual security-scoped cloud-provider coordination still needs a device. No game content, keys, saves, signing material or private identifiers were downloaded or committed.

## Acceptance audit

| Issue | What the source/cloud run establishes | What remains open |
|---|---|---|
| #1 baseline | Existing protocol separates startup/cache reuse, render versus drawable size, and gameplay versus presentation. New trace tool labels its metrics and missing data. | Real repeatable scene choices, synchronized memory/thermal evidence, native frame attribution and the sustained 30-minute run. |
| #2 launcher | Deferred startup and duplicate-start guards remain. Preferences validate stored choices; signed capability gates display controls. Input fixes improve interruption behavior. | Current glass layout, accessibility/controller navigation, relaunch/lifecycle/languages and actual settings behavior on the new build. |
| #3 saves | Existing descriptor-based bounded copying, account separation, synchronized sealing and atomic publication remain. New mutation/refusal regressions are prepared. | Foundation build/probes and actual Files/provider failure behavior, followed by current-build save-load regression. Earlier physical results remain historical evidence. |
| #4 display | Signed instruction checks and 4:3 data/projection contracts pass synthetic portable probes; iOS live canvas changes are blocked. | Actual GPU render dimensions, correct camera/HUD/map/cutscene/effects and known marker/UI limitations. |
| #5 input | Main-thread adapter uses GCMouse; capture policy requires focus and granted lock. Explicit cancellation prevents old touches being republished. | Real mouse direction/sensitivity/buttons and controller models. Persistent sensitivity, inversion, button remapping, extra mouse buttons and full Mac control parity are not delivered. |
| #6 graphics | Source inventory and bounded existing-trace analysis are available; GPU durations and present-call cadence are labeled separately. | Apple builds/visual checks before exposing more settings; actual measured bottlenecks; matched-scene 1080-high performance, memory, thermal data and agreed stability thresholds. |

Mac control inventory: `runtime/frontend.m` documents keys 1 overlay, 2 interpolation, 3 picture, 4 aspect, 5 temporal AA, 6 controller type and 7 mouse. The iPad UIKit menu currently wires Escape and live HUD settings; desktop NSEvent shortcuts are not an iPad feature contract. Shared `controller_map.h` supports more bindings and hold/tap/toggle/aim modes than the current iPad UI exposes. The iPad mouse adapter handles left/right/middle buttons. Shared mouse-look environment options are not persistent in-app controls. The iOS text-entry frontend currently cancels game text entry; keyboard release handling does not implement that feature. Original Switch Pro support does not establish Switch 2 Pro support.

## Exact cloud checks

Environment: Linux x86_64, CPython 3.14.8, repository-pinned `games/totk/requirements.txt`, system C compiler. No Apple SDK, xcrun, connected iPad, local Xcode caches, private game inputs, saves or signing credentials are present.

- Full command `python -m unittest discover -s tests`: **329 tests run, 0 assertion failures, 15 errors, 54 skipped**. The same platform errors were present at the starting checkpoint (317 run, 15 errors, 51 skipped under Python 3.14). Missing Darwin `clonefile`, `st_birthtime`, and an import-time `xcrun` invocation prevent a green unfiltered Linux result. Error events include subtest cascades; they are not 15 independent product regressions.
- `python tests/run_portable.py`: **317 tests run, 263 passed, 54 skipped, 0 failures/errors**. The runner prints each exclusion: 11 Darwin-only packaging tests plus the 3 real codesign/Xcode tests in `test_data_bundle`, whose import invokes xcrun. Existing native-test skips remain visible. This subset does not replace full macOS CI.
- Focused display suite: **4 run, 3 passed, 1 macOS exporter skip**. Aspect suite: **1 passed**, with Apple ARM64 execution unavailable. Mouse capture policy: **1 passed**. Frame trace analyzer: **7 passed**. Foundation saves/preferences: **16 skipped**.
- Undefined-behavior sanitizer probes: **27 RomFS path cases passed** and **controller layout cases passed** using the repository CI flags. Integrated `git diff --check` passed.

Apple-only app builds, signing, installation, launch, visual checks, save transfers and gameplay checks are **unavailable in this run**. No simulator was set up; no merge or release was performed.

## Prior checkpoint and next local run

The user's checkpoint records 319 passing tests and a cached physical-iPad build of `3d7d6e8`. Installation succeeded, and all 35 save-directory files matched their immediate pre-install SHA256 snapshot. The iPad was locked when new-build checks were attempted; **no new functional checks executed**, so this establishes neither a functional failure nor acceptance.

Earlier implementation `2dc8c34` passed physical save import/export/restore, preference persistence, Play, an existing-save load and native HUD verification. Keep those results attached to that revision. They do not validate the current cloud changes or experimental display/input features.

Use the short [physical acceptance checklist](ipados-acceptance.md) with the existing private local build/install procedure, previous signed app and immediate save snapshots. Stable native 60 FPS and hardware-dependent issue acceptance remain unverified. Save-value editing and BOTW remain outside this work.
