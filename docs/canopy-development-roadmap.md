# Canopy: complete cloud development roadmap

Parent: [#34](https://github.com/monkeorg/MacNativeGames/issues/34).
Revised direction: 2026-10-25, following the user's explicit request to finish all
work possible here, including reviewed Apple source that cannot yet be exercised
on the local Mac/iPad. This supersedes earlier sequencing that deferred library,
settings, saves or preparation implementation until native iPad gameplay.

## What this goal must deliver

Implement the current Switch launcher across its whole development surface:
user-owned NSP/game-folder inputs → private validated asset preparation → a
multi-game library → per-game configuration and saves → native runtime/session
integration, including input, graphics, overlay, diagnostics and multiplayer
infrastructure. Keep unsupported execution visibly unavailable. Preserve the
separate working TOTK track.

The existing inspection app is a starting component, not this deliverable.
As of `6a273f8`, it has no NCA decryption, ExeFS/RomFS extraction, prepared-game
store, per-game settings/runtime integration or supported multiplayer session.
Existing Mac/iPhoneOS builds and native synthetic Mac calls do not change that.

Two finish lines must stay separate:

- **Cloud development handoff:** every implementable work item has concrete code
  connected to its real caller and consumer, appropriate review and available
  checks. Unverified Apple paths may be implemented and handed off explicitly
  as source-only. Each remaining external dependency has exact evidence, affected
  code and an executable local verification step. No independent TODO remains.
- **Product acceptance:** content-free signed public artifact, real on-device
  import/preparation/gameplay, exact supported titles, visual/input/save/recovery
  correctness, efficient updates and a real Mario Kart multiplayer session.
  This cannot be claimed from cloud tests or unverified source.

Device absence, lack of private inputs and unresolved iPad executable permission
are not blanket reasons to stop independent source development. Difficult or
lengthy implementation is not an external blocker. Conversely, accepting blind
coding does not authorize inventing title addresses, checked original words,
save formats, credentials, compatibility claims or passing test results.

## Development workstreams

These are required outcomes, not optional ideas. Reuse the existing code and
pins; port host tooling into native app-callable components instead of wrapping
Python/subprocesses that cannot run in the shipping iPad app.

| ID / issue | Required implementation | Depends on | Development evidence |
|---|---|---|---|
| D0 / #34 | Versioned title/version/profile identity, prepared manifest, job/session contracts, capability and evidence states | Current parser/audit | Reviewed schemas, migration/refusal tests; identified ≠ prepared ≠ executable |
| D1 / #36 | Native NCA headers/sections, local key-provider, key-area/common-ticket decryption and bounded reads | D0 | Standard crypto vectors and synthetic encrypted inputs; wrong keys, truncation, overflow and unsupported layouts refused; no keys in logs/manifests |
| D2 / #36 | Actual ExeFS and RomFS asset production into private folders; stream integrity checks, progress and cancellation | D1 + D3 | Byte-checked synthetic extraction to disk, corruption/short-read/cancel tests; encrypted NCA copies do not qualify |
| D3 / #39 | Immutable prepared generations, staging, verification, atomic publication, recovery/resume, low-space handling, rollback and safe garbage collection | D0 | Fault injection at copy/verify/publish boundaries; old generation and saves preserved; real filesystem operations |
| D4 / #36, #41 | Base/update/DLC identity and dependency checks; supported update composition and version selection | D0–D3 | Synthetic matching/mismatch cases; explicit unsupported delta refusal; never mix incompatible versions silently |
| D5 / #37 | Multi-game library backed by real imported/prepared records, folder discovery, onboarding, progress/cancel/recovery and storage management | D0 + D3; D2 for preparation | Integrate actual preparation jobs; migrate inspection history without loss; independent title data tested |
| D6 / #37 | Per-game graphics/input/language settings, validation/migration, capability model, live/startup application semantics and full floating overlay | D0 + D5; D8 for runtime application | Per-title isolation tests, actual backend callbacks and state handling; source/build checks now, physical UI later |
| D7 / #37 | Safe per-title/profile save export/import, backup/restore, account identity separation, session sealing and rollback | D0 + D3; D8 for session state | Byte-preserving synthetic round trips/failure tests; title-specific validators; no guessed semantic editing |
| D8 / #38 | Real runtime/session adapter to existing native loader/rewriter/services/Metal paths; prepared-path binding, startup errors, lifecycle, teardown/relaunch semantics and production-loader harness | D0; D2/D3 for prepared input | Native original-source fixtures, real host integration and Apple compilation where available; a stub backend does not count |
| D9 / #40 | Independent physical-device snapshots, mappings, player assignment and guest controller routing; disconnect/focus/overlay handling | D0 + D8 | Distinct simultaneous-player synthetic inputs, disconnect/reassign/cancel tests; preserve existing TOTK/Mac behavior |
| D10 / #41 | Private shader preparation integration, recipe/content/device cache identity, invalidation, cache recovery and storage controls | D0 + D2 + D8 | Actual translator/preparation paths where available; synthetic cache/reuse tests; no game shader payload in public app |
| D11 / #40 | Per-game multiplayer capabilities and required native services; Mario Kart profile/integration to extent supported by available source/contracts | D8 + D9 | Real service/routing code and synthetic/native fixtures; exact-version/private/device gaps named; assignment UI alone is not multiplayer |
| D12 / #39, #41 | Efficient app/content updates, migrations, chunk/reuse planning, generation retention and rollback | D3 + D4 + D10 | Measured synthetic copied/reused bytes, interrupted-update recovery, no save/identity loss |
| D13 / #37, #41 | Honest preparation/storage/runtime diagnostics, redacted export, memory/thermal hooks and performance instrumentation integration | D3 + D8 | Real measured values and bounded logs; no synthetic gameplay FPS or present-count substitution |
| D14 / #34 | Full integration, native UI/accessibility polish, provenance checks, build packaging and exact Mac/iPad acceptance debt | Continuous | End-to-end synthetic import→assets→library→settings/save/session paths; clean Apple builds where possible; reviewed artifact inventory |

Every row needs production implementation and integration. Interfaces, mock
screens, fixture-only paths and disabled settings do not satisfy a row. A
supported-format refusal is correct error handling, not completion of the
required format's implementation. Missing title-specific evidence is recorded
at that sub-item; unrelated rows continue.

## Native preparation and storage contract

- Adapt the existing `extract_exefs.py`, `extract_romfs.py`, update verification,
  version pins and save transaction semantics. Do not duplicate whole runtimes
  or copy emulator services. Preserve license/notice requirements.
- Use standard cryptographic primitives behind a small native interface (Apple
  CommonCrypto and a portable test provider such as OpenSSL are available
  candidates). Do not write a new AES implementation. Keep supplied keys local
  and transient; synthetic tests use invented keys and public test vectors.
- Stream large data with checked arithmetic and explicit count, memory, depth,
  file-size and disk-space limits. Hash-chain integrity is not RSA authenticity;
  declare exactly which checks ran and retain known-title input pins.
- Separate title/version identity, source identity, recipe fingerprint, prepared
  generation, cache compatibility and executable capability. An extracted
  folder must not become playable through a boolean inferred from extraction.
- Stage into private per-title/version generations. Verify before publishing;
  retain previous usable generations. Account identity, active saves and backups
  live outside generation/cache deletion. No generic cleanup may traverse them.
- Reuse prepared content across app updates by verified content/recipe identity.
  Do not silently overwrite caches or recopy whole games because the app changed.
- Source/private preparation may contain the user's derived assets. The public
  app must contain none of their code, shaders, fonts, artwork, keys or saves.

## Parallel execution batches

Agree shared interfaces first; root owns integration, shared schema changes and
build-source allowlists. Assign concrete files before starting workers. The
current runtime supports seven agents including root; queue extra tasks instead
of inventing twenty active workers. Use gpt-6.1-sol Medium.

1. **Foundations:** native import/crypto; title/update metadata; generation storage;
   runtime adapter/harness audit; shader integration; library/settings source.
   Keep writers on distinct modules. Reserve reviewers as artifacts become ready.
2. **Connected features:** actual asset extraction/composition; prepared-library
   integration; saves; independent input/players; graphics/settings application;
   cancellation/recovery/diagnostics. Reuse completed workers for review.
3. **Close development gaps:** multiplayer/service integration; update/cache reuse;
   migrations; Apple integration fixes; end-to-end/adversarial checks; final
   provenance, packaging and handoff. Reassess the entire matrix after each batch.

These are scheduling waves, not gates that force all tasks in one wave to wait
for another blocked task. Move work forward as soon as its own interface exists.

## Review and verification

Use one independent reviewer for routine behavior and two for cryptography,
untrusted parsing, executable loading, destructive storage and save replacement.
Authors cannot approve their own work. Fix substantive findings and re-review
changed risky behavior. Do not add ceremonial review rounds after clean results.

Available checks include the portable suite, focused Canopy/launcher suites,
CMake CLI builds, macOS Foundation checks and public GitHub macOS/iPhoneOS builds.
Use them. The current baseline passed 431 macOS tests with one filesystem skip,
27 Canopy tests on Mac, iPhoneOS compilation and 20,000 original-source native
Mac calls. These do not validate future changes automatically.

For each requirement record separately: implemented, independently reviewed,
compiled, synthetically exercised, private-input verified and device accepted.
Native UI needs real functional/visual/accessibility acceptance later; a browser
mockup or source screenshot is not evidence of UIKit behavior. No simulator
setup is part of this workflow. The user's source-only authorization permits
writing/reviewing the real Apple UI and adapters before that later acceptance.

## Persistence and stop rules

Maintain `.goal-task/content-free-launcher/state.md` as the recovery entrypoint
and `todo.md` as the executable task list. Checkpoint with focused commits/draft
PRs and issue evidence; a published checkpoint never ends the goal by itself.
Continue after plans, successful builds, partial apps and individual blockers.

Defer one item only after bounded diagnosis/retries or a precise unavailable
external contract. Record its blocker, completed independent work and exact next
verification. A retry limit is scheduling only; it never turns a fixable code
defect into an external blocker or waives its completion gate. Pick another
task immediately. Overall blocked is valid only when
no meaningful remaining development task can proceed; verify this across three
successive goal turns rather than repeating one global signing blocker.

Never describe the app, roadmap or release as complete when only an inspection
slice or a screen exists. At the cloud handoff, enumerate actual source gaps and
validation debt. Product/gameplay acceptance remains open until the separate
physical/private-input evidence exists.

## Scope boundaries

Current platform: Switch. Preserve the native/recompiled direction and existing
working TOTK track. Required multiplayer includes Mario Kart; supporting one
title never proves arbitrary-game compatibility. Exclude the mod manager, Wii U
and future console backends. Semantic save-value editing stays disabled for any
unvalidated format. No private game uploads, automatic merges or releases.
