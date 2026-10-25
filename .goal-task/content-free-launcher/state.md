# Canopy active cloud development — acceptance gates open

## Active continuation after #151

The full D0–D14 roadmap remains the goal. The finite compiler-source handoff
below is historical, not an instruction to stop independent implementation.
The user confirms that current working app code is on GitHub and authorizes
building on it. Preserve the draft dependency chain and existing app behavior.
No tests, probes, builds, CI dispatches, new tests, private inputs, installs,
merges or releases in this continuation. Source review is not runtime evidence.

Latest published source: `796c089e1eb0d80aa183cdd85bd484414d82fc97`, draft #152,
`feat/canopy-preparation-io-diagnostics`, depends on #151. Actual native progress
units and bounded logical I/O attempt counters reach opt-in diagnostics/export;
publication and uncertainty are separate. Product author, independent execution
and root source reviews; unbuilt/untested. No performance/device acceptance.

Active ownership (shared worktree; stage exact reviewed files only):

- native_review: real linked shader-provider adapter, TOTK shader runtime/host,
  private build linkage and related integration docs (D10).
- runtime_impl: CANOPY terminal audio-output suspension in audio_mixer.c and
  runtime.h; native_review alone integrates the host cleanup call (D8).
- storage_audit: native durable add-on job intent plus Storage/Addons backend
  adapters; root owns StorageController/routing integration (D3/D4/D5).
- product_audit: actual per-title mouse enable policy, settings, input/session
  application and Games caller (D6/D9). Root queues Games routing until frozen.
- execution_audit/artifact_audit: independent reviews; risky storage/translator
  slices need two independent reviewers. Authors cannot approve themselves.

Newly established source gaps also queued: interrupted save-backup deletion
recovery (D7); real MK8DX integration from pinned original MIT host/HLE source
(D11), including seat isolation and truthful controller-support handling.
Public original upstream metadata/source exists; the earlier blanket claim that
no MK source exists is superseded. Nintendo-derived code/assets/shaders remain
forbidden to fetch or vendor. Exact private hashes, Apple compilation and actual
multiplayer acceptance remain open. No metadata-only provider counts as runtime.

Combined same-run import→library→settings/saves→session/update/recovery evidence
remains validation debt, not a new test authorized by this continuation.

## Live source cursor after the published #101 handoff

