#!/usr/bin/env python3
"""Compare a .app directory with an independently reviewed public inventory.

This is not a Nintendo-content detector or a signature verifier. The reviewed
inventory and its source/build provenance are the trust boundary. IPA/ZIP input
and Mach-O formats other than little-endian ARM64 MH_MAGIC_64 are unsupported.
Mach-O inspection performs selected header, segment and file-range checks only;
it does not establish full Mach-O validity or validate VM/section containment,
relocations or nonsegment load-command contents. Symlinks and special files are
rejected; hardlinks are ordinary files and are inventoried by each path.
No files (including signing metadata) are ignored. This tool never writes to the
application. Inventory v1 requires source_revision, recipe_id and files entries
with path, size, sha256 and provenance {source, license, recipe}; these references
must be reviewed externally. Do not approve an inventory generated from the
candidate itself as independent evidence.
"""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
import unicodedata


class AuditError(ValueError):
    """Artifact or inventory does not meet the bounded contract."""


@dataclass(frozen=True)
class Limits:
    entries: int = 20000
    file_bytes: int = 1024 * 1024 * 1024
    total_bytes: int = 4 * 1024 * 1024 * 1024
    inventory_bytes: int = 16 * 1024 * 1024
    commands: int = 4096
    command_bytes: int = 16 * 1024 * 1024


