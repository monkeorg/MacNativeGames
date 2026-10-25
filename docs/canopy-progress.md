# Canopy · development update

**FOSS native game launcher · source development continues**
Source through [#100](https://github.com/monkeorg/MacNativeGames/pull/100),
[`62dd868`](https://github.com/monkeorg/MacNativeGames/commit/62dd868c5e66d830ca1f5973462c4725a56aa759),
on `feat/canopy-shader-removal-recovery`.
Source review, Apple compilation and physical acceptance are separate. The current
`/goal` runs no new tests or probes; the results below are recorded evidence.

**Later compiler source:** dependent drafts [#102](https://github.com/monkeorg/MacNativeGames/pull/102)–[#109](https://github.com/monkeorg/MacNativeGames/pull/109)
extend the same pinned compiler with loop quotas and recursion guards. At
[`2408740`](https://github.com/monkeorg/MacNativeGames/commit/2408740f8546a7f8a0ccd8a3d284db10e3f619c4),
Cross has 429 loop checkpoints (72 formerly unbraced); 90 raw loop sites remain (10 fixed, 80
input-dependent or unproven). Each slice has two independent source reviews.
These are unbuilt, untested source changes; runtime translation remains disabled.
The app feature snapshot and recorded CI below still refer to their exact revisions.

**Library correction:** [#110 / `73bb8db`](https://github.com/monkeorg/MacNativeGames/pull/110)
keeps the friendly game name visible after the first settings change. Other
custom names retain priority; an exact title-ID name uses the default fallback
because legacy metadata has no name-origin flag. No metadata is rewritten.
Independently source-reviewed; unbuilt and untested.

[#111 / `c6f1502`](https://github.com/monkeorg/MacNativeGames/pull/111) then charges
seven traversal-wrapper loops whose recursive callees already have depth guards:
436 checkpoints,79 formerly unbraced,83 raw sites (10 fixed/73 pending).
Two independent source reviews; no tests, probes or builds; runtime stays off.

**Later app corrections:** [#119 / `b136283`](https://github.com/monkeorg/MacNativeGames/pull/119)
also resolves the current friendly/custom name for the session title without
changing its runtime entry. [#120 / `6c06d9a`](https://github.com/monkeorg/MacNativeGames/pull/120)
expires stale storage confirmations/resume intent across scene/background/navigation
changes. [#122 / `2c3f23e`](https://github.com/monkeorg/MacNativeGames/pull/122)
does the same for save dialogs and queued exports while keeping accepted Files
export data until the exact picker finishes. Each lifecycle correction has two
independent source reviews; all remain unbuilt/untested.

Compiler drafts through [#121 / `5a95607`](https://github.com/monkeorg/MacNativeGames/pull/121)
add checked interface offsets, recursive interface/packing guards and further
iteration accounting: **457 checkpoints, 100 formerly unbraced, 62 raw sites
(12 fixed, 50 pending)**. These counts are an inventory, not a safety percentage.
Runtime translation remains disabled; source assessment continues.

**Parser/resource follow-ups through [#133 / `2468ba0`](https://github.com/monkeorg/MacNativeGames/pull/133):**
checked null-constant planning, array queries and resource-binding arithmetic;
normal emission/metadata iteration limits; precharges before amplified type
copies; and three direct self-alias replacement refusals. Current recorded
inventory is **485 checkpoints, 128 formerly unbraced, 34 raw sites
(13 fixed, 21 pending)**. The capacity planner has its own source-proven bounded
loop, excluded from that inventory. Every compiler slice has at least two
independent source reviews; #132 has three. All are source-only and unbuilt;
no new tests, probes or compiler runs. Runtime translation remains disabled.

| Area | Current source | Remaining acceptance / work |
|---|---|---|
| 📚 Library & preparation | Multiple titles, versions, NSP/XCI and supported folders; updates/add-ons; selected-title verified reuse | Real private inputs, provider failures and large-library/device checks; preparation grants no execution capability |
| 🛡 Saves & identity | Isolated profiles/accounts, backup/export/import and pre-Play seals; explicit label-only recovery API and confirmation UI | Current-build transfer/recovery checks; preserve identity and existing saves |
| ✎ SaveEditor · #7 | **Active:** TOTK reference-family rupee preview and explicit raw candidate share; Canopy source reviewed | No active Apply until an exact format/integrity contract exists; candidate integrity, checksum and game compatibility remain unverified. Both original iPad and Canopy candidate-share callers are committed; exact format/integrity and physical acceptance remain open |
| 🎮 Input & accessibility | Real controller/keyboard/mouse/touch routing, modal capture; reviewed focus-owned VoiceOver analog actions and bounded preparation announcements | Physical models, pointer-lock, focus/rotation and VoiceOver interaction; four seats do not establish multiplayer TOTK/Mario Kart support |
| ⚙ Display & settings | Supported live controls, System language; immutable startup projection with presentation-only layout updates and incompatible-4:3 capture | New Apple results, physical visual/input checks and actual rendered-resolution evidence; experimental quality presets remain off |
| ⚡ Storage & reuse | Mac-tested copy-on-write reuse including growth/shrink; inode/lease-bound retirement recovery; nonmutating preflight correction source-fixed in #99 | Later Source run is **red** on hardlink refusal preserving the canonical namespace; new-request full-tree preflight is source-fixed, **not rerun**. Logical counters are not physical space savings |
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

These focused drafts depend on their predecessors. #77 has the green evidence
above; #85 has the later red Source result. Subsequent cohorts through #100 are
**source reviewed, untested/unbuilt**, with `[skip ci]` commits. Earlier green
checks do not validate them. #97 is declaration **clarity cleanup**, not a
reproduced compiler-failure fix: the old form compiled in the green #77 build. No local validation commands were run for these source changes; earlier automatic
CI results are listed above. No merges or releases were performed.

Default original-iPad builds still bundle shaders. The optional pack route is
bound to installed app metadata and a verified complete seed, has no cancellation
API, and grants no Canopy trust bypass. Both routes need their own Apple/device
results. Neither removal fix has rerun evidence; the recorded red failure is
not relabeled green. Bounded compiler source assessment continues across the
21 input-dependent or unproven loop sites (34 raw including 13 fixed), other
recursion and noexcept boundaries at #133.
This identifies coverage work, not a newly demonstrated broken app flow; it is
not a claim that all cloud work is complete. There is no
registered BOTW provider, active-save Apply or actual TOTK restart mechanism.

Continue with [the ordered Mac/iPad handoff](canopy-mac-ipad-checklist.md),
[issue coverage](canopy-issue-coverage.md) and [the development roadmap](canopy-development-roadmap.md).
