# Canopy · development update

**FOSS native launcher · cloud development active · local validation outstanding**

Current published source: [#155 / `2f5d3ba`](https://github.com/monkeorg/MacNativeGames/pull/155),
`fix/canopy-backup-retirement-recovery`,
`2f5d3baf459ffad9087cb4f7afa37eba174813b6`.
Newer source is reviewed but **unbuilt and untested**. This cloud pass ran no
new tests, probes, compilers or builds and performed no installs, merges or releases.

| Recent change | Published source | Acceptance |
|---|---|---|
| Preparation diagnostics | Actual native logical I/O attempt counters, exact progress units and separate publication/uncertainty flags (#152 / `796c089`) | Independently source-reviewed; no new execution; counters do not prove physical savings |
| Mouse switch | Existing per-title settings now control real mouse handlers, capture requests and event admission; default On (#153 / `ad8da58`) | Independently source-reviewed; physical lock transitions and UI unverified |
| Terminal audio | Real main-worker cleanup stops tracked outputs and irreversibly prevents further audio output (#154 / `7d112a2`) | Independently source-reviewed; CoreAudio unbuilt/unrun; no teardown/relaunch claim |
| Backup deletion | Verified retirement record and interrupted-cleanup recovery; unknown/corrupt data preserved (#155 / `2f5d3ba`) | Two independent source reviews; fault injection, Apple and physical saves unverified |
| Friendly names | Library keeps its name after the first preference write (#110); session uses current custom/friendly name (#119) | Source-reviewed; check rename/reload/start locally |
| Save dialogs | Scene/navigation-bound export, picker and confirmation intent; accepted Files export retains its data until its exact picker finishes (#122) | Two independent reviews; no new execution |
| Storage dialogs | Stale confirmations/resume cannot revive after background or scene changes; accepted backend work still settles (#120) | Two independent reviews; no new execution |
| Existing TOTK updates | Reused upstream normalized keys, warm-up/memory controls, packaging/verified transfer, thermal reporting and optional pinned shader-pack route (#88–#98) | No inferred performance or device acceptance |
| Recovery | Nonmutating generation-removal preflight (#99) and recorded shader-removal recovery (#100) | Source fixes **unrun**; older red CI retained below |
| Compiler boundaries | Reviewed recursion, operands, fixed storage, capacity planning, dependency roles and local index/arithmetic guards (#102–#150) | Source-only; runtime translator **off** |

The original164 pending loop sites are fully classified:145 instrumented,
16 source-bounded, two fixed macro wrappers and one delegated duplicate. The
original four files now retain501 checks (356 originally braced +145 added).
Five additional ParsedIR checks are recorded
separately. This is an inventory, **not whole-compiler safety or runtime permission**.
All compiler slices have at least two independent source reviews; parser/storage
boundary cohorts received additional reviews where recorded. Exact checked patch,
input and output SHA provenance is retained. General SPIR-V ID/grammar/other-op
validation, allocator/noexcept isolation, managed/static/parity and Apple/device
acceptance remain explicit gates.

The table below includes the app-source snapshot through #100 plus the later
corrections above. None inherits old green CI as proof of current behavior.

Active source work continues across the full roadmap: real linked shader
consumer/build integration; durable exact-base add-on resume; original-source
MK8DX host/runtime integration. These are
in-flight implementations, not completed features. Pinned public original MIT
MK host/HLE source now provides a concrete reuse path; metadata is not execution
authority, and private version pins, Apple builds and multiplayer acceptance
remain open. Nintendo-derived code/assets/shaders are never public inputs.

| Area | Current source | Remaining acceptance / work |
|---|---|---|
| 📚 Library & preparation | Multiple titles, versions, NSP/XCI and supported folders; updates/add-ons; selected-title verified reuse | Real private inputs, provider failures and large-library/device checks; preparation grants no execution capability |
| 🛡 Saves & identity | Isolated profiles/accounts, backup/export/import and pre-Play seals; explicit label-only recovery API and confirmation UI | Current-build transfer/recovery checks; preserve identity and existing saves |
| ✎ SaveEditor · #7 | **Active:** TOTK reference-family rupee preview and explicit raw candidate share; Canopy source reviewed | No active Apply until an exact format/integrity contract exists; candidate integrity, checksum and game compatibility remain unverified. Both original iPad and Canopy candidate-share callers are committed; exact format/integrity and physical acceptance remain open |
| 🎮 Input & accessibility | Real controller/keyboard/mouse/touch routing, modal capture; reviewed focus-owned VoiceOver analog actions and bounded preparation announcements | Physical models, pointer-lock, focus/rotation and VoiceOver interaction; four seats do not establish multiplayer TOTK/Mario Kart support |
| ⚙ Display & settings | Supported live controls, System language; immutable startup projection with presentation-only layout updates and incompatible-4:3 capture | New Apple results, physical visual/input checks and actual rendered-resolution evidence; experimental quality presets remain off |
| ⚡ Storage & reuse | Existing copy-on-write reuse with earlier Mac growth/shrink evidence; inode/lease-bound retirement recovery; nonmutating preflight correction source-fixed in #99 | Later Source run is **red** on hardlink refusal preserving the canonical namespace; new-request full-tree preflight is source-fixed, **not rerun**. Logical counters are not physical space savings |
| ◉ Lifecycle & restart · #55 | Native ownership observation retains protections; reviewed two-confirmation restart control protocol | **No actual TOTK restart mechanism or UIKit restart caller.** Protocol/fixture is not game reload; full teardown/relaunch remains separate |
| ✦ Shaders | Private cache identity, cooperative compiler controls and upstream normalized keys/warm-up/memory controls; optional pinned original-iPad pack producer/reader | Interrupted shader-identity deletion recovery is **source-fixed in #100, unrun**. Pack/tuple/reuse and Apple/device acceptance remain open; translator stays **off** |
| 🌿 Packaging & profiles | Compiled trusted profiles and actual UI/validator callers; upstream safe packaging/transfer checkpoints and actual thermal-state reporting | New source is unbuilt; metadata is not a provider, thermal reporting is not an optimization, and warm-up controls establish no performance gain |
| ⏸ Deferred | BOTW **#8** and mod manager **#35 parked** | Future extensible BOTW configuration is an architectural aim only, not current implementation or compatibility |

## Recorded CI evidence · green baseline and later failure

The newest fully green baseline is [#77 / `976d856`](https://github.com/monkeorg/MacNativeGames/commit/976d8561ce9839dcf3da86221fa7c1c321bd87fd), not the current head:

| Recorded check | Outcome |
|---|---|
| [Canopy 40222639497](https://github.com/monkeorg/MacNativeGames/actions/runs/40222639497) · Mac job `121257329603` | **524 run: 517 passed**, 7 skipped · 71.610s; unsigned SDK 26.2 app and original **32-object** matrix green |
| [Source 40222639501](https://github.com/monkeorg/MacNativeGames/actions/runs/40222639501) · job `121257329585` | **940 run: 931 passed**, 9 skipped · 231.342s · green |
| **Later red:** [#85 / `0b808195` · Source 40223242649](https://github.com/monkeorg/MacNativeGames/actions/runs/40223242649) · job `121259156586` | **971 run: 961 passed**, 9 skipped, **1 error** · 140.111s. Hardlink-preservation test observes canonical generation moved into `.retirement` before shape refusal |
| Earlier `09785cd` · [Canopy 40218521737](https://github.com/monkeorg/MacNativeGames/actions/runs/40218521737) / Mac `121244801250` | **509 run: 502 passed**, 7 skipped · 84.665s; unsigned SDK 26.2 app and original 32-object matrix green |
| Earlier `09785cd` · [Source 40218521806](https://github.com/monkeorg/MacNativeGames/actions/runs/40218521806) / job `121244801597` | **925 run: 916 passed**, 9 skipped · 169.779s |

These are existing logs read without running anything new. Counts overlap;
none proves private gameplay or later-source acceptance. The new-request
nonmutating full-tree retirement preflight is committed in #99 / `5f2f43d`;
shader-cache interrupted-deletion recovery is committed in #100 / `62dd868`.
Both received two independent source reviews and remain **unrun/not rerun**. The later red result remains part of the handoff.

## Dependent drafts · source reviewed, newer cohorts unbuilt

| Draft cohort | Published change |
|---|---|
| [#77](https://github.com/monkeorg/MacNativeGames/pull/77)–[#80](https://github.com/monkeorg/MacNativeGames/pull/80) | Candidate save preview/share (`976d856`), presentation layout (`b0aaafa`), System language/experiment isolation (`27db117`), shader dependency depth (`67c4d58`) |
| [#81](https://github.com/monkeorg/MacNativeGames/pull/81)–[#84](https://github.com/monkeorg/MacNativeGames/pull/84) | Shared production module-mapping fixture (`55782b5`), accessible analog actions (`e743397`), recoverable generation retirement (`8d4fe94`), restart control protocol (`26db74f`) |
| [#85](https://github.com/monkeorg/MacNativeGames/pull/85)–[#87](https://github.com/monkeorg/MacNativeGames/pull/87) | Original iPad copy-only candidate (`0b80819`), trusted registry (`fb26d02`) and actual library/validator consumers (`7f13c9a`) |
| [#88](https://github.com/monkeorg/MacNativeGames/pull/88)–[#92](https://github.com/monkeorg/MacNativeGames/pull/92) | Existing upstream TOTK metadata/normalized keys (`606dc1e`), warm-up/memory controls (`90ca3da`), verified packaging transfers (`2a282e2`), thermal reporting (`b6195f2`), hash-bound split warm lists (`0d266ec`) |
| [#93](https://github.com/monkeorg/MacNativeGames/pull/93)–[#98](https://github.com/monkeorg/MacNativeGames/pull/98) | Preparation announcements (`acbaf65`), label-only recovery API (`ce899d2`) and UI (`b9bc663`), signed-metadata optional pack producer (`8d67aec`) and original-iPad reader (`c09cbab`), save-preview declaration clarity cleanup (`98627cc`) |
| [#99](https://github.com/monkeorg/MacNativeGames/pull/99) | Nonmutating full-tree generation-removal preflight ([`5f2f43d`](https://github.com/monkeorg/MacNativeGames/commit/5f2f43d36c116fa900055e279d968b82dce9c78f)); two source reviews, **not rerun** |
| [#100](https://github.com/monkeorg/MacNativeGames/pull/100) | Recoverable shader-identity removal ([`62dd868`](https://github.com/monkeorg/MacNativeGames/commit/62dd868c5e66d830ca1f5973462c4725a56aa759)); two source reviews, **unrun** |
| [#110](https://github.com/monkeorg/MacNativeGames/pull/110), [#119](https://github.com/monkeorg/MacNativeGames/pull/119), [#120](https://github.com/monkeorg/MacNativeGames/pull/120), [#122](https://github.com/monkeorg/MacNativeGames/pull/122) | Friendly names and scene-bound storage/save UI intent; source-reviewed, unbuilt/untested |
| [#102](https://github.com/monkeorg/MacNativeGames/pull/102)–[#150](https://github.com/monkeorg/MacNativeGames/pull/150) · compiler cohorts | Scoped recursion/work/operand/index/arithmetic/storage guards, shared helper reuse and finite follow-up fixes; exact provenance and independent reviews recorded; translator off |

These focused drafts depend on their predecessors. #77 has the green evidence
above; #85 has the later red Source result. Subsequent source cohorts through #150 are
**source reviewed, untested/unbuilt**, with `[skip ci]` commits. Earlier green
checks do not validate them. #97 is declaration **clarity cleanup**, not a
reproduced compiler-failure fix: the old form compiled in the green #77 build. No local validation commands were run for these source changes; earlier automatic
CI results are listed above. No merges or releases were performed.

Default original-iPad builds still bundle shaders. The optional pack route is
bound to installed app metadata and a verified complete seed, has no cancellation
API, and grants no Canopy trust bypass. Both routes need their own Apple/device
results. Neither removal fix has rerun evidence; the recorded red failure is
not relabeled green. The finite source reassessment closed the demonstrated local
array-length dependency and selected specialization-composite contracts in #149
and #150. Bounded app-flow reviews found no additional demonstrated supported
launcher/save/settings/preparation defect after the published corrections. This
is not complete-product acceptance or a blanket vendor audit. General translator
enablement, actual build/parity evidence and physical checks remain outstanding.
There is no registered BOTW provider, active-save Apply or actual TOTK restart
mechanism; their exact blockers remain in the issue ledger.

Continue with [the ordered Mac/iPad handoff](canopy-mac-ipad-checklist.md),
[issue coverage](canopy-issue-coverage.md) and [the development roadmap](canopy-development-roadmap.md).
