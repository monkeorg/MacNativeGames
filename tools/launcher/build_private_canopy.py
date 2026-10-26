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
import mmap
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RECIPE = 'canopy-private-native-ios26-game-data-v1'
FRAMEWORKS = ('UIKit', 'Metal', 'MetalFX', 'Foundation', 'QuartzCore', 'ImageIO',
              'CoreGraphics', 'CoreText', 'UniformTypeIdentifiers', 'CoreFoundation',
              'AudioToolbox', 'GameController', 'AVFAudio', 'Security', 'WebKit', 'CoreHaptics')
SHADER_SYSTEM_LIBRARIES = {'-lSystem', '-lobjc', '-lc++', '-liconv', '-lz', '-licucore', '-lcompression', '-lresolv'}
SHADER_SYSTEM_FRAMEWORKS = set(FRAMEWORKS) | {'CFNetwork', 'GSS', 'Network', 'SystemConfiguration'}
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
PROFILE_HELPER = 'tools/launcher/game_profiles.py'
# Bind the observation to the exact source bytes executed, bypassing bytecode
# caches and a later path reread. PUBLIC/APPLE retain their existing loaders.
PROFILE_HELPER_BYTES = PUBLIC.public_input(ROOT, PROFILE_HELPER)
if len(PROFILE_HELPER_BYTES) > 1 << 20:
    raise ValueError('registry helper exceeds source bound')
PROFILE_HELPER_SHA256 = hashlib.sha256(PROFILE_HELPER_BYTES).hexdigest()
_profile_spec = importlib.util.spec_from_file_location('canopy_game_profiles', ROOT / PROFILE_HELPER)
PROFILES = importlib.util.module_from_spec(_profile_spec)
exec(compile(PROFILE_HELPER_BYTES, str(ROOT / PROFILE_HELPER), 'exec'), PROFILES.__dict__)
DEFAULT_GAME = PROFILES.game_profile(ROOT)
TOTK = Path(DEFAULT_GAME['sourceDirectory'])
DEFAULT_VERSION = DEFAULT_GAME['defaultVersion']
VERSIONS = {v['alias']: v['_expected']['display_version'] for v in DEFAULT_GAME['versions']}
MODULES = tuple(DEFAULT_GAME['modules'])
DISPLAY_VERSION = next(v['alias'] for v in DEFAULT_GAME['versions']
                       if PROFILES.DISPLAY[v['displayProfile']] != 0)


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
    return PROFILES.version_profile(repo, version)[1]['_expected']


def source_names(repo, version):
    """Reuse the production runtime/NVN directory selection and public app list."""
    game, selected = PROFILES.version_profile(repo, version)
    source_root = Path(game['sourceDirectory'])
    names = set(PUBLIC.SOURCES)
    excluded = {'frontend.m', 'game_patches_botw.c'} | {
        v['patchSource'] for v in game['versions'] if v['patchSource'] != selected['patchSource']}
    for directory in (source_root / 'runtime', source_root / 'third_party/d2r_gfx/gfx/nvn',
                      source_root / 'third_party/d2r_gfx/gfx/tex'):
        for path in sorted((repo / directory).iterdir()):
            if path.suffix in ('.c', '.m', '.S') and path.name not in excluded:
                names.add(str(path.relative_to(repo)))
    names.add('games/totk/ios/Sources/save_validation.m')
    names.add('launcher/apple/Sources/CanopyShaderTranslator.m')
    return tuple(sorted(names))


def display_option(version, enabled):
    if enabled:
        selected = PROFILES.version_profile(ROOT, version)[1]
        require(PROFILES.DISPLAY[selected['displayProfile']] != 0,
                '--display-settings supports only TOTK1.4.3')


def exporter_environment(modules, display_settings=False):
    """Same explicit signed-code settings as the existing build_ipa exporter."""
    result = {'TOTK_EXPORT_IOS': str(modules)}
    if display_settings:
        result.update(DISPLAY_EXPORT)
    return result


