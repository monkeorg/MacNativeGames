# Canopy iPhoneOS inspection host

This is a separate original host target for iPhone and iPad, with iOS 16.0 as its
minimum deployment version. It links UIKit, Foundation and UniformTypeIdentifiers
and the portable Canopy container/file inspection code. It does not link the TOTK
runtime or package games, shaders, firmware fonts, keys, saves or private caches.
The working TOTK target and bundle identity are unchanged.

From the repository root, inspect the recipe on any supported Python host:

```sh
python3 tools/launcher/build_canopy.py --plan
```

On a Mac with Xcode's iPhoneOS SDK selected, produce a separate unsigned bundle:

```sh
python3 tools/launcher/build_canopy.py --out /path/to/existing/parent/canopy-build-001
```

The output directory must not exist, and its parent must use a canonical physical
path with no symlink ancestors. On macOS use `/private/tmp` instead of `/tmp`, or
obtain a parent path with `pwd -P`; `/var` likewise resolves under `/private/var`.
It contains `Canopy.app` and
`build-observation.json`; the JSON stays outside the app. The builder uses only
its fixed list of public repository sources and headers. It snapshots and hashes
those files, compiles the snapshot, checks the original and snapshot again, and
records the exact commands, source revision, builder hash, SDK path/version,
compiler version and output hashes. Use an isolated stable checkout and output
parent; this is not a sandbox against concurrent malicious filesystem changes.
Failed builds keep a diagnostic observation and do not publish `Canopy.app`.
The builder never signs, installs, overwrites an earlier output or modifies the
existing game build. Default identity is `org.monkeorg.canopy`; optional
`--bundle-id org.example.canopy` must retain the `.canopy` suffix.

The approved `launcher/Resources/Branding/Canopy.png` is hash checked and copied
byte-for-byte into the bundle. It remains a resource, not a compiled Apple icon
catalog; correct SpringBoard icon presentation is a later Apple validation task.
Do not resize it or claim it is a production app icon in this slice.

The build observation is not an approved public inventory and is not provenance
certification. Independent review must trace each compiled input and the recipe,
then prepare an inventory in the schema documented in
`tools/launcher/audit_public_artifact.py`. Run the separate inventory check only
against that reviewed inventory:

```sh
python3 tools/launcher/audit_public_artifact.py \
  /path/to/existing/parent/canopy-build-001/Canopy.app \
  /path/to/reviewed-inventory.json
```

Never treat hashes generated from the candidate itself as independent approval.
The checker reports `inventory matches`; it does not certify absence of
Nintendo-derived bytes, validate signing or establish gameplay compatibility.
The builder produces a `.app` directory, not an IPA, and performs no upload.

Portable tests exercise planning and file-handling with a synthetic fake command
runner. Those tests do not establish Apple compilation. Actual Xcode compilation,
signing review and physical-device acceptance must be reported separately; they
are unavailable in the current cloud environment. This target is an inspection
app and does not provide game execution, decryption or installation.
