"""Reviewed repository game metadata -> immutable compiled lookup data.

This is build-time configuration, never an app import format. There is no CLI
option to load an arbitrary registry. A row supplies no native function, editor,
service implementation, executable content or device acceptance.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = Path('launcher/config/game-profiles.v1.json')
GENERATED = Path('launcher/src/mng_game_profile_data.inc')
NATIVE = {'canopy-arm64-abi3': 'MNG_GAME_NATIVE_ARM64_ABI3'}
BUILD = {'totk-ios26': 'MNG_GAME_BUILD_TOTK_IOS26'}
VALIDATOR = {'none': 'MNG_GAME_SAVE_NONE', 'totk-slots-structural-v1': 'MNG_GAME_SAVE_TOTK_STRUCTURAL'}
DISPLAY = {'stock-720': 0, 'v143-signed-720-1080-four-three-v1': 3}
FONT_ROLES = ('standard', 'chinese-simplified', 'chinese-simplified-extension',
              'chinese-traditional', 'korean', 'nintendo-extension')


def require(value, message):
    if not value:
        raise ValueError(message)


def keys(value, required, optional=()):
    require(type(value) is dict and set(required) <= value.keys() <= set(required) | set(optional),
            'Unknown or missing trusted registry/manifest field')


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def token(value, pattern, limit=128):
    return type(value) is str and len(value) <= limit and re.fullmatch(pattern, value) is not None


def digest_text(value):
    return token(value, '[0-9a-f]{64}', 64)


def read_public(root, relative, limit):
    relative = Path(relative)
    require(not relative.is_absolute() and relative.parts and
            all(p not in ('.', '..') for p in relative.parts), 'Invalid trusted source path')
    root = Path(root).resolve()
    path = root / relative
    require(path.is_relative_to(root) and not any(p.is_symlink() for p in (path, *path.parents)),
            'Linked trusted source refused')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= limit,
                'Trusted source is not a bounded regular file')
        chunks = []
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(65536, remaining))
            require(block, 'Truncated trusted source')
            chunks.append(block)
            remaining -= len(block)
        require(not os.read(fd, 1), 'Trusted source grew during read')
        after = os.fstat(fd)
        require(all(getattr(before, key) == getattr(after, key) for key in
                    ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')),
                'Trusted source changed during read')
        return b''.join(chunks)
    finally:
        os.close(fd)


def decode(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique,
                          parse_constant=lambda value: require(False, 'Nonfinite JSON number'))
    except RecursionError as error:
        raise ValueError('Trusted JSON nesting exceeds decoder limits') from error


def expected_manifest(root, game, version):
    name = version['expectedManifest']
    require(token(name, re.escape(game['sourceDirectory']) + r'/assets/[a-zA-Z0-9][a-zA-Z0-9_.-]*\.json', 256),
            'Expected manifest must be public version metadata inside the game source directory')
    raw = read_public(root, name, 128 << 10)
    expected = decode(raw)
    keys(expected, ('title_id', 'version', 'display_version', 'exefs_sha256',
                    'rewritten_sha256', 'romfs', 'shared_fonts_sha256'), ('_comment',))
    require(token(expected['title_id'], '[0-9a-fA-F]{16}', 16) and
            expected['title_id'].lower() == game['titleID'] and
            integer(expected['version'], 0, (1 << 32) - 1) and
            token(expected['display_version'], r'[0-9]+(?:\.[0-9]+){2}', 32),
            'Manifest title/version identity mismatch')
    for table, required in (('exefs_sha256', {'rtld', 'main.npdm', *game['modules']}),
                            ('rewritten_sha256', {m + '.patched.bin' for m in game['modules']})):
        require(type(expected[table]) is dict and set(expected[table]) == required and
                all(digest_text(value) for value in expected[table].values()), 'Invalid module digest table')
    keys(expected['romfs'], ('size', 'sha256'))
    require(integer(expected['romfs']['size'], 1, 64 << 30) and digest_text(expected['romfs']['sha256']),
            'Invalid bounded RomFS identity')
    require(type(expected['shared_fonts_sha256']) is dict and
            tuple(expected['shared_fonts_sha256']) == FONT_ROLES and
            all(digest_text(value) for value in expected['shared_fonts_sha256'].values()),
            'Invalid shared-font type/role/digest table')
    return expected, hashlib.sha256(raw).hexdigest()


def load_registry(root=ROOT, check_generated=True):
    raw = read_public(root, REGISTRY, 64 << 10)
    document = decode(raw)
    keys(document, ('schemaVersion', 'defaultGame', 'games'))
    require(integer(document['schemaVersion'], 1, 1) and token(document['defaultGame'], '[a-z][a-z0-9-]*', 32) and type(document['games']) is list and
            1 <= len(document['games']) <= 32, 'Unsupported trusted registry schema/count')
    ids, titles = set(), set()
    source_records = {str(REGISTRY): hashlib.sha256(raw).hexdigest()}
    for game in document['games']:
        keys(game, ('gameID', 'titleID', 'displayName', 'sourceDirectory', 'nativeAdapter', 'buildAdapter',
                    'saveValidator', 'maxPlayers', 'modules', 'defaultVersion', 'versions'))
        require(token(game['gameID'], '[a-z][a-z0-9-]*', 32) and game['gameID'] not in ids and
                token(game['titleID'], '[0-9a-f]{16}', 16) and game['titleID'] != '0' * 16 and
                game['titleID'] not in titles, 'Invalid or duplicate game identity')
        require(token(game['displayName'], '[ -~]+', 128), 'Invalid public game label')
        require(type(game['nativeAdapter']) is str and game['nativeAdapter'] in NATIVE and
                type(game['buildAdapter']) is str and game['buildAdapter'] in BUILD and
                type(game['saveValidator']) is str and game['saveValidator'] in VALIDATOR,
                'Unknown native/build/validator adapter')
        # This closed adapter reuses the existing TOTK-family source recipe.
        # Another engine/ABI requires real backend code, not a JSON flag.
        require(game['sourceDirectory'] == 'games/totk' and integer(game['maxPlayers'], 1, 1),
                'Unsupported source adapter or native player ceiling')
        require(type(game['modules']) is list and 1 <= len(game['modules']) <= 8 and
                all(token(m, '[a-z][a-z0-9_]*', 32) for m in game['modules']) and
                len(set(game['modules'])) == len(game['modules']) and
                {'main', 'sdk'} <= set(game['modules']), 'Invalid native module roles')
        require(type(game['versions']) is list and 1 <= len(game['versions']) <= 8,
                'Invalid version count')
        aliases, revisions, labels = set(), set(), set()
        for version in game['versions']:
            keys(version, ('alias', 'expectedManifest', 'compileDefine', 'patchSource', 'displayProfile'))
            require(token(version['alias'], '[a-z][a-z0-9-]*', 16) and version['alias'] not in aliases and
                    token(version['compileDefine'], '[A-Z][A-Z0-9_]*', 64) and
                    token(version['patchSource'], r'[a-z][a-z0-9_]*\.c', 64) and
                    type(version['displayProfile']) is str and version['displayProfile'] in DISPLAY,
                    'Invalid version/build recipe field')
            patch = Path(game['sourceDirectory']) / 'runtime' / version['patchSource']
            read_public(root, patch, 4 << 20)
            expected, manifest_sha = expected_manifest(root, game, version)
            require(expected['version'] not in revisions and expected['display_version'] not in labels,
                    'Duplicate declared version')
            version['_expected'] = expected
            version['_manifestSHA256'] = manifest_sha
            source_records[version['expectedManifest']] = manifest_sha
            aliases.add(version['alias']);revisions.add(expected['version']);labels.add(expected['display_version'])
        require(type(game['defaultVersion']) is str and game['defaultVersion'] in aliases, 'Unknown default version')
        ids.add(game['gameID']);titles.add(game['titleID'])
    require(document['defaultGame'] in ids, 'Unknown default game')
    document['_sourceSHA256'] = hashlib.sha256(json.dumps(source_records, sort_keys=True,
                                                        separators=(',', ':')).encode()).hexdigest()
    if check_generated:
        require(read_public(root, GENERATED, 512 << 10) == render_c(document).encode(),
                'Trusted compiled registry drift; regenerate with game_profiles.py --write')
    return document


def game_profile(root=ROOT, game_id=None):
    registry = load_registry(root)
    game_id = registry['defaultGame'] if game_id is None else game_id
    game = next((g for g in registry['games'] if g['gameID'] == game_id), None)
    require(game is not None, 'Unregistered game profile')
    result = copy.deepcopy(game)
    result['_registrySHA256'] = registry['_sourceSHA256']
    return result


def version_profile(root=ROOT, alias=None, game_id=None):
    game = game_profile(root, game_id)
    alias = game['defaultVersion'] if alias is None else alias
    version = next((v for v in game['versions'] if v['alias'] == alias), None)
    require(version is not None, 'Unregistered private native version')
    return game, version


def c_string(value):
    return json.dumps(value, ensure_ascii=True)


def render_c(document):
    lines = ['/* Generated by tools/launcher/game_profiles.py; do not edit. */',
             '/* Source metadata identity: ' + document['_sourceSHA256'] + ' */']
    games = sorted(document['games'], key=lambda row: row['titleID'])
    for index, game in enumerate(games):
        lines.append('static const char *const game_modules_' + str(index) + '[] = {' +
                     ', '.join(c_string(m) for m in game['modules']) + '};')
        lines.append('static const struct mng_game_version game_versions_' + str(index) + '[] = {')
        for version in sorted(game['versions'], key=lambda row: row['_expected']['version']):
            expected = version['_expected']
            fields = [c_string(version['alias']), c_string(expected['display_version']),
                      c_string(version['expectedManifest']), c_string(version['compileDefine']),
                      c_string(version['patchSource']), c_string(version['displayProfile']),
                      c_string(version['_manifestSHA256']), c_string(expected['exefs_sha256']['main']),
                      c_string(expected['romfs']['sha256']), str(expected['version']) + 'u',
                      str(DISPLAY[version['displayProfile']]) + 'u', 'UINT64_C(' + str(expected['romfs']['size']) + ')']
            lines.append('    {' + ', '.join(fields) + '},')
        lines.append('};')
    lines.append('static const struct mng_game_profile game_profiles[] = {')
    for index, game in enumerate(games):
        fields = [c_string(game['gameID']), c_string(game['displayName']), c_string(game['sourceDirectory']),
                  c_string(game['defaultVersion']), 'UINT64_C(0x' + game['titleID'] + ')',
                  NATIVE[game['nativeAdapter']], BUILD[game['buildAdapter']], VALIDATOR[game['saveValidator']],
                  str(game['maxPlayers']) + 'u', 'game_modules_' + str(index), str(len(game['modules'])),
                  'game_versions_' + str(index), str(len(game['versions']))]
        lines.append('    {' + ', '.join(fields) + '},')
    lines += ['};', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    registry = load_registry(check_generated=False)
    output = render_c(registry).encode()
    if args.write:
        (ROOT / GENERATED).write_bytes(output)
    else:
        require(read_public(ROOT, GENERATED, 512 << 10) == output, 'Compiled registry drift')


if __name__ == '__main__':
    main()
