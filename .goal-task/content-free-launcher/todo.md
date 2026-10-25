# Canopy executable development backlog

Live cursor after the app snapshot below: source compiler drafts through #133 add
reviewed controls (485 checkpoints,128 formerly unbraced,34 raw=13 fixed+21 pending).
Later cohorts include actual null-constant planning, array/spec/resource bounds,
parser type-copy precharges and three direct self-alias lifetime refusals.
#110 / `73bb8db` corrects the settings-first friendly-title fallback without
metadata writes; #119 / `b136283` follows the same policy in the session title.
#120 / `6c06d9a` and #122 / `2c3f23e` correct storage/save UI intent lifetimes
across background/scene/navigation; accepted backend work and Files data retained
until authoritative completion. Two independent lifecycle source reviews, no runs.
All are source-only, unbuilt/untested, runtime translator off.
See state.md for current author/reviewer ownership and the next bounded slice;
historical checklist/counts below are not latest-head validation. Goal ACTIVE.

Authority: docs/canopy-development-roadmap.md. This is the item-status source;
state.md links here rather than duplicating the checklist. Baseline inspector,
CLI, artifact audit and probes exist. They do not close the tasks below.
Current issue-level scope/evidence is in [the 18-issue ledger](../../docs/canopy-issue-coverage.md).
SaveEditor #7 is ACTIVE by the latest user instruction; BOTW #8 and mods #35
remain PARKED. The current /goal runs no new tests/probes; all counts are prior
recorded evidence, not executions performed for this reconciliation.

Status vocabulary: TODO, ACTIVE(owner/files), REVIEW, DONE(source/check evidence),
EXTERNAL(exact missing dependency/next step). Only real evidence changes status.

## Foundation batch

- [ ] C00 / D0: agree title/version/profile/generation/job/session schemas, native
  import/key/sink/progress/cancellation interfaces and migrations from inspection
  history. Root owns shared contract/build changes; name files before delegation.
- [x] C01 / D1: native crypto primitive provider, bounded ephemeral key-provider
  interface and synthetic public vectors; no key-value serialization/logging.
- [x] C02 / D1: bounded NCA inventory/header/section validation, key-area and
  common-ticket decryption; explicit malformed/unsupported/refusal states.
- [x] C03 / D3: immutable generation store, staging, verified manifests, atomic
  publication, previous-generation retention and locking/serialization.
- [ ] C04 / D0,D4: title/version/base/update/DLC identity and dependency model;
  preserve existing known-title pins; unknown versions are not executable.
- [ ] C05 / D8: existing runtime boundary audit, actual adapter contract and
  original-source production-loader harness; implement real available host paths.
- [ ] C06 / D10: shader preparation portability/dependency implementation plan
  grounded in existing translator/runtime; native integration code where feasible.

## Connected implementation batch

- [x] C07 / D2: actual streaming ExeFS extraction with checked table/block hashes
  and per-asset outputs, not copying encrypted containers as 'assets'.
- [x] C08 / D2: actual RomFS integrity validation, private image/index production
  and bounded folder materialization for supported layouts.
- [ ] C09 / D3: cancellation, restart/resume, provider loss, low space, interrupted
  publication/rollback and garbage collection that cannot touch saves/identity.
- [ ] C10 / D4: supported update/DLC composition and mismatched dependency refusal;
  missing format evidence attaches only to that sub-format, not all preparation.
- [ ] C11 / D5: actual prepared multi-game catalog and migration; folder/file setup
  and local key selection; wire UI to native jobs/store, errors and progress.
- [ ] C12 / D6: validated per-title settings persistence, migration, capabilities
  and real backend application; distinguish live vs next-session behavior.
- [ ] C13 / D6,D9: full shared in-game overlay, resume/lifecycle, touch/mouse/input
  exclusion, accessible navigation and real settings application wiring.
- [ ] C14 / D7: per-title/profile save storage, validator selection, bounded import/
  export, backups, restore, atomic replacement, rollback and account separation.
- [ ] C15 / D7,D8: seal save operations at actual session start and preserve failed
  startup retry/rollback; unsupported production semantic Apply remains disabled.
  This does not park the active #7 candidate parser/preview/share work.
- [ ] C16 / D9: independent controller snapshots, mappings and player assignment;
  actual guest Npad routing and disconnect/reassign/focus cancellation.
