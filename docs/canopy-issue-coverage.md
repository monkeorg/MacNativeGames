# Canopy: coverage of all current issues and ideas

Read-only issue reconciliation: 2026-10-25. The 18 issue bodies below were read
from GitHub individually; each returned explicit `state: open` at this snapshot.
This records those fetches, not a live-state guarantee. This ledger does not close issues or rewrite their
acceptance boxes. The latest user instruction makes SaveEditor #7 active despite
older “later/parked” text in #7/#9. BOTW #8 and mods #35 remain parked. Source,
review, Apple compilation, synthetic execution, private-input validation and
physical acceptance are different evidence levels.

The current /goal runs no new tests or probes. Counts here are historical
recorded results. See [state](../.goal-task/content-free-launcher/state.md) for
exact revisions, jobs, source ownership and integration status, and
[the backlog](../.goal-task/content-free-launcher/todo.md) for D0–D14 work items.
No complete-product, arbitrary-game compatibility or physical gameplay claim is
made. A source feature or fixture is not a checked product acceptance box.

Current source is [#100](https://github.com/monkeorg/MacNativeGames/pull/100),
`feat/canopy-shader-removal-recovery` at
`62dd868c5e66d830ca1f5973462c4725a56aa759`. All label/editor/pack/removal
cohorts are published. #88–#100 are source-reviewed, `[skip ci]`, unbuilt/untested.
#99 corrects the preflight source implicated by later #85 red CI; #100 supplies
recorded shader-identity removal recovery. Both are UNRUN, not verified fixes.
Goal remains ACTIVE. The compiler assessments identified two bounded source slices.
Native owns the frozen two-function query depth patch 0005 and its SHA/coverage/docs;
execution and root reviewed it. Execution owns the subsequent five PHI-query loop
checks only after 0005 is committed. No compiler tests/builds or runtime enablement
are authorized by this source work. There is no other demonstrated broken
supported flow after the reviewed source corrections, but compiler debt remains
source work, not only a hardware gate. Runtime translation remains disabled and
product/Apple/private/device/signing acceptance is separate.

## Original iPad track: #1–#9

| Issue / scope | Source and recorded evidence | Remaining source work | Exact external acceptance / status |
|---|---|---|---|
| [#1 Baseline and repeatable benchmark](https://github.com/monkeorg/MacNativeGames/issues/1) | [Baseline](ipados-baseline.md) preserves earlier save backup, exact candidate/device/OS, image versus drawable and cache state. The standard-library frame-trace analyzer has recorded synthetic coverage; its cadence is not independently attributed native FPS. | Retain reproducible trace definitions, missing-data reporting and current-build provenance; connect measured bottlenecks to changes rather than speculate. | Select actual quiet/traversal/busy scenes from existing saves, warm them, then capture matched continuous30-minute frame/footprint/thermal traces with profiler overhead and gaps. No sustained result exists. **Open physical acceptance.** |
| [#2 Persistent pre-launch menu](https://github.com/monkeorg/MacNativeGames/issues/2) | Original launcher/settings defer and guard Play; validation, accessibility labels, shared settings overlay, live FPS/TAA/touch and restart-required fields exist. Earlier installed candidates have explicitly bounded physical menu/HUD/save-load evidence. | Preserve single-start and pre-Play authority. Committed System-language/reset and current-presentation follow-ups need their own Apple results; no invented self-restart. | Current-build landscape/large-text/VoiceOver/controller navigation, all supported languages/System, relaunch, background/focus and settings behavior. Historical test06f exercised choices, not achieved FPS or TAA quality. **Open.** |
| [#3 Safe save transfers](https://github.com/monkeorg/MacNativeGames/issues/3) | Original and Canopy stores implement bounded copy, backup, atomic/journal publication, account separation and sealing. #69 fixes original-iPad descriptor flush failures/lifetimes while preserving standalone Mac. Prior original-app Files round trips and save load belong to recorded revisions. | Finish current retirement/profile/editor integration without weakening format, seal or recovery authority. Treat runtime payload flush separately from complete crash transactions. | Current-build export/import/restore and existing-save load with immediate local account/save hashes; actual provider cancellation, eviction, read/permission failures, low storage and recovery. No cloud-provider acceptance inferred from fault fixtures. **Open.** |
| [#4 Resolution and camera aspect](https://github.com/monkeorg/MacNativeGames/issues/4) | Checked v143 display patches/profile and generated overlays support requested720/1080-high; exact full4:3 means1440×1080. Experimental defaults and unsupported-ratio fallback remain explicit. New presentation-only layout source is published in #78. | Complete current layout/overlay caller integration and capability reporting. A presentation resize must not silently change scene/projection or restore input. Extend game patches only with verified original sites. | GPU-capture actual scene targets separately from drawable; inspect projection, HUD/map/menu, telescope/world markers, cutscenes and effects at each supported mode. No stable60 or complete visual result. **Open.** |
| [#5 Controls and mouse](https://github.com/monkeorg/MacNativeGames/issues/5) | Shared mapping backend, persistent sensitivity/inversion/default/None/custom bindings, GameController relative mouse/auxiliary buttons, pointer-lock admission and focus/disconnect cleanup exist. #71 compiles original iOS mouse/C fixtures; #75 has recorded Foundation Controls validation. | Continue analog VoiceOver/touch accessibility acceptance and actual caller/epoch/refocus reconciliation; final source in #82 is UNTESTED. Compile-only iOS regression objects do not execute their assertions. | Real identified mouse/controller models, direction/endpoints/extra buttons, quick taps, disconnect/reconnect, lock denial/regain, text/menu/scene focus loss and no stuck input. Switch Pro is not Switch2 Pro evidence. **Open.** |
| [#6 Graphics settings and stable60](https://github.com/monkeorg/MacNativeGames/issues/6) | [Graphics inventory](ipados-graphics.md), checked display, real native frame ceilings/TAA request path and existing diagnostics are present. Physical selection/request evidence does not establish quality/cost or throughput. | Reconcile stale inventory with current source; complete reviewed settings application and measured optimizations only. Preserve Mac image quality and avoid exposing unaccepted experimental presets. | Matched baseline/1440×1080 scenes; native versus generated/presented frames; median/p95/p99/1% low, stalls, memory/thermal and visual comparisons. Agree numerical stability thresholds before “stable60.” **Open.** |
| [#7 Optional save-value editor](https://github.com/monkeorg/MacNativeGames/issues/7) | **ACTIVE by latest instruction.** Original `mng_totk_save` candidate parser uses the pinned MIT reference-family tuple and discovered scalar tag; it changes only four wallet bytes in a disjoint copy, guesses no checksum. Opaque instance/profile/slot snapshot/CAS transaction requires constructor-only file and whole-stage validators. Old constructors provide no edit validator. #77 publishes the core; native candidate-only Canopy UI is source-reviewed and committed; original Track-A candidate UI is committed in #85 on a new dedicated serial queue; #97 splits opaque preview property declarations for clarity, not a reproduced compiler error, and has no new build evidence. | Follow through the committed Canopy slot→private preview→old/new wallet→unverified candidate share; follow through #85 Track-A reuse on its NEW dedicated serial queue, with busy/cancel/background guards, no logged save values and unchanged save authority. Its separate existing web editor remains available; no Apply was added. **Production Apply stays disabled**, not all editor work. | Exact1.4.3 discriminator, integrity/dependent-field evidence and contract-derived fixtures are absent. A physical edited-save load/backup restoration is required before default enablement. Reference UI policy0–999999 is not a certified game limit. Candidate share is not a validated Canopy save export/import or compatibility result. |
| [#8 Separate BOTW assessment](https://github.com/monkeorg/MacNativeGames/issues/8) | [Assessment](ipados-botw-assessment.md) records versions, shared-runtime possibilities and platform/build/identity/save blockers. | **PARKED.** Preserve assessment and generic extensible configuration; do not assign a BOTW implementation or invent an ABI/backend. | A later explicit scope, exact original version/contracts, Apple builds and independent physical acceptance would be needed. Future trusted-profile configuration is not a BOTW capability promise. Not a current finish gate. |
| [#9 iPad adaptation roadmap](https://github.com/monkeorg/MacNativeGames/issues/9) | [Roadmap](ipados-roadmap.md), [status](ipados-roadmap-status.md), original draft chain#10–#14 and subsequent source follow-ups remain attributable. | Reconcile current source/evidence and current user scope. Older “keep save-value editing parked” text is superseded for #7; #8 stays parked. Preserve the working TOTK app/identity and separate Canopy work. | Each #1–#7 acceptance remains independently measurable; the roadmap is not accepted by one successful menu/save load. Original and Canopy physical results cannot be substituted for one another. **Open umbrella.** |

## Public launcher track: #34–#41

| Issue / scope | Source and recorded evidence | Remaining source work | Exact external acceptance / status |
|---|---|---|---|
| [#34 Full content-free native launcher](https://github.com/monkeorg/MacNativeGames/issues/34) | The D0–D14 source matrix now includes real supported preparation, generations, library/settings/overlay, saves, controls, update/add-on consumers, cache identity and diagnostics. Public unsigned Apple builds have recorded CI results. This is no longer only an inspector. | Finish active cohort review/integration, real callers/migrations/history/accounting, accessibility and native preparation/execution boundaries. Keep source/profile evidence explicit and use all independent workstreams despite external gates. | Clean signed public artifact plus actual user-owned import-to-gameplay, supported multiplayer, recovery/update and physical Apple acceptance are still required. A private embedded app or fixture does not complete #34. **Active umbrella; product incomplete.** |
| [#35 Mod manager](https://github.com/monkeorg/MacNativeGames/issues/35) | Explicit backlog requirements distinguish data packs/executable changes, compatibility/conflicts, bounded staging and recovery. | **PARKED by user.** No implementation worker, dependency, duplicated4:3 toggle or current finish gate. | Requires a later user instruction and a proven backend before mod activation/physical recovery can be accepted. Do not silently expand scope. |
| [#36 Bounded native import](https://github.com/monkeorg/MacNativeGames/issues/36) | Portable PFS0/HFS0/NSP/XCI inventory, supported NCA3 crypto/integrity, real ExeFS/RomFS outputs, update composition and NCA/plaintext-folder routes connect to CLI/Foundation jobs and security-scoped input. Synthetic encrypted fixtures use invented keys. | Broaden only grounded subformats, refusal/progress/cancellation and current provider/caller integration; preserve whole-source versus canonical member-inventory provenance and no invalid-highest-version fallback. | Real user-owned supported inputs, large-file/device quotas, cloud-provider loss/cancel and private format coverage. Decryption/extraction is not authenticity, native permission or gameplay. **Supported source subset exists; acceptance open.** |
| [#37 Library/settings/saves/accessibility](https://github.com/monkeorg/MacNativeGames/issues/37) | Actual prepared multi-title catalog, jobs/Resume/storage/add-on UI, per-title settings/full overlay and title/profile SaveStores exist. Logical profile selection and prior native integration have recorded Apple compilation/fixture evidence at specific commits. | Follow through the committed #86 registry and #87 actual profile callers/onboarding (two source reviews; provenance/default/onboarding findings fixed; no tests/builds, `[skip ci]`) and the committed Track-A editor; label-only repair and explicit UI are committed #94/#96, preserving IDs/current selection/other rows through opaque CAS/quarantine, and #93 preparation VoiceOver phase/completion announcements are committed; reconcile migrations/build-mode-aware copy and integration of the committed System-language, presentation and analog accessibility source. Public provider absence and private host availability are different from compatibility/playability. | Current physical onboarding, touch/controller/VoiceOver/large-text navigation, lifecycle/provider/save/profile isolation, private exact-title settings and gameplay. **Source integration active; product acceptance open.** |
| [#38 Execution and Apple signing](https://github.com/monkeorg/MacNativeGames/issues/38) | Public `CanopyRuntime` provider isNULL; generic module loader explicitly refuses external modules on iOS. Mac original call-window fixture executed20,000 calls historically, using a different permission path. Private builder links embedded exact-profile code/fonts/shader seed and requires a Mac exporter. New shared production-loader source/fixture in #81 removes the separate Apple mapper and links actual `gate.S`; root/native source review is complete, new Apple execution remains unperformed. | Follow through shared-core build inventories and actual Apple harness results; native AOT rewrite/export on iPad, execution-profile/provenance contracts, recoverable loader failures and full ownership/TLS/finalizer/service teardown remain source work. No new JIT/emulator/streaming backend is authorized. | First run a signed original embedded fixture on physical hardware without debugger; then prove permitted execution of an external original fixture absent from the public host’s signed executable under the intended distribution mode. Finally prove exact-title private import/setup/gameplay. A Mac-assisted private signed app remains intermediate and does not satisfy standalone on-iPad preparation/execution. **Primary product gate open; independent coding continues.** |
| [#39 Public provenance/private recovery](https://github.com/monkeorg/MacNativeGames/issues/39) | Reviewed inventory checker compares exact path/size/hash/provenance and refuses unsupported Mach-O shapes/guest segments. V1–V5 private generations use full verification, atomic current/previous, leases, cancel/resume and rollback. Same-verification asset facts and real Mac COW/chunk/growth/shrink evidence exist; clone metrics are logical I/O. | Shader-identity removal recovery is committed #100, root/artifact source-reviewed and UNRUN. Follow up committed native retirement intent/recovery #83, absence-versus-corruption refusal, ownership/pin protection, migrations/history and storage accounting; later #85 CI exposes a generation-retirement canonical-path failure, with committed #99 nonmutating preflight correction (root/runtime source reviewed, UNRUN). No earlier store counts validate the correction. Integrate all new source/header inventories. | Independently review final signed public artifact/build inputs and preserve private saves/generations across actual app updates/provider/storage failures. Neither absence of known extensions nor an inventory generated from the candidate certifies content purity. **Source/recovery active; final artifact acceptance open.** |
| [#40 Mario Kart multiplayer/full Apple matrix](https://github.com/monkeorg/MacNativeGames/issues/40) | Independent controller seats, input mapping and known FullKey guest-service routing have original native fixtures. TOTK’s current host is single-player. | Develop grounded per-game services/profile integration when exact contracts are available; keep four-seat frontend infrastructure separate from a working title. Do not invent title/version/module/patch addresses or missing service behavior. | Exact Mario Kart originals/ABI/profile/graphics/service evidence and a real local multiplayer session, disconnect/reassign, saves, lifecycle, recovery/update/performance and content-free public artifact checks. **No Mario Kart gameplay claim.** |
| [#41 Private shaders/efficient updates](https://github.com/monkeorg/MacNativeGames/issues/41) | Seed/map/content/recipe/device identity, private cache leases, in-place reads and native compiler source/offline build recipe exist. Checked managed/Cross cooperative budgets have actual original Cross parity/quota/cancel fixtures; new dependency-depth patch is published in #80. Verified reuse and CLI/Foundation callers plus #76 selected-title update UI are connected. #88/#89 shader-list/warm/archive/texture ports, #92 split-list admission and #95/#98 signed-metadata-bound original pack producer/reader are source-reviewed/committed with no new execution evidence. | Shader-identity removal recovery is committed #100, UNRUN; assess raw-loop normal-step and recursion/noexcept/ownership source next, with no new patch yet. Continue remaining compiler coverage (396 checkpoints; 123 raw sites = 10 fixed + 113 input-dependent/unproven), recursion/noexcept/STL/framework growth and actual managed/static/iOS build/link/parity gates; native on-device shader preparation and migrations/accounting/caller integration remain active. Runtime translator stays off. | Real private preparation/Metal compilation, missing-variant behavior, measured cold/warm preparation and transfer/storage, actual interrupted-update/previous-generation preservation and graphics/gameplay acceptance. Quotas are not a hard process sandbox; clone counters are not physical space savings. **Active.** |

## Experimental restart: #55

[#55](https://github.com/monkeorg/MacNativeGames/issues/55) is active. The user
already accepts unsaved-progress loss and crash risk; do not ask for that risk
permission again or impose guaranteed save completion/full safe teardown as a
prerequisite for an experimental game-owned reload.

The committed `mng_restart` component in #84 is a confirmation/cancellation/single-flight
control helper against a mandatory real dispatcher interface. Its six recorded
native fixture cases exercise authored fixture behavior, not a TOTK restart.
No actual restart mechanism or shared-overlay red button/two confirmation dialogs
is wired. Imported metadata or a no-op/default provider cannot advertise support.

Required source/UI behavior remains: red Restart game beside Keep playing;
Cancel/red Continue with loss warning; Cancel/red Restart game final decision;
zero engine calls on either cancel; no overlap/stale callback dispatch; observed
real completion/failure. Submission, a lifecycle callback, SDK return or a joined
worker is not completion. A request that might still complete must not be retried
as a second overlapping request merely because observation timed out.

The exact missing engine contract is the request selecting Title/load target,
its arguments/transition ownership and valid guest-thread context. The issue
records private lifecycle research but supplies no callable public contract.
Next local step: observe one normal original return-to-title transition and
trace target selection. Never invoke an unidentified factory, all-data reset or
lifecycle callback alone. A fallback full-session restart has separate complete
ownership/reset work. Loader/main twice, app exit/relaunch and replayed menu
inputs are not implementations. Pending graphics startup settings still require
full app restart until an actual coordinated apply path exists. UIKit/process
survival and actual title/reload outcomes need exact-device evidence.

## Evidence and integration checkpoints

Latest checked green revision: #77
`976d8561ce9839dcf3da86221fa7c1c321bd87fd` (root read existing logs only).
Canopy40222639497/Mac121257329603: **524 run,517 passed,7 skipped** in71.610s;
unsigned SDK26.2 app and original32-object matrix green.
Source40222639501/job121257329585: **940 run,931 passed,9 skipped** in231.342s.
This validates that revision only, not #78 or later source/device behavior.

Later red checkpoint, separately: #85
`0b8081952d2ef5e0ff4600a79b44ac857d7bd27f`, Source40223242649/
job121259156586: **971 run,961 passed,9 skipped,1 error** in140.111s.
The hardlink was preserved, but its canonical generation path disappeared because
retirement renamed the generation before full shape preflight. The nonmutating preflight source correction is committed in #99. No fix
test/rerun has occurred. This later failure is not superseded by the earlier green run.

- At `398ced32b6f42c2cdc1c1f040490abb7d81f30ce`, recorded Canopy Mac485 run/478
  pass/7 skip; Source889 run/881 pass/8 skip; unsigned SDK26.2 app/archive. Counts
  overlap; actual Mac clone/worker fixtures are not iPad gameplay.
- At `19e972f5bbc79ba35edff5aef429cae5b44ece03`, recorded Canopy503 run/496
  pass/7 skip and Source911 run/902 pass/9 skip. Public app and original32-object
  matrix passed. The preceding profile compiler warning was fixed.
- At `4563064cc76f6253f84ffae1e321539e9b44ec43`, recorded Source922 run/913
  pass/9 skip, including actual original Controls Foundation and loader syntax
  cases with explicitly nonexecutable metadata. This is not the new native core
  fixture, a private SDK, device execution or gameplay.
- At `09785cdb1fd53e520c52286b61e5cb8dfbe6a859`, root read existing logs:
  Canopy40218521737/Mac job121244801250:509 run/502 pass/7 skip/84.665s, unsignedSDK26.2
  app plus original32-object matrix; Source40218521806/job121244801597:925 run/916
  pass/9 skip/169.779s. No new test/probe was run for this documentation task.
- Draft#77 publishes the candidate-save core and has the exact green evidence
  above. Drafts#78–#80 publish presentation layout, System-language and shader
  dependency-depth source; #77 results do not validate these later revisions.
- Drafts#81–#84 publish shared-loader source, accessible analog actions,
  retirement recovery and restart control respectively. New Apple results are
  still separate. Later #85 CI separately exposes the retirement regression below; touch has no newly credited acceptance.
- Draft#85 publishes original Track-A candidate UI at
  `0b8081952d2ef5e0ff4600a79b44ac857d7bd27f`, branch `feat/ipad-save-candidates`.
  Root/runtime source review includes the refreshed-directory collision fix;
  original project/source matrix include the shared C core. No tests or builds
  ran at #85 publication; its later Source CI red result is recorded above.
- Draft#86 `fb26d02e5e7d1fcca2688baaafd3c3321a467712` and #87
  `7f13c9abbf6d86f6dab9b0b7d58ba599c77f70d5` publish the trusted registry and
  actual callers. Two source reviews fixed provenance/default/onboarding findings;
  no tests/builds, `[skip ci]`.
- [#88](https://github.com/monkeorg/MacNativeGames/pull/88) `606dc1e40f43c642a4958ae5df3d7c2212c44068`: TOTK shader metadata and normalized pipeline keys; BOTW list untouched.
- [#89](https://github.com/monkeorg/MacNativeGames/pull/89) `90ca3da7060a992aa77555a8a133ff3f6126d944`: iOS warm/archive/purge/eviction ports; Mac title-first/idle queue preserved.
- [#90](https://github.com/monkeorg/MacNativeGames/pull/90) `2a282e26eb3adb4332c48714844bc3c6b697504d`: single-copy packaging and SHA-verified device checkpoints.
- [#91](https://github.com/monkeorg/MacNativeGames/pull/91) `b6195f2dcd0e8abd2b6fab92fdd2e9eaa09c3e6d`: actual thermal hook; checked display defaults unchanged.
- [#92](https://github.com/monkeorg/MacNativeGames/pull/92) `0d266ec0137b48d78ee0c02cc8fa855dd4ccb976`: two exact optional PSO names with complete manifest hashes.
- [#93](https://github.com/monkeorg/MacNativeGames/pull/93) `acbaf6587b692c13d97f1dbb0cb83bab44b12f46`: preparation VoiceOver phases and authoritative outcomes.
- [#94](https://github.com/monkeorg/MacNativeGames/pull/94) `ce899d29a59c729541a9646c57cfe57d3717e209`: known-v1 label-only repair preserving IDs/selection; opaque CAS/quarantine.
- [#95](https://github.com/monkeorg/MacNativeGames/pull/95) `8d67aeccf0e003cc9f86cc9f35609e8a7d5b3a40`: signed-metadata-bound pack producer/installer; owned temp canonicalization.
- [#96](https://github.com/monkeorg/MacNativeGames/pull/96) `b9bc66381156b0a0b0e62cda03036dd7a353ccdc`: explicit label-only profile recovery caller.
- [#97](https://github.com/monkeorg/MacNativeGames/pull/97) `98627cc3b7cece5efa09af06a113f89250fdeb48`: one Objective-C identifier per save-preview property; clarity cleanup, not a reproduced compiler error.
- [#98](https://github.com/monkeorg/MacNativeGames/pull/98) `c09cbabea714d73e9fccc783202754275592f64c`: verified private shader reader/pre-Play lease/renderer integration.
- All #88–#100 commits are source-only `[skip ci]`, with no new tests/builds.
  #90's listing-error-as-absence and #95's macOS temporary-path findings were
  corrected/re-reviewed. #98 includes actual reader/main/project and renderer
  attestation; the worker is progress-only/noncancellable. No old seed is deleted,
  every part/member/stream is hash-bound, private reuse fully rehashes, and the
  retained lease attests integrity rather than Apple signing. Default bundling,
  explicit Play/audio/single-start, compiled identity and Canopy's separate pins/
  quotas/leases remain. Current reader/provider/signing/Apple/device execution
  gates have not been performed. Shader-removal recovery and generation-retirement
  preflight are now source-corrected in #100/#99, independently reviewed but UNRUN.
  The later #85 red run remains red until an authorized actual rerun.
- [#99](https://github.com/monkeorg/MacNativeGames/pull/99) `5f2f43d36c116fa900055e279d968b82dce9c78f`: nonmutating generation-removal preflight; root/runtime source reviewed, UNRUN.
- [#100](https://github.com/monkeorg/MacNativeGames/pull/100) `62dd868c5e66d830ca1f5973462c4725a56aa759`: recorded shader-identity removal recovery; root/artifact source reviewed, UNRUN.
- Artifact attachment attempts #74–#87 all returned connection closed; none
  succeeded. #88–#91 remain pending in cell709; #92–#100 not attempted.
  Issues #37/#7 were updated; PR publication is not attachment success.

Physical/private/signing criteria remain open separately for each issue. Keep
account identifiers, saves, keys, private manifests/paths, signing material,
device reports and game-derived code/resources out of public commits/logs.
