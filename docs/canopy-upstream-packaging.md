# Upstream iOS packaging integration

This source slice adopts the bounded packaging improvements from upstream
`dea3666beb74ab55565045992d889fc5797b2dcc` and the reachable-device distinction
from `efe38a212d58225c61d9a7155cd473c20e775882`. Those commits contain source,
documentation and original tests, not game payloads. Their reported timings are
upstream observations; this integration has not been built or run.

## Implemented source

The original `games/totk/ios/tools/build_ipa.py` copies the small Xcode product
once into the final `.app` or clean IPA Payload directory, then assembles private
GameData there. It removes old GameData left in the derived product. Existing
version selection, app/bundle identity, fonts, shader/PSO generation and opt-in
display overlays remain in their original route. Shader seeds remain bundled.
This first slice does not add background deletion. The subsequent source-only
opt-in Documents shader transport is described below; ordinary builds continue
to bundle their shader seed.

The explicitly invoked original `install_device.py` signs the user-selected
`.app` output in place instead of cloning it again. This changes that selected
build output's plist, provisioning profile and signature, as part of the explicit
installation command. IPA extraction reuse now binds a stable SHA256 of the
archive rather than its mtime; the archive is checked again after extraction.
That checkpoint describes the trusted local archive and extraction operation,
not an attestation against subsequent manual changes to the signing workspace.

Device inspection distinguishes a missing child directory from an inaccessible
Documents container. An unreachable device fails instead of triggering a new
large upload. RomFS reuse requires the marker's source fingerprint, exact part
sizes, and rereading all device parts to match that SHA256. The local image is
also hashed against its extraction fingerprint. Full upload hashes its actual
stream again before writing a completed marker. There is no size-only marker
repair or partial-part resume. Reuse verification downloads parts into a private
temporary directory, one part at a time, and can be expensive; this is integrity
work, not a measured transfer-speed claim. Existing unpartitioned images or extra
part names require explicit migration and are refused without replacement.

Canopy's public builder remains payload-free and unsigned. Its private builder
continues to use its independent source/input snapshots, explicit manifest pin,
authenticated seed cache and unsigned output. The original install tool is not
connected to either builder. No profile, account identity, save path or private
input contents are changed by this source integration. No signing, installation,
device queries, tests, probes or compilation were executed for this slice.

## Opt-in hardened transport producer

The original builder now has an explicit `--seed-pack` option, which also requires
`--image-outside`. It preserves the useful `TOTKPACK1` stream while binding its
expected bytes to app resources. Before removing the bundled seed it requires
strict integer `TOTKShaderSeedPackReaderABI=1` in the actual Xcode product plist
and the defined `_TOTKShaderPackReaderABI` symbol in that product's executable,
queried with installed Apple `nm` during a real build. A header or source marker
alone cannot pass this gate. Root integration must wire and review the actual
reader/main caller before enabling its project capability; source here does not
establish that build/device gate has passed. Default builds are self-contained.

Final exported and alias-renamed `pso_list.tsv` and `pso_title.tsv` are freshly
hashed into `seed-manifest.json.files` for both stock and packed builds. The final
map hash is refreshed as `shader_map_sha256`. This happens before any raw manifest
pin is taken. `ios-final-seed-observation.json` in private build logs records the
previous/final manifest hashes, list/map hashes and builder source hash. A changed
manifest requires a new independently reviewed trusted pin for Canopy; its old
pin cannot authorize the changed seed. The shared importer must accept the two
specific optional list names while retaining existing hash/identity checks.

The producer snapshots the verified final seed, map and PSO lists into an owned
private staging directory, refusing links, changing reads and duplicate names.
It hashes the actual snapshot bytes rather than trusting cached file lengths or
fingerprint text. It emits `GameData/shader-seed-pack.json` **inside the app before
the final developer signature**, plus a private sibling transport directory.
The bundle contains public identity facts in `TOTKShaderSeedPackTitleID`,
`TOTKShaderSeedPackTitleVersion`, `TOTKShaderSeedPackRomFSSHA256`,
`TOTKShaderSeedPackGameVersion` and `TOTKShaderSeedPackChain`. These derive from
existing expected manifests and the actual source `DMSH_CHAIN`; main must compare
them with compiled game-version/chain facts before attesting an external seed.
`TOTKShaderSeedPackMetadataSHA256` pins the exact raw bundled JSON bytes, separately
from its individual member/stream hashes, and is set before the final signature.
The JSON has exactly these fields:

