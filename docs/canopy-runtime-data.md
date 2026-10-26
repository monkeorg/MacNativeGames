# Private runtime-data source port

This source cohort reuses the original host/data separation from
`ly05010419/MacNativeGames@f541e14eca36b02035cd14a30aeb4d20b467b47a`
(primary commit `1cbe2a104a2340c851a228db85e3afe724c562bf`). The reference source
snapshot was compared with `f4fe63ac48c2867d4b2f5a915fb4f638c2bef294`.
No generated table, rewritten program, font, shader or other game payload was
fetched. The format/generator/reader/build integration are original source.
Generated data remains private and must never enter the public input inventory.

The selected private producer writes four files under
`build/game-data/<version>`: `runtime-tables.bin`, `romfs-config.txt`,
`shared-fonts.txt` and `rewriter.txt`. It retains the existing verified rewrite
and original-input checks. The binary uses upstream `TOTKTAB1`: a64-byte header,
three208-byte module records, aligned24-byte symbol/relocation/gate records,
and the producer's contiguous NUL-terminated symbol-name table. The supported
current gate kinds remain svc0 and timer1. Upstream spin2 requires a scheduler
contract absent from this branch and is not silently treated as a timer.

One `runtime/game_data.c` reader validates owned snapshots before exposing
module/config values. Reads and SHA256 run in64KiB chunks with cancellation;
parsing and symbol/string/relocation/gate validation also poll cancellation.
The producer and reader admit at most256MiB of table bytes and a256MiB envelope
for normalized symbol/gate metadata. These are admission limits, not a hard heap
or process-memory claim: allocator overhead, module symbol hash tables, fonts,
module images, graphics and the guest remain additional. Actual private artifact
sizes/counts have not been observed here. Oversized data refuses before entry.

The reader checks exact format/version/module names, digest syntax, zero
reserved/padding fields, bounded canonical array/string ranges, mapped module
layout, constructor/probe addresses, supported relocation/gate fields and
strictly ordered unique gate returns. Text schemas reject duplicate/unknown
keys, embedded NULs, invalid numbers and unsafe font basenames. Configured
RomFS/index hashes must match independently compiled profile pins. It never
uses a text file's own hash assertion as execution authority.

The existing `loader_module_core.h` remains the single actual mapper and
relocator. Its iOS embedded-section layout/hash/remap/permission checks, Mac
patched-image hash, checked game patches, SDK callback ordering, typed Canopy
unexpected-return handling and lifecycle observation remain in place. Module
rows point into the retained snapshots. RomFS metadata likewise uses an owned
byte copy whose hash is checked before parsing, rather than a file-backed mmap
that could observe later writes. The actual RomFS image descriptor and immutable
prepared-generation lease retain their existing process-owned lifetimes. Font
payloads retain their existing read-into-owned-region and hash-before-use path.

ABI3 host/start layouts remain unchanged. The optional `totk_canopy_host_v4`
accessor adds an exact-version/size wrapper around that same legacy descriptor
and a versioned game-data record with compiled manifest SHA, worker prepare,
pre-entry release and main install callbacks. An invalid present v4 descriptor
refuses; it never falls back to ABI3. Public and legacy private builds have an
optional weak NULL v4 accessor. A new `CANOPY_GAME_DATA_RESOURCES` build requires
the actual strong accessor and an installed context before native start; using
only the old ABI3 call cannot bypass the new verification.

Canopy preflight opens the exact compiled resource directory and verifies a
fixed `runtime-data/manifest.txt` whole-file pin. Its ordered manifest names the
four files with exact sizes/hashes; the directory must contain exactly those
files and the manifest. Stable regular single-link/nofollow reads produce owned
bytes. The same context feeds the loader, RomFS config and font config; consumers
never reopen those metadata paths or consult `TOTK_GAME_DATA`. Main installation
performs no I/O. Cancellation/refusal releases only pre-entry context; once host
handoff begins the context, generation, saves, shaders, device and other session
protections remain retained through process death, including failure. This adds
no safe stop, finalizer ordering or relaunch claim.

The private Canopy builder runs the original generators against its already
verified private snapshot, packages the four files plus exact manifest under
`GameData/runtime-data`, and compiles its manifest and independent profile
RomFS/index pins. Generator subprocesses ignore inherited Python overrides.
The trusted local exporter receives the exact staged game-data path; its copied
executable and the existing `gen_embed.py` signed-section preparation remain the
actual production path. The recorded rewriter SHA describes retained input
provenance; full reviewed original/rewrite hashes remain the independent trust
gate. Existing shader/display/native-provider/account protections are retained.

For the original Mac path, normal `runtime[-version]` targets still prepare both
binary and game data. The source port reuses upstream `binary`/`game-data` split,
Mac default `build/game-data/<version>` and the existing explicit
`TOTK_GAME_DATA` override. Mac app packaging carries the private data at that
same relative path. The original iOS builder packages `GameData/game-data` and
its original main binds that exact resource path. BOTW keeps its current legacy
headers/consumers; no new BOTW implementation or generated data is included.
Legacy Canopy ABI3 builds likewise keep their generated-header consumer branch.

No updater, runtime replacement, executable permission workaround or newly
approved game is included. Externalizing metadata does not remove the private
iOS executable's embedded game instruction sections. The public Canopy provider
still reports unavailable without a deliberately linked trusted host.

This is source-only work. No tests, probes, compiler, build, CI dispatch, signing,
installation or gameplay execution was performed. Existing direct harnesses and
CLI/setup code that assumed generated TOTK headers need a later authorized
update to exercise this new v4/data-resource branch. Their old ABI3 link remains
optional-v4 compatible; no tests or fixtures were edited or claimed as passed.
Actual private Mac/iOS build, artifact-format acceptance and device/gameplay
validation remain unperformed.
