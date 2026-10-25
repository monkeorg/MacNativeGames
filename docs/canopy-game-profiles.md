# Trusted Canopy game profiles

`launcher/config/game-profiles.v1.json` is reviewed repository build metadata.
It currently registers only Tears of the Kingdom 1.2.1 (`v121`, revision 393216)
and 1.4.3 (`v143`, revision 720896). The default remains `v121`. BOTW and the mod
manager remain parked; neither is registered by this change.

Each game declares its public title ID and label, ordered native modules, native
adapter, build adapter, save validator and player ceiling. Each version refers
to the existing public expected manifest, compile define, checked patch source
and display profile. Original/rewrite/font hashes remain in the existing
`games/totk/assets/expected-*.json` manifests. The registry does not duplicate
those authoritative tables or infer versions from filenames.

`tools/launcher/game_profiles.py` validates bounded regular, nonlinked source
files, exact schema fields, duplicate JSON keys, title/version uniqueness,
module/hash tables, font-role order and a closed set of adapter IDs. It emits
`launcher/src/mng_game_profile_data.inc`. The C interface in
`launcher/include/mng_game_profile.h` exposes only immutable compiled rows.
Unknown titles, revisions, aliases and foreign profile pointers return null;
there is no runtime JSON import or default-version fallback for unknown data.

When a reviewed registry or expected manifest changes, regenerate its source:

```sh
python tools/launcher/game_profiles.py --write
```

The private builder checks generated-source drift whenever it loads the
registry. `--check` is also available for an authorized validation run. The
source metadata fingerprint binds the registry and referenced expected-manifest
bytes. It is not the identity of backend source or of a resulting executable.

The actual consumer in `tools/launcher/build_private_canopy.py` obtains default
and version aliases, expected assets, ordered modules, patch selection, compiler
define and display-profile selection from this registry. Existing v121/v143
commands and compile settings remain the same. The builder rejects registry
changes after initialization, compares selected metadata with its tracked public
staging snapshot, and records the registry fingerprint and helper source hash in
its existing private observation. Its existing source/input/exporter/codec/tool
snapshots still provide their own separate evidence.

A row is metadata, not an execution or save-editor grant. Runtime must continue
to require an actual compiled provider, exact asset pins, approved versioned
capabilities, generation leases and device acceptance. Structural save-validator
selection does not authorize semantic editing or account conversion. Display
flags describe an implemented profile ceiling and do not authorize patches by
themselves.

`CanopyGameProfiles` maps compiled metadata to labels and a closed structural
save-validator factory. Games uses the factory on its existing profile-open
worker; actual Store opening, pre-Play seals and selection CAS remain unchanged.
The library displays verified catalog revisions, known version labels or an
explicit unidentified/unknown result, with saved user names taking precedence.
Host presence is assessed through the actual Runtime provider, separately from
metadata and compatibility. No edit validator is supplied. Runtime and native
host callback, ABI, asset and device gates remain unchanged.

Future additions can reuse the metadata path where they share implemented
contracts. An incompatible native ABI, loader, services, shaders, save format or
patch recipe still requires backend code and independent review. Adding a BOTW
row cannot supply that code, and imported manifests cannot register adapters.

No new tests, probes, compilation or private build were executed for this phase
under the current no-test instruction. The generated table was produced as a
source-generation step. CMake and fixed public inventories include the compiled
table, header and implementation, plus the separately reviewed Apple adapter and
Games caller. Source generation establishes no Apple or device execution result.
