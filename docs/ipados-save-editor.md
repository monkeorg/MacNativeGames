# Optional iPad save-value editor: prerequisite review

Issue: [#7 — optional version-validated save-value editor](https://github.com/monkeorg/MacNativeGames/issues/7).

Review date: 2026-10-24. Source reviewed at `236930c`, including the save-transfer change `b10f4b8`. The initial logical target is the **rupee-wallet value only**; positions, world state, quests and inventory are excluded from the first slice. The editor is **blocked before implementation** because the repository does not establish a supported format and integrity contract for saves written by TOTK 1.4.3. No editor or new write path has been added.

This was a manual source review. No tests, compilers, probes, simulators, game launches, private-save downloads, or device operations were run, following the current instruction not to run tests or simulators. Earlier physical transfer results do not validate an editor.

## What the repository establishes

| Evidence | What it supports | What it does not establish |
|---|---|---|
| [`save_store.m:134`](../games/totk/ios/Sources/save_store.m#L134), `validate` | Slot names `slot_00` through `slot_05`; four required nonempty regular files; rejection of a top-level `account.uid`. | Save contents, save-format version, valid field values, checksums, or game compatibility. |
| [`save_store.m:39`](../games/totk/ios/Sources/save_store.m#L39), `copyDirectory` | Opaque copying with link/type checks, entry/depth/size limits, file-size/mtime checks and post-enumeration directory metadata checks. | A parser, field edit, semantic validator, or filesystem-wide snapshot against arbitrary concurrent changes. |
| [`save_position.py:2`](../games/totk/scripts/diag/save_position.py#L2), older diagnostic position editor | Two explicitly admitted older `progress.sav` layouts: TOTK 1.0.0 and 1.1.2/1.2.1. `locate_all` checks the size/header pair and locates two position vectors through tags and bounded aligned pointers. The CLI requires a different output path and finite coordinates within its diagnostic limits. | Support for a save newly written by 1.4.3, an approved iPad field list, or a complete save integrity specification. |
| [`stage_test_profile.py:2`](../games/totk/scripts/stage_test_profile.py#L2) | An older-layout diagnostic copy that 1.4.3 can migrate when loading. It explicitly says it does not assume a layout for newly written saves. Lines 43–60 validate those old inputs, copy the profile, restrict differences to the two vectors, and compare the source manifest. | A native 1.4.3 editor. Loading a migrated older save does not validate editing the format subsequently written by 1.4.3. |
| [`v1.2.1-port.md:112`](v1.2.1-port.md#L112) | The recorded observation that 1.4.3-written saves use a different header and that older 1.2.1 cannot read 1.4.3-written progress. | Field offsets, file length, integrity algorithm, or a sufficient acceptance rule for that new layout. A header observation alone is insufficient. |
| [`expected-v1.4.3.json:2`](../games/totk/assets/expected-v1.4.3.json#L2) and [`game_version.h:42`](../games/totk/runtime/game_version.h#L42) | Game source/rewrite/RomFS identity and the compiled game version. | The version or validity of a user-selected save; the running game can load older saves. |
| [`ios_save_store_probe.m:42`](../tests/ios_save_store_probe.m#L42) | Synthetic strings and binary bytes for transfer equality and refusal scenarios. | Parseable 1.4.3 save-format fixtures or evidence that an edited save loads. |

The existing diagnostic editor means the repository is not entirely opaque about older saves. Its explicit version boundary must remain intact. Do not expand its admitted size/header set, reuse its hashes or vector assumptions for 1.4.3, or infer a new layout from the app version.

The reviewed save-related sources and tests provide no documented 1.4.3 field schema, integrity validation/update routine, or nonprivate format fixtures for an editor. No conclusion is made about undocumented private material or external tools.

## Inputs required before implementation

1. **Establish a 1.4.3 save-format contract.** Supply an independently documented, legally usable description of version discrimination, structure, rupee-wallet field lookup/encoding, lengths and bounds. Establish the field's type, legal range, dependent values and unsupported combinations from that verified contract. No offset, encoding, numeric range or integrity behavior is claimed here. The contract must explain how unsupported, truncated, duplicate or ambiguous records are refused. Identify its provenance and license before using third-party material; do not copy GPL implementation code into this MIT repository.
2. **Establish integrity requirements.** Document every affected checksum, digest, redundant value and cross-file relationship, with validation and update rules. If a rupee-wallet edit requires no integrity changes, provide evidence for that conclusion. A byte-difference report or a plausible value alone is insufficient.
3. **Provide nonprivate fixtures derived from that contract.** Use synthetic data with expected parsed values, expected permitted byte changes and documented integrity outcomes. Include unsupported versions, malformed structures, contract-defined boundary values and inconsistent dependent records. Do not commit real saves, account identifiers or game content. A synthetic transfer folder is not a save-format fixture.
4. **Arrange physical acceptance on the existing private setup.** Preserve the immediate original save and account identity. After the format and implementation are reviewed, retain the exact build/game version and private evidence that the supported rupee-wallet edit loads correctly and that restoration recovers the original. Do not enable the editor by default before a successful physical save load. Current device access and permission to run validation are separate prerequisites.

The first two inputs define what can safely be implemented; fixture work and field limits depend on that verified contract. The logical field selection is settled and is not an external blocker. Guessing offsets, adding unvalidated numeric controls, or implementing a write-only parser would leave the format and integrity prerequisites unresolved.

## Safety contract for a future implementation

The editor must remain optional and unavailable after Play. The Play handler's [`sealForPlay` call](../games/totk/ios/Sources/launcher.m#L224) seals the store before starting the game, and [`save_store.m:164`](../games/totk/ios/Sources/save_store.m#L164) checks that state for transfers. A future editing operation must use the same exclusion so editing cannot overlap Play or another save operation.

Keep a complete original backup before edits and change only a private stage. Validate the supported save version and all selected fields before writing, enforce field and transfer limits, update only documented dependencies/integrity data, and revalidate the completed stage. Publish through the existing validated replacement boundary or an equally reviewed extension; never patch the active save in place. [`save_store.m:189`](../games/totk/ios/Sources/save_store.m#L189) stages a complete incoming folder, validates it, backs up the current directory and uses same-volume atomic replacement. Parser validation is an additional requirement; current folder validation cannot substitute for it.

Preserve unrelated slot files, album/storage content and unknown bytes. Keep `account.uid` outside the replaced directory. Failures before publication must leave the active save unchanged, and the original backup must remain available for recovery. Permission, provider, parse, validation, integrity, storage and publication failures need explicit outcomes before the feature can be enabled.

## Save-transfer review boundary

The existing transfer path remains appropriate for opaque round trips. Imports coordinate provider reads and balance successful security-scope access in [`confirmImport`](../games/totk/ios/Sources/launcher.m#L315); copying or coordination failure does not reach the replacement step. The documented limits remain 64 MiB per file, 512 MiB total, 10,000 entries and 12 directory levels. The previous physical results in [the baseline](ipados-baseline.md#launcher-candidate-checks) belong to their recorded revision.

Manual review found no concrete compile-hook defect in `b10f4b8`: [`test_ios_save_store.py:23`](../tests/test_ios_save_store.py#L23) includes `dirent.h` before defining the wrapper macro and applies it only to `save_store.o`. [`ios_save_store_probe.m:18`](../tests/ios_save_store_probe.m#L18) defines that wrapper in a separate translation unit and calls real `readdir`, avoiding recursive redirection. The hook is not part of the production app build. Apple compilation and execution remain unverified in this review.

The directory metadata check in [`save_store.m:99`](../games/totk/ios/Sources/save_store.m#L99) rejects detectable membership changes during that directory's traversal. It does not freeze already-read files or provide a transaction across an external provider. Keep the existing instruction not to modify saves during transfers or gameplay; do not represent this check as a save-format integrity validator.

Issue #7 remains blocked on the 1.4.3 format/integrity evidence and contract-derived fixtures above; enabling it also requires physical load and recovery evidence. Issue #3's latest Apple build, provider failures and physical transfer/load acceptance remain separate from this prerequisite review.