- [ ] C17 / D8: native session startup/prepared paths/modules/services/presentation
  adapter and truthful lifecycle/teardown behavior; no fake successful backend.

## Close source-development gaps

- [ ] C18 / D10: native shader/preparation integration, private content+recipe+
  device cache identity, missing-variant behavior and recoverable invalidation.
- [ ] C19 / D11: actual supported multiplayer services/profile code and Mario Kart
  integration supported by available contracts; do not invent version addresses.
- [ ] C20 / D12: app/content/schema updates, verified reuse/chunks, migrations,
  storage accounting and interrupted-update/rollback tests across titles.
- [ ] C21 / D13: bounded actual job/storage/runtime diagnostics and redacted export;
  wire existing frame/memory/thermal hooks without invented FPS measurements.
- [ ] C22 / D14: build allowlists/packaging/CI for all new production modules;
  preserve clean public inputs and complete known dependency/license records.
- [ ] C23 / D14: end-to-end synthetic container→private assets→catalog→settings/
  saves→native fixture session and cancellation/recovery/update integration.
- [ ] C24 / D14: independent adversarial reviews and fix/re-review substantive
  crypto/parser/loader/storage/save findings; no unresolved high-severity defects.
- [ ] C25 / D14: reconcile every roadmap row against code and evidence; record
  source-only Apple validation debt and exact remaining external dependencies.

- [ ] C26 / #7: integrate the reviewed reference-family rupee candidate parser,
  exact-profile opaque snapshot and native candidate-only UI on the existing save
  queue. Preserve all non-wallet bytes; label shared raw candidates unverified.
  Keep production Apply disabled until an independently supported exact-version/
  integrity contract and physical load/recovery acceptance exist. Track-A reuse
  must preserve its existing pre-Play authority and web-editor admission.
- [ ] C27 / #55: connect the experimental red Restart/Continue/Restart interaction
  and cancellation/single-flight controller to an ACTUAL verified engine request
  and guest-thread completion observation. Risk authorization is already given.
  The control helper/fixtures are not a mechanism or working UIKit action; do not
  require guaranteed save completion or full safe teardown for an engine-owned
  experimental reload, and do not invent the missing target-selection context.

## Parked work (not current finish gates)

- #8 BOTW: retain the assessment and any generic trusted configuration model,
  but do not implement or claim a BOTW backend/version/ABI/device capability.
- #35 mod manager: backlog only. No worker implementation, dependency, duplicate
  display-toggle substitute or release gate without a later user instruction.

## External product acceptance (does not stop the tasks above)

- [ ] E01: physical Canopy UI/provider/accessibility/lifecycle acceptance. Needs
  local signing and an iPad; exact commands already in launcher/apple/README.md.
- [ ] E02: permitted native execution of private imported modules absent from the
  public app's signed executable. Needs physical mechanism proof; keep isolated
  from all independent source development. Existing Mac call probe is not proof.
- [ ] E03: exact supported-title private-input preparation and real gameplay;
  correct graphics, saves, controls and performance measurements.
- [ ] E04: actual Mario Kart local multiplayer session with independent players,
  disconnect/reassign/recovery, and final signed content-free artifact acceptance.

Initial ownership allocation is chosen at activation from the real runtime
limit (currently root + six workers). Suggested separate modules: crypto/import;
identity/update metadata; generation storage; runtime/harness; shader integration;
library/settings. Root integrates and schedules independent reviewers. Ownership
is explicit per file; no shared-module edits without reassignment.

### Recorded source evidence and dirty integration queue (2026-10-25)

Checked boxes denote reviewed supported source subsets, never arbitrary-format,
private-input or device acceptance. Other broad rows remain open. Recovery HEAD
is `62dd868c5e66d830ca1f5973462c4725a56aa759`; read state.md and git status.
#77–#100 are committed source. Registry/callers, label recovery/UI, preparation
announcements, candidate property syntax and hardened shader pack transport/reader
are published after source review and fixes. #88–#100 use `[skip ci]`; no tests/builds.
Both removal fixes are committed: #99 nonmutating generation preflight and #100
recorded shader-identity recovery, source reviewed but UNRUN. Former cache/store
owners are clear. Execution now assesses raw-loop normal-step source; native
assesses recursion/noexcept/ownership, both read-only with no new patch yet.
Compiler debt remains source work; the active goal is not complete or hardware-only.