MACH_MAGICS = {bytes.fromhex(h) for h in (
    'cefaedfe', 'feedface', 'cffaedfe', 'feedfacf',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def require(condition, message):
    if not condition:
        raise AuditError(message)


def keys(value, expected, label):
    require(isinstance(value, dict) and set(value) == set(expected),
            f'invalid {label} fields')


def identifier(value, label):
    require(isinstance(value, str) and bool(value.strip()) and
            len(value) <= 4096 and not any(ord(c) < 32 for c in value),
            f'invalid {label}')


def path_key(value):
    require(isinstance(value, str) and value and len(value) <= 4096,
            'invalid relative path')
    require(not value.startswith('/') and '\\' not in value and ':' not in value
            and not any(ord(c) < 32 for c in value)
            and all(p not in ('', '.', '..') for p in value.split('/')),
            'unsafe relative path')
    return unicodedata.normalize('NFC', value).casefold()


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def read_inventory(path, limits):
    with open(path, 'rb') as stream:
        raw = stream.read(limits.inventory_bytes + 1)
    require(len(raw) <= limits.inventory_bytes, 'inventory size limit exceeded')
    try:
        data = json.loads(raw, object_pairs_hook=no_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AuditError('invalid inventory JSON') from exc
    keys(data, ('schema_version', 'source_revision', 'recipe_id', 'files'), 'inventory')
    require(type(data['schema_version']) is int and data['schema_version'] == 1,
            'unsupported inventory schema')
    for name in ('source_revision', 'recipe_id'):
        identifier(data[name], name)
    require(isinstance(data['files'], list) and 0 < len(data['files']) <= limits.entries,
            'inventory entry limit exceeded or empty inventory')
    entries, aliases, total = {}, set(), 0
    for entry in data['files']:
        keys(entry, ('path', 'size', 'sha256', 'provenance'), 'file')
        alias = path_key(entry['path'])
        require(alias not in aliases, 'duplicate or colliding inventory path')
        aliases.add(alias)
        size = entry['size']
        require(type(size) is int and 0 <= size <= limits.file_bytes, 'invalid file size')
        total += size
        require(total <= limits.total_bytes, 'inventory total size limit exceeded')
        require(isinstance(entry['sha256'], str) and
                re.fullmatch('[0-9a-f]{64}', entry['sha256']), 'invalid SHA-256')
        keys(entry['provenance'], ('source', 'license', 'recipe'), 'provenance')
        for name, value in entry['provenance'].items():
            identifier(value, 'provenance ' + name)
        entries[entry['path']] = entry
    return data, entries, hashlib.sha256(raw).hexdigest()


def inspect_macho(stream, size, limits):
    stream.seek(0)
    magic = stream.read(4)
    if magic not in MACH_MAGICS:
        return None
    require(magic == bytes.fromhex('cffaedfe'), 'unsupported Mach-O format (including fat)')
    header = magic + stream.read(28)
    require(len(header) == 32, 'truncated Mach-O header')
    _, cpu, _, _, count, command_size, _, _ = struct.unpack('<8I', header)
    require(cpu == 0x0100000c, 'unsupported Mach-O CPU')
    require(count <= limits.commands and command_size <= limits.command_bytes and
            command_size <= size - 32, 'invalid Mach-O command bounds')
    commands = stream.read(command_size)
    require(len(commands) == command_size, 'truncated Mach-O commands')
    offset, segments = 0, []
    for _ in range(count):
        require(offset + 8 <= len(commands), 'truncated load command')
        command, length = struct.unpack_from('<II', commands, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= len(commands),
                'invalid load command size')
        if command == 0x19:  # LC_SEGMENT_64
            require(length >= 72, 'truncated segment')
            segment = struct.unpack_from('<II16sQQQQIIII', commands, offset)
            name = segment[2].split(b'\0', 1)[0]
            require(not name.startswith(b'__TOTK'), 'forbidden guest Mach-O segment')
            file_offset, file_size, sections = segment[5], segment[6], segment[9]
            require(file_offset <= size and file_size <= size - file_offset,
                    'segment outside file')
            require(72 + sections * 80 == length, 'invalid segment section count')
            for index in range(sections):
                section = struct.unpack_from('<16s16sQQIIIIIIII', commands,
                                             offset + 72 + index * 80)
                section_size, section_offset, flags = section[3], section[4], section[8]
                # S_ZEROFILL, S_GB_ZEROFILL and S_THREAD_LOCAL_ZEROFILL have no file bytes.
                if flags & 0xff not in (1, 0xc, 0x12):
                    require(section_offset <= size and section_size <= size - section_offset,
                            'section outside file')
            segments.append(name.decode('ascii', errors='backslashreplace'))
        offset += length
    require(offset == command_size, 'unused Mach-O command bytes')
    return {'format': 'arm64-mach-o-64', 'segments': segments}


def audit(app, inventory, limits=Limits()):
    """Return an inventory-match report or raise AuditError. Input must be stable.

    Call on an isolated, immutable build output: this is not a hostile concurrent
    filesystem sandbox. Stat checks detect ordinary changes while hashing.
    """
    app = Path(app)
    require(app.suffix == '.app' and not app.is_symlink() and app.is_dir(),
            'input must be a real .app directory; IPA/ZIP is unsupported')
    metadata, expected, inventory_hash = read_inventory(inventory, limits)
    seen, directories, aliases, report, total, count = set(), set(), set(), [], 0, 0
    expected_directories = {str(parent) for name in expected
                            for parent in Path(name).parents if str(parent) != '.'}
    stack = [app]
    while stack:
        directory = stack.pop()
        with os.scandir(directory) as iterator:
            for item in iterator:
                count += 1
                require(count <= limits.entries, 'artifact entry limit exceeded')
                path = Path(item.path)
                relative = path.relative_to(app).as_posix()
                alias = path_key(relative)
                require(alias not in aliases, 'case or Unicode path collision')
                aliases.add(alias)
                before = item.stat(follow_symlinks=False)
                require(stat.S_ISDIR(before.st_mode) or stat.S_ISREG(before.st_mode),
                        'symlinks and special files are forbidden')
                if stat.S_ISDIR(before.st_mode):
                    directories.add(relative)
                    stack.append(path)
                    continue
                require(relative in expected, 'unlisted file: ' + relative)
                entry = expected[relative]
                require(before.st_size <= limits.file_bytes, 'artifact file size limit exceeded')
                total += before.st_size
                require(total <= limits.total_bytes, 'artifact total size limit exceeded')
                require(before.st_size == entry['size'], 'size mismatch: ' + relative)
                digest = hashlib.sha256()
                # O_NOFOLLOW prevents a final-component symlink replacement on POSIX.
                fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
                with os.fdopen(fd, 'rb') as stream:
                    opened = os.fstat(stream.fileno())
                    require((opened.st_dev, opened.st_ino, opened.st_size) ==
                            (before.st_dev, before.st_ino, before.st_size), 'file changed during audit')
                    read = 0
                    while True:
                        chunk = stream.read(min(1024 * 1024, limits.file_bytes - read + 1))
                        if not chunk:
                            break
                        read += len(chunk)
                        require(read <= entry['size'], 'file grew during audit')
                        digest.update(chunk)
                    require(read == entry['size'] and digest.hexdigest() == entry['sha256'],
                            'hash mismatch: ' + relative)
                    macho = inspect_macho(stream, read, limits)
                    after = os.fstat(stream.fileno())
                    require((opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) ==
                            (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                            'file changed during audit')
                seen.add(relative)
                report.append({'path': relative, 'size': read, 'sha256': digest.hexdigest(),
                               'mach_o': macho})
    require(seen == set(expected), 'inventory files missing from artifact')
    require(directories == expected_directories, 'unlisted or missing artifact directories')
    return {'status': 'inventory matches', 'schema_version': 1,
            'source_revision': metadata['source_revision'], 'recipe_id': metadata['recipe_id'],
            'inventory_sha256': inventory_hash, 'total_bytes': total,
            'files': sorted(report, key=lambda row: row['path']),
            'limitations': ['Reviewed inventory and provenance are trusted external inputs.',
                            'Does not establish absence of Nintendo-derived content.',
                            'Does not verify code signatures or gameplay.',
                            'Selected Mach-O header, segment and file-range checks only; '
                            'not full validity, VM/section containment, relocation or '
                            'nonsegment load-command validation.',
                            'Only .app directories and thin little-endian ARM64 Mach-O supported.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('inventory', type=Path)
    args = parser.parse_args()
    try:
        result = audit(args.app, args.inventory)
    except (AuditError, OSError) as exc:
        print(json.dumps({'status': 'failed', 'error': str(exc)}))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
