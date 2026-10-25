# Original-source ARM64 rewrite fixture

This directory exercises the real NSO rewriter, embed generator and shared
production loader mechanics with an original small ARM64 program. It consumes no
game files. Portable artifact generation does not execute code. The Apple native
runner tests real execution only when actually run; it never establishes gameplay
or permission to execute externally imported code on iPad.

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

No fixture code is executed by the portable tool/artifact tests. Generated
`fixture_module.h` contains bounded original Module/Symbol/Reloc/Gate records
derived from the actual rewrite output and original NSO. The separate native
runner applies relocation and invokes the service gate through shared production
code; its service handler is an authored fixture callback, not a Horizon service.

## Shared production-loader Apple probe

`apple_probe.m` is an isolated UIKit display/result wrapper. `fixture_runner.c`
and production `runtime/loader.c` include the same internal
`runtime/loader_module_core.h`: the symbol helpers, both platform mappers,
relocation, sealing, permission checks and gate dispatch have one implementation.
The probe links production `runtime/gate.S` unchanged. It does not invoke game
boot, title patches, an SDK or the full service runtime.

The former duplicated platform probe compiled in public Apple CI. This new shared
core integration requires its own Apple build result; prior compilation is not
evidence for this revision. Signing and physical execution remain open.

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

The app calls the shared production mapper for signed section hashes, executable
shared remaps and writable copy-on-write data, then the actual relocation, sealing
and permission checks. It initializes real Darwin TLS and invokes the rewritten
indirect call, TLS read, relocated leaf and SVC gate. The unchanged assembly gate
switches to a fixture-owned host stack and the shared dispatcher calls the
original bounded fixture handler. This is not a full HLE thunk/service proof.
It checks return address, arguments, results, host-stack slot restoration and
copy-on-write isolation. Success appears
on screen, in `FIXTURE_RESULT` logging and `Documents/fixture-result.json`. Preserve
this result with device/OS/signing details. Missing output or a crash is not a pass.
Run once without debugger; a debugger-assisted pass alone cannot establish the
normal execution path. Failure remains fatal like the production checks; missing
result output, a crash or a negative-test failure is never a pass.

`tests/test_launcher_loader_core.py` builds the actual shared Mac core and
executes the original code on Apple silicon, with fresh-process digest/layout/
relocation/gate refusal cases. It also links the unsigned iPhoneOS app. These
cases explicitly skip where Apple tools are absent; no emulator/simulator is
substituted. The fixture is single-use and owns its one mapping/TLS/host stack;
its cleanup is not a commercial-runtime teardown contract.

Remaining gates: this revision's iPhoneOS compilation, signing, physical-device execution of
the embedded fixture with observed permissions/results, then independently
demonstrated execution of a private external fixture absent from the public
executable. The last gate is still an unresolved Apple loading/signing dependency.
See [execution feasibility](../../../docs/content-free-execution.md).
