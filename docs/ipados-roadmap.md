# iPad adaptation roadmap

Target: TOTK 1.4.3 on an M4 iPad Pro, with a persistent pre-launch menu, save transfers, Mac feature parity where supported, and native 60 FPS at 1080-high full-aspect output. Performance is unverified. The intended 4:3 render size is 1440×1080; use the actual display aspect when it differs.

Roadmap: https://github.com/monkeorg/MacNativeGames/issues/9

## Delivery sequence

1. [Establish TOTK 1.4.3 iPad baseline and repeatable benchmark](https://github.com/monkeorg/MacNativeGames/issues/1)
2. [Add persistent pre-launch menu on iPad](https://github.com/monkeorg/MacNativeGames/issues/2)
3. [Add safe save import, export, backup, and restore](https://github.com/monkeorg/MacNativeGames/issues/3)
4. [Adapt resolution and camera aspect to 1440×1080 on iPad](https://github.com/monkeorg/MacNativeGames/issues/4)
5. [Adapt Mac controls and mouse input for iPad](https://github.com/monkeorg/MacNativeGames/issues/5)
6. [Adapt remaining Mac graphics settings and validate stable 60 FPS](https://github.com/monkeorg/MacNativeGames/issues/6)
7. [Add optional version-validated save-value editor](https://github.com/monkeorg/MacNativeGames/issues/7)
8. [Assess a separate BOTW iPad port](https://github.com/monkeorg/MacNativeGames/issues/8)

## Decisions and reasons

- Extend the working MacNativeGames fork. It already launches on the target iPad; replacing it would discard that baseline.
- Deliver the launcher and safe save transfers first. These features improve use without requiring speculative renderer changes.
- Reuse existing runtime, settings, build checks, and diagnostics. Add abstractions only for demonstrated duplication.
- Compare OJZen/totk-mobile as a reference. Verify code compatibility and licensing before reuse. Its published iPad limitations do not establish our device's performance.
- Apply instruction patches before signing, from verified original modules. Persist runtime preferences separately from signed code.
- Preserve Mac behavior. Build and test affected platforms and game versions as CONTRIBUTING.md requires.
- Save import/export is distinct from save-value editing. A validated backup and atomic replacement come before field editing.
- A 60 FPS target is not a result. Measure rendered frames separately from presentation and interpolation.
- Keep BOTW outside the TOTK delivery milestone.

## Acceptance

The first milestone requires persistent settings, deferred game startup, save round-trip verification, rollback checks, and a physical-device save load. Use fixture data for automated tests. Do not commit private saves.

Graphics acceptance requires correct projection and UI at the actual iPad aspect. Resizing the drawable or stretching 16:9 does not qualify. Native performance acceptance needs a repeatable scene set, warm shader-cache state, and a sustained 30-minute session. Agree numerical stability thresholds before claiming stable 60 FPS.

Record commit, game version, device model, OS, render and output sizes, frame times, memory, and thermal state. Label build, installation, launch, and gameplay verification separately. Document blocked hardware checks without inventing results.

## Local build continuity

Checkout: `/Users/philipp/Developer/MacNativeGames`.

Existing work: `/Users/philipp/Downloads/iPad-Feather-TOTK/TOTK_build`.

Keep the original inputs, extracted data, generated modules, iOS dependencies, shader caches, and Xcode incremental cache. Prefer `.app` output rather than a separate large IPA. The redundant unsigned IPA and duplicate ZIP inputs were removed; consult the task folder README for retained paths. The historical `install-verified.py` assumes the removed IPA path and needs adjustment before reuse.

The existing `--ios-game-data documents` build option can reduce repeated transfers after a verified one-time migration. Back up saves before migration. Preserve the current bundle identity and signing team; read their private local configuration rather than publishing it.

Do not perform general laptop cleanup. Other work owns that scope.

## Codex goal prompt: first milestone

Use the following text as the goal body in Codex. This document does not activate a goal.

```text
Implement the first iPad milestone in monkeorg/MacNativeGames:
https://github.com/monkeorg/MacNativeGames/milestone/1

Work in /Users/philipp/Developer/MacNativeGames. Read AGENTS.md, CONTRIBUTING.md, docs/ipados-roadmap.md, and issues #1–#3. Check the current checkout and device state before changes. Preserve unrelated local work.

Use the existing native TOTK 1.4.3 port. Deliver a persistent pre-launch menu with Play, implemented settings, and safe save import/export, backup, and restore. Defer game startup until Play. Validate incoming saves before replacement; preserve account identity; back up and stage changes atomically. Disallow save replacement after the game starts.

Reuse /Users/philipp/Downloads/iPad-Feather-TOTK/TOTK_build and its caches. Prefer .app output. Back up device saves before installation. Preserve the installed bundle identity and team. Never commit game data, keys, signing material, device identifiers, or saves. Do not clean unrelated laptop storage.

Use focused branches and one-topic PRs. Run repository tests and relevant builds. Verify relaunch, lifecycle behavior, save round-trip equality, failed-import rollback, and a physical-device save load. Report unavailable device checks as blocked; do not mark issues complete without their acceptance evidence. Update issues with concise results and attach PRs to this chat.

Stop this milestone at verified launcher and save-management delivery. Leave graphics parity, 1080-high/60 FPS, mouse input, save-value editing, and BOTW to their linked issues. Distinguish implemented, tested, installed, and gameplay-verified states in the final report.
```
