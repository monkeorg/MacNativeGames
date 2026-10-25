# Canopy

Canopy is the separate free, open-source native Switch launcher project tracked
in [#34](https://github.com/monkeorg/MacNativeGames/issues/34). Its current usable
component is a **read-only container inspector**, available as a portable CLI
and an iPad app source target. It does not decrypt, extract or execute games.
There are no supported gameplay profiles yet.

The inspector reads bounded NSP/PFS0 or XCI/HFS0 directory tables and returns
entry names, offsets and sizes. It rejects malformed/overlapping ranges, unsafe
names, nonregular inputs and observable source mutation. Container recognition
is not authentication or executable compatibility. The parser does not verify
HFS hashes. No user-supplied payload is shipped with Canopy.

## Portable build

With a C11 compiler and CMake:

```sh
cmake -S launcher -B /tmp/canopy-build
cmake --build /tmp/canopy-build
/tmp/canopy-build/canopy inspect /path/to/your/container.nsp
```

The output is local JSON. Entry names may reveal private file metadata; review
it before sharing. The tool never writes to the input and does not upload data.
Use your own local inputs; the repository's regression fixtures are synthetic.

## iPad app

See [Apple build instructions](apple/README.md). The separate Canopy target uses
its own bundle identity and the approved [icon](Resources/Branding/README.md).
The first app flow is select a container → inspect → retain a local metadata
record. Removing a record removes only that record; the source remains untouched.
The stored record contains neither a source URL/bookmark nor game payloads,
keys or saves. It is inspection history, not a prepared game installation.

The host can be prepared from public source without the TOTK private inputs.
Apple compilation, signing and device behavior must be verified on a Mac/iPad;
Linux test results do not establish them. The native imported-code execution
route remains [unproven](../docs/content-free-execution.md).

## Validation and remaining work

Run `python -m unittest discover -s tests -p 'test_canopy_*.py'` with the project
Python environment, alongside the existing `test_launcher_*.py` tests and the
portable regression suite. Preserve explicit platform skips.

Native execution, decryption, shader preparation, prepared-generation recovery,
per-game settings/saves, real multiplayer and physical acceptance remain release
requirements. The mod manager, Wii U and other backends are excluded. The
working TOTK app/runtime and its identity remain separate.
