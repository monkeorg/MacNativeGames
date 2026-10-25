#!/usr/bin/env python3
"""Build the separate unsigned Canopy iPhoneOS inspection host, or print its plan.

Only fixed public repository inputs are accepted. No game, key, cache, SDK path,
compiler path, signing identity or private input options are supported. Generated
inventory is an observation, not independently reviewed provenance certification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


RECIPE = 'canopy-connected-host-arm64-ios16-v3'
BRAND = 'launcher/Resources/Branding/Canopy.png'
BRAND_SHA256 = 'f7f596a192596aee546970b4db36068efb9b65932743bd3318353b6ea7a340d0'
SOURCES = ('launcher/apple/Sources/CanopyApp.m',
           'launcher/apple/Sources/CanopyLibrary.m',
           'launcher/apple/Sources/CanopyCatalog.m',
           'launcher/apple/Sources/CanopySettings.m',
           'launcher/apple/Sources/CanopyPreparation.m',
           'launcher/apple/Sources/CanopyControllers.m',
           'launcher/apple/Sources/CanopyGames.m',
           'launcher/apple/Sources/CanopyRomFS.m',
           'launcher/apple/Sources/CanopySaveStore.m',
           'launcher/apple/Sources/CanopyShaderCache.m',
           'launcher/apple/Sources/CanopyDiagnostics.m',
           'launcher/apple/Sources/CanopyDiagnosticsController.m',
           'launcher/apple/Sources/CanopyRuntime.m',
           'launcher/apple/Sources/CanopySessionController.m',
           'launcher/apple/Sources/CanopyOverlay.m',
           'launcher/apple/Sources/CanopyStorage.m',
           'launcher/apple/Sources/CanopyStorageController.m',
           'games/totk/ios/Sources/save_validation.m',
           'launcher/src/mng_container.c', 'launcher/src/mng_file.c',
           'launcher/src/mng_crypto.c', 'launcher/src/mng_keys.c',
           'launcher/src/mng_content.c', 'launcher/src/mng_bktr.c', 'launcher/src/mng_prepare.c', 'launcher/src/mng_store.c',
           'launcher/src/mng_folder.c',
           'launcher/src/mng_romfs.c', 'launcher/src/mng_romfs_runtime.c',
           'launcher/src/mng_players.c', 'launcher/src/mng_session.c')
SOURCES += ('launcher/src/mng_addon.c', 'launcher/src/mng_multiplayer.c')
HEADERS = ('launcher/apple/Sources/CanopyLibrary.h',
           'launcher/apple/Sources/CanopyCatalog.h',
           'launcher/apple/Sources/CanopySettings.h',
           'launcher/apple/Sources/CanopyPreparation.h',
           'launcher/apple/Sources/CanopyControllers.h',
           'launcher/apple/Sources/CanopyGames.h',
           'launcher/apple/Sources/CanopyRomFS.h',
           'launcher/apple/Sources/CanopySaveStore.h',
           'launcher/apple/Sources/CanopyShaderCache.h',
           'launcher/apple/Sources/CanopyDiagnostics.h',
           'launcher/apple/Sources/CanopyDiagnosticsController.h',
           'launcher/apple/Sources/CanopyRuntime.h',
           'launcher/apple/Sources/CanopySessionController.h',
           'launcher/apple/Sources/CanopyOverlay.h',
           'launcher/apple/Sources/CanopyStorage.h',
           'launcher/apple/Sources/CanopyStorageController.h',
           'games/totk/ios/Sources/save_validation.h',
           'games/totk/runtime/canopy_host.h',
           'launcher/include/mng_container.h', 'launcher/include/mng_file.h',
           'launcher/include/mng_crypto.h', 'launcher/include/mng_keys.h',
           'launcher/include/mng_content.h', 'launcher/include/mng_bktr.h', 'launcher/include/mng_prepare.h', 'launcher/include/mng_store.h',
           'launcher/include/mng_folder.h', 'launcher/src/mng_prepare_internal.h',
           'launcher/include/mng_romfs.h', 'launcher/include/mng_romfs_runtime.h',
           'launcher/include/mng_players.h', 'launcher/include/mng_session.h')
HEADERS += ('launcher/include/mng_addon.h', 'launcher/include/mng_multiplayer.h')
INPUTS = SOURCES + HEADERS + (BRAND,)
MAX_INPUT_BYTES = 16 * 1024 * 1024


class BuildError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise BuildError(message)


def bundle_identifier(value):
    require(isinstance(value, str) and len(value) <= 255 and
            re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', value) and
            value.endswith('.canopy'),
            'bundle identifier must be a reverse-DNS identifier ending in .canopy')
    return value


def public_input(repo, name):
    """Reject linked inputs/ancestors; caller must use an isolated stable tree."""
    path = repo
    for part in Path(name).parts:
        path = path / part
        require(not path.is_symlink(), 'linked public input: ' + name)
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and before.st_size <= MAX_INPUT_BYTES,
            'invalid public input: ' + name)
    with path.open('rb') as stream:
        data = stream.read(MAX_INPUT_BYTES + 1)
        after = os.fstat(stream.fileno())
    require(len(data) <= MAX_INPUT_BYTES and
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            'public input changed while reading: ' + name)
    return data


def capture_inputs(repo):
    inputs = {name: public_input(repo, name) for name in INPUTS}
    require(hashlib.sha256(inputs[BRAND]).hexdigest() == BRAND_SHA256,
            'Canopy branding differs from the approved original PNG')
    return inputs


def records(inputs):
    return [{'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            for name, data in sorted(inputs.items())]


def recipe_identity(repo):
    revision = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True)
    return {'source_revision': revision.stdout.strip() if revision.returncode == 0 else None,
            'builder_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'source_note': 'Input hashes bind the actual files, including any uncommitted changes.'}


def commands(source_root, work, sdk):
    base = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios16.0',
            '-isysroot', sdk, '-O2', '-Wall', '-Wextra', '-fno-common',
            '-I', str(source_root / 'launcher/include'),
            '-I', str(source_root / 'launcher/apple/Sources')]
    result, objects = [], []
    for index, name in enumerate(SOURCES):
        obj = work / f'{index}.o'
        objects.append(str(obj))
        language = ['-fobjc-arc'] if name.endswith('.m') else ['-std=c11']
        result.append(base + language + ['-c', str(source_root / name), '-o', str(obj)])
    result.append(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios16.0',
                   '-isysroot', sdk, *objects, '-framework', 'UIKit', '-framework', 'Foundation',
                   '-framework', 'UniformTypeIdentifiers', '-framework', 'CoreFoundation',
                   '-framework', 'GameController',
                   '-framework', 'Metal', '-framework', 'QuartzCore',
                   '-Wl,-no_adhoc_codesign',
                   '-o', str(work / 'Canopy.app/Canopy')])
    return result


def build_plan(repo, identifier='org.monkeorg.canopy'):
    bundle_identifier(identifier)
    inputs = capture_inputs(repo)
    return {'status': 'plan only; Apple compilation not performed', 'recipe_id': RECIPE,
            **recipe_identity(repo),
            'bundle_identifier': identifier, 'deployment_target': '16.0',
            'input_files': records(inputs), 'sdk': 'resolved with xcrun --sdk iphoneos',
            'commands': commands(Path('<source-snapshot>'), Path('<staging>'), '<iphoneos-sdk>'),
            'resource': 'Canopy.png copied byte-for-byte; no icon asset catalog'}


def run_command(command):
    return subprocess.run(command, check=True, capture_output=True, text=True)


def plist(identifier):
    return plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleName': 'Canopy',
        'CFBundleDisplayName': 'Canopy', 'CFBundleExecutable': 'Canopy',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1',
        'CFBundleVersion': '1', 'MinimumOSVersion': '16.0', 'LSRequiresIPhoneOS': True,
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'UIDeviceFamily': [1, 2],
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'UILaunchScreen': {}, 'UISupportedInterfaceOrientations':
        ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft',
         'UIInterfaceOrientationLandscapeRight']}, sort_keys=True)


def build(repo, output, identifier='org.monkeorg.canopy', runner=run_command):
    """Build to a new directory. runner injection supports orchestration tests only.

    Requires an isolated stable source tree and parent output directory. Failure
    leaves a new diagnostic directory, never replaces an existing output.
    """
    bundle_identifier(identifier)
    repo = Path(repo).resolve()
    inputs = capture_inputs(repo)
    output = Path(output).absolute()
    require(output.parent.is_dir(), 'output parent must already exist')
    require(not output.exists() and not output.is_symlink(), 'output already exists')
    for parent in output.parents:
        require(not parent.is_symlink(), 'output ancestors must not be symlinks')
    output.mkdir()  # Exclusive creation; never overwrite an existing directory.
    observation = {'status': 'build started; no artifact accepted', 'recipe_id': RECIPE,
                   **recipe_identity(repo),
                   'bundle_identifier': identifier, 'input_files': records(inputs),
                   'commands': [], 'provenance_review': 'unreviewed build observation'}
    record_path = output / 'build-observation.json'
    try:
        with tempfile.TemporaryDirectory(prefix='.canopy-stage-', dir=output) as temporary:
            work = Path(temporary)
            snapshot = work / 'source'
            for name, data in inputs.items():
                destination = snapshot / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            def execute(command):
                observation['commands'].append(command)
                result = runner(command)
                require(getattr(result, 'returncode', 0) == 0, 'Apple command failed')
                return result.stdout.strip()
            sdk = execute(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
            require(sdk and '\n' not in sdk and Path(sdk).is_absolute(), 'invalid iPhoneOS SDK path')
            observation['sdk_path'] = sdk
            observation['sdk_version'] = execute(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'])
            observation['clang_version'] = execute(['xcrun', '--sdk', 'iphoneos', 'clang', '--version'])
            app = work / 'Canopy.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plist(identifier))
            (app / 'Canopy.png').write_bytes(inputs[BRAND])
            for command in commands(snapshot, work, sdk):
                execute(command)
            require(capture_inputs(repo) == inputs, 'repository inputs changed during build')
            require(capture_inputs(snapshot) == inputs, 'staged inputs changed during build')
            require({p.name for p in app.iterdir()} == {'Canopy', 'Info.plist', 'Canopy.png'},
                    'unexpected application output')
            output_files = {}
            for path in app.iterdir():
                require(path.is_file() and not path.is_symlink(), 'invalid application output')
                data = path.read_bytes()
                output_files[path.name] = data
            require(output_files['Canopy'], 'compiler produced empty executable')
            require(output_files['Canopy.png'] == inputs[BRAND], 'branding changed during build')
            require(output_files['Info.plist'] == plist(identifier), 'application metadata changed during build')
            observation['output_files'] = records(output_files)
            observation['status'] = 'unsigned build produced; independent review and Apple acceptance pending'
            observation['limitations'] = [
                'Build observation only; not independently reviewed provenance or content certification.',
                'No signing, installation, device test or gameplay acceptance performed.',
                'Canopy.png is an unchanged resource, not a compiled Apple app icon.']
            app.rename(output / 'Canopy.app')
    except Exception:
        observation['status'] = 'failed; no artifact accepted'
        record_path.write_text(json.dumps(observation, indent=2, sort_keys=True) + '\n')
        raise
    record_path.write_text(json.dumps(observation, indent=2, sort_keys=True) + '\n')
    return observation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', action='store_true', help='inspect public inputs and print a portable build plan')
    parser.add_argument('--out', type=Path, help='new output directory; existing paths are never overwritten')
    parser.add_argument('--bundle-id', default='org.monkeorg.canopy')
    args = parser.parse_args()
    if args.plan and args.out:
        parser.error('--plan does not create output; omit --out')
    if not args.plan and args.out is None:
        parser.error('--out is required unless --plan is selected')
    repo = Path(__file__).resolve().parents[2]
    try:
        result = build_plan(repo, args.bundle_id) if args.plan else build(repo, args.out, args.bundle_id)
    except (BuildError, OSError, subprocess.SubprocessError) as exc:
        print(f'Canopy build failed: {exc}', file=sys.stderr)
        # All compiler inputs are the fixed public snapshot. Preserve bounded
        # diagnostics so an actual compile/link failure can be corrected in CI.
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            diagnostics = exc.stderr.decode('utf-8', errors='replace') if isinstance(exc.stderr, bytes) else exc.stderr
            print(diagnostics[-65536:], file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