- C00/C04: versioned title/base/update/add-on/generation/job/session identities and
  capability refusal exist. Trusted profile/config registry and
  actual builder/caller consumers are committed in #86/#87. Label-only repair and explicit UI are committed in #94/#96, preserving IDs,
  current selection and other rows with opaque CAS/quarantine; no schema/global rollback. Future
  BOTW configuration is not permission to enable an unsupported backend. History
  and future schema migration/accounting reconciliation remain source work.
- C01/C02/C07/C08: supported bounded NCA3 crypto, ExeFS/RomFS extraction, runtime
  index, NCA/plaintext folder preparation and supported BKTR are connected to
  CLI/Foundation. Highest declared versions are selected; bad selected content
  refuses without fallback. Private/large/provider coverage is not accepted.
- C03/C09/C10: V1–V5 immutable generations, complete payload verification,
  staged current/previous publication, cancel/resume/GC leases and typed add-on
  producer/installer/catalog exist. Native retirement/removal source is reviewed and committed in #83; its final
  code has a later #85 CI canonical-path regression; the #99 preflight source
  correction is committed/reviewed, UNRUN. Missing/mismatched leases and ambiguous retirement cannot
  authorize delete.
  Receipt identities, account/save boundaries and actual pin protections persist.
- C11/C12/C13: actual library/preparation/storage/add-on UI, per-title settings,
  independent input, captured mouse/touch and shared overlay are connected.
  #76 selected-title update/reuse is committed and has recorded Apple CI at09785cd.
  System-language/reset and presentation-only layout are committed in #79/#78
  and need cohort-specific evidence. Analog VoiceOver #82 is source-reviewed
  and committed but final code UNTESTED. #93 preparation VoiceOver phase/outcome
  announcements are source-reviewed/committed, not accessibility acceptance.
- C14/C15/C26: isolated title/profile saves, structural validators, raw/bundle
  transfer, backup/journal recovery, pre-Play seals and durable payload flushing
  exist. Logical profile selection has recorded Apple Foundation evidence at
  19e972f. ACTIVE #7 adds a bounded four-byte reference-family candidate, opaque
  instance/slot-bound snapshot/CAS transaction and candidate-only UIKit share.
  Parser/transaction/candidate UI are source-reviewed and published in #77;
  original Track-A candidate UI is committed in #85 on a NEW dedicated serial
  queue, with original project/source-matrix shared C inclusion. Root/runtime
  source approved the refresh-directory collision fix; no tests/builds ran. Its
  separate existing web editor and pre-Play authority remain. Apple acceptance is pending. Old constructors supply no edit validator, so
  production TOTK Apply is unavailable. No guessed checksum or exact1.4.3 claim.
- C16/C19: four independent seats/FullKey have authored native fixtures; TOTK
  remains single-player. Exact Mario Kart title/version/modules/services/graphics/
  patches and local session acceptance are absent. Assignment UI is not proof.
- C17/C05: actual private TOTK loader/Metal/input/audio/shader/save binding and
  builder exist; public provider is NULL and iOS external-module execution is
  refused. Child ownership/main-worker join and SDK return70 are committed.
  The shared production-loader core/fixture replaces duplicated probe logic;
  root/native source reviewed and committed as #81. Its Mac
  native/signed-iPhoneOS build methods have not run locally. Full helper/service/
  graphics teardown, finalizer/TLS/reset contracts remain independent source work.
- C18: seed/map/recipe/device cache identity and real Cross parity/resource checks
  exist. Earlier coverage was394 checkpoints; reviewed patch0004 in #80 now has396 with
  123 raw unbraced sites, 10 fixed and113 input-dependent/unproven. Treat its
  historical checks separately from any newer Apple result. Managed/static/iOS
  link and remaining recursion/noexcept/STL/framework work gate runtime translation,
  which stays off. Quotas are cooperative, not hard heap/process isolation.
  #88/#89 ports preserve Mac policy; #92 hash-bound split lists and #95/#98 original
  pack producer/reader are committed source, unbuilt/untested. Pack verification
  is not shader compilation or native-execution permission. Shader-identity removal recovery with the minimal storage caller is committed
  in #100, source-reviewed and UNRUN.
