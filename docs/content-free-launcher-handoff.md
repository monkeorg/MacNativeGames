# Content-free launcher: cloud handoff

Issue: [#34](https://github.com/monkeorg/MacNativeGames/issues/34).

## Two tracks

**Track A — existing TOTK app:** continue local integration, telescope correction, visual checks and performance work. Preserve the working installed app, saves, signing identity and private caches. Draft PR #33 remains separate from the redesign. No merges or releases.

**Track B — launcher redesign:** use a separate cloud chat and feature branch. Plan the complete product, create a dependency-ordered roadmap and issues, then implement vertical slices. Do not replace the working TOTK target as an initial design step.

The user requests autonomous work and Sol 6.1 workers at Medium reasoning. They want a large team, up to 20 workers where the runtime supports it. Inspect the real limit. Queue independent work when the limit is lower; never claim workers were spawned when they were not. Do not change global agent configuration or create user-owned chats as substitutes for workers.

## Starting state

- Repository: `monkeorg/MacNativeGames`.
- Integration branch: `feat/ipad-full-settings-overlay`.
- Installed production source: `ecd124ed9079d68dd0590c84f161346a6197ada6`.
- Integration checkpoint: `3f7afd34d7d377f14c28f1221f5cddf86973466a`.
- Telescope source correction: `a6a794a`; not installed or physically accepted yet.
- Start from the commit containing this handoff. Record its full SHA, then create a dedicated redesign branch.

The installed production candidate passed 360 repository tests, 22 iPhoneOS object checks, a full native host build and full Apple build. Nine embedded executable-section hashes matched. It loaded the retained post-tutorial save, and account identity remained byte-identical. Physical test `test06fExistingGameGraphicsAndTouchApplyLive` later passed after the user enabled UI Automation. It exercised FPS choices, TAA request persistence, touch visibility and outside dismissal. Renderer logs also record successful TAA frames. These results do not establish sustained native 1080-high/60 FPS, image quality or complete input acceptance.

Read `CONTRIBUTING.md`, `docs/how-it-works.md`, `docs/ipados-roadmap.md`, `docs/ipados-roadmap-status.md`, `docs/ipados-cloud-audit.md` and `docs/ipados-acceptance.md`. Historical cloud restrictions and results must retain their dates. Do not present old “unbuilt” rows as current state.

Entire returned no recorded session for this chat. This handoff uses verified repository state and local build/device evidence instead.

## Product contract

The public IPA must contain no Nintendo-derived program bytes, assets, translated game shaders, firmware fonts, game icons, keys or saves. The user's private import/cache may contain data derived from their own supplied games. The app still contains our implementation and licensed dependencies; “no Nintendo code” does not mean an executable contains no code.

The desired first-use flow is: select a local game folder and user-supplied inputs → validate → prepare once → show the game in a library → Play. Import progress, cancellation, recovery and storage use must remain clear. Later app updates reuse prepared data without resending or extracting the whole game.

Switch is the current implementation platform. Wii U and other platforms are future roadmap items, outside this cloud build. Different CPU architectures require separate feasibility work. A folder scanner does not establish game compatibility.

Required product areas:

- A redesigned iPad library and onboarding, with clean menus and accessible touch/controller navigation.
- Per-game settings, compatibility status, graphics controls, input mappings and saves.
- A full floating in-game settings overlay, with live settings applied live and startup-only changes explained accurately.
- Private, versioned game data, updates, DLC and shader caches with a documented folder contract.
- Safe save import/export, backup, restore and supported editor workflows.
- Per-game multiplayer capabilities and controller/player assignment. Include a Mario Kart local multiplayer milestone; do not substitute a settings screen for an actual working session.
- Honest performance, memory, thermal and storage diagnostics, plus data-preserving app updates.

**Explicit exclusions:** do not implement a mod manager in this cloud build. [Issue #35](https://github.com/monkeorg/MacNativeGames/issues/35) is backlog only. Do not schedule it as a worker task, dependency or finish gate. Wii U and other console backends also remain future roadmap items.

Native/recompiled execution is the requested direction. Do not silently substitute a CPU emulator, streamed game or mock runtime and declare the goal complete.

## Architecture facts and first gate

The current project rewrites original ARM64 machine code ahead of time. It does not recover the original C/C++ source. `ios/tools/gen_embed.py` embeds rewritten game modules in signed executable sections; `runtime/loader.c` requires those sections. Current game-derived shader libraries, layouts, fonts and icons are also packaged. External RomFS alone is therefore insufficient for a clean public artifact.

`build_ipa.py --image-outside` and top-level `--ios-game-data documents` already separate the largest image. The supported installer transfers chunks once; runtime verification checks the complete image. This can reduce the current logical package from about 17.62 GiB to 1.74 GiB. It is an interim efficiency improvement, not the final content-free architecture.

NSP import, update merging and shader preparation are separate from executable loading. Existing extraction scripts depend on host Python/native tools. iOS runtime shader translation is disabled. Audit these paths before designing their native replacements.

The first milestone must prove an execution path for one exact supported title/version with a content-free public app. Investigate platform code-signing, permissions, native loading and any Mac-assisted preparation requirement. Label every unverified path. Do not promise that adding a JIT entitlement or decrypting an NSP makes arbitrary games executable. The current CONTRIBUTING policy excludes CPU emulation/JIT. Document any proposed policy change explicitly; keep Track A intact. The user's redesign request authorizes investigation, not false claims about feasibility.

A Mac-assisted private build/sign workflow may be an intermediate result. It does not satisfy standalone on-iPad setup. An interpreter/emulator fallback also does not satisfy the requested native/recompiled product without a new user decision.

## Plan, then implement

First publish a concise architecture decision, a complete requirement matrix, a dependency-ordered roadmap and GitHub issues. Link them from #34. Use outcome-based milestones, explicit supported games/versions and actual finish gates. Do not scope “all games” to whatever happens to work.

Then implement the execution proof and one complete import-to-gameplay slice. Expand the product in the roadmap order. Reuse verified runtime and parser code where appropriate; do not duplicate whole engines just to support a second UI.

Suggested independent work packages, dispatched only when their dependencies permit:

| Package | Ownership |
|---|---|
| 1 | Native execution feasibility and proof |
| 2 | iPadOS code-signing and permission contract |
| 3 | Rewriter, relocation and game-profile boundaries |
| 4 | Shader extraction, translation and caching |
| 5 | Bounded NSP parsing and decryption |
| 6 | Update/DLC merge and version identity |
| 7 | Library index, folder discovery and persistence |
| 8 | Atomic preparation, recovery and storage management |
| 9 | App navigation, onboarding and design system |
| 10 | Game library UI and compatibility presentation |
| 11 | Per-game settings and full in-game overlay |
| 12 | Graphics capabilities and performance diagnostics |
| 13 | Input, mappings and controller assignment |
| 14 | Per-game multiplayer, including Mario Kart |
| 15 | Saves, backups, transfers and editor integration |
| 16 | Local Apple build/device acceptance handoff |
| 17 | Public artifact provenance and content audit |
| 18 | Meaningful portable regression checks and CI |
| 19 | Requirement matrix, roadmap and status records |
| 20 | Independent integration and adversarial review |

The lead assigns distinct file ownership or isolated branches. Share interfaces before dependent edits. Keep commits reviewable and PRs focused. Run checks appropriate to the changed code. Do not maintain 20 active workers when the work has only a few independent tasks.

## Cloud boundary

The cloud does not have this Mac's Xcode, iPad, signing material, private originals, keys, saves or shader caches. Never upload them to the cloud or Git. Use synthetic parser inputs and nonproprietary execution fixtures for portable checks. Public metadata and source references do not prove gameplay compatibility.

Run available meaningful checks. Record unavailable Apple compilation and device checks explicitly. Prepare exact local build commands and ordered physical acceptance scripts. Cloud-only completion cannot establish an installed, content-free, working iPad product.

Do not merge, release, revoke certificates, migrate private data or change the working app identity. Do not wait for permission for routine reversible code work already within this scope. If a platform boundary blocks one task, continue independent roadmap work and preserve a reviewable checkpoint.

## Goal loop and completion

Maintain `.goal-task/content-free-launcher/state.md` with the exact goal, current branch/SHA, requirement evidence, dependency graph, active ownership, completed checks and external gates. Keep this record small; link detailed artifacts.

Loop: audit requirements and latest state → select independent unblocked tasks → implement → review → run meaningful checks → fix failures → integrate → publish a checkpoint → update evidence. Resolve discovered defects; do not stop after a plan, mockup or scaffold.

Finish only when the current Switch release roadmap is implemented and every in-scope requirement has matching evidence: a content-free public artifact; supported user-owned import/setup; actual gameplay; per-game settings/saves; supported multiplayer; safe failure recovery; efficient updates; and Apple/device acceptance. The future mod manager and future console backends are excluded from this finish gate. Record them as backlog; do not implement placeholders for them.

If hardware, private inputs or a genuinely unsupported execution path is the only remaining gate, finish independent work and report the exact dependency. Do not mark the product complete, fabricate results, run empty retry loops or weaken acceptance criteria.