Reviewed source point: `feat/canopy-shader-specialization-composite-bounds`,
`6f166e738a4748dde8e0a844a3b1acc327c3ddd5` (#150). Documentation-only
successors may be newer; inspect actual log/status. New source is unbuilt and
untested. This finite cloud-source pass is handed off; overall product acceptance
remains OPEN. No hardware/format/runtime gate is closed by source review.

The original visual Mac/iPad handoff was published in #101, branch
`feat/canopy-cloud-handoff`, head `3cec301a6dc32da136e7c86f3038d92fb2a54607`.
That snapshot covers app source through #100 and remains a valid local starting
point for that historical app snapshot. Later source and ordered local steps are
recorded in docs/canopy-progress.md and docs/canopy-mac-ipad-checklist.md. The old
.goal-task/totk-cloud/state.md path now redirects here.

Reviewed dependent compiler source drafts after #101:

- #102 `a079f9f35d88a1bfed47c478a89d4d007b43cc01`: checked patch0005,
  function purity/control-dependence query depth guards.
- #103 `897bd588644107bcb4eec9080e6f2d75233a1bcf`: patch0006, five PHI scans;
  401 checkpoints,118 raw sites=10 fixed+108 pending.
- #104 `a5bfbc40f07a832c760e8323b0476e03da5e3aa3`: patch0007, five normal IR
  queries;406 checkpoints,113 raw=10 fixed+103 pending.
- #105 `ef9fe3a0fffb23877c8732c3c65e7a4d970fb676`: patch0008, ten ordinary
  statement loops;416 checkpoints,103 raw=10 fixed+93 pending.
- #106 `98c01ffd9b08aa761ce8b79e4d8290e1d3b83aac`: patch0009, actual Parser
  structural-type comparison and Compiler alias-name depth guards; counts unchanged.
- #107 `3ec62ae23411998f3bf1585c0008676d9c24399c`: patch0010, eleven normal
  query/local-scalar scans;427 checkpoints,70 formerly unbraced,raw92=10 fixed+82 pending.
- #108 `f053c9641a822cecb8b0a54c79d606c64f61546a`: patch0011, implied-read,
  invariant-expression and global-read function-dependency depth guards; counts unchanged.
- #109 `2408740f8546a7f8a0ccd8a3d284db10e3f619c4`: patch0012, type-location
  depth/shape/narrowing/checked local arithmetic and two scans;429/72/raw90=10+80.
- #110 `73bb8dbfc9692334d1061e337baa2d406fb0d989`: library friendly-name
  fallback after settings-first placeholder creation. Other custom names retained;
  literal title-ID legacy ambiguity documented; metadata untouched. Product author,
  independent root source review; unbuilt/untested.

- #111 `c6f15028d73a8e0ca1e1ef287ab4b58f64264704`: patch0013, seven already
  depth-controlled wrapper loops;436/79/raw83=10 fixed+73 pending.
- #112 `9c3654883cca18d7af8a50f234bb0b271581412d`: independently reviewed
  visual progress/checklist/recovery refresh, app snapshot100 still explicit.
- #113 `c099c0e28b68e2f2bed5b9214fe1e32ec884fea5`: patch0014, MSL occupied
  location spans/search increments reserve existing unknown sentinel; counts unchanged.
- #114 `4c658773d21b87f4dae559c67d4771fe3448d31e`: patch0015, four ordinary
  flag/capability loops plus source-proven zero-iteration MSL4265 classification;
  440/83/raw79=11 fixed+68 pending. No checkpoint credited for classification.
- #115 `d7aec412e831a748f9d0c38bab0cb77e720df0dc`: patch0016, eight checked
  caller interface offsets/cursor advances; conservative sentinel exhaustion refusal.
- #116 `775594bdcd85800b8753527a818f9388e42832c4`: patch0017, actual recursive
  composite-member entry depth guard; compiler-owned fixups discarded on failure.
- #117 `41420059da1375b2d5294e172b14c77d1f903d71`: patch0018, eight normal
  IR-collection loops;448/91/raw71=11 fixed+60 pending; underlying growth still gated.
- #118 `073eff616f6b50494ec7e02cf86482c22081f85d`: patch0019, two packing/
  workgroup entry depth guards; original visited/parent order retained.
- #119 `b1362838022e1e2aeeef82d311e6096ce6462f2d`: session display name resolves
  current settings/registry fallback without changing runtime entry. Product author,
  independent root source review; unbuilt/untested.
- #120 `6c06d9a010e87c91eac831eb580d52e5dbb04926`: StorageController UI intent
  scene/epoch/foreground/top-owner/exact-modal checks, exact-sheet resume dismissal.
  Storage author; root/artifact independent source reviews of exact final code.
- #121 `5a95607a23360c8618aa1dd020d9469f039b260d`: patch0020, nine text/output
  loops and one literal-array[2] classification;457/100/raw62=12 fixed+50 pending.
- #122 `2c3f23e54c264cdda0cd78c1714e8c8b33b309e0`: SaveController queued export/
  picker/confirmation intent expires across scene/background/navigation; accepted
  Files export retains data until exact terminal picker. Runtime author; root/
  artifact source reviews including exact-owned full-screen picker window fallback.
  Underlying store/seals/backup/account/recovery unchanged; unbuilt/untested.
- #123 `989f6ec6bb3bc358715b9f3d727820c3ae5cbc54`: reviewed visual/local/active
  handoff through122, app snapshot and exact older CI evidence retained.
- #124 `42ae3cf2266c2a699f9d450fc8a5f95970000472`: patch0021 actual scalar
  specialization helper:32 existing opcodes (3 unary/1 Select/28 binary), exact
  arity/depth/defined shifts and signed32 arithmetic. Lazy Select/uint32 wraps kept.
- #125 `11ca9296e090d27b048235b220f0f2d65cd2d6d2`: patch0022, eight normal
  expression-dependency/invalidation loops;465/108/raw54=12 fixed+42 pending.
- #126 `eb197cd24243d28aeee684d05b236e041bc21deb`: patch0023, actual ParsedIR
  null-constant depth/shape/narrowing/planned temporary+subconstant slots/bytes.
- #127 `284a87069f6910996cb23fc9d21a9e26257ecbac`: patch0024, eight MSL loops
  plus fixed16 argument-buffer reset classification;473/116/raw46=13+33.
- #128 `f0621396ec642292755e19602c543b945e4ac53e`: patch0025, two array query
  overloads refuse empty/narrowing/shape/index failures before vector access.
- #129 `9d00dfa152bee21e9c0de714e4478d05617639a0`: patch0026, six normal
  emission/semantic-cleanup/reset loops (not C++ destruction);479/122/raw40=13+27.
- #130 `f38cb8be2975ddf505bd53bc45e77d3f5275facb`: patch0027, one resource
  binding method's checked stride/plane/numeric cursors; exactMAX/zero retained.
- #131 `48c62b08f4d09ea3a47cd9e5d819406e8f4a296d`: patch0028, six metadata
  walks;485/128/raw34=13 fixed+21 pending.
- #132 `9d4640350a647641c0b4106118a1c59530d13ca1`: patch0029, parser type-copy
  precharges before Variant/ObjectPool replacement: four SmallVector payloads,
  checked N8/POT capacities and immediate append growth, incidental CoopVec copy
  and forward-fixup member copy. Artifact author; THREE independent root/execution/
  native source reviews. Bounded <=25 planning loop excluded from raw inventory;
  capacity/payload planning is not hard heap/allocator/complete parser proof.
- #133 `2468ba0da7c36ae828d0a598f7a18588238d81f5`: patch0030, three direct
  TypeArray/RuntimeArray/Pointer raw result/source equality refusals before lookup/
  precharge/replacement. Untyped short-circuit and distinct-pointee forward pointer
  resolution retained. Vector initial copy happens before old-holder destruction,
  not the same lifetime bug; no global ID/cycle validator claim. Counts unchanged.
- #134 `3ab37a073f3e1080fc7e9657e1b8b5fd8ac8b961`: reviewed visual/local/
  recovery refresh through133, no new execution or completion claim.
- #135 `84b96489191d8593bac6c643d87387c58d877fa1`: patch0031, eight normal
  analysis/emission wrappers;493/136/raw26=13 fixed+13 pending.
- #136 `e0696d1510f1d01f4495e73f9cd0cf0321f050f0`: patch0032, actual recursive
  member-decoration query entry depth guard; metadata/type-index assumption retained.
- #137 `bc4f135c0fa5aed780009aa799f2c6c674cd45cb`: patch0033, selected fixed[4]
  matrix/vector fill shape and MIN initializer availability before writes; arrays/
  Structs/extras unchanged; caller CompositeInsert index validity still open.
- #138 `5ae23ca66c6f5e0f77f0c07b255d4b5473163d27`: patch0034, two ordinary
  collection checkpoints plus three source-bounded classifications (10 candidates,
  6 dependencies, 4 fill slots under0033);495/138/raw24=16 fixed+8 pending.
- #139 `1fca62a28c5f061fdb30bfe80b0b12dc7415d24f`: patch0035, capacity-aware
  metadata growth before three ParsedIR writers and type-member query bound.
  Artifact author; root/execution/native independent reviews.
- #140 `47ede3ff7f1996672dc451de565153bf22d7a75d`: patch0036, actual MSL
  alignment depth/member work;496/139/raw23=16 fixed+7 pending.
- #141 `a659c7a8b9b9e67ce70c48bc20678532ae97d61c`: patch0037, shared preparation
  helper routes six member writers once, preserving variable-ID/pre-type/pre-member
  annotations and unset row creation. Artifact author; three independent reviews.
- #142 `56e6bf91d62f86b7aade38da698fa86e2ce621df`: patch0038, three conditional
  GLSL flattening helper bounds/depth and two walks;498/141/raw21=16+5.
- #143 `c12f3f912512addea0f54e285f41a235225792f2`: patch0039, optional zero-init
  query depth/two scans;500/143/raw19=16+3.
- #144 `86be47753efdafe3daa5827bee9d201d5b5c216b`: patch0040, inactive Compiler
  null helper delegates to guarded ParsedIR true-registration. Removes one old
  braced checkpoint and raw duplicate, with no fake credit:499=356+143, raw18=16+2,
  plus one separately delegated original site. Signature/valid-ID semantics kept.
- #145 `9e25d5781a5b157cd7e28bbb825365d40b3c8c8e`: patch0041, optional tessellation
  struct parent/depth/index/dimension/interface-cursor contract;500/144/raw17=16+1.
- #146 `41923cb4163c1f1a0d4ef69b317b9ca49498fcb8`: patch0042, fixed composite
  caller preflights before three pool constructors; empty aggregates/long-vector
  ID-list/replicated branches kept. Artifact author; three independent reviews.
- #147 `2ef26cfa134a3cc445548ac4db4c21242cb9db6c`: patch0043, actual selected
  tessellation access chain bounds/depth/operand/sentinel contract; three reviews.
  Original164 pending sites fully classified:145 instrumented+16 source-bounded+
  2 fixed macro wrappers+1 delegated. Retained checks501=356+145, not full safety.
- #148 `e57871fadb072b138c46fa7768faa94ec6885f88`: patch0044, finite38 parser
  declaration/constant operand floors and Float8/wide-literal availability checks;
  three reviews, no full grammar/ID/other-op validation claim.
- #149 `52acf6a1a4802a2e2bfc7fdd64a071005400c8b6`: patch0045, actual ParsedIR
  array-length dependency depth/ID/fixed-column/selected-operand controls, including
  VectorShuffle two-ID dependency roles (literal selectors excluded). Five checks
  in that additional file recorded separately, not original-inventory credit.
  Root/execution/artifact reviewed the final revised source.
- #150 `6f166e738a4748dde8e0a844a3b1acc327c3ddd5`: patch0046, selected GLSL
  specialization CompositeExtract/Insert operand/initializer-index/Struct-member
  guards, preserving array-first and whole-four-slot behavior. Three reviews.

Compiler drafts #102–#109/#111/#113–#118/#121/#124–#133/#135–#150 have at least two independent source reviews (root plus non-author reviewer), checked
patch/before/after SHA provenance, vendor untouched, source generation only.
NO new tests/probes/compiler runs or new tests; `[skip ci]`. Runtime translator
stays off; no malformed-SPIRV, heap-isolation, parity, FPS or hardware proof.

No authored source slice remains in flight. Root owns this final handoff/docs/
issues integration; workers have released metadata ownership. The finite source
reassessment's two demonstrated current-path contracts are addressed by #149/#150.
No further supported Canopy app-flow defect was established by those bounded
passes. This is not a blanket vendor audit or complete-product acceptance.

Required future translator contracts remain OPEN: general SPIR-V ID/type/grammar,
variable/function/control-flow/string/other-operator/image-mask validation,
generic STL/framework work and allocator/noexcept isolation. Local checks do not
authorize arbitrary translation jobs. Actual managed/NativeAOT static exports,
resource/parity execution, Apple deployment/Metal and signed-device external-code
permission still require their real tools/inputs/evidence. Runtime remains OFF.
Use exact provider/build/parity results to scope further bounded implementation;
do not invent a broad validator rewrite or enable capability from inventory counts.
App acceptance remains open. Product's supported-flow pass found and fixed the
name and lifecycle issues recorded above; these newer changes are unbuilt/untested.
Product's additional read-only overlay/input/settings audit after122 found no new
demonstrated source defect: modal capture/explicit Resume/focus+scene+callback
epoch guards and desired/effective settings remain coherent. No execution or
feature-complete/physical acceptance claim follows.
Product's preparation/update/add-on caller audit also found no new demonstrated
source defect: exact selection/reuse/resume and cancellation/commit authority/
verified catalog refresh inspected. No provider/format/device acceptance inferred.
No concurrent metadata edits. Any newly demonstrated scoped Canopy gap should
start a separately owned, independently reviewed cohort; historical fixtures do
not validate source-only patches0005–0046. Current no-test/probe/install and
other user constraints still apply; this batch ran no compilers/builds. Later
local-checklist commands are not automatic action.

Attachment attempts88–149 returned connection closed; all those wait cells
are drained. Attempt150 is still in cell998; no attachment success is
established. Source/source-review milestones do not replace exact CI:
#77 green524/517/7 and940/931/9; later#85 red971/961/9/1, #99 fix UNRUN.

## App-source snapshot through #100 (historical below this cursor)

Everything below is historical #100-era recovery context. All old ownership,
ACTIVE/queue labels and counts are superseded by the live source handoff above;
they must not revive a patch0005 assignment or override current user constraints.

Reconciliation date: 2026-10-25. Current source branch is
`feat/canopy-shader-removal-recovery`, HEAD
`62dd868c5e66d830ca1f5973462c4725a56aa759` (#100).
Read actual status/log before editing; preserve all uncommitted owner files.
The separate original checkout `/workspace/MacNativeGames` is outside this scope.
All label/editor/pack/removal cohorts through #100 are published source, not tested
product acceptance. #99 fixes the generation preflight source implicated by later
#85 red CI; #100 adds exact recorded shader-identity removal recovery. Both have
independent source reviews and are UNRUN, with no fix tests/rerun.

Goal remains ACTIVE. The compiler assessments identified two bounded source slices.
Native owns the frozen two-function query depth patch 0005 and its SHA/coverage/docs;
execution and root reviewed it. Execution owns the subsequent five PHI-query loop
checks only after 0005 is committed. No compiler tests/builds or runtime enablement
are authorized by this source work. There is no other demonstrated broken
supported flow after the reviewed source corrections, but compiler debt remains
source work, not only a hardware gate. Runtime translation remains disabled and
product/Apple/private/device/signing acceptance is separate.

Root fetched `origin/main` at `d259f83dd72db768a95a2caf031516cee3367b0f`
and identified eight upstream commits absent from the earlier branch. Focused
ports are now committed in #88–#91; no whole-main merge/cherry-pick or inherited
upstream phone performance claim. Current goal forbids new local tests/probes/
builds/installs/private inputs. New #88–#100 commits use `[skip ci]`; none has new
build/test evidence. Historical exact counts below remain unchanged.

## Historical #100 authority

Follow CONTRIBUTING.md and `docs/canopy-development-roadmap.md` D0–D14. The goal
remains active; status/cost questions and hardware gates did not cancel source
work. The user's latest instruction makes SaveEditor #7 ACTIVE. Older #7/#9
“later/parked” wording does not override it. BOTW #8 and mod manager #35 remain
PARKED and are not current implementation dependencies or finish gates. A future
trusted profile/configuration model may describe BOTW, but must not invent or
enable a BOTW backend, private ABI, title compatibility or deployment promise.

The current /goal prohibits new tests/probes. This reconciliation runs none.
Results below and in the issue ledger are previously recorded checkpoints, not
new executions. Source review/documentation continue within assigned ownership;
root controls integration and any permitted later verification. Do not quietly
rerun a historical command or describe an unavailable Apple case as passed.

Public standard GitHub runners are authorized; no larger runners, SDK/package
installs, simulators, private inputs/credentials, merges/releases or working-app
identity changes. Preserve original Mac/TOTK behavior, saves, accounts, backups,
pre-Play exclusion and rollback. No guessed instructions, save checksums or engine
requests. Native/recompiled execution remains the requested direction: no CPU
emulator, JIT, streaming or fixture reported as a commercial game.

Use actual gpt-6.1-sol Medium workers with explicit ownership, at most root plus
six workers. Routine changes require one independent review; crypto, parsing,
loading, destructive storage and saves require two. Authors do not self-approve.
No AGENTS.md was found. Do not repeat completed reviews without a material delta.

[Issue coverage](../../docs/canopy-issue-coverage.md) accounts for all 18 current
issues #1–#9, #34–#41 and #55. [todo.md](todo.md) retains the D0–D14 work items.
Source implementation, Apple compilation, synthetic execution, private-input
validation and physical acceptance are separate. No complete-product, stable
60 FPS, rendered 1080-high or physical signing claim is supported here.

## Draft dependency chain and source checkpoints

Preserve original TOTK #10→#11→#12→#13→#14 and Canopy #42–#54.
The later chain is #56→54, then each following draft depends on its predecessor:

| Draft | Branch | Source checkpoint / change |
|---|---|---|
| #57 | feat/canopy-asset-extraction | Native extraction |
| #58 | feat/canopy-prepared-library | 7f92958, prepared/native services |
| #59 | feat/canopy-input-addons | ae04d67, input/add-ons/Canopy flush/verified asset facts |
| #60 | feat/canopy-display-profile | a5e3f7e, checked display and private overlay generation |
| #61 | feat/canopy-shader-controls | a7753e6, cooperative resource controls/static build gates |
| #62 | feat/canopy-thread-ownership | 100fb47, actual guest-child join ownership |
| #63 | feat/canopy-app-icon | d048f5a, public/private compiled icon packaging |
| #64 | feat/canopy-resume-jobs | f166103, retained jobs and guarded input reselection |
| #65 | feat/canopy-shader-walks | 52c56f8, parser and cyclic-parent checkpoints |
| #66 | feat/canopy-generation-reuse | d30aa73, verified same-size clone/chunk reuse |
| #67 | feat/canopy-main-observation | 4a209a0, ABI3 worker cleanup/join observation |
| #68 | feat/canopy-reuse-callers | 398ced3, explicit CLI/Foundation reuse and I/O reports |
| #69 | feat/ipad-durable-save-flush | 70a1236, original-iPad safe descriptor flush |
| #70 | feat/canopy-resize-reuse | 45722af, verified overlap across growth/shrink |
| #71 | feat/ipad-public-source-matrix | cedc028, actual 32-object Apple CI matrix |
| #72 | feat/canopy-shader-invalidation | 9287fff, ten IR invalidation checkpoints |
| #73 | feat/canopy-save-profiles | 19e972f, logical profiles plus strict-warning fix |
| #74 | feat/canopy-sdk-return | 5eae724, TOTK-only natural SDK return reports host error70 |
| #75 | feat/ipad-controls-validation | 4563064, original controls validation and accurate docs |
| #76 | feat/canopy-title-updates | 09785cd, actual selected-title update/reuse UI |
| #77 | feat/canopy-save-candidates | 976d856, candidate parser/opaque Store transaction/native candidate share |
| #78 | feat/canopy-window-presentation | b0aaafa, presentation-only layout with immutable projection |
| #79 | feat/ipad-system-language | 27db117, System language and Canopy-only setting isolation |
| #80 | feat/canopy-shader-dependency-depth | 67c4d58, two dependency helpers with depth/edge checks |
| #81 | feat/canopy-shared-loader | 55782b5, actual shared production core/original fixture source |
| #82 | feat/canopy-accessible-sticks | e743397, focus-owned accessible analog actions; final source UNTESTED |
| #83 | feat/canopy-retirement-recovery | 8d4fe94, generation retirement; later #85 CI regression, fix pending |
| #84 | feat/canopy-restart-confirmations | 26db74f, restart control helper only; no actual game mechanism/UI |
| #85 | feat/ipad-save-candidates | 0b80819, Track-A candidate UI/new serial queue; no tests/builds |
| #86 | feat/canopy-game-registry | fb26d02, trusted registry and builder consumers; no tests/builds, [skip ci] |
| #87 | feat/canopy-profile-callers | 7f13c9a, actual profile callers/onboarding; no tests/builds, [skip ci] |
| [#88](https://github.com/monkeorg/MacNativeGames/pull/88) | feat/canopy-upstream-shader-lists | 606dc1e, TOTK shader metadata and normalized pipeline keys; BOTW list untouched; source only, [skip ci] |
| [#89](https://github.com/monkeorg/MacNativeGames/pull/89) | feat/canopy-upstream-shader-memory | 90ca3da, iOS warm/archive/purge/eviction ports; Mac title-first/idle queue preserved; source only, [skip ci] |
| [#90](https://github.com/monkeorg/MacNativeGames/pull/90) | feat/ipad-upstream-packaging | 2a282e2, single-copy packaging and SHA-verified device checkpoints; source only, [skip ci] |
| [#91](https://github.com/monkeorg/MacNativeGames/pull/91) | feat/ipad-thermal-observation | b6195f2, actual thermal hook; checked display defaults unchanged; source only, [skip ci] |
| [#92](https://github.com/monkeorg/MacNativeGames/pull/92) | feat/canopy-seed-warm-lists | 0d266ec, two exact optional PSO names with complete manifest hashes; source only, [skip ci] |
| [#93](https://github.com/monkeorg/MacNativeGames/pull/93) | feat/canopy-preparation-announcements | acbaf65, preparation VoiceOver phases and authoritative outcomes; source only, [skip ci] |
| [#94](https://github.com/monkeorg/MacNativeGames/pull/94) | feat/canopy-profile-label-repair | ce899d2, known-v1 label-only repair preserving IDs/selection; opaque CAS/quarantine; source only, [skip ci] |
| [#95](https://github.com/monkeorg/MacNativeGames/pull/95) | feat/ipad-verified-shader-pack-producer | 8d67aec, signed-metadata-bound pack producer/installer; owned temp canonicalization; source only, [skip ci] |
| [#96](https://github.com/monkeorg/MacNativeGames/pull/96) | feat/canopy-profile-label-ui | b9bc663, explicit label-only profile recovery caller; source only, [skip ci] |
| [#97](https://github.com/monkeorg/MacNativeGames/pull/97) | feat/canopy-save-preview-declarations | 98627cc, one Objective-C identifier per save-preview property (clarity cleanup, not a reproduced compiler error); source only, [skip ci] |
| [#98](https://github.com/monkeorg/MacNativeGames/pull/98) | feat/ipad-verified-shader-pack-reader | c09cbab, verified private shader reader/pre-Play lease/renderer integration; source only, [skip ci] |
| [#99](https://github.com/monkeorg/MacNativeGames/pull/99) | feat/canopy-removal-preflight | 5f2f43d, nonmutating generation-removal preflight; root/runtime source reviewed, UNRUN; [skip ci] |
| [#100](https://github.com/monkeorg/MacNativeGames/pull/100) | feat/canopy-shader-removal-recovery | 62dd868, recorded shader-identity removal recovery; root/artifact source reviewed, UNRUN; [skip ci] |

All these PRs exist and are strictly dependent drafts. Root records the required
per-cohort independent source reviews for #77–#100; touch had
an initial finding fixed and re-reviewed. Do not infer testing from review or
commit. Touch has no separately credited acceptance. Later #85 CI exposes a
generation-retirement failure; the committed correction has no tests/rerun. Earlier
store/fixture counts cannot be adopted for either fix. Artifact attachment attempts for #74–#87 all returned connection closed; none
succeeded. #88–#91 attachment cell709 is pending; #92–#100 have not been
attempted. PR publication and artifact attachment are separate outcomes.

## Exact verified evidence

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

Previous green checkpoint retained without promotion to newer source:
`09785cdb1fd53e520c52286b61e5cb8dfbe6a859`.

- Canopy40218521737, Mac121244801250: **509 run,502 passed,7 skipped** in84.665s;
  public unsigned SDK26.2 app and original32-object matrix green.
- Source40218521806, job121244801597: **925 run,916 passed,9 skipped** in169.779s.

Earlier exact checkpoints, retained separately:
`19e972f5bbc79ba35edff5aef429cae5b44ece03`:

- Canopy40217382055, Mac121241370935: **503 run,496 passed,7 skipped** in78.415s;
  public unsigned iPhoneOS SDK26.2 and original 32-object matrix succeeded.
- Source40217382063,121241370829: **911 run,902 passed,9 skipped** in206.696s.
- Actual profile Foundation tests, original-iPhoneOS save-flush compilation,
  real native clone/growth/shrink/ENOSPC/cancel/recovery and prior worker cases pass.
- At4563064, Source40217610465/job121242059921: **922 run,913 passed,9 skipped**
  in109.303s, including actual original-controls Foundation cases and original
  nonexecutable-metadata loader SDK syntax matrix. No private SDK ran.
- The original matrix at cedc028 compiled30 production+2 isolated fixture
  objects; fixture assertions were not executed. Actual sips316/actool26.3 icon
  compilation passed earlier at ed33633 and remains part of public builds.

Counts overlap. The prior profile compile warning at30accb3 is fixed and the
19e972f rerun passed; selected-title update09785cd now has the separate green
results above. Newer cohorts require their own evidence. Physical input/provider/
save/rendering/FPS acceptance remains open.

## Historical #100 dirty ownership and source handoff

All published source cohorts through #100 are committed. The former native
shader-cache and storage preflight ownership is complete at source-review level,
UNRUN. No author currently owns further cache/store edits under that assignment.

| Owner | Exact active scope | Status / next step |
|---|---|---|
| execution | Compiler raw-loop normal-step source assessment | Read-only assessment, no new patch yet; report concrete source findings. |
| native | Compiler recursion/noexcept/ownership source assessment | Read-only assessment, no new patch yet; report concrete source findings. |
| artifact | this file, `todo.md`, `docs/canopy-issue-coverage.md` | Frozen for root review; no source/tests/probes. |
| product | `docs/canopy-progress.md`, `docs/canopy-mac-ipad-checklist.md` | Separate documentation ownership. |
| root | integration/build inventories/GitHub evidence | Documentation draft #101 is published on `feat/canopy-cloud-handoff`, based on #100 (initial doc commit78948c40904bb85d5fd1a1de106d8bee275194b9). Continue the approved compiler source slices. |

Published recent source cohorts and limits:

- #77 `976d8561ce9839dcf3da86221fa7c1c321bd87fd`: candidate parser, opaque
  Store/CAS and candidate-only native UI. Prior five C cases passed; 32 Foundation
  methods were local skips. No production edit validator/Apply or exact1.4.3 proof.
- #78 `b0aaafad634752d559de8600883fc746fb955999`: presentation-only layout;
  no scene/projection reconfiguration or automatic focus restoration promise.
- #79 `27db1177616d6c856846ca2dcf77c1a85f7c8f4d`: System language and narrow
  Canopy setting reset. Prior six native cases passed, two Apple gates skipped.
- #80 `67c4d58933bf068185eba0a561811fd1fecb40f9`: dependency traversal depth/
  edge checks, coverage396 checkpoints; raw123 remaining=10 fixed+113 unproven.
  Runtime translator remains off; newer source needs its own applicable evidence.
- #81 `55782b560f1377ec821c15cf28ac4633e33bdd93`: shared actual mapper,
  relocation, sealing, symbol and gate-dispatch core plus original fixture,
  unchanged `gate.S`. Root/native source approved. Prior16 portable cases passed;
  three Apple native/build methods skipped locally. No Apple core execution yet.
- #82 `e743397a82d1ec6f3893b37a6ae2e6790c695374`: accessible analog actions.
  Source reviewed after a finding/fix; final cohort UNTESTED, not device accepted.
- #83 `8d4fe944b30a4906bffd1293c43de6f9f05114dd`: native retirement recovery.
  Source reviewed; later #85 CI exposed canonical-path loss before full preflight.
  Storage correction is committed #99, UNRUN; do not reuse earlier51-store counts.
- #84 `26db74f65b07050232d23ae7ac8188c8fbcd06a4`: confirmation/single-flight
  restart helper and portable-core build-list connection. Prior six fixture cases
  concern only the helper. There is no app caller/capability or real TOTK request.
- #85 `0b8081952d2ef5e0ff4600a79b44ac857d7bd27f`: original Track-A native
  candidate UI using a NEW dedicated serial queue and the same C core. Root/runtime
  source reviewed after refresh-directory collision fix/re-review. Original
  project and source matrix include that core. No tests/builds ran at publication;
  later #85 Source CI is separately recorded above as red. No Apply;
  separate existing web editor and pre-Play save authority remain unchanged.

- #86 `fb26d02e5e7d1fcca2688baaafd3c3321a467712`: trusted game registry and
  consumers, with two independent source reviews. Provenance/default findings fixed.
- #87 `7f13c9abbf6d86f6dab9b0b7d58ba599c77f70d5`: profile callers/onboarding,
  with two independent source reviews and onboarding findings fixed. Both #86/#87
  were committed with `[skip ci]`; no tests/builds ran. Neither supplies an
  unsupported backend or changes standalone execution/signing gates.

- [#88](https://github.com/monkeorg/MacNativeGames/pull/88) `606dc1e40f43c642a4958ae5df3d7c2212c44068`: TOTK shader metadata and normalized pipeline keys; BOTW list untouched.
- [#89](https://github.com/monkeorg/MacNativeGames/pull/89) `90ca3da7060a992aa77555a8a133ff3f6126d944`: iOS warm/archive/purge/eviction ports; Mac title-first/idle queue preserved.
- [#90](https://github.com/monkeorg/MacNativeGames/pull/90) `2a282e26eb3adb4332c48714844bc3c6b697504d`: single-copy packaging and SHA-verified device checkpoints.
- [#91](https://github.com/monkeorg/MacNativeGames/pull/91) `b6195f2dcd0e8abd2b6fab92fdd2e9eaa09c3e6d`: actual thermal hook; checked display defaults unchanged.
- [#92](https://github.com/monkeorg/MacNativeGames/pull/92) `0d266ec0137b48d78ee0c02cc8fa855dd4ccb976`: two exact optional PSO names with complete manifest hashes.
- [#93](https://github.com/monkeorg/MacNativeGames/pull/93) `acbaf6587b692c13d97f1dbb0cb83bab44b12f46`: preparation VoiceOver phases and authoritative outcomes.
- [#94](https://github.com/monkeorg/MacNativeGames/pull/94) `ce899d29a59c729541a9646c57cfe57d3717e209`: known-v1 label-only repair preserving IDs/selection; opaque CAS/quarantine.
- [#95](https://github.com/monkeorg/MacNativeGames/pull/95) `8d67aeccf0e003cc9f86cc9f35609e8a7d5b3a40`: signed-metadata-bound pack producer/installer; owned temp canonicalization.
- [#96](https://github.com/monkeorg/MacNativeGames/pull/96) `b9bc66381156b0a0b0e62cda03036dd7a353ccdc`: explicit label-only profile recovery caller.
- [#97](https://github.com/monkeorg/MacNativeGames/pull/97) `98627cc3b7cece5efa09af06a113f89250fdeb48`: one Objective-C identifier per save-preview property (clarity cleanup, not a reproduced compiler error).
- [#98](https://github.com/monkeorg/MacNativeGames/pull/98) `c09cbabea714d73e9fccc783202754275592f64c`: verified private shader reader/pre-Play lease/renderer integration.

#88/#89 were artifact/root source-reviewed; Mac platform-scope correction was
included. #90's error-as-missing-directory finding was fixed/re-reviewed before
commit. #92 closed filenames preserve full pin/tree/quota checks. #94/#96 preserve
IDs, order, selected profile and other rows; no schema/global rollback. #95's
macOS owned-temp alias issue was corrected/re-reviewed. #98 reader and root
renderer/project integration received independent source reviews; property
syntax was corrected before publication. Reviews are source evidence only.

Original opt-in pack contract: explicit `--seed-pack` also requires
`--image-outside`, built integer ReaderABI1 and the actual defined Mach-O reader
symbol. Default bundle stays self-contained. Signed bundle metadata binds exact
12-key title/revision/RomFS/chain/rawmanifest/member/part/fullstream identities.
Inputs are fixed content-addressed Documents parts; complete extraction publishes
private ApplicationSupport/TOTKShaderSeeds with full hashes/EOF/exact-tree/durable
exclusive rename/shared lease. Cached private snapshots fully rehash without
requiring transport pieces. Main compares signed facts and compiled game version/
chain before retained-lease attestation. This integrity is not Apple code signing.
The worker is intentionally noncancellable with progress only; no Cancel claim.
Limits are original-iOS transport-only: 64MiB metadata/member, 262144 members,
16GiB stream and16 contiguous1GiB parts, ASCII leaves/casefold uniqueness.
Canopy retains its independent100000/64MiB/16GiB quotas, compiled manifest/map pins,
exact tree/device namespace/leases. Final exported/renamed PSO bytes require a
new real trusted pin. No old pin, marker or environment grants authority.
No producer/reader/signing/provider execution or Apple acceptance is claimed.

- [#99](https://github.com/monkeorg/MacNativeGames/pull/99) `5f2f43d36c116fa900055e279d968b82dce9c78f`: nonmutating generation-removal preflight; root/runtime source reviewed, UNRUN.
- [#100](https://github.com/monkeorg/MacNativeGames/pull/100) `62dd868c5e66d830ca1f5973462c4725a56aa759`: recorded shader-identity removal recovery; root/artifact source reviewed, UNRUN.

Goal remains ACTIVE. The compiler assessments identified two bounded source slices.
Native owns the frozen two-function query depth patch 0005 and its SHA/coverage/docs;
execution and root reviewed it. Execution owns the subsequent five PHI-query loop
checks only after 0005 is committed. No compiler tests/builds or runtime enablement
are authorized by this source work. There is no other demonstrated broken
supported flow after the reviewed source corrections, but compiler debt remains
source work, not only a hardware gate. Runtime translation remains disabled and
product/Apple/private/device/signing acceptance is separate.

Read root messages/status before resuming; ownership and HEAD can advance again.

## Product boundaries and remaining source work

- The public provider remains NULL; the generic external-module loader refuses
  iOS execution. The private Mac-assisted builder embeds private code/fonts/seed
  and is an intermediate only. Shared production-fixture source does not solve
  standalone on-iPad imported-code signing or exact-title gameplay (#38).
- Preparation selects the highest declared content revision and refuses invalid
  selected content without fallback. Reviewed V1–V5 receipt identities remain
  stable; committed retirement source must not reinterpret absent leases as garbage.
  Its later #85 canonical-path failure has a committed nonmutating preflight
  correction #99; the correction is UNRUN and does not turn the red run green.
- Default logical profile and save/account paths are preserved. New profiles
  copy/generate no account bytes; current/previous registry publication, sandbox-
  safe opener and main-thread pre-Play guards are committed. Provider/device
  acceptance remains open.
- SaveEditor #7 is active: a reference-family rupee parser/serializer changes
  only four discovered bytes in a separate copy; opaque Store previews/CAS and
  candidate-only share UI are committed for Canopy and original Track-A in #85;
  the latter uses a new dedicated serial queue, not an existing queue. No exact 1.4.3 integrity proof or
  production edit validator exists. Active Apply remains disabled, not all #7 work.
- #55 risk authorization is already given. Its control helper has prior six-case fixture evidence for two
  confirmations, cancellation and single flight, but supplies no real target-
  selection request, guest-thread context, completion observer or UIKit button.
  Observe a normal original return-to-title transition locally to establish that
  missing engine contract. Do not invoke unknown factories, all-data resets,
  lifecycle callbacks alone, loader twice, app exit/relaunch or menu replay and
  call it game-only restart. Guaranteed save completion/full safe teardown are
  not prerequisites for the authorized experimental engine-owned route.
- Guest-child/main joins and SDK-return error70 retain runtime protection; they
  are not complete GPU/audio/IPC/helper quiescence or safe reusable shutdown.
  Continue bounded ownership/finalizer/TLS/reset work without injecting exits.
- Shader controls remain cooperative, not hard heap isolation or preemptive
  timeouts. The earlier 394-checkpoint baseline has recorded real Cross parity;
  the newer 396-checkpoint source is reviewed but requires its own
  applicable execution/build evidence. Managed/static/
  iOS link and remaining loops/depth/noexcept/STL/framework gates stay open.
- Four-seat/FullKey fixtures are not Mario Kart. Exact title/version/module/
  service/graphics/patch contracts and actual local multiplayer are missing.
- Continue history/schema migrations, recovery/accounting, accessibility,
  remaining real callers and current-cohort integration. Resolve concrete CI
  failures before widening validation claims. Signing/device gates do not stop
  independent source work; no global completion/blocked declaration is justified.

## Original Track A and external acceptance

Source follow-ups #69/#71/#75 address original iOS flush, the orphan mouse/public
C-object matrix, and Controls validation/docs. Their historical evidence is above;
do not reimplement them from stale issue comments. Mouse fixture assertions need
an isolated physical host. Language/current-layout and candidate-only editor adaptations are committed;
their current-cohort build/device acceptance remains separate.

The historical locked-iPad attempt executed no new-build actions. It was neither
functional failure nor acceptance. Existing Track-A save/load results belong to
their recorded revisions and packaged-code architecture. Keep immediate local
save/account backups, exact signing modes and private captures local. External
steps are in `docs/canopy-mac-ipad-checklist.md`; all 18 issue gates are in the
coverage ledger. No physical Canopy gameplay, standalone external-code permission,
complete visual correctness, sustained native 60 FPS or Mario Kart result is claimed.

## Tools and integration recovery

Existing Python: `/workspace/.venvs/macnativegames/bin/python`; cmake, ninja and
GCC14.2 are installed. Pinned public Cross is ignored under
`games/totk/build/native-shader/SPIRV-Cross`, with an existing CLI beside it.
There is no local dotnet, Xcode/xcrun, iPad, private input or signing material.
The current no-new-tests/probes goal still applies; these tool paths are recovery
context, not instructions to execute validation now.

Use functions ALL_TOOLS for GitHub. `gh` API has returned401 while git push works.
Workflow lookup requires a full40-character SHA; abbreviations can return[].
Root owns issue/PR updates and attachments. Stage only the explicit sanitized
state/todo/coverage files, never the whole `.goal-task` directory. Preserve all
uncommitted author cohorts while integrating.

Historical issue3 comment6400854059 records original-iPad flush/open hardware
criteria; issue39 comment6400934957 records Mac clone/caller evidence. Newer
results require exact cohort/commit attribution, not cumulative passed counts.
