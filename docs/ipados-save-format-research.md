# Public evidence for a TOTK rupee-wallet editor

Reviewed 2026-10-25 for [issue #7](https://github.com/monkeorg/MacNativeGames/issues/7), starting from repository revision `39da158`. This extends the [local prerequisite review](ipados-save-editor.md). Public source establishes a useful **1.4.x format candidate and wallet encoding**. It does not establish a complete, independently validated integrity contract for saves written by **1.4.3**. The in-app editor remains blocked; no parser, editor or write path is enabled by this document.

The narrower conclusion is actionable: an offline, explicitly experimental 1.4.x-family reader and separate-copy candidate writer can be source-implemented from the evidence below without inventing offsets. Such implementation is distinct from declaring saves valid, claiming exact 1.4.3 support, or enabling production editing. Integrity and physical acceptance remain gates for use on real saves.

Only public repository source, documentation, commit metadata and issue text were inspected through the connected GitHub tools. No tests, builds, probes, simulators, public/private save downloads, game-content downloads, game launches or device operations ran. Links to save attachments encountered in discussions were not followed. No third-party implementation was copied into this repository.

## Primary source and license

The primary reference is Marc Robledo's `savegame-editors`, pinned to commit [`450752f98876755944ea22eb457f4dc1468d79ea`](https://github.com/marcrobledo/savegame-editors/commit/450752f98876755944ea22eb457f4dc1468d79ea). Its [LICENSE at that revision](https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/LICENSE) is MIT. Reading its source therefore identifies an available permissively licensed reference, rather than a need to copy GPL implementation. Any future import of code or substantial portions still needs attribution and the repository's third-party notice process. This research document records facts and source behavior, not an imported library.

Relevant immutable sources:

- [Main TOTK editor](https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/zelda-totk/zelda-totk.js): version table at lines 21–24, wallet identity at line 31, scalar accessors, `_getOffsets`, `checkValidSavegame`, numeric range and `save`.
- [Variable/table reader](https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/zelda-totk/zelda-totk.variables.js#L753): `findHashTableEnd` and the surrounding table-boundary explanation.
- [Generic editor/file helper](https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/savegame-editor.js): `MarcFile` read/write/save helpers at line 11 and `saveChanges` at lines 214–220.
- [Initial 1.4 support commit, `16e1bf85ec479439232d7e97d6f7e8dc8f81a1a6`](https://github.com/marcrobledo/savegame-editors/commit/16e1bf85ec479439232d7e97d6f7e8dc8f81a1a6): adds the size/header/metadata tuple labeled `v1.4.0` on 2025-06-13.
- [Label change, `32b807da13ef8fcd4d31788eb145d616c54c04e4`](https://github.com/marcrobledo/savegame-editors/commit/32b807da13ef8fcd4d31788eb145d616c54c04e4): changes `v1.4.0` to `v1.4.x` the same day without changing the tuple or parser.

## What the source actually establishes

All offsets below are byte offsets in `progress.sav`. They are reference-source facts, not a claim that any selected file is a genuine 1.4.3 save.

| Subject | Observed source behavior | Limit for this project |
|---|---|---|
| Byte order and magic | `checkValidSavegame` sets little endian and checks unsigned 32-bit word at offset `0` equals `0x01020304`. | A format marker is not a checksum or proof of provenance. |
| 1.4.x signature | The version table records length **2,307,856 bytes**, unsigned 32-bit word at offset `4` equal to **`0x0049e946`**, and word at offset `8` equal to **`0x0003c138`**, named `metaDataStart`. | It labels a family, not a unique 1.4.3 discriminator. Do not infer undocumented meaning for the header or metadata field. |
| Record shape | `_getOffsets` examines aligned eight-byte records beginning at **`0x28`**. The first word is a hash. For scalar fields, the following four bytes are the inline value; pointer-valued fields use the following word as an offset. | Do not search unaligned bytes for a wallet-looking value, or use the position-vector pointer rules for a scalar. |
| Table terminator | `Variable.findHashTableEnd` searches from `0x28` in eight-byte steps for **`0xa3db7114`** (`MetaData.SaveTypeHash`), returns its offset plus four; `_getOffsets` stops when it encounters that record and calls its value `guidsArrayOffset`. | The source searches up to file length. Its older comment/default `0x03c800` is not a verified 1.4.3 fixed boundary. Neither this comment nor the name `metaDataStart` proves every structural relation between the header, terminator and later payload. |
| Wallet | Hash **`0xa77921d7`** is named **`PlayerStatus.CurrentRupee`**, marked non-pointer. The editor reads and writes it with **unsigned little-endian 32-bit** access at the matching record's offset plus four. | This supplies a tag and representation, not a universal fixed wallet offset. |
| Range | The reference UI calls `setNumericRange('rupees', 0, 999999)`. | **0–999,999 is an editor policy evidenced by source.** It is not independently established here as the game's full legal range or proof that no other value is persisted. |
| Missing and duplicate records | `_getOffsets` fails when required field names are missing, but its assignments silently overwrite repeated hashes. The terminator search takes the first occurrence. | A strict new reader must reject missing, duplicate or ambiguous wallet/terminator structures rather than inherit this permissive behavior. |
| Unknown format | The reference first permits a broad length interval, then displays an unmatched tuple as `*Game mod*` and can still return success if its fields were found. | Do not import that admission policy. A project parser must fail closed on unknown tuples and clearly label the admitted family. |
| Save output | The TOTK `save` method writes `PlayerStatus.CurrentRupee` and other UI fields. Generic `saveChanges` calls that method then `tempFile.save`; `MarcFile.save` serializes the byte array into a Blob. No wallet-specific checksum update appears in this reviewed path. | Evidence of what the reference does, not a specification proving there are no integrity requirements. The full UI save also writes other fields, so it is not a four-byte-only oracle. |

The observed wallet operation is consequently a **four-byte scalar replacement at a discovered record**, not an item insertion, inventory rewrite or pointer relocation. A dedicated candidate writer can preserve every other byte. That restriction does not by itself establish that the resulting game save is acceptable.

## Exact 1.4.3 evidence and remaining uncertainty

The local [1.2.1 port record](v1.2.1-port.md#143-写过的存档), line 114, says that a `progress.sav` written by 1.4.3 has the same header `0x49E946` as its discussed `option.sav`. This agrees with the public family's header. The **880-byte** size in that paragraph belongs to `option.sav`, not `progress.sav`; it must not be used as the wallet file size. The record does not establish the 1.4.3 progress length or its word at offset eight.

Public discussion provides limited corroboration:

- In [issue #488, author comment dated 2025-06-13](https://github.com/marcrobledo/savegame-editors/issues/488#issuecomment-2970914203), the author announces “Support for TOTK 1.4 was added” and asks whether it works. This corresponds to the initial support commit, not a later exact-1.4.3 audit. The earlier discussion includes save attachments; none were retrieved.
- In [issue #522, comment dated 2026-06-20](https://github.com/marcrobledo/savegame-editors/issues/522#issuecomment-4760126287), a user reports that overwriting an autobuild slot works on **1.4.3**, including in game. This is an exact-version **anecdote about autobuild import**, not a measured wallet round trip, byte-layout attestation or integrity specification. Issue comments are mutable evidence; the immutable code commits above remain the format reference.
- The repository release named `v1.4` says “Added Zelda TOTK editor and some smaller fixes to other editors.” That is an **editor release version**, not evidence of game 1.4.x compatibility. No release artifact was downloaded.

Bounded searches of the primary editor's code/commit history and public issue text found no exact-1.4.3 wallet integrity contract. This is not a claim that none exists anywhere. The concrete gaps are:

1. **Family membership:** confirm the complete length/magic/header/metadata tuple for saves newly written by the target 1.4.3 build, rather than an older save it can load. The family signature cannot distinguish patch versions sharing that layout, or attest provenance against arbitrary crafted input.
2. **Integrity:** establish whether a wallet-only edit requires any checksum, digest, redundant wallet value, counter, metadata or companion-file change. The absence of a checksum call in one working editor is suggestive but does not prove all such requirements absent. Hashes identifying field names are not demonstrated integrity digests.
3. **Structural validity:** settle the required relationship between the metadata offset, simple-record terminator and payload bounds; define rejection of duplicate markers and corrupted/truncated structures. Do not silently treat a marker-shaped payload word as the end of a valid table.
4. **Semantics and acceptance:** confirm the intended range and behavior from an authoritative format contract or a later controlled target-version wallet round trip. The reported autobuild success and current transfer fixtures are not that evidence.

## Work justified now, without enabling the editor

The primary MIT reference is sufficient to specify an **experimental offline source implementation** with the narrow scope below. This is a proposal for review; no implementation or validation ran in this research task.

- Label its admitted format `TOTK 1.4.x reference tuple`, never `verified TOTK 1.4.3`. Require the full exact tuple above before any field inspection. Keep older layouts outside its scope unless separately specified.
- Use bounded little-endian reads and complete eight-byte records. Locate one unambiguous table terminator and one wallet scalar before it; reject absent, repeated, out-of-bounds or otherwise ambiguous structures. Keep unresolved structural interpretations explicit rather than inventing magic offsets.
- Provide a read-only inspection result with family label, wallet value and evidence status. A strict read-only parser is useful before any mutable API is admitted.
- If a separate-copy candidate writer is added, accept only integer values within the reference UI policy, require distinct source/output destinations, preserve the source, patch only the discovered four bytes and verify that all other bytes are identical. Describe its output as an **unvalidated candidate**, not a repaired or guaranteed playable save. Do not use it on the active app save or integrate it into the launcher while integrity is unresolved.
- Add no production capability flag, settings row or automatic migration from this evidence alone. Future in-app work still needs the [backup/stage/seal contract](ipados-save-editor.md), reviewed integrity decisions, appropriate validation when authorized, and a physical 1.4.3 load plus restoration result. Current “do not run tests” instructions remain in force.

Other public leads were screened without importing their content: the [archived lchmagKekse editor at `6968e1f37a2962b8462c8c28717ccdbbf681823c`](https://github.com/lchmagKekse/TOTK-SaveGame-Editor/tree/6968e1f37a2962b8462c8c28717ccdbbf681823c) advertises rupee editing but its reviewed root lists no license file and its README does not establish 1.4.3 support. [McSpazzy's README at `5bf06e5077aa24348eb1a1fb1ef1ef110081fb2a`](https://github.com/McSpazzy/totk-gamedata/blob/5bf06e5077aa24348eb1a1fb1ef1ef110081fb2a/README.md) describes save structure/GameDataList research but supplies no exact-version or integrity contract in that text; the root listing includes older `Product.110` metadata and no license file. No game-derived data tables were retrieved. [The position extractor README at `42a1738783d674d9acdd1af08912ff7d9fe1497e`](https://github.com/deano309/TotK-Save-Position-Extractor/blob/42a1738783d674d9acdd1af08912ff7d9fe1497e/README.md) covers position/rotation, not wallet integrity, and its reviewed root lists no license file. None of these leads is used to fill a missing contract by assumption.

The result advances issue #7 from “no external format evidence reviewed” to a pinned, permissively licensed family-layout/field reference. It does not remove the integrity and physical-acceptance gates or establish supported production editing.
