# MK8DX private Canopy host source

This directory contains original integration source, not a game program. Its
source-only private recipe selects `seedds/nxnative` at
`7861e7c1a9913e020600b1cc7f65132427e9cc50` and MK8DX4.0.0
(title `0100152000022000`, revision1441792). `source-allowlist.json` records
individual original-source/profile/license Git blob identities. It excludes all
rewritten modules, generated game instruction tables, shader lists and game
assets. The source export is supplied locally; the recipe never fetches it.

The seedds MIT notice is retained in `UPSTREAM-LICENSE.txt`. The original source
export's separate libvpx, stb_vorbis and Vulkan-header notices are also required
and preserved by the private snapshot and app notice directory. This does not
replace existing jhaizhou attribution elsewhere in this repository or imply
that Nintendo-derived build outputs may be redistributed.

The production path is the existing Canopy SessionController → CanopyRuntime →
CanopyRuntimeRegistry → strong compiled `canopy_mk8dx_host_v1` → pinned original
`main.c` (renamed `nxnative_host_main`) → `front_run` → original `guest_main`.
The public weak provider returns NULL; preparation metadata cannot install or
approve a provider. TOTK continues through its separate ABI3 path.

Before native entry the existing store fully hashes the prepared generation and
holds a real shared generation lease. The provider additionally checks all three
original ExeFS hashes/build IDs and the compiled RomFS identity. It validates the
whole pinned native manifest and seed manifest, exact bounded seed tree and each
file hash, stages an immutable private seed, holds its namespace lease, and
materializes/reuses the original RomFS through the single existing CanopyRomFS engine. Its separate stable romfs-derived root is keyed only by RFRecipe+title+generation, with full byte/tree validation on reuse and a retained shared sidecar/folder lease; app/device/shader changes do not force a full recopy. Its separate
mutable namespace includes recipe/seed/source/device/OS identities. Corrupt
published caches refuse reuse; they are not overwritten. The selected strong
Metal device reaches the actual original renderer; it has no default fallback.

The account UID is created in SaveStore's separate account identity directory.
`DM_SAVE` names `active/guest-user`, so the original device/work/new siblings
remain inside that profile's sealed active directory. Imported saves never
supply account identity. The compiled host cannot safely stop or relaunch:
starting it retains the generation, seed, prepared context, device and save seal
through process death even if startup or a later worker fails. Main cleanup and
actual pthread_join/TLS completion are observations, not all-service teardown.

Four portable seats map explicitly to original `dm_pad_set_player` buttons and
axes. Guarded original HLE adaptations preserve seat IDs, report actual
connections (including an absent seat1), disable one-player merging, and clear
held/latched state on disconnect, reassignment and capture. No old physical
controller frontend is linked. The bounded controller adapter reports the original successful result only when
focused supported FullKey seats satisfy positive minimum/maximum counts1..4.
It reads only the original direct-SDK count bytes0/1 and explicitly writes the
positive result's signed byte count, three zero padding bytes, and selected ID.
Null, min0, invalid/impossible requests and terminal waits produce a named Canopy
provider failure and exit only the calling native thread with protections held;
they never return an invented guest SDK cancellation/error Result. Public libnx
applet header facts do not establish equivalence of the direct SDK object's full
layout or single-mode byte, and its translated libnx error is not the SDK Result.
Full request/single-mode fidelity and exact SDK cancellation remain named external
contracts, not accepted completion. Unimplemented imports
no longer return successful zero: actual invocation marks provider failure,
captures input and exits the calling native thread while protections remain.

The frontend binds the existing CAMetalLayer/host view with a separate16:9
presentation child layer with the original framebufferOnly=NO and actual screen nativeScale-derived drawable size. Outputs above the conservative8192-pixel Metal admission ceiling refuse instead of downscaling. This does not patch guest scene resolution. It implements
the original software keyboard completion contract and combines host focus,
actual app/scene/key-window state, text capture and audio interruption. System
language is reduced to supported nonempty native language codes; explicit
Chinese script precedes region fallback. The actual pinned dm/host/hle_oe.c h_oe_GetLang reads DM_LANG and copies up to7 bytes into the zeroed8-byte native language code; each emitted code fits that original contract. Its h_oe_GetRegion derives the region from the same code. This is the MK original HLE path, not a TOTK locale assumption. Other preferences have no approved MK
setter and report unsupported. There is no network-multiplayer, FPS, performance
or thermal acceptance claim.

Use `tools/launcher/build_private_mk8dx.py --plan` for the source recipe, or its
`--build` mode only on an Apple-silicon Mac with user-retained original files.
Build mode requires an explicitly trusted local manifest SHA256 containing
schema1, the exact title/revision, `modules` with `main/subsdk0/sdk` each having
`sha256` and `size`, and `romfs` with `sha256` and `size`. Public16-byte build IDs
are checked in addition to, never in place of, full-byte pins. The native
rewrites are produced afresh by the pinned original `patch_nso.py` and embedded
by its `gen_embed.py`; the original `gen_build.py` supplies the source graph.
All tools use a closed environment (private HOME/TMPDIR, fixed PATH/C locale, exact GAME and verified Python snapshot); no inherited profile selectors, MAKEFLAGS, compiler flags or loader injection survive. Original Mac source exports are never modified. No old iOS/main entry is linked.

The rewriter's Capstone/LZ4 host dependencies must be supplied in a local folder
with an explicitly trusted dependency manifest SHA. That manifest is schema1
with `files` mapping each `capstone/...` or `lz4/...` relative path to its full
SHA256. Only those verified bytes are privately copied; Python uses `-S` and the
snapshot, without inherited site packages. There are no downloads, code signing,
installation or execution steps. Private outputs must remain private.

The public source/build inventory now includes the additive Registry and host
ABI. Games admits assigned seats against the actual compiled profile's player
limit, so the existing Session caller is connected to the four-seat MK provider
in source. Successful startup reports its immutable language policy as applied;
a later different policy requires restart. System means the policy resolved
once at startup, not an effective language code queried from the guest. Failed
or pre-entry sessions cannot report a newly applied language preference.

This implementation is source-only and has not been compiled, tested or run.
Storage now connects MK shader identities/runtime clearing and derived RomFS
removal through the reviewed family-specific recovery backend. The capability
dictionary reports these connected source routes, not tested behavior.
Producers refuse pending/unknown removal journals
under their existing parent locks, preserving Storage's recovery authority.
No local multiplayer gameplay, content-free iPad execution, complete controller
applet cancellation, safe stop or relaunch acceptance is claimed.