def build_plan(repo=ROOT, version=DEFAULT_VERSION, identifier='org.monkeorg.canopy', display_settings=False):
    display_option(version, display_settings)
    PUBLIC.bundle_identifier(identifier)
    profile = expected_profile(repo, version)
    game, selected = PROFILES.version_profile(repo, version)
    sources = source_names(repo, version)
    plan = {'recipe': RECIPE, 'status': 'plan only; no private inputs or Apple compilation used',
            'bundleIdentifier': identifier, 'version': profile['display_version'], 'titleID': profile['title_id'].lower(),
            'gameProfile': game['gameID'], 'registrySHA256': game['_registrySHA256'],
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
        plan['displaySettings'] = {'profile': selected['displayProfile'],
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


def generate_display_resources(stage_tree, data, run, version=DISPLAY_VERSION):
    """Execute only the public staged generators on the verified staged image."""
    output = data / 'romfs-patches-out';layout = data / DISPLAY_LAYOUT
    require(output.is_dir() and not any(output.iterdir()) and not layout.exists(),
            'display resources require fresh output directories')
    run([sys.executable, str(stage_tree / 'scripts/make_output_res_overlay.py'), '1920x1080',
         '--scene', '1920x1080', '--version', version, '--output-root', str(output)])
    run([sys.executable, str(stage_tree / 'scripts/make_romfs_patches.py'), '--version', version,
         '--aspect', '1440x1080', '--output-dir', str(layout)])
    source = stage_tree / 'extracted' / version / 'romfs'
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
            metadata.get('script_sha256') == digest(script, limit=4 << 20) and metadata.get('version') == version and
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
    copy(f'rewritten/{version}/build_src.sha256', limit=4096)
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


def shader_native_option(source, report_sha):
    require((source is None) == (report_sha is None),
            'native shader products and their explicit build-report SHA256 are required together')
    require(report_sha is None or re.fullmatch('[0-9a-f]{64}', report_sha) is not None,
            'invalid native shader build-report pin')


def inspect_shader_autolink(data, start, end):
    """An object cannot smuggle dependencies around the closed link plan."""
    require(12 <= end - start <= 65536, 'native autolink command exceeds bounds')
    count = struct.unpack_from('<I', data, start + 8)[0]
    require(count <= 128, 'native autolink token count exceeds limit')
    tokens, at = [], start + 12
    for _ in range(count):
        stop = data.find(b'\0', at, min(end, at + 257))
        require(stop >= at, 'native autolink token is missing or excessive')
        tokens.append(data[at:stop].decode('ascii'));at = stop + 1
    require(all(byte == 0 for byte in data[at:end]), 'unexpected native autolink trailing bytes')
    index = 0
    while index < len(tokens):
        token = tokens[index];index += 1
        if token in SHADER_SYSTEM_LIBRARIES:
            continue
        require(token in ('-framework', '-weak_framework') and index < len(tokens) and
                tokens[index] in SHADER_SYSTEM_FRAMEWORKS,
                'hidden native dependency or linker directive refused')
        index += 1


def inspect_shader_archive(path):
    """Inspect every real archive object, not report/RID/filename assertions.

    No compiler/tool invocation. Thin archives, bitcode, fat objects, arm64e,
    simulator/macOS and objects without explicit iOS build metadata refuse.
    """
    require(8 <= path.stat().st_size <= 512 << 20, 'native shader archive exceeds bounds')
    objects, members, names, tables = 0, 0, set(), set()
    with path.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        require(data[:8] == b'!<arch>\n', 'native shader input is not a self-contained archive')
        at, string_table = 8, b''
        while at < len(data):
            members += 1
            require(members <= 4112, 'native archive total member count exceeds limit')
            require(at + 60 <= len(data) and data[at + 58:at + 60] == b'`\n', 'invalid archive header')
            raw_name = data[at:at + 16].decode('ascii').strip()
            raw_size = data[at + 48:at + 58].decode('ascii').strip()
            require(raw_size.isdecimal(), 'invalid archive member size')
            size = int(raw_size);start = at + 60;end = start + size
            require(end <= len(data), 'truncated archive member')
            name = raw_name
            if raw_name.startswith('#1/'):
                require(raw_name[3:].isdecimal(), 'invalid BSD archive name')
                length = int(raw_name[3:]);require(0 < length <= 255 and length <= size, 'excessive archive name')
                name = data[start:start + length].rstrip(b'\0').decode('ascii');start += length
            elif raw_name == '//':
                require(size <= 1 << 20, 'archive string table exceeds bounds')
                string_table = data[start:end]
            elif raw_name.startswith('/') and raw_name[1:].isdecimal():
                offset = int(raw_name[1:]);require(offset < len(string_table), 'invalid archive name offset')
                stop = string_table.find(b'/\n', offset)
                require(stop >= offset and stop - offset <= 255, 'invalid archive long name')
                name = string_table[offset:stop].decode('ascii')
            metadata = name in ('/', '//', '/SYM64/', '__.SYMDEF', '__.SYMDEF SORTED',
                                '__.SYMDEF_64', '__.SYMDEF_64 SORTED')
            if metadata:
                require(name not in tables, 'duplicate native archive metadata table')
                tables.add(name)
            else:
                name = name[:-1] if name.endswith('/') else name
                require(name and '/' not in name and len(name) <= 255 and
                        all(32 <= ord(c) < 127 for c in name) and name not in names,
                        'unsafe or duplicate native archive member')
                names.add(name);objects += 1;require(objects <= 4096, 'native archive member count exceeds limit')
                require(end - start >= 32, 'native archive member is not Mach-O')
                magic, cpu, subtype, kind, count, command_bytes, _, _ = struct.unpack_from('<8I', data, start)
                require(magic == 0xfeedfacf and cpu == 0x0100000c and subtype == 0 and kind == 1 and
                        0 < count <= 4096 and command_bytes <= 1 << 20 and start + 32 + command_bytes <= end,
                        'native shader object is not bounded plain arm64 Mach-O')
                cursor, builds = start + 32, 0
                for _ in range(count):
                    require(cursor + 8 <= start + 32 + command_bytes, 'truncated Mach-O load command')
                    command, length = struct.unpack_from('<2I', data, cursor)
                    require(length >= 8 and length % 4 == 0 and cursor + length <= start + 32 + command_bytes,
                            'invalid Mach-O load command size')
                    plain_command = command & 0x7fffffff
                    require(plain_command not in (0x24, 0x25, 0x2f, 0x30),
                            'legacy/contradictory native platform metadata refused')
                    require(plain_command not in (0x0c, 0x0d, 0x0e, 0x0f, 0x18, 0x1c, 0x1f, 0x20, 0x23, 0x27),
                            'dynamic dependency/rpath/environment command in native object refused')
                    if plain_command == 0x2d:  # LC_LINKER_OPTION
                        inspect_shader_autolink(data, cursor, cursor + length)
                    if command == 0x32:  # LC_BUILD_VERSION, PLATFORM_IOS
                        require(length >= 24, 'truncated native build version')
                        platform, minimum, _, tools = struct.unpack_from('<4I', data, cursor + 8)
                        require(platform == 2 and 0 < minimum <= 0x00100000 and 24 + tools * 8 <= length,
                                'native shader object target is not supported iPhoneOS16-or-earlier')
                        builds += 1
                    cursor += length
                require(cursor == start + 32 + command_bytes and builds == 1,
                        'native shader object lacks one exact platform identity')
            at = end + (size & 1)
        require(at == len(data) and objects, 'empty or malformed native archive')
    return {'objects': objects, 'architecture': 'arm64', 'platform': 'IOS', 'maximumMinimumOS': '16.0'}


def stage_shader_native(source, destination, report_sha, repo):
    """Explicit local executable-input admission, never runtime/import JSON.

    The operator pins the publisher report. Actual captured archive bytes and
    every runtime archive determine the compiled cache recipe. Link plans are
    parsed into a closed argument grammar; never forwarded or shell-executed.
    """
    source = Path(source).absolute();destination.mkdir(mode=0o700)
    report_bytes = stable_bytes(source / 'native-build.json', 8 << 20)
    require(hashlib.sha256(report_bytes).hexdigest() == report_sha, 'native shader report pin mismatch')
    report = json.loads(report_bytes)
    require(isinstance(report, dict) and type(report.get('schema')) is int and report['schema'] == 1 and report.get('rid') == 'ios-arm64' and
            report.get('kind') == 'Static' and all(report.get(k) is True for k in
                ('crossCompiled', 'nativeAotCompiled', 'staticConsumerLinked')),
            'native shader products lack a real static iPhoneOS consumer build')
    here = repo / 'games/totk/tools/totk_xlate'
    recipe = hashlib.sha256()
    paths = sorted([*here.glob('*.cs'), *here.glob('*.csproj'), *here.glob('inprocess_cross.*'),
                    *here.glob('canopy_cross_budget.*'), *here.glob('patches/*'), *here.glob('cross_patches/*'),
                    here / 'checked_patches.py', here / 'publish_library.py'])
    for path in paths:
        require(path.is_file(), 'unexpected native shader source recipe member')
        relative = path.relative_to(here).as_posix()
        recipe.update(relative.encode() + b'\0' + PUBLIC.public_input(repo, str(path.relative_to(repo))) + b'\0')
    require(report.get('bridgeRecipeSHA256') == recipe.hexdigest() and
            report.get('crossCommit') == 'aa217aeb6c9f0ace7a0ab233b28807edf45eb165',
            'native shader products do not match current checked source recipe')
    plan_bytes = stable_bytes(source / 'native-link.args', 1 << 20)
    require(hashlib.sha256(plan_bytes).hexdigest() == report.get('nativeLinkPlanSHA256'), 'native dependency plan changed')
    property_bytes = stable_bytes(source / 'native-link.args.properties', 64 << 10)
    properties = property_bytes.decode('utf-8-sig').splitlines()
    require(properties == report.get('nativeToolchainProperties') and len(properties) <= 32,
            'native toolchain property observation changed')
    parsed = {}
    keys = {'NETCoreSdkVersion', 'RuntimeIdentifier', 'TargetFramework', 'PublishAotUsingRuntimePack',
            'AppleMinOSVersion', 'IlcHostPackagePath', 'IlcFrameworkNativePath'}
    for line in properties:
        if not line:
            continue
        key, equal, value = line.partition('=')
        require(equal and key in keys and key not in parsed and len(value) <= 4096 and '\0' not in value,
                'invalid native toolchain property')
        parsed[key] = value
    require(parsed.get('RuntimeIdentifier') == 'ios-arm64' and parsed.get('TargetFramework') == 'net10.0' and
            parsed.get('PublishAotUsingRuntimePack', '').lower() == 'true' and
            re.fullmatch(r'16\.0(?:\.0)?', parsed.get('AppleMinOSVersion', '')) and
            parsed.get('NETCoreSdkVersion', '').startswith('10.'), 'unsupported native runtime-pack contract')
    roots = [source]
    for key in ('IlcHostPackagePath', 'IlcFrameworkNativePath'):
        value = parsed.get(key, '')
        require(value and Path(value).is_absolute(), 'native dependency root is missing')
        roots.append(Path(os.path.abspath(value)))
    records, admitted, runtime_roots_used = {}, {}, set()
    primary_archives = {source / 'native/CanopyShaderNative.a', source / 'libcanopy_spirv_cross.a'}
    def archive(path, expected=None):
        require(Path(path).is_absolute(), 'relative native dependency archive refused')
        path = Path(os.path.abspath(path))
        require(any(path.is_relative_to(root) for root in roots) and path.suffix == '.a',
                'native dependency escapes explicit product/runtime-pack roots')
        if path in admitted:
            return admitted[path]
        if path not in primary_archives:
            owners = [root for root in roots[1:] if path.is_relative_to(root)]
            require(owners, 'extra product archive has no admitted runtime-package notice contract')
            runtime_roots_used.add(max(owners, key=lambda root: len(root.parts)))
        require(len(admitted) < 128, 'too many native shader dependency archives')
        target = destination / f'archive-{len(admitted):03d}.a'
        remaining = (2 << 30) - sum(record['size'] for record in records.values())
        sha = digest(path, target, expected, min(512 << 20, remaining))
        record = {'sha256': sha, 'size': target.stat().st_size, 'target': inspect_shader_archive(target)}
        records[target.name] = record;admitted[path] = str(target)
        return str(target)
    require(isinstance(report.get('managedArtifacts'), dict) and isinstance(report.get('crossArtifacts'), dict),
            'native artifact tables are missing')
    managed_record = report.get('managedArtifacts', {}).get('CanopyShaderNative.a', {})
    cross_record = report.get('crossArtifacts', {}).get('libcanopy_spirv_cross.a', {})
    for record in (managed_record, cross_record):
        require(isinstance(record, dict) and isinstance(record.get('sha256'), str) and
                re.fullmatch('[0-9a-f]{64}', record['sha256']), 'native archive identity is missing')
    managed = archive(source / 'native/CanopyShaderNative.a', managed_record['sha256'])
    cross = archive(source / 'libcanopy_spirv_cross.a', cross_record['sha256'])
    require(Path(managed).stat().st_size == managed_record.get('size') and
            Path(cross).stat().st_size == cross_record.get('size'), 'native archive size observation differs')
    arguments = []
    for line in plan_bytes.decode('utf-8-sig').splitlines():
        require('\0' not in line, 'invalid native link plan')
        arguments.extend(shlex.split(line))
    require(0 < len(arguments) <= 4096, 'native dependency argument count exceeds limit')
    normalized, cursor = [], 0
    while cursor < len(arguments):
        token = arguments[cursor];cursor += 1
        if token == '-Xlinker':
            require(cursor < len(arguments), 'truncated native linker transport')
            token = arguments[cursor];cursor += 1
        normalized.append(token)
    arguments, search_directories, cursor = [], [], 0
    while cursor < len(normalized):
        token = normalized[cursor];cursor += 1
        if token == '-L' or token.startswith('-L'):
            if token == '-L':
                require(cursor < len(normalized), 'missing native library search directory')
                value = normalized[cursor];cursor += 1
            else:
                value = token[2:]
            require(Path(value).is_absolute(), 'relative native library search directory refused')
            folder = Path(os.path.abspath(value))
            require(any(folder.is_relative_to(root) for root in roots) and folder.is_dir(),
                    'native library search escapes explicit product/runtime roots')
            for parent in (folder, *folder.parents):
                require(not parent.is_symlink(), 'linked native library search directory refused')
            require(len(search_directories) < 64, 'too many native library search directories')
            search_directories.append(folder)
        else:
            arguments.append(token)
    allowed_libraries = SHADER_SYSTEM_LIBRARIES
    allowed_frameworks = SHADER_SYSTEM_FRAMEWORKS
    harmless = {'-dead_strip', '-dead_strip_dylibs', '-Wl,-dead_strip', '-Wl,-dead_strip_dylibs',
                '-Wl,-no_deduplicate', '-Wl,-pie', '-pie', '-fPIC', '-fobjc-arc', '-pthread'}
    link, index, dependencies = [], 0, 0
    while index < len(arguments):
        arg = arguments[index];index += 1
        if arg in allowed_libraries or arg in harmless:
            link.append(arg)
        elif re.fullmatch(r'-l[A-Za-z0-9_.-]{1,128}', arg):
            name = 'lib' + arg[2:] + '.a'
            selected = next((folder / name for folder in search_directories + roots[1:]
                             if (folder / name).exists()), None)
            require(selected is not None, 'native static library is unavailable in explicit roots')
            captured = archive(selected)
            if captured not in (managed, cross):
                link.append(captured);dependencies += 1
        elif arg in ('-framework', '-weak_framework'):
            require(index < len(arguments) and arguments[index] in allowed_frameworks, 'unsupported native framework')
            link.extend((arg, arguments[index]));index += 1
        elif arg in ('-arch', '-target', '-isysroot', '-o'):
            require(index < len(arguments), 'truncated native link option')
            value = arguments[index];index += 1
            require(arg == '-o' or (arg == '-arch' and value == 'arm64') or
                    (arg == '-target' and re.fullmatch(r'arm64-apple-ios16\.0(?:\.0)?', value)) or
                    (arg == '-isysroot' and Path(value).is_absolute() and re.fullmatch(r'iPhoneOS(?:[0-9]+(?:\.[0-9]+)*)?\.sdk', Path(value).name)),
                    'conflicting native toolchain target')
        elif re.fullmatch(r'-miphoneos-version-min=16\.0(?:\.0)?', arg):
            pass
        elif arg.endswith('.a') and not arg.startswith('-'):
            captured = archive(arg)
            if captured not in (managed, cross):
                link.append(captured);dependencies += 1
        elif arg == '-force_load' or arg.startswith('-Wl,-force_load,'):
            if arg == '-force_load':
                require(index < len(arguments), 'missing force-load archive');value = arguments[index];index += 1
            else:
                value = arg[len('-Wl,-force_load,'):]
            link.extend(('-Xlinker', '-force_load', '-Xlinker', archive(value)));dependencies += 1
        elif arg == '-u' or arg.startswith('-Wl,-u,'):
            if arg == '-u':
                require(index < len(arguments), 'missing native root symbol');value = arguments[index];index += 1
            else:
                value = arg[len('-Wl,-u,'):]
            require(re.fullmatch(r'_[A-Za-z0-9_.$]{1,255}', value), 'invalid native root symbol')
            link.extend(('-u', value))
        elif arg.endswith('.o') and not arg.startswith('-'):
            require(Path(arg).name == 'CanopyShaderNative.o' and Path(os.path.abspath(arg)).is_relative_to(source),
                    'unrepresented native object input')  # Supplied by its captured static archive.
        else:
            raise ValueError('unsupported native link-plan argument; no flags were forwarded')
    require(dependencies > 0 and runtime_roots_used, 'native static runtime dependency archives were not represented')
    # Include adapter source as well as actual archive bytes in cache identity.
    consumers = ('launcher/apple/Sources/CanopyShaderTranslator.m',
                 'launcher/apple/Sources/CanopyShaderTranslator.h',
                 'games/totk/third_party/d2r_gfx/gfx/nvn/totk_shader_provider.h',
                 'games/totk/third_party/d2r_gfx/gfx/nvn/totk_shader_rt.m',
                 'games/totk/third_party/d2r_gfx/gfx/nvn/totk_shader_rt.h',
                 'games/totk/third_party/d2r_gfx/gfx/nvn/nvn_mtl.m',
                 'games/totk/runtime/canopy_host.h', 'games/totk/runtime/canopy_host.m')
    consumer_sha = {name: hashlib.sha256(PUBLIC.public_input(repo, name)).hexdigest() for name in consumers}
    identity = {'buildReportSHA256': report_sha, 'bridgeRecipeSHA256': recipe.hexdigest(),
                'consumerSHA256': consumer_sha, 'archives': records,
                'linkPlanSHA256': hashlib.sha256(plan_bytes).hexdigest(),
                'dependencyPropertiesSHA256': hashlib.sha256(property_bytes).hexdigest()}
    licenses = destination / 'licenses';licenses.mkdir(mode=0o700)
    license_records = {}
    for name in ('SPIRV-Cross-LICENSE', 'translator-MIT.txt', 'Ryujinx-MIT.txt'):
        license_records[name] = digest(source / 'licenses' / name, licenses / name, limit=1 << 20)
    license_root = source / 'licenses/SPIRV-Cross-LICENSES'
    require(license_root.is_dir() and not license_root.is_symlink(), 'native shader license inventory missing')
    license_entries = []
    for path in license_root.iterdir():
        require(len(license_entries) < 29, 'native shader license directory exceeds entry bound')
        license_entries.append(path)
    for path in sorted(license_entries):
        require(len(license_records) < 32 and re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', path.name),
                'native shader license inventory exceeds bounds')
        name = 'SPIRV-Cross-LICENSES/' + path.name
        license_records[name] = digest(path, licenses / name, limit=1 << 20)
    require(len(license_records) > 3, 'native shader license texts missing')
    runtime_notices = {}
    for index, root in enumerate(sorted(runtime_roots_used)):
        # The exact package layout is admitted, not guessed by ancestor search.
        if root == roots[2]:
            require(root.parts[-3:] == ('runtimes', 'ios-arm64', 'native'),
                    'unknown native runtime package notice layout')
            notice_root = root.parents[2]
        else:
            require(root == roots[1], 'unrepresented native runtime notice root')
            notice_root = root
        prefix = f'runtime-{index:03d}'
        license_name = prefix + '/LICENSE.TXT'
        license_records[license_name] = digest(notice_root / 'LICENSE.TXT', licenses / license_name, limit=1 << 20)
        candidates = []
        for name in ('THIRD-PARTY-NOTICES.TXT', 'ThirdPartyNotices.txt'):
            path = notice_root / name
            if path.exists():
                candidates.append((path, digest(path, limit=8 << 20)))
        require(candidates and len({sha for _, sha in candidates}) == 1,
                'runtime third-party notices missing or ambiguous')
        third_name = prefix + '/THIRD-PARTY-NOTICES.TXT'
        license_records[third_name] = digest(candidates[0][0], licenses / third_name,
                                             candidates[0][1], 8 << 20)
        runtime_notices[prefix] = {'licenseSHA256': license_records[license_name],
                                  'thirdPartySHA256': license_records[third_name]}
    identity['runtimeNoticeSHA256'] = runtime_notices
    identity['licenseSHA256'] = license_records
    identity['recipeSHA256'] = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'observation': identity, 'libraries': [managed, cross], 'arguments': link + ['-lc++'],
            'licenses': licenses}


GAME_DATA_FILES = ('runtime-tables.bin', 'romfs-config.txt', 'shared-fonts.txt', 'rewriter.txt')

def stage_game_data(stage_tree, destination, version, profile):
    source = stage_tree / f'build/game-data/{version}'
    require(sorted(p.name for p in source.iterdir()) == sorted(GAME_DATA_FILES), 'unexpected runtime-data output')
    rows = {}; manifest = ['CANOPY-GAME-DATA-1']
    for name in GAME_DATA_FILES:
        data = stable_bytes(source / name, (256 << 20) if name == 'runtime-tables.bin' else (1 << 20))
        require(data, 'empty runtime-data output')
        rows[name] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        manifest.append(f'{name} {len(data)} {rows[name]["sha256"]}')
    def config(name):
        data = stable_bytes(source / name, 1 << 20).decode('ascii')
        pairs = [line.split(' ') for line in data.splitlines() if line and not line.startswith('#')]
        require(all(len(row) == 2 and row[0] and row[1] for row in pairs) and len({row[0] for row in pairs}) == len(pairs), 'invalid runtime-data config')
        return dict(pairs)
    romfs = config('romfs-config.txt')
    require(romfs == {'ROMFS_IMAGE_SIZE': str(profile['romfs']['size']), 'ROMFS_IMAGE_SHA256': profile['romfs']['sha256'],
                     'ROMFS_INDEX_SHA256': hashlib.sha256(stable_bytes(stage_tree / f'extracted/{version}/romfs/runtime-index.bin',128 << 20)).hexdigest()}, 'runtime-data RomFS identity differs')
    fonts = config('shared-fonts.txt')
    require(len(fonts) == 24, 'runtime-data font schema differs')
    for i, (name, expected) in enumerate(profile['shared_fonts_sha256'].items()):
        require(fonts.get(f'FONT{i}_FILE') == name and fonts.get(f'FONT{i}_SHA256') == expected, 'runtime-data font identity differs')
    rewrite = config('rewriter.txt')
    recorded = stable_bytes(stage_tree / f'rewritten/{version}/build_src.sha256',4096).decode('ascii').split()[0]
    require(re.fullmatch('[0-9a-f]{64}', recorded) and rewrite == {'REWRITER_SHA256': recorded}, 'runtime-data rewriter record differs')
    destination.mkdir(mode=0o700)
    for name, row in rows.items():
        digest(source / name, destination / name, expected=row['sha256'], limit=1 << 30)
    raw = ('\n'.join(manifest)+'\n').encode('ascii');(destination / 'manifest.txt').write_bytes(raw)
    return {'manifestSHA256': hashlib.sha256(raw).hexdigest(), 'files': rows, 'recordedRewriterSHA256': recorded,
            'runtimeIndexSHA256': romfs['ROMFS_INDEX_SHA256']}


def compiler_commands(stage, work, toolchain, version, profile, seed_sha, deps, display_profile=None, shader_native=None, game_data=None):
    display_option(version, display_profile is not None)
    selected = PROFILES.version_profile(stage, version)[1]
    require(profile == selected['_expected'], 'compiler profile differs from staged registry')
    generated = stage / TOTK / ('build/' + version)
    base = [toolchain['clang'], '-target', 'arm64-apple-ios26.0', '-isysroot', toolchain['sdk'],
            '-O2', '-mcpu=apple-a15', '-Wall', '-Wextra', '-Werror=implicit-function-declaration',
            '-DCANOPY_HOST_RUNTIME=1', '-D' + selected['compileDefine'] + '=1',
            '-DCANOPY_HOST_TITLE_ID=0x' + profile['title_id'] + 'ULL',
            '-DCANOPY_HOST_ORIGINAL_MAIN_SHA256="' + profile['exefs_sha256']['main'] + '"',
            '-DCANOPY_HOST_SHADER_SEED_MANIFEST_SHA256="' + seed_sha + '"']
    require(isinstance(game_data,dict) and re.fullmatch('[0-9a-f]{64}',game_data.get('manifestSHA256','')), 'runtime-data manifest pin is required')
    base += ['-DCANOPY_GAME_DATA_RESOURCES=1',
             '-DCANOPY_HOST_GAME_DATA_MANIFEST_SHA256="'+game_data['manifestSHA256']+'"',
             '-DCANOPY_HOST_ROMFS_SHA256="'+profile['romfs']['sha256']+'"',
             '-DCANOPY_HOST_RUNTIME_INDEX_SHA256="'+game_data['runtimeIndexSHA256']+'"']
    if shader_native is not None:
        recipe = shader_native['observation']['recipeSHA256']
        require(re.fullmatch('[0-9a-f]{64}', recipe), 'native shader product recipe is missing')
        base += ['-DCANOPY_LINKED_SHADER_TRANSLATOR=1', '-DCANOPY_SHADER_PROVIDER_RECIPE_SHA256="' + recipe + '"']
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
    native_source = getattr(args, 'shader_native_products', None)
    native_pin = getattr(args, 'shader_native_build_sha256', None)
    shader_native_option(native_source, native_pin)
    display_option(getattr(args, 'version', None), display_settings)
    require(sys.platform == 'darwin' and os.uname().machine == 'arm64', 'private build requires an Apple silicon Mac')
    repo = ROOT
    PUBLIC.bundle_identifier(args.bundle_id)
    game, selected = PROFILES.version_profile(repo, args.version)
    require(game == DEFAULT_GAME, 'trusted registry changed after builder initialization')
    profile = expected_profile(repo, args.version)
    digest(ROOT / PROFILE_HELPER, expected=PROFILE_HELPER_SHA256, limit=1 << 20)
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
                   'gameProfile': game['gameID'], 'registrySHA256': game['_registrySHA256'],
                   'registryHelperSHA256': PROFILE_HELPER_SHA256,
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
            observation['publicInputs'][PROFILE_HELPER] = digest(
                ROOT / PROFILE_HELPER, stage / PROFILE_HELPER,
                expected=PROFILE_HELPER_SHA256, limit=1 << 20)
            digest(stage / PROFILE_HELPER, expected=PROFILE_HELPER_SHA256, limit=1 << 20)
            staged_game, staged_version = PROFILES.version_profile(stage, args.version)
            require(staged_game == game and staged_version == selected,
                    'staged registry differs from selected recipe')
            digest(ROOT / PROFILE_HELPER, expected=PROFILE_HELPER_SHA256, limit=1 << 20)
            stage_tree = stage / TOTK
            observation['privateInputs'] = stage_inputs(tree, stage_tree, args.version, profile)
            generated = stage_tree / 'build' / args.version
            for script in ('prepare_runtime.py', 'prepare_romfs_backend.py'):
                run([sys.executable, '-E', str(stage_tree / 'scripts' / script), '--version', args.version])
            run([sys.executable, '-E', str(stage_tree / 'scripts/prepare_shared_fonts.py'), '--version', args.version])
            host = tree / f'build/totk-native-{args.version}'
            require(os.access(host, os.X_OK), 'trusted local exporter is not executable')
            exporter = work / 'trusted-native-exporter'
            observation['trustedLocalExporterSHA256'] = digest(host, exporter, limit=512 << 20)
            exporter.chmod(0o700)
            modules = work / 'modules';modules.mkdir()
            run([str(exporter), str(stage_tree / 'rewritten' / args.version), 'export-ios'],
                dict(exporter_environment(modules,display_settings),TOTK_GAME_DATA=str(stage_tree / f'build/game-data/{args.version}')))
            flags = shlex.split(run([sys.executable, str(stage_tree / 'ios/tools/gen_embed.py'),
                                    str(stage_tree / 'rewritten' / args.version), str(work / 'embed.S'),
                                    '--text-dir', str(modules), *MODULES]))
            require(flags == [f'-Wl,-segprot,__TOTK{m}W,rw,rw' for m in MODULES] + ['-Wl,-segprot,__TOTKX,r-x,r-x'],
                    'unexpected generated segment flags')
            app = work / 'Canopy.app';app.mkdir(mode=0o700)
            data = app / 'GameData';data.mkdir(mode=0o700)
            game_data=stage_game_data(stage_tree,data/'runtime-data',args.version,profile)
            observation['runtimeData']=game_data
            chain_header = (stage_tree / 'third_party/d2r_gfx/gfx/nvn/dmsh_chain.h').read_text()
            chain = re.search(r'^#define DMSH_CHAIN "([^"\n]+)"$', chain_header, re.M).group(1)
            stage_seed(seed, data / 'shader-seed', args.shader_manifest_sha256, profile['romfs']['sha256'], chain)
            shutil.copytree(stage_tree / 'extracted/firmware/shared-fonts', data / 'shared-fonts')
            for name in ('romfs-patches', 'romfs-patches-out'):
                (data / name).mkdir(mode=0o700)  # No unverified optional title patches.
            display_profile = generate_display_resources(stage_tree, data, run, args.version) if display_settings else None
            if display_profile is not None:
                observation['displaySettings'] = display_profile
            codec_snapshot = work / 'codecs'
            observation['codecInputs'] = stage_codecs(deps, codec_snapshot)
            libraries = [str(codec_snapshot / f'lib/lib{name}.a') for name in ('opus', 'vpx')]
            shader_native = stage_shader_native(native_source, work / 'native-shader', native_pin, repo) if native_source else None
            native_arguments = []
            if shader_native is not None:
                for name, sha in shader_native['observation']['consumerSHA256'].items():
                    require(observation['publicInputs'].get(name) == sha,
                            'native shader consumer differs from captured compiled source')
                observation['nativeShaderProvider'] = shader_native['observation']
                libraries.extend(shader_native['libraries'])
                native_arguments = shader_native['arguments']
            commands, objects = compiler_commands(stage, work, toolchain, args.version, profile, args.shader_manifest_sha256, codec_snapshot, display_profile, shader_native, game_data)
            for command in commands:
                run(command)
            link = [toolchain['clang'], '-target', 'arm64-apple-ios26.0', '-isysroot', toolchain['sdk'],
                    *objects, *libraries, *native_arguments, *flags, '-Wl,-no_adhoc_codesign']
            for framework in FRAMEWORKS:
                link += ['-framework', framework]
            run(link + ['-o', str(app / 'Canopy')])
            if shader_native is not None:
                shutil.copytree(shader_native['licenses'], app / 'NativeShaderLicenses')
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
    parser.add_argument('--version', choices=VERSIONS, default=DEFAULT_VERSION)
    parser.add_argument('--display-settings', action='store_true', help='opt-in v143 signed720/1080 scene and4:3 aspect profile')
    parser.add_argument('--bundle-id', default='org.monkeorg.canopy')
    parser.add_argument('--tree', type=Path, help='trusted retained private games/totk tree')
    parser.add_argument('--deps', type=Path, help='local iPhoneOS codec prefix with include/ and lib/')
    parser.add_argument('--shader-seed', type=Path)
    parser.add_argument('--shader-manifest-sha256', help='explicit independently reviewed seed-manifest pin')
    parser.add_argument('--shader-native-products', type=Path, help='opt-in trusted local publish_library.py ios-arm64 Static output')
    parser.add_argument('--shader-native-build-sha256', help='explicit independently reviewed native-build.json SHA256')
    parser.add_argument('--developer-dir')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.plan == args.build:
        parser.error('select exactly one of --plan or --build')
    try:
        display_option(args.version, args.display_settings)
        shader_native_option(args.shader_native_products, args.shader_native_build_sha256)
    except ValueError as error:
        parser.error(str(error))
    if args.plan:
        plan = build_plan(version=args.version, identifier=args.bundle_id, display_settings=args.display_settings)
        plan['nativeShaderProvider'] = {'requested': args.shader_native_products is not None,
            'status': 'plan only; no native products read or linked', 'default': 'seed only',
            'requires': 'explicit pinned real ios-arm64 static archives and closed native dependency plan'}
        print(json.dumps(plan, indent=2))
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
