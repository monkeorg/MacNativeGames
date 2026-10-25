# Original-source ARM64 rewrite fixture

This directory exercises the real TOTK NSO rewriter and iOS embed generator with
an original, small ARM64 program and generated module metadata. It consumes no
game files. It is an artifact proof, **not native execution or gameplay**.

`build_fixture.py` contains the canonical instruction source as address, word,
assembly triples. Tests decode each word independently with Capstone. The module
has a replayable stack-store/`blr x18` call, a leaf that adds seven, a TLS read,
a system-service instruction, two defined symbols and one relative relocation
into writable data. Minimal MOD0, dynamic and unwind-header metadata are generated
for the production rewriter. The unwind header describes function starts only;
it does not supply complete unwind FDEs for use by a runtime unwinder.

Run from the repository root, with the existing development environment providing
`capstone` and `lz4`:

```sh
python tools/launcher/fixture/build_fixture.py /tmp/launcher-native-fixture
python -m unittest discover -s tests -p test_launcher_execution_fixture.py -v
```

The output directory must not already exist. Outputs include the original NSO,
production rewrite logs/tables, rewritten bytes, production `embed.S`, generated
section digests/linker flags and a manifest recording tool hashes, options and
artifact hashes. Absolute `.incbin` paths are deliberate production-generator
output, so assembly file hashes vary with the output location. Original NSO and
rewritten image bytes are deterministic. Generated outputs stay outside Git.

The unchanged production embed generator uses `__TOTK*` segment names even for
this original fixture. The strict public-artifact checker therefore deliberately
rejects this engineering probe. It is not a public launcher artifact; that
conservative rejection does not establish that these fixture bytes are
proprietary. A public host needs a separate reviewed packaging path.

Negative tests exercise production rejection of a branch into an unprepared
call, a non-replayable call prefix, an invalid MOD0 pointer and truncated exported
text. Positive tests independently check actual branch rewriting, emitted system
gates, section content hashes, padding, protections and provenance records.

No fixture code is executed by the portable tool or its tests. Relative
relocation is recorded but not applied by a production native loader. The service
gate is emitted but no host service is invoked.

## Apple platform permission probe (unbuilt in cloud)

`apple_probe.m` is an isolated UIKit app which uses `getsectiondata` and the
same Apple remapping APIs, through the existing `mach_vm_compat.h`. It shares
that compatibility header and generated artifacts with production, not the
production loader. Its purpose is to test platform permissions. It must not be
reported as production runtime integration.

On a Mac with Xcode, after generating the fixture above:

```sh
python tools/launcher/fixture/build_apple_probe.py \
  --fixture /tmp/launcher-native-fixture \
  --output /tmp/ExecutionFixture.app
```

The builder verifies the fixture artifact hashes, compiles for physical iPhoneOS
and records its command, Xcode version, source/header/executable hashes in
`probe-build.json`. It does not sign or install. Use a dedicated development App
ID and matching provisioning profile; never reuse or alter the installed game's
identity. Custom `--bundle-id` values must end in `.executionfixture`; the builder
rejects game app identifiers. Absolute `.incbin` references must resolve within
the selected fixture directory and match its manifest hashes. After copying or
moving a fixture, regenerate it at the new location instead of compiling stale
references to the old location. With locally chosen values, the subsequent
standard steps are:

```sh
cp "$FIXTURE_PROFILE" /tmp/ExecutionFixture.app/embedded.mobileprovision
codesign --force --sign "$FIXTURE_SIGNING_IDENTITY" \
  --entitlements "$FIXTURE_ENTITLEMENTS" /tmp/ExecutionFixture.app
xcrun devicectl device install app --device "$FIXTURE_DEVICE" /tmp/ExecutionFixture.app
xcrun devicectl device process launch --device "$FIXTURE_DEVICE" \
  org.macnativegames.executionfixture
```

Those environment values require local provisioning; the entitlements must match
the dedicated profile. No JIT or increased-memory entitlement is requested. Record
the actual distribution/provisioning mode and signed artifact hash before use.

The app verifies signed section hashes, remaps executable pages shared and data
copy-on-write, applies its one known data-pointer relocation, initializes real
Darwin TLS, checks protections and invokes the rewritten indirect call, TLS read
and relocated leaf. It checks original return address, arguments, computed results
and copy-on-write isolation. It does not invoke the service gate. Success appears
on screen, in `FIXTURE_RESULT` logging and `Documents/fixture-result.json`. Preserve
this result with device/OS/signing details. Missing output or a crash is not a pass.
Run once without debugger; a debugger-assisted pass alone cannot establish the
normal execution path. A reviewed shared production loader interface is still
needed for runtime integration acceptance.

Remaining gates: iPhoneOS compilation, signing, physical-device execution of
the embedded fixture with observed permissions/results, then independently
demonstrated execution of a private external fixture absent from the public
executable. The last gate is still an unresolved Apple loading/signing dependency.
See [execution feasibility](../../../docs/content-free-execution.md).
