#!/usr/bin/env python3
"""Compile an unsigned original-source iPhoneOS permission probe on a Mac.

Does not sign, install or access certificates. Uses an existing fixture build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
COMPAT = ROOT/'games/totk/third_party/d2r_gfx/gfx/nvn/include'


def validate_bundle_id(bundle_id):
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.executionfixture', bundle_id):
        raise ValueError('use a dedicated bundle ID ending in .executionfixture; never reuse a game app identity')


def verify_fixture(fixture):
    """Validate hashes and the exact files the assembler will consume.

    gen_embed emits absolute paths, so copied artifacts must be regenerated.
    Hashing the copies alone would not check the assembler's actual inputs.
    """
    fixture = Path(fixture).resolve()
    record = json.loads((fixture/'manifest.json').read_text())
    for name, expected in record['files'].items():
        path = (fixture/name).resolve()
        if not path.is_relative_to(fixture):
            raise ValueError('fixture manifest path escapes build directory')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'fixture changed after generation: {name}')
    assembly = fixture/'generated/embed.S'
    if 'generated/embed.S' not in record['files']:
        raise ValueError('manifest must cover generated/embed.S; regenerate the fixture')
    includes = 0
    for line in assembly.read_text().splitlines():
        if not line.lstrip().startswith('.incbin'):
            continue
        match = re.fullmatch(r'\s*\.incbin\s+"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*(0x[0-9a-fA-F]+|[0-9]+)\s*', line)
        if not match:
            raise ValueError('unsupported .incbin directive; regenerate the fixture')
        source, offset, length = match.groups()
        path = Path(source)
        if not path.is_absolute() or not path.resolve().is_relative_to(fixture):
            raise ValueError('embedded .incbin input is outside the selected fixture; '
                             'regenerate the fixture at its current location')
        path = path.resolve()
        name = str(path.relative_to(fixture))
        expected = record['files'].get(name)
        if expected is None:
            raise ValueError(f'.incbin input is missing from manifest: {name}; regenerate the fixture')
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError(f'.incbin input changed after generation: {name}')
        offset, length = int(offset, 0), int(length, 0)
        if offset > len(raw) or length > len(raw)-offset:
            raise ValueError(f'.incbin range exceeds its input: {name}')
        includes += 1
    if not includes:
        raise ValueError('no .incbin inputs; regenerate the fixture')
    return record


def build(fixture, output, bundle_id='org.macnativegames.executionfixture'):
    fixture, output = Path(fixture).resolve(), Path(output).resolve()
    validate_bundle_id(bundle_id)
    verify_fixture(fixture)
    if sys.platform != 'darwin':
        raise RuntimeError('requires a Mac with Xcode and the iPhoneOS SDK; no build was attempted')
    if output.suffix != '.app':
        raise ValueError('output must be a new .app directory')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    output.mkdir(parents=True, exist_ok=False)
    command = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios16.0',
        '-isysroot', sdk, '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Wl,-no_adhoc_codesign',
        '-Wno-deprecated-declarations', '-I'+str(COMPAT), '-I'+str(fixture/'generated'),
        str(Path(__file__).with_name('apple_probe.m')), str(fixture/'generated/embed.S'),
        '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreGraphics',
        *shlex.split((fixture/'generated/linker-flags.txt').read_text()),
        '-o', str(output/'ExecutionFixture')]
    subprocess.run(command, check=True)
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'ExecutionFixture',
        'CFBundleName': 'Execution Fixture', 'CFBundleDisplayName': 'Execution Fixture',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'LSRequiresIPhoneOS': True,
        'CFBundleVersion': '1', 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2],
        'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
        'UILaunchScreen': {}, 'UIRequiredDeviceCapabilities': ['arm64']}
    (output/'Info.plist').write_bytes(plistlib.dumps(info))
    evidence = {'status': 'built_unsigned', 'native_execution': 'not_run',
        'apple_signing': 'not_run', 'command': command,
        'fixture_manifest_sha256': hashlib.sha256((fixture/'manifest.json').read_bytes()).hexdigest(),
        'probe_source_sha256': hashlib.sha256(Path(__file__).with_name('apple_probe.m').read_bytes()).hexdigest(),
        'compat_header_sha256': hashlib.sha256((COMPAT/'mach_vm_compat.h').read_bytes()).hexdigest(),
        'executable_sha256': hashlib.sha256((output/'ExecutionFixture').read_bytes()).hexdigest(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip()}
    (output/'probe-build.json').write_text(json.dumps(evidence, indent=2)+'\n')
    return evidence


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle-id', default='org.macnativegames.executionfixture')
    args = parser.parse_args()
    build(args.fixture, args.output, args.bundle_id)
    print('Built unsigned iPhoneOS platform probe. Signing, installation and execution NOT RUN.')