- C20: genuine same-verification facts/lease avoid repeated consumer hashing.
  Verified clone/chunk overlap, differing-size reuse and CLI/Foundation callers
  are committed with recorded actual Mac clone/growth/shrink evidence. #76 UI
  connects explicit selected-title reuse; migration/accounting work remains.
- C21: bounded opt-in diagnostics/redacted export have actual providers. Desired
  dimensions, frame ceilings, presentation counts and fixture values are not
  native gameplay FPS, memory/thermal measurements or graphics acceptance.
- C22: public unsigned builds and compiled icon recipe have recorded Apple
  evidence. Private embedded packaging is an intermediate and must never be
  uploaded as public content-free. Every dirty production header/source/caller
  needs root allowlist/build integration and its own applicable later checks.
- C27: experimental restart control helper is committed in #84 with six recorded native
  fixture cases; the actual engine selector/context, real completion observer
  and required shared-overlay red button/two dialogs are not connected. #55
  remains open. Child/main join, SDK return or a no-op is not game-only restart.
- C23–C25: connected integration, migrations/history/accounting, independent
  review/re-review, source/Apple/private/device evidence and the full issue matrix
  remain open. No overall product/goal completion follows from this checkpoint.

### Historical checkpoints (do not reinterpret or rerun here)

Exact `dfd59cff5c02f024f44fd1dbad33525e3ea553c1`:
Canopy40211081559 macOS414 run/409 pass/5 skip/81.028s;
Linux414 run/284 pass/130 skip/35.211s; CLI and unsigned SDK26.2 app succeeded.
Source40211081551:782 run/3 setup errors/6 skip/118.011s, from three strict
ShaderCache warnings. Reviewed format-only e04daf1 followed. This is a historical
red run, not the current unresolved status; later green results below supersede it
only for their exact revisions.

Exact `398ced32b6f42c2cdc1c1f040490abb7d81f30ce`:
Canopy40216569500 Mac485 run/478 pass/7 skip/98.497s; unsignedSDK26.2 build/archive.
Source40216569598:889 run/881 pass/8 skip/129.471s. Counts overlap. Actual Mac
same-size clone/changed spans and main-worker/TLS fixtures ran; not iPad gameplay.

Exact `19e972f5bbc79ba35edff5aef429cae5b44ece03`:
Canopy40217382055 Mac503 run/496 pass/7 skip/78.415s; unsignedSDK26.2 and original
32-object matrix succeeded. Source40217382063:911 run/902 pass/9 skip/206.696s.
The preceding profile warning at30accb3 was fixed; this rerun passed. At4563064,
Source40217610465:922 run/913 pass/9 skip/109.303s, including original-controls
Foundation and original nonexecutable-metadata loader syntax cases. This does
not execute a private SDK or the NEW shared loader fixture.

Previously recorded local frozen-cohort checks: shared-loader artifact/metadata16
passed, new Apple-native/build3 methods skipped; candidate parser5 strict O3/UBSan
passed, SaveStore32 Foundation methods skipped locally (10 editor methods);
language6 native passed/2 Apple skipped; restart6 native fixture cases. These are
historical author/reviewer records, not new tests/probes run in this goal.
Exact `09785cdb1fd53e520c52286b61e5cb8dfbe6a859`:
root read existing Canopy40218521737/Mac121244801250 logs:509 run/502 pass/7 skip/
84.665s; unsignedSDK26.2 app plus32 objects green. Source40218521806/
121244801597:925 run/916 pass/9 skip/169.779s. No new tests/probes here.

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

Newer #78–#100 source needs its own applicable evidence. The #85 red run is
recorded separately, not treated as passing. Accessible touch #82 has no newly
credited acceptance; no earlier counts are inherited. Track-A #85 remains
committed with a new dedicated serial queue. #97 split declarations are clarity
cleanup, not a reproduced compiler error. Both source fixes are committed #99/#100, reviewed and UNRUN; no tests/rerun. #84 still has no actual restart mechanism/app caller/capability.

Recent dependent source chain (all `[skip ci]`, no tests/builds):

