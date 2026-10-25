# Canopy inspection app checkpoint

Canopy now has a real read-only NSP/XCI inspector, a persistent iPad inspection
library, and a portable CLI. This checkpoint does not execute games. An inspected
container is never presented as a supported or prepared title.

See [CLI usage](../launcher/README.md), [Apple build recipe](../launcher/apple/README.md)
and the [remaining execution gate](content-free-execution.md). The original
TOTK target, resources and bundle identity are unchanged.

## Implemented behavior

- The CMake-built `canopy inspect FILE` command uses the production bounded
  container parser through a regular-file descriptor adapter. Reads preserve the
  descriptor position and reject observed identity, size or timestamp changes.
  JSON output explicitly reports `execution_verified: false`.
- The UIKit app selects an NSP/XCI file through Files, coordinates read access,
  balances security scope and reads the same parser on a background queue.
  Cancel or background invalidates the pending result. A late provider callback
  cannot add metadata after cancellation.
- The library keeps at most 500 local metadata records in a versioned, bounded
  JSON file. It stores no source URL/bookmark, payload, key or save. Removing a
  record affects only metadata. A corrupt index is preserved and blocks mutation
  until the user explicitly confirms resetting it.
- The separate `.canopy` app uses the approved artwork as an in-app resource.
  It contains only its own host code, parser, plist and PNG. SpringBoard icon
  asset production remains separate; the raw resource is not an Apple asset catalog.
- The builder uses a fixed public input list, snapshots and hashes it, rejects
  changed sources and existing output destinations, and builds an unsigned app.
  The observation JSON is evidence of the build, not independent origin approval.

## Ordered local acceptance

1. Keep the existing TOTK app and private data in place. Use Canopy's distinct
   `org.monkeorg.canopy` identity and a matching local profile if signing this
   separate app. Neither building nor inspecting requires a TOTK save or key.
2. Build from the exact checkpoint with the Apple recipe, or obtain its matching
   unsigned build artifact from the focused Canopy CI run. Check the artifact's
   hashes against the recorded build observation before local signing. Do not
   mistake a ZIP or successful compile for an installed app.
3. Install this separate app only through the authorized local signing workflow.
   Verify cold launch, portrait/landscape layout, Dynamic Type and VoiceOver.
   Confirm the icon is shown in-app; home-screen icon acceptance remains pending.
4. Select a locally retained user-owned NSP/XCI. Verify the reported format,
   source size and entry count against local reference inspection. Relaunch and
   confirm the metadata record persists. The source file must remain unchanged.
5. Cancel Files selection, then cancel an active slow-provider inspection.
   Background/foreground the app during provider access. Require no late record,
   duplicate operation, stuck busy UI or leaked access. Retry with a local file.
6. Remove a metadata record and confirm the source is untouched. On a synthetic
   test install, exercise corrupt/unsupported index recovery, record limits and
   write failure. Confirm unreadable metadata is not silently replaced.
7. Treat native execution, decryption, prepared game generations, shaders,
   per-game settings/saves and multiplayer as the remaining release work. The
   independent original-source permission probe still needs physical execution;
   no imported commercial title is claimed playable by this checkpoint.

Keep local inputs, provider paths, signing material and any later gameplay/save
captures private. No merge or release is part of this checkpoint.

## Verified build and test evidence — 2026-10-25

Source: `e8c5be95d6ff2bc8494bc6da1949e60062f98e42`.

| Check | Observed result |
|---|---|
| Full repository suite on macOS | 431 run, 430 passed, 1 skipped, zero failures/errors; 66.190 seconds |
| Focused Canopy tests on macOS | 27 passed, zero skips/failures/errors |
| Focused Canopy tests on Ubuntu | 27 run, 21 passed, 6 Foundation skips, zero failures/errors |
| Portable suite in Linux workspace | 417 run, 330 passed, 87 skipped, zero failures/errors (before the final Apple-only linkage repairs) |
| CMake CLI builds | Passed on Linux and macOS; actual synthetic NSP command verified on Linux |
| Canopy iPhoneOS app build | Passed, arm64, iOS 16 deployment target, iPhoneOS 18.5 SDK / Xcode 16.4, Apple clang 17.0.0 |
| Original-source rewrite/fixture checks | 14 passed on macOS; isolated unsigned iPhoneOS platform probe compiled |
| Native path/controller sanitizers | Existing full-suite CI UBSan steps passed on macOS |
| Signing, install and device execution | Not performed; physical acceptance remains open |

The sole macOS skip is the physical `A`/`a` two-directory collision fixture,
which cannot exist on that case-insensitive filesystem. Both case and Unicode
inventory-policy rejection assertions still ran. Linux covers the physical
collision case. This does not suppress a product error.

The first Apple runs exposed and fixed Darwin feature-macro visibility,
filesystem-alias assumptions in test fixtures, an ARC NSError-pointer mismatch,
and an explicit CoreGraphics link dependency. Final runs passed after the fixes.

- [Focused builds, tests and downloadable unsigned app](https://github.com/monkeorg/MacNativeGames/actions/runs/40186345633)
- [Full macOS regression run](https://github.com/monkeorg/MacNativeGames/actions/runs/40186345591)
- [Unsigned Canopy artifact](https://github.com/monkeorg/MacNativeGames/actions/runs/40186345633/artifacts/12596163185), retained until 2026-11-01.

The downloaded artifact was inspected separately from the build process. Its
inner ZIP contains exactly `Canopy.app/Canopy`, `Info.plist` and `Canopy.png`.
Every file matches the CI output hash; all eight public source/resource input
hashes match this checkout. The ARM64 executable has no `LC_CODE_SIGNATURE` and
its segment list contains only `__PAGEZERO`, `__TEXT`, `__DATA_CONST`, `__DATA`
and `__LINKEDIT`; there are no embedded guest segments. This verifies inventory
and build identity, not arbitrary content ownership or device execution.

Inner ZIP SHA-256:
`c1f5003d9551a2c8a1b8192a658e597f88bbe619fac5b2e335046b38c275dfc8`.
Executable SHA-256:
`24dfa76a1580cd0fb542244cebaf03a3ba0bb48282c16f31b4342fc7f1815267`.

The app is an unsigned inspection build. Local provisioning/signing and physical
UI/provider/lifecycle acceptance remain necessary. No installation, game launch,
multiplayer session, stable-FPS claim, merge or release occurred in this pass.