| Field | Required value |
| --- | --- |
| `schema` | Integer 1 |
| `format` | `TOTKPACK1` |
| `titleID`, `titleVersion`, `sourceRomFSSHA256`, `chain` | Selected verified source identity and current translator chain |
| `manifestSHA256` | Exact final `seed-manifest.json` bytes |
| `streamSHA256`, `streamSize` | Entire ordered stream, including header and end marker |
| `partSize` | 1073741824 bytes |
| `parts` | Ordered records with integer `index`, integer `size`, lowercase `sha256` |
| `members` | Strictly bytewise-sorted unique records with ASCII `name`, integer `size`, lowercase `sha256` |

Proposed bounds are 262144 members, 64MiB per member, 16GiB total stream,
64MiB signed metadata and at most 16 parts. These are original-iOS transport
ceilings, not changes to CanopyShaderCache's independent limits. The source
manifest, map, warm-up/scope lists and every actual shader member are included;
no keys, source containers, saves or account data belong in this stream.
All names are 1..127-byte ASCII leaves in `[A-Za-z0-9_.-]`, without a leading dot,
slash, backslash, NUL, duplicate or ASCII-casefold collision. The required raw
manifest and map plus each actual file appear exactly once; the existing shader
consumer still applies its stricter semantic file grammar.

The wire format remains nine-byte `TOTKPACK1`, followed by explicit little-endian
u16 name length, name bytes, little-endian u64 payload size and payload bytes per
member, then one zero u16 name length. Decoding must consume exactly the declared
stream size with no trailing bytes. Piece indices are contiguous, all nonfinal
pieces have the fixed part size, and the last has its exact declared length.
The JSON inventory, individual hashes and full stream hash must all agree.

Private sidecar output is `<output-stem>-shader-pack/<streamSHA256>/`, containing
the exact same `shader-seed-pack.json` and `parts/000` through at most `parts/015`
(no extensions). The producer verifies complete actual sidecar bytes before reuse.
The installer takes authority only from app-bundled metadata, verifies local
sidecar identity/inventory/full stream and unchanged metadata through signing,
then writes only `Documents/GameData/shader-packs/<streamSHA256>/parts/NNN`.
Each actual reused device piece is reread and hashed; uploads consume an owned
copy/hash snapshot and receive a hash-checked readback. The final part inventory
must be exact. No marker chooses a path or grants completion, and no old packs or
seeds are deleted. Source inventories are bounded and reject links/hardlinks.

The separately owned reader takes expected metadata only from its installed main bundle. It
opens fixed content-addressed paths with nofollow descriptors, bounds every
read/count/addition, checks parts and member hashes during one streaming decode,
reports bounded progress off the main thread. This checkpoint has no cancellation
API; it must not advertise cancellation or completed runtime teardown. Staging
uses a fresh owned UUID sibling under private Application Support and exclusive
files; failures clean only that stage. Its final output is
`ApplicationSupport/TOTKShaderSeeds/<streamSHA256>`, never Documents. After full
manifest/map/member verification and successful flushes it
publishes an immutable seed without deleting the old complete seed first.
Crash reconciliation must distinguish complete, partial and published states;
cleanup cannot remove an active seed or its pieces.

Documents data must never be described as Apple-signed merely because an
environment variable or marker names it. The original shader consumer may use
verified private seed bytes in place only through an explicit reader attestation
with appropriate lifetime protection. Canopy keeps its existing separate
compiled-pin/cache verification and leases; enabling this transport for the
original app grants no Canopy bypass. Producer and reader require independent
source review before enabling the route, with authorized validation and actual
Apple/device acceptance remaining separate gates.
