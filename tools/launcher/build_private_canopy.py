#!/usr/bin/env python3
"""Build a local unsigned Canopy app from retained, verified native-port inputs.

--plan needs only public sources. --build requires an Apple silicon Mac, Xcode26,
a trusted local native exporter, local iPhoneOS codec libraries and private input
files. No downloads, signing, installation or game execution are performed.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOTK = Path('games/totk')
VERSIONS = {'v121': '1.2.1', 'v143': '1.4.3'}
RECIPE = 'canopy-private-native-ios26-icon-v2'
MODULES = ('main', 'subsdk0', 'sdk')
FRAMEWORKS = ('UIKit', 'Metal', 'MetalFX', 'Foundation', 'QuartzCore', 'ImageIO',
              'CoreGraphics', 'CoreText', 'UniformTypeIdentifiers', 'CoreFoundation',
              'AudioToolbox', 'GameController', 'AVFAudio', 'Security', 'WebKit', 'CoreHaptics')
DISPLAY_HEAP = 'romfs-patches-out/1920x1080-scene-1920x1080'
DISPLAY_LAYOUT = 'romfs-patches-4x3'
DISPLAY_EXPORT = {'TOTK_IOS_DISPLAY_SETTINGS': '1', 'TOTK_RENDER_RES': '1280x720',
                  'TOTK_OUTPUT_RES': '1280x720', 'TOTK_FIXED_RES': '1', 'TOTK_ASPECT': '0',
                  'TOTK_ASPECT_VERT': '1', 'TOTK_IOS_ASPECT_VERT': '1'}


def load_helper(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PUBLIC = load_helper('canopy_public_builder', 'tools/launcher/build_canopy.py')
APPLE = load_helper('canopy_apple_sources', 'games/totk/ios/tools/build_sources.py')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path, destination=None, expected=None, limit=64 << 30):
    """Stable regular-file read; copy uses exclusive creation and private mode."""
    path = Path(path)
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), 'linked private input refused')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    out = None
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= limit,
                'private input is not a bounded regular file')
        if destination is not None:
            destination = Path(destination)
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            out = os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb')
        sha = hashlib.sha256()
        total = 0
        with os.fdopen(fd, 'rb', closefd=False) as source:
            while chunk := source.read(1 << 20):
                total += len(chunk)
                sha.update(chunk)
                if out:
                    out.write(chunk)
        after = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(total == before.st_size and all(getattr(before, k) == getattr(after, k) for k in fields),
                'private input changed during read')
        result = sha.hexdigest()
        require(expected is None or result == expected, 'private input does not match the selected recipe')
        return result
    finally:
        if out:
            out.close()
        os.close(fd)


def expected_profile(repo, version):
    require(version in VERSIONS, 'unsupported private native profile')
    profile = json.loads(PUBLIC.public_input(repo, str(TOTK / f'assets/expected-v{VERSIONS[version]}.json')))
    require(profile['title_id'].lower() == '0100f2c0115b6000', 'unexpected recipe title identity')
    return profile


def source_names(repo, version):
    """Reuse the production runtime/NVN directory selection and public app list."""
    names = set(PUBLIC.SOURCES)
    excluded = {'frontend.m', 'game_patches_botw.c',
                'game_patches.c' if version == 'v143' else 'game_patches_v143.c'}
    for directory in (TOTK / 'runtime', TOTK / 'third_party/d2r_gfx/gfx/nvn',
                      TOTK / 'third_party/d2r_gfx/gfx/tex'):
        for path in sorted((repo / directory).iterdir()):
            if path.suffix in ('.c', '.m', '.S') and path.name not in excluded:
                names.add(str(path.relative_to(repo)))
    names.add('games/totk/ios/Sources/save_validation.m')
    return tuple(sorted(names))


def display_option(version, enabled):
    require(not enabled or version == 'v143', '--display-settings supports only TOTK1.4.3')


def exporter_environment(modules, display_settings=False):
    """Same explicit signed-code settings as the existing build_ipa exporter."""
    result = {'TOTK_EXPORT_IOS': str(modules)}
    if display_settings:
        result.update(DISPLAY_EXPORT)
    return result


def build_plan(repo=ROOT, version='v121', identifier='org.monkeorg.canopy', display_settings=False):
    display_option(version, display_settings)
    PUBLIC.bundle_identifier(identifier)
    profile = expected_profile(repo, version)
    sources = source_names(repo, version)
    plan = {'recipe': RECIPE, 'status': 'plan only; no private inputs or Apple compilation used',
            'bundleIdentifier': identifier, 'version': VERSIONS[version], 'titleID': profile['title_id'].lower(),
            'originalMainSHA256': profile['exefs_sha256']['main'],
            'romfsSHA256': profile['romfs']['sha256'], 'sources': list(sources),
            'entry': 'launcher/apple/Sources/CanopyApp.m',
            'loaderRename': {'source': 'games/totk/runtime/loader.c', 'flag': '-Dmain=totk_host_main'},
            'deploymentTarget': '26.0', 'signing': 'none',
            'steps': ['verify original ExeFS, rewrites, report, RomFS and shared fonts against checked-in recipe',
                      'stage public sources and private inputs without modifying retained inputs',
                      'run existing prepare_runtime.py, prepare_romfs_backend.py and prepare_shared_fonts.py',
                      'run explicitly trusted local Mac exporter in export-ios mode',
                      'run existing gen_embed.py; compile selected public sources and embedded sections',
                      'link unsigned Canopy.app with verified fonts and explicitly pinned shader seed'],
            'limitations': ['A build is not game compatibility, signing or device acceptance.',
                            'The current native host is single use and cannot safely stop or relaunch.']}
    if display_settings:
        plan['displaySettings'] = {'profile': 'v143-signed-720-1080-four-three-v1',
            'exporterEnvironment': dict(DISPLAY_EXPORT), 'maximumScene': '1920x1080',
            'aspectLayout': '1440x1080',
            'resources': [DISPLAY_HEAP + '/manifest.tsv', DISPLAY_LAYOUT + '/manifest.tsv'],
            'manifestPins': 'generated from verified staged private inputs; unavailable in a portable plan',
            'compileFlags': ['-DTOTK_IOS_DISPLAY_SETTINGS=1', '-DTOTK_IOS_ASPECT_VERT=1']}
        plan['steps'].insert(4, 'generate and validate the real 1920x1080 scene heap and 1440x1080 layout overlays; pin their exact manifests')
    return plan


def stable_bytes(path, limit):
    """Read small generated metadata once; parse/hash the same stable bytes."""
    path = Path(path)
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), 'linked display resource refused')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= limit,
                'invalid bounded display metadata')
        with os.fdopen(descriptor, 'rb', closefd=False) as source:
            data = source.read(limit + 1)
        after = os.fstat(descriptor)
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(len(data) == before.st_size and all(getattr(before, k) == getattr(after, k) for k in fields),
                'display metadata changed during read')
        return data
    finally:
        os.close(descriptor)


def display_path(name):
    require(isinstance(name, str) and len(name) <= 512 and
            re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', name) is not None and
            len(name.split('/')) <= 8 and all(part not in ('.', '..') for part in name.split('/')),
            'invalid display member path')
    return name


def original_member_hash(image, entry):
    require(isinstance(entry, dict) and type(entry.get('offset')) is int and type(entry.get('size')) is int and
            0 <= entry['offset'] and 0 <= entry['size'] <= 64 << 20, 'invalid display original member range')
    descriptor = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and entry['offset'] <= before.st_size and
                entry['size'] <= before.st_size - entry['offset'], 'display original member exceeds image')
        sha = hashlib.sha256();position = entry['offset'];remaining = entry['size']
        while remaining:
            data = os.pread(descriptor, min(remaining, 1 << 20), position)
            require(data, 'truncated display original member')
            sha.update(data);remaining -= len(data);position += len(data)
        after = os.fstat(descriptor)
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(all(getattr(before, k) == getattr(after, k) for k in fields), 'display original changed during read')
        return sha.hexdigest()
    finally:
        os.close(descriptor)


def validate_display_tree(folder, index, image, extra_files=()):
    """Authenticate original+generated bytes; refuse any unlisted file/tree."""
    raw = stable_bytes(folder / 'manifest.tsv', 128 << 10)
    try:
        lines = raw.decode('ascii').splitlines()
    except UnicodeDecodeError as error:
        raise ValueError('invalid display manifest encoding') from error
    members = {};folded = set();member_bytes = 0
    total = len(raw) + sum(len(stable_bytes(folder / name, 128 << 10)) for name in extra_files)
    for line in lines:
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        require(len(fields) == 4, 'invalid display manifest row')
        name, size, sha, original = fields;display_path(name)
        require(name.casefold() not in folded and name.casefold() not in {value.casefold() for value in ('manifest.tsv', *extra_files)} and
                re.fullmatch(r'0|[1-9][0-9]{0,9}', size) is not None and
                all(re.fullmatch('[0-9a-f]{64}', value) is not None for value in (sha, original)),
                'invalid or duplicate display manifest member')
        require(len(members) < 128 and 0 < int(size) <= 64 << 20 and total + int(size) <= 256 << 20,
                'display resource budget exceeded')
        require(name in index and original_member_hash(image, index[name]) == original,
                'display manifest does not match its verified original member')
        member = folder / name;metadata = member.lstat()
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size == int(size),
                'display member type or size mismatch')
        require(digest(member, expected=sha, limit=64 << 20) == sha, 'display member hash mismatch')
        members[name] = sha;folded.add(name.casefold());total += int(size);member_bytes += int(size)
    require(members, 'display manifest has no generated resources')
    expected = {'manifest.tsv', *members, *extra_files};directories = set()
    for name in members:
        directories.update(str(parent) for parent in Path(name).parents if str(parent) != '.')
    seen = set();seen_dirs = set();count = 0
    for current, children, files in os.walk(folder, followlinks=False):
        for name in [*children, *files]:
            count += 1;require(count <= 1152, 'display resource tree count exceeded')
            member = Path(current) / name;relative = str(member.relative_to(folder));metadata = member.lstat()
            require(not stat.S_ISLNK(metadata.st_mode), 'linked display resource refused')
            if stat.S_ISDIR(metadata.st_mode):
                require(relative in directories, 'unlisted display directory');seen_dirs.add(relative)
            else:
                require(relative in expected and stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1,
                        'unlisted or unsafe display file');seen.add(relative)
    require(seen == expected and seen_dirs == directories, 'incomplete display resource tree')
    return {'manifestSHA256': hashlib.sha256(raw).hexdigest(), 'members': members,
            'memberBytes': member_bytes, 'treeBytes': total}


def generate_display_resources(stage_tree, data, run):
    """Execute only the public staged generators on the verified staged image."""
    output = data / 'romfs-patches-out';layout = data / DISPLAY_LAYOUT
    require(output.is_dir() and not any(output.iterdir()) and not layout.exists(),
            'display resources require fresh output directories')
    run([sys.executable, str(stage_tree / 'scripts/make_output_res_overlay.py'), '1920x1080',
         '--scene', '1920x1080', '--version', 'v143', '--output-root', str(output)])
    run([sys.executable, str(stage_tree / 'scripts/make_romfs_patches.py'), '--version', 'v143',
         '--aspect', '1440x1080', '--output-dir', str(layout)])
    source = stage_tree / 'extracted/v143/romfs'
    index_document = json.loads(stable_bytes(source / 'index.json', 256 << 20))
    require(isinstance(index_document, dict) and isinstance(index_document.get('files'), list) and len(index_document['files']) <= 1000000,
            'display generation requires the verified extraction inventory')
    index = {}
    for entry in index_document['files']:
        require(isinstance(entry, dict) and isinstance(entry.get('path'), str) and entry['path'] not in index,
                'duplicate or invalid original inventory member')
        index[entry['path']] = entry
    heap = data / DISPLAY_HEAP
    require(sorted(p.name for p in output.iterdir()) == [heap.name], 'unexpected generated output profile')
    heap_record = validate_display_tree(heap, index, source / 'romfs.bin', ('overlay.json',))
    layout_record = validate_display_tree(layout, index, source / 'romfs.bin')
    metadata_bytes = stable_bytes(heap / 'overlay.json', 128 << 10)
    metadata = json.loads(metadata_bytes)
    script = stage_tree / 'scripts/make_output_res_overlay.py'
    require(isinstance(metadata, dict) and metadata.get('script') == script.name and
            metadata.get('script_sha256') == digest(script, limit=4 << 20) and metadata.get('version') == 'v143' and
            metadata.get('size') == '1920x1080' and metadata.get('scene') == '1920x1080' and
            metadata.get('heapdef') is None and metadata.get('heapdef_sha256') is None and
            type(metadata.get('extra_kib')) is int and metadata['extra_kib'] > 0,
            'generated display heap recipe does not match its staged generator')
    # Existing generators emit build provenance, but the native overlay loader
    # consumes only manifest.tsv and its members. Keep provenance in the private
    # observation, never as an unbound extra file in the installed resource tree.
    metadata_sha = hashlib.sha256(metadata_bytes).hexdigest()
    generated_bytes = heap_record['treeBytes']
    (heap / 'overlay.json').unlink()
    heap_record = validate_display_tree(heap, index, source / 'romfs.bin')
    heap_record['generatedTreeBytes'] = generated_bytes
    heap_record['overlayMetadataSHA256'] = metadata_sha
    heap_record['overlayMetadata'] = {key: metadata[key] for key in (
        'script', 'script_sha256', 'version', 'size', 'scene', 'extra_kib', 'heapdef', 'heapdef_sha256')}
    return {'heapManifestSHA256': heap_record['manifestSHA256'],
            'layoutManifestSHA256': layout_record['manifestSHA256'],
            'heap': heap_record, 'layout': layout_record,
            'generatorSHA256': {str(name): digest(stage_tree / name, limit=4 << 20) for name in (
                'scripts/make_output_res_overlay.py', 'scripts/make_romfs_patches.py', 'scripts/tall_layout.py')}}


def copy_public(repo, stage):
    # A tracked public source snapshot excludes ignored extracted/build/rewritten
    # data. Generator dependencies are copied with their original relative roots.
    tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
    snapshot = {}
    for raw in tracked:
        if not raw:
            continue
        name = os.fsdecode(raw)
        if name.startswith(('launcher/', 'games/totk/')) and Path(name).suffix in (
                '.c', '.m', '.S', '.h', '.inc', '.def', '.py', '.json', '.png'):
            data = PUBLIC.public_input(repo, name)
            destination = stage / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            snapshot[name] = hashlib.sha256(data).hexdigest()
    return snapshot


def stage_inputs(tree, stage_tree, version, profile):
    copied = {}
    def copy(name, expected=None, limit=64 << 30):
        copied[name] = digest(tree / name, stage_tree / name, expected, limit)
    for name, sha in profile['exefs_sha256'].items():
        copy(f'extracted/{version}/exefs/{name}', sha, 512 << 20)
    for name, sha in profile['rewritten_sha256'].items():
        copy(f'rewritten/{version}/{name}', sha, 1 << 30)
    report_name = f'analysis/{version}-port/phase12-validation.json'
    copy(report_name, limit=16 << 20)
    report = json.loads((stage_tree / report_name).read_bytes())
    require(report.get('status') == 'pass' and report.get('rom_version') == version,
            'retained native validation did not pass the selected version')
    for name in MODULES:
        require(report['module_file_sha256'][f'extracted/{version}/exefs/{name}'] == profile['exefs_sha256'][name] and
                report['module_file_sha256'][f'rewritten/{version}/{name}.patched.bin'] == profile['rewritten_sha256'][name + '.patched.bin'],
                'retained report disagrees with the checked-in recipe')
        for suffix in ('fixups.tsv', 'gates.tsv'):
            copy(f'rewritten/{version}/{name}.{suffix}', limit=64 << 20)
        copy(f'extracted/{version}/elf/{name}-inventory.json', limit=16 << 20)
    copy(f'extracted/{version}/romfs/romfs.bin', profile['romfs']['sha256'])
    require((stage_tree / f'extracted/{version}/romfs/romfs.bin').stat().st_size == profile['romfs']['size'],
            'RomFS size disagrees with the checked-in recipe')
    copy(f'extracted/{version}/romfs/index.json', limit=256 << 20)
    index = json.loads((stage_tree / f'extracted/{version}/romfs/index.json').read_bytes())
    require(index.get('status') == 'pass' and index.get('romfs_sha256') == profile['romfs']['sha256'] and
            index.get('romfs_size') == profile['romfs']['size'], 'retained RomFS index identity mismatch')
    copy('extracted/firmware/shared-fonts/manifest.json', limit=1 << 20)
    fonts = json.loads((stage_tree / 'extracted/firmware/shared-fonts/manifest.json').read_bytes())
    require(fonts.get('status') == 'pass' and [f['type'] for f in fonts['fonts']] == list(range(6)),
            'invalid shared-font manifest')
    for font in fonts['fonts']:
        name = font['name']
        require(name == list(profile['shared_fonts_sha256'])[font['type']], 'shared-font name/type mismatch')
        require(name in profile['shared_fonts_sha256'] and font['sha256'] == profile['shared_fonts_sha256'][name],
                'shared-font identity mismatch')
        copy(f'extracted/firmware/shared-fonts/{font["type"]}-{name}.bfttf', font['sha256'], 64 << 20)
    return copied


def stage_seed(source, destination, expected, romfs, chain):
    require(re.fullmatch('[0-9a-f]{64}', expected) is not None, 'a reviewed shader manifest SHA256 is required')
    destination.mkdir(mode=0o700)
    digest(source / 'seed-manifest.json', destination / 'seed-manifest.json', expected, 32 << 20)
    manifest = json.loads((destination / 'seed-manifest.json').read_bytes())
    require(manifest.get('schema') == 1 and type(manifest.get('shaders')) is int and 1 <= manifest['shaders'] <= 100000 and
            all(isinstance(manifest.get(k), str) and re.fullmatch('[0-9a-f]{64}', manifest[k]) for k in
                ('translator_sha256', 'spirv_cross_sha256', 'preparation_sha256')), 'invalid shader preparation identities')
    require(manifest.get('source_romfs_sha256') == romfs and manifest.get('chain') == chain,
            'shader seed does not belong to the selected profile and translator chain')
    files = dict(manifest['files'])
    require('shader_map.tsv' not in files and len(files) <= 100000, 'invalid shader seed file table')
    files['shader_map.tsv'] = manifest['shader_map_sha256']
    total = (destination / 'seed-manifest.json').stat().st_size
    for name, sha in files.items():
        require(re.fullmatch(r'[A-Za-z0-9_-]+\.(?:metal|json|metallib|variants|tsv)', name) is not None and
                re.fullmatch('[0-9a-f]{64}', sha) is not None, 'invalid shader seed member')
        digest(source / name, destination / name, sha, min(64 << 20, (16 << 30) - total))
        total += (destination / name).stat().st_size


def stage_codecs(source, destination):
    records = {}
    include = source / 'include'
    require(include.is_dir() and not include.is_symlink(), 'codec include directory is unavailable')
    total = 0
    for path in sorted(include.rglob('*')):
        relative = path.relative_to(include)
        require(not path.is_symlink() and len(relative.parts) <= 8, 'linked or excessive codec header tree refused')
        if path.is_dir():
            continue
        require(len(records) < 10000, 'codec header count exceeds limit')
        name = 'include/' + str(relative)
        records[name] = digest(path, destination / name, limit=min(16 << 20, (512 << 20) - total))
        total += (destination / name).stat().st_size
    require(records and (destination / 'include/vpx/vpx_decoder.h').is_file() and
            ((destination / 'include/opus/opus.h').is_file() or (destination / 'include/opus.h').is_file()),
            'codec headers are incomplete')
    for name in ('opus', 'vpx'):
        leaf = f'lib/lib{name}.a'
        records[leaf] = digest(source / leaf, destination / leaf, limit=512 << 20)
    return records


def compiler_commands(stage, work, toolchain, version, profile, seed_sha, deps, display_profile=None):
    display_option(version, display_profile is not None)
    generated = stage / TOTK / ('build/' + version)
    base = [toolchain['clang'], '-target', 'arm64-apple-ios26.0', '-isysroot', toolchain['sdk'],
            '-O2', '-mcpu=apple-a15', '-Wall', '-Wextra', '-Werror=implicit-function-declaration',
            '-DCANOPY_HOST_RUNTIME=1', '-DTOTK_GAME_' + version.upper() + '=1',
            '-DCANOPY_HOST_TITLE_ID=0x' + profile['title_id'] + 'ULL',
            '-DCANOPY_HOST_ORIGINAL_MAIN_SHA256="' + profile['exefs_sha256']['main'] + '"',
            '-DCANOPY_HOST_SHADER_SEED_MANIFEST_SHA256="' + seed_sha + '"']
    if display_profile is not None:
        require(isinstance(display_profile, dict) and all(isinstance(display_profile.get(key), str) and
                re.fullmatch('[0-9a-f]{64}', display_profile[key]) for key in
                ('heapManifestSHA256', 'layoutManifestSHA256')), 'generated display manifest pins are required')
        base += ['-DTOTK_IOS_DISPLAY_SETTINGS=1', '-DTOTK_IOS_ASPECT_VERT=1',
                 '-DCANOPY_HOST_DISPLAY_HEAP_SHA256="' + display_profile['heapManifestSHA256'] + '"',
                 '-DCANOPY_HOST_DISPLAY_LAYOUT_SHA256="' + display_profile['layoutManifestSHA256'] + '"']
    for folder in (stage / 'launcher/include', stage / 'launcher/apple/Sources', stage / TOTK / 'runtime',
                   stage / TOTK / 'third_party/d2r_gfx/gfx/nvn', stage / TOTK / 'third_party/d2r_gfx/gfx/nvn/include',
                   generated, stage / TOTK / 'build', work, deps / 'include', deps / 'include/opus'):
        base += ['-I', str(folder)]
    commands, objects = [], []
    for i, name in enumerate((*source_names(stage, version), str(work / 'embed.S'))):
        obj = work / f'object-{i}.o';objects.append(str(obj))
        flags = ['-fobjc-arc', '-fblocks'] if name.endswith('.m') else ['-std=gnu11'] if name.endswith('.c') else []
        if name == 'games/totk/runtime/loader.c':
            flags += ['-Dmain=totk_host_main']
        commands.append(base + flags + ['-c', str(stage / name), '-o', str(obj)])
    return commands, objects


def package_app_icon(stage, work, app, run):
    """Reuse the public icon recipe in an isolated, payload-free asset directory."""
    icon_work = work / 'app-icon'
    icon_app = icon_work / 'Canopy.app'
    catalog = icon_work / 'Assets.xcassets/AppIcon.appiconset'
    catalog.mkdir(parents=True, mode=0o700)
    icon_app.mkdir(mode=0o700)
    (catalog.parent / 'Contents.json').write_bytes(PUBLIC.catalog_root())
    (catalog / 'Contents.json').write_bytes(PUBLIC.icon_catalog())
    source = stable_bytes(stage / PUBLIC.BRAND, PUBLIC.MAX_INPUT_BYTES)
    require(hashlib.sha256(source).hexdigest() == PUBLIC.BRAND_SHA256 and
            PUBLIC.png_dimensions(source) == [1254, 1254], 'invalid approved app icon source')
    versions = {'sips': run(['/usr/bin/sips', '--version']),
                'actool': run(['xcrun', '--sdk', 'iphoneos', 'actool', '--version'])}
    commands = PUBLIC.icon_commands(stage, icon_work)
    run(commands[0])
    generated = stable_bytes(catalog / 'Canopy-1024.png', PUBLIC.MAX_INPUT_BYTES)
    require(PUBLIC.png_dimensions(generated) == [1024, 1024], 'app icon derivative must be 1024x1024')
    run(commands[1])
    icons = PUBLIC.icon_metadata(icon_work / 'icon-info.plist')
    outputs = PUBLIC.icon_outputs(icon_app)
    require(stable_bytes(catalog / 'Canopy-1024.png', PUBLIC.MAX_INPUT_BYTES) == generated and
            stable_bytes(catalog / 'Contents.json', 65536) == PUBLIC.icon_catalog() and
            stable_bytes(catalog.parent / 'Contents.json', 65536) == PUBLIC.catalog_root(),
            'app icon catalog changed during compilation')
    for name, content in outputs.items():
        target = app / name
        with target.open('xb') as destination:
            destination.write(content)
        require(digest(target, expected=hashlib.sha256(content).hexdigest(), limit=64 << 20),
                'packaged app icon changed')
    return icons, {'sourceSHA256': PUBLIC.BRAND_SHA256,
        'generatedSHA256': hashlib.sha256(generated).hexdigest(),
        'sourceDimensions': [1254, 1254], 'generatedDimensions': [1024, 1024],
        'catalogSHA256': hashlib.sha256(PUBLIC.icon_catalog()).hexdigest(),
        'compiledFiles': PUBLIC.records(outputs), 'toolVersions': versions}


def build(args):
    # Refuse unsupported opt-ins before inspecting private paths or Apple tools.
    display_settings = getattr(args, 'display_settings', False)
    display_option(getattr(args, 'version', None), display_settings)
    require(sys.platform == 'darwin' and os.uname().machine == 'arm64', 'private build requires an Apple silicon Mac')
    repo = ROOT
    PUBLIC.bundle_identifier(args.bundle_id)
    profile = expected_profile(repo, args.version)
    branding = PUBLIC.public_input(repo, PUBLIC.BRAND)
    require(hashlib.sha256(branding).hexdigest() == PUBLIC.BRAND_SHA256, 'Canopy branding differs from the approved original')
    tree = args.tree.resolve(strict=True);deps = args.deps.resolve(strict=True);seed = args.shader_seed.resolve(strict=True)
    require(tree != repo / TOTK, 'use an isolated retained private tree, not this public checkout')
    output = args.out.absolute()
    require(output.parent.is_dir() and not output.exists() and not output.is_symlink(), 'output must be a new directory')
    for parent in output.parents:
        require(not parent.is_symlink(), 'linked output ancestor refused')
    toolchain = APPLE.apple_toolchain(args.developer_dir)
    env = dict(os.environ, DEVELOPER_DIR=toolchain['developer_dir'])
    for key in tuple(env):
        if key.startswith(('TOTK_', 'DM_NVN_')):
            del env[key]
    output.mkdir(mode=0o700)
    observation = {'recipe': RECIPE, 'status': 'started; no accepted artifact', 'toolchain': toolchain,
                   'bundleIdentifier': args.bundle_id, 'version': args.version, 'commands': [],
                   'builderSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    def run(command, extra=None):
        observation['commands'].append([str(x) for x in command])
        result = subprocess.run(command, env=env if extra is None else dict(env, **extra),
                                capture_output=True, text=True, check=False)
        log = output / f'command-{len(observation["commands"]):04d}.log'
        log.write_text(result.stdout + result.stderr)
        log.chmod(0o600)
        require(result.returncode == 0, 'private build command failed; inspect the private build log')
        return result.stdout.strip()
    try:
        with tempfile.TemporaryDirectory(prefix='.private-stage-', dir=output) as folder:
            work = Path(folder);stage = work / 'source';stage.mkdir()
            observation['publicInputs'] = copy_public(repo, stage)
            stage_tree = stage / TOTK
            observation['privateInputs'] = stage_inputs(tree, stage_tree, args.version, profile)
            generated = stage_tree / 'build' / args.version
            for script in ('prepare_runtime.py', 'prepare_romfs_backend.py'):
                run([sys.executable, str(stage_tree / 'scripts' / script), '--version', args.version])
            run([sys.executable, str(stage_tree / 'scripts/prepare_shared_fonts.py')])
            host = tree / f'build/totk-native-{args.version}'
            require(os.access(host, os.X_OK), 'trusted local exporter is not executable')
            exporter = work / 'trusted-native-exporter'
            observation['trustedLocalExporterSHA256'] = digest(host, exporter, limit=512 << 20)
            exporter.chmod(0o700)
            modules = work / 'modules';modules.mkdir()
            run([str(exporter), str(stage_tree / 'rewritten' / args.version), 'export-ios'], exporter_environment(modules, display_settings))
            flags = shlex.split(run([sys.executable, str(stage_tree / 'ios/tools/gen_embed.py'),
                                    str(stage_tree / 'rewritten' / args.version), str(work / 'embed.S'),
                                    '--text-dir', str(modules), *MODULES]))
            require(flags == [f'-Wl,-segprot,__TOTK{m}W,rw,rw' for m in MODULES] + ['-Wl,-segprot,__TOTKX,r-x,r-x'],
                    'unexpected generated segment flags')
            app = work / 'Canopy.app';app.mkdir(mode=0o700)
            data = app / 'GameData';data.mkdir(mode=0o700)
            chain_header = (stage_tree / 'third_party/d2r_gfx/gfx/nvn/dmsh_chain.h').read_text()
            chain = re.search(r'^#define DMSH_CHAIN "([^"\n]+)"$', chain_header, re.M).group(1)
            stage_seed(seed, data / 'shader-seed', args.shader_manifest_sha256, profile['romfs']['sha256'], chain)
            shutil.copytree(stage_tree / 'extracted/firmware/shared-fonts', data / 'shared-fonts')
            for name in ('romfs-patches', 'romfs-patches-out'):
                (data / name).mkdir(mode=0o700)  # No unverified optional title patches.
            display_profile = generate_display_resources(stage_tree, data, run) if display_settings else None
            if display_profile is not None:
                observation['displaySettings'] = display_profile
            codec_snapshot = work / 'codecs'
            observation['codecInputs'] = stage_codecs(deps, codec_snapshot)
            libraries = [str(codec_snapshot / f'lib/lib{name}.a') for name in ('opus', 'vpx')]
            commands, objects = compiler_commands(stage, work, toolchain, args.version, profile, args.shader_manifest_sha256, codec_snapshot, display_profile)
            for command in commands:
                run(command)
            link = [toolchain['clang'], '-target', 'arm64-apple-ios26.0', '-isysroot', toolchain['sdk'],
                    *objects, *libraries, *flags, '-Wl,-no_adhoc_codesign']
            for framework in FRAMEWORKS:
                link += ['-framework', framework]
            run(link + ['-o', str(app / 'Canopy')])
            import plistlib
            icons, observation['appIcon'] = package_app_icon(stage, work, app, run)
            info = plistlib.loads(PUBLIC.plist(args.bundle_id, icons));info['MinimumOSVersion'] = '26.0'
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            (app / 'Canopy.png').write_bytes(branding)
            observation['executableSHA256'] = digest(app / 'Canopy')
            observation['shaderManifestSHA256'] = args.shader_manifest_sha256
            app.rename(output / 'Canopy.app')
            observation['status'] = 'unsigned private app built; signing, device acceptance and gameplay untested'
    except Exception:
        observation['status'] = 'failed; no accepted artifact'
        raise
    finally:
        (output / 'private-build-observation.json').write_text(json.dumps(observation, indent=2, sort_keys=True) + '\n')
        (output / 'private-build-observation.json').chmod(0o600)
    return observation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--version', choices=VERSIONS, default='v121')
    parser.add_argument('--display-settings', action='store_true', help='opt-in v143 signed720/1080 scene and4:3 aspect profile')
    parser.add_argument('--bundle-id', default='org.monkeorg.canopy')
    parser.add_argument('--tree', type=Path, help='trusted retained private games/totk tree')
    parser.add_argument('--deps', type=Path, help='local iPhoneOS codec prefix with include/ and lib/')
    parser.add_argument('--shader-seed', type=Path)
    parser.add_argument('--shader-manifest-sha256', help='explicit independently reviewed seed-manifest pin')
    parser.add_argument('--developer-dir')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.plan == args.build:
        parser.error('select exactly one of --plan or --build')
    if args.display_settings and args.version != 'v143':
        parser.error('--display-settings supports only TOTK1.4.3')
    if args.plan:
        print(json.dumps(build_plan(version=args.version, identifier=args.bundle_id, display_settings=args.display_settings), indent=2))
    else:
        if not all((args.tree, args.deps, args.shader_seed, args.shader_manifest_sha256, args.out)):
            parser.error('--build requires --tree, --deps, --shader-seed, --shader-manifest-sha256 and --out')
        try:
            build(args)
        except (ValueError, OSError, KeyError, subprocess.SubprocessError):
            parser.exit(1, 'Private build failed; no signing or device acceptance was performed.\n')
        print('Unsigned private Canopy app built; device acceptance remains untested.')


if __name__ == '__main__':
    main()
