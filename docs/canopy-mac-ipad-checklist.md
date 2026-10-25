# Canopy · ordered Mac and iPad handoff

**Pending local acceptance, not completed results.** Newest fully green baseline
[#77 / `976d856`](https://github.com/monkeorg/MacNativeGames/commit/976d8561ce9839dcf3da86221fa7c1c321bd87fd): recorded Canopy 524 run/517 passed/7 skipped
(71.610s), Source 940 run/931 passed/9 skipped (231.342s), unsigned SDK 26.2 app
and original 32-object matrix green. Earlier `09785cd` remains recorded in
[the progress table](canopy-progress.md): Canopy 502 passed/7 skipped (84.665s),
Source 916 passed/9 skipped (169.779s).

**Later red result retained:** [#85 / `0b808195` Source run 40223242649](https://github.com/monkeorg/MacNativeGames/actions/runs/40223242649)
recorded 971 run/961 passed/9 skipped/**1 error** (140.111s). A hardlink-preservation
check observes the canonical generation moved into `.retirement` before shape
refusal. Nonmutating preflight is now source-fixed in #99 / `5f2f43d`;
shader-cache interrupted-deletion recovery is source-fixed in #100 / `62dd868`.
Each received two independent source reviews; neither has been rerun.

The historical app snapshot reaches #100 / `62dd868c5e66d830ca1f5973462c4725a56aa759` on
`feat/canopy-shader-removal-recovery`. Later source cohorts are reviewed but
untested/unbuilt (`[skip ci]`), not covered by the green baseline. #97's declaration
split is clarity cleanup, not a reproduced compiler failure; #77 compiled the old
form successfully. No new tests/probes run under this `/goal`; the steps below
are the later authorized local handoff. A locked-iPad run executed no new-build checks.

**Current published source starting point:** the dependent chain through #154,
`fix/canopy-terminal-audio-silence` /
`7d112a2e5af94b6388b912c4eee4bac1934ef963`,
includes the friendly library/session title fixes (#110/#119), storage UI intent
correction (#120), save UI intent correction (#122) and compiler source through
#150, plus preparation diagnostics (#152), per-title mouse policy (#153) and
terminal audio output suspension (#154). Inspect the actual recovery cursor and
status before checkout; full-roadmap source work continues. No later source
inherits earlier green CI. The overall product acceptance remains open.
Both lifecycle corrections have two independent source reviews and no execution.

For #152, opt into Diagnostics and compare actual preparation success/failure
counters and bytes/blocks/records units; inspect redaction before sharing. For
#153, toggle Mouse input per title, including while a button is held, then check
actual lock release/reacquisition and keyboard/touch independence across modal,
focus and scene changes. For #154, verify terminal main-worker cleanup silences
output and interruption/restart notifications cannot revive it. Retain guest,
save and module ownership protections; this does not authorize relaunch.
These are later local validation steps, not checks run in this cloud continuation.

| Order | Mac / iPad action | Evidence to retain locally |
|---|---|---|
| 1 · Mac source review | Use an isolated checkout of the exact recorded dependent chain through #150, or its explicitly reviewed successor in the recovery cursor. Preserve the working original TOTK checkout/app identity and separate Canopy `.canopy` identity. Review source-fixed/unrun #99/#100 retirement recovery and newer #120/#122 lifecycle corrections separately. | Exact revision/cohorts and source findings; no global complete claim and no old CI assigned to new source |
| 2 · Backup first | Immediately back up saves **and account identity** outside build/install targets; record SHA-256 inventory before any installation or test. | Compare again after installation against this immediate inventory; historical 35-file matches do not substitute |
| 3 · Public/private builds | In the later authorized Mac validation phase, run existing suites and documented original iPad and Canopy builds separately. Follow `canopy-private-build.md`; inspect `python tools/launcher/build_private_canopy.py --plan --version v143`. Inspect actual generated-source/profile pins, compiler/link output, signed app metadata and fixed inventories before signing/installing locally. | Results for original/public/private targets separately. A plan/public app/profile row is not a private executable provider; new source needs its own Apple compilation; #97 is declaration clarity cleanup |
| 4 · Default bundled route | First build and exercise the unchanged default bundled-shader route. Check normalized pipeline keys, existing warm-up/memory controls, bounded split warm lists and actual thermal reporting. Preserve experimental display defaults. | Actual seed/map/list identities, startup/cache behavior and thermal observations; no inferred speed, memory or FPS gain |
| 5 · Optional shader pack | Only then enable the documented opt-in original-iPad pack route with actual product reader ABI/symbol and app-bundled metadata pins. Exercise exact app/seed tuple, part/member hashes, initial extraction, complete-seed reuse **without transport parts**, malformed/missing/wrong parts, interrupted stages and relaunch. | No Cancel is implemented for pack extraction: do not advertise or simulate it. Failures preserve old complete seeds; verified reuse cannot trust a marker alone. App-metadata pins do not make Documents bytes Apple-signed. Canopy retains its separate pin/lease authority |
| 6 · Preparation/storage/reuse | Supported base NSP/XCI, matching update and NCA/ExeFS/RomFS folders; selected-title updates reselect original inputs. Cancel preparation and await authoritative completion; resume exact jobs. Exercise generation retirement and shader-identity removal across interruption/reopen, current/previous protection and actual active leases. | Actual source/assets/dependencies, provider/low-storage/background/relaunch outcomes and current readback after uncertain publication. Retirement namespace preservation has a recorded red result; its preflight and shader deletion recovery are now **source-fixed, not rerun**. Retain the red evidence until an actual new run checks the fixes. Logical clone/I/O counters are not physical space savings |
| 7 · Profiles/saves/candidate | Before Play, check profile selection, label-only repair inspection/cancel/confirmation/stale CAS, backup/export/import/restore/recovery and identity separation. In original iPad and Canopy, explicitly share only an **UNVERIFIED** raw rupee candidate; preserve originals and inspect changed bytes. | Label repair preserves exact selected identity, saves and valid previous metadata; failure keeps Play gated. Reference-family 1.4.x is not exact 1.4.3 compatibility; no repaired checksum, active Apply, automatic import or certified game acceptance |
| 8 · Input/layout | Physical controller defaults/maps/taps/disconnect; keyboard dedup/Escape/Command; mouse settings with actual pointer-lock grant. Check direct touch/safe areas, indirect rejection, VoiceOver analog directions/Neutral/focus loss, human preparation announcements, large text and Reduce Transparency. Resize/rotate with supported profiles; full experimental 4:3 at 1080-high is **1440×1080**. | No stale input across modal/text/Diagnostics/background/scene/key-window transitions. Incompatible 4:3 captures input and retains startup projection; compatible return needs explicit Resume. Verify camera/HUD/map/menus/cutscenes/effects and touch placement physically; drawable size is not rendered scene resolution. TOTK accepts one native player |
| 9 · Gameplay/performance | Load a local save through the actual native host. Agree stable-60 thresholds, then collect matched warmed scenes over sustained 30-minute runs with memory/thermal/stall and frame-distribution evidence. Opt into Diagnostics explicitly; inspect redaction before sharing. | Native rendered FPS identity distinct from guest present cadence, callbacks, generated/presented frames, ceilings and Metal HUD. Record median/p95/p99/1% lows and gaps. Translator remains off pending managed/static/iOS/resource/parity proof |

Opening an overlay captures input/GPU focus; it does **not** promise guest CPU
pause or unlock saves. Partial startup and native ownership must retain save seals
and leases until actual permitted cleanup or process exit. A main-worker join is
not complete runtime teardown.

**#55:** only the two-confirmation/single-flight control protocol exists. Neither
its original fixture nor a submitted request is an actual TOTK Title/reload
transition. Do not test it by calling the loader twice or claim it accepted.
The user accepts experimental progress-loss/crash risk; whole-runtime safe
teardown is not a prerequisite for a future real engine-owned request.

**Scope:** #7 SaveEditor is active with candidate-only limits. BOTW #8 and mods
#35 remain parked; future configurable BOTW support is an aim, not a provider.
Prepared add-ons likewise do not imply mounting; TOTK advertises no DLC.

Keep keys, saves, identity, game-derived resources/code, private manifests/paths,
signing material, device identifiers and raw private logs out of GitHub. Use only
the documented retained local exporter/codec/shader inputs; no public upload is
part of this handoff. Record exact revisions, unavailable checks and reproducible
failures. Source review and compilation never replace physical acceptance.

The compiler source handoff through #150 / `6f166e7` records 501 retained
original-file checks (356 braced +145 added), 16 source-bounded raw sites and one
delegated duplicate. The original164 pending sites reconcile as145 instrumented,
16 bounded, two macro wrappers and one delegated. Five additional ParsedIR
checks are recorded separately. These drafts have independent source reviews
and no new build/execution evidence. General ID/grammar/other-operator validity,
allocator/noexcept isolation and managed/static/resource/parity gates remain open;
runtime translation stays OFF. Inventory completion is not whole-compiler safety.

For #110 / `73bb8db`, check a fresh friendly title before and after changing one
setting and reloading the library. Other custom names must survive. An exact
title-ID name intentionally takes the default label fallback; no metadata is
rewritten by this correction. This source change has not been built or run.

For #119, rename a game and check the session title without changing its runtime
entry. For #120/#122, background or switch the owning scene and navigate away
while export work, Files selection, storage/resume and destructive confirmations
are pending. Old intent must not revive on return. Already accepted backend work
must settle, and an accepted Files export must retain its data until the matching
picker finishes. Check the full-screen picker presentation too. These are local
acceptance steps, not executed results.

Later compiler validation must include the exact checked patch chain through
#150: specialization/array bounds, null-constant planning, numeric bindings,
parser type-copy/member growth, self-alias refusals, selected operand admission,
fixed-composite caller preflights, array-length operand roles and specialization
composite bounds. Source precharges
do not prove hard heap isolation or allocator failure recovery. The runtime
translator stays disabled until the full existing build/resource/parity gates
pass; do not enable it just because a source patch applies or a build links.

The finite source reassessment addressed its two demonstrated local contracts in
#149/#150. Broader malformed-SPIR-V variable/function/control-flow/string and
other-operator validation is not supplied by these local guards. Keep arbitrary
translation jobs disabled. Use real managed/native/parity results and exact
current provider contracts to scope any subsequent source work; no old fixture
result certifies patches0005–0046.