- [#88](https://github.com/monkeorg/MacNativeGames/pull/88) `feat/canopy-upstream-shader-lists` `606dc1e40f43c642a4958ae5df3d7c2212c44068`: TOTK shader metadata and normalized pipeline keys; BOTW list untouched.
- [#89](https://github.com/monkeorg/MacNativeGames/pull/89) `feat/canopy-upstream-shader-memory` `90ca3da7060a992aa77555a8a133ff3f6126d944`: iOS warm/archive/purge/eviction ports; Mac title-first/idle queue preserved.
- [#90](https://github.com/monkeorg/MacNativeGames/pull/90) `feat/ipad-upstream-packaging` `2a282e26eb3adb4332c48714844bc3c6b697504d`: single-copy packaging and SHA-verified device checkpoints.
- [#91](https://github.com/monkeorg/MacNativeGames/pull/91) `feat/ipad-thermal-observation` `b6195f2dcd0e8abd2b6fab92fdd2e9eaa09c3e6d`: actual thermal hook; checked display defaults unchanged.
- [#92](https://github.com/monkeorg/MacNativeGames/pull/92) `feat/canopy-seed-warm-lists` `0d266ec0137b48d78ee0c02cc8fa855dd4ccb976`: two exact optional PSO names with complete manifest hashes.
- [#93](https://github.com/monkeorg/MacNativeGames/pull/93) `feat/canopy-preparation-announcements` `acbaf6587b692c13d97f1dbb0cb83bab44b12f46`: preparation VoiceOver phases and authoritative outcomes.
- [#94](https://github.com/monkeorg/MacNativeGames/pull/94) `feat/canopy-profile-label-repair` `ce899d29a59c729541a9646c57cfe57d3717e209`: known-v1 label-only repair preserving IDs/selection; opaque CAS/quarantine.
- [#95](https://github.com/monkeorg/MacNativeGames/pull/95) `feat/ipad-verified-shader-pack-producer` `8d67aeccf0e003cc9f86cc9f35609e8a7d5b3a40`: signed-metadata-bound pack producer/installer; owned temp canonicalization.
- [#96](https://github.com/monkeorg/MacNativeGames/pull/96) `feat/canopy-profile-label-ui` `b9bc66381156b0a0b0e62cda03036dd7a353ccdc`: explicit label-only profile recovery caller.
- [#97](https://github.com/monkeorg/MacNativeGames/pull/97) `feat/canopy-save-preview-declarations` `98627cc3b7cece5efa09af06a113f89250fdeb48`: one Objective-C identifier per save-preview property; clarity cleanup, not a reproduced compiler error.
- [#98](https://github.com/monkeorg/MacNativeGames/pull/98) `feat/ipad-verified-shader-pack-reader` `c09cbabea714d73e9fccc783202754275592f64c`: verified private shader reader/pre-Play lease/renderer integration.

Artifact attachment attempts #74–#87 all returned connection closed; none succeeded.
Issue #37/#7 updates are recorded separately from attachment success.

- [#99](https://github.com/monkeorg/MacNativeGames/pull/99) `feat/canopy-removal-preflight` `5f2f43d36c116fa900055e279d968b82dce9c78f`: nonmutating generation-removal preflight; root/runtime source reviewed, UNRUN.
- [#100](https://github.com/monkeorg/MacNativeGames/pull/100) `feat/canopy-shader-removal-recovery` `62dd868c5e66d830ca1f5973462c4725a56aa759`: recorded shader-identity removal recovery; root/artifact source reviewed, UNRUN.

Goal remains ACTIVE. Execution owns a read-only raw-loop normal-step source
assessment; native owns a read-only recursion/noexcept/ownership source assessment.
No new compiler patch is implemented yet. There is no other demonstrated broken
supported flow after the reviewed source corrections, but compiler debt remains
source work, not only a hardware gate. Runtime translation remains disabled and
product/Apple/private/device/signing acceptance is separate.

Root plans documentation draft #101, `feat/canopy-cloud-handoff`, base #100.
Artifact attachments #88–#91 remain pending in cell709; #92–#100 not attempted.

### Approved next source slices after the #100 checkpoint

Native owns frozen Cross0005: two function-query depth guards, with execution/root
source approval. Execution authors PHI-loop0006 only after0005 is committed. No
tests/probes/compiler runs; runtime translation stays off. Counts remain396/123/113
until a reviewed loop patch changes them. Continue the authorized source goal.
