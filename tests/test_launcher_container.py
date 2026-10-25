"""Compile/run the content-free inventory parser against synthetic containers."""
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def partition(files, hfs=False):
    strings, table, payload = bytearray(), bytearray(), bytearray()
    for name, data in files:
        name = name.encode() if isinstance(name, str) else name
        table += struct.pack('<QQII', len(payload), len(data), len(strings), 0)
        if hfs:
            table += bytes(40)
        strings += name + b'\0'
        payload += data
    return bytearray((b'HFS0' if hfs else b'PFS0') +
                     struct.pack('<III', len(files), len(strings), 0) + table + strings + payload)


def xci(secure, siblings=()):
    header = bytearray(0x200)
    header[0x100:0x104] = b'HEAD'
    struct.pack_into('<Q', header, 0x130, len(header))
    return header + partition([*siblings, ('secure', secure)], hfs=True)


class LauncherContainer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = shutil.which('gcc') or shutil.which('clang') or shutil.which('cc')
        if not cls.compiler:
            raise unittest.SkipTest('C compiler unavailable')
        cls.workspace = tempfile.TemporaryDirectory()
        cls.root = Path(cls.workspace.name)
        cls.probe = cls.root / 'container-probe'
        cls.command = [cls.compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic',
                       '-I', str(ROOT / 'launcher/include'),
                       str(ROOT / 'launcher/src/mng_container.c'),
                       str(ROOT / 'launcher/tests/container_probe.c')]
        # Undefined-behavior instrumentation executes throughout this suite when
        # supported. Compiler absence is visible; ordinary compile errors fail.
        sanitizer = subprocess.run([*cls.command, '-fsanitize=undefined',
                                    '-fno-sanitize-recover=all', '-o', str(cls.probe)],
                                   capture_output=True, text=True)
        cls.sanitized = sanitizer.returncode == 0
        if not cls.sanitized:
            subprocess.run([*cls.command, '-o', str(cls.probe)], check=True,
                           capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'workspace'):
            cls.workspace.cleanup()

    def inspect(self, data, fail_call=None):
        source = self.root / 'synthetic.bin'
        source.write_bytes(data)
        args = [str(self.probe), str(source)]
        if fail_call is not None:
            args.append(str(fail_call))
        completed = subprocess.run(args, capture_output=True, text=True, timeout=5,
                                   env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, '')
        rows = completed.stdout.splitlines()
        status, kind, count = map(int, rows[0].split())
        entries = []
        for row in rows[1:]:
            offset, size, name = row.split()
            entries.append((int(offset), int(size), bytes.fromhex(name).decode()))
        self.assertEqual(count, len(entries))
        return status, kind, entries

    def test_nsp_preserves_names_order_ranges_and_payload(self):
        files = [('alpha.nca', b'abc'), ('é.nca', b'defg'), ('zero', b'')]
        data = partition(files)
        status, kind, entries = self.inspect(data)
        self.assertEqual((status, kind), (0, 2))
        self.assertEqual([entry[2] for entry in entries], [name for name, _ in files])
        for entry, (_, payload) in zip(entries, files):
            offset, size, _ = entry
            self.assertEqual(data[offset:offset + size], payload)

    def test_xci_inventory_only_uses_secure_partition(self):
        data = xci(partition([('game.nca', b'game')], hfs=True),
                   [('update', b'not a partition'), ('normal', b'anything')])
        status, kind, entries = self.inspect(data)
        self.assertEqual((status, kind), (0, 3))
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0][2], 'game.nca')
        self.assertEqual(data[entries[0][0]:entries[0][0] + entries[0][1]], b'game')

    def test_empty_partitions(self):
        self.assertEqual(self.inspect(partition([])), (0, 2, []))
        self.assertEqual(self.inspect(xci(partition([], hfs=True))), (0, 3, []))

    def test_rejects_unsafe_and_invalid_utf8_names(self):
        for name in (b'', b'.', b'..', b'a/b', b'a\\b', b'\xff', b'\xc0\xaf',
                     b'\xed\xa0\x80', b'\xf4\x90\x80\x80', b'\xe2\x82'):
            with self.subTest(name=name):
                self.assertEqual(self.inspect(partition([(name, b'x')]))[0], 1)

    def test_rejects_duplicates_and_overlapping_ranges(self):
        self.assertEqual(self.inspect(partition([('a', b'a'), ('a', b'b')]))[0], 1)
        data = partition([('a', b'abc'), ('b', b'def')])
        struct.pack_into('<Q', data, 16 + 24, 2)
        self.assertEqual(self.inspect(data)[0], 1)

    def test_zero_length_order_matches_stable_range_validation(self):
        self.assertEqual(self.inspect(partition([('zero', b''), ('full', b'a')]))[0], 0)
        data = partition([('full', b'a'), ('zero', b'')])
        struct.pack_into('<Q', data, 16 + 24, 0)
        self.assertEqual(self.inspect(data)[0], 1)

    def test_rejects_truncations_and_bad_magic(self):
        data = partition([('hello', b'world')])
        for length in range(len(data)):
            with self.subTest(length=length):
                self.assertNotEqual(self.inspect(data[:length])[0], 0)
        data[:4] = b'NOPE'
        self.assertEqual(self.inspect(data)[0], 1)

    def test_rejects_header_limits_before_allocating_tables(self):
        for count, strings in ((4097, 0), (0, 1024 * 1024 + 1), (0xffffffff, 0xffffffff)):
            data = b'PFS0' + struct.pack('<III', count, strings, 0)
            self.assertEqual(self.inspect(data)[0], 3)
        self.assertEqual(self.inspect(partition([('a' * 1025, b'')]))[0], 3)
        self.assertEqual(self.inspect(partition([('a' * 1024, b'')]))[0], 0)

    def test_maximum_entry_table_and_unterminated_long_name(self):
        files = [(str(i), b'x') for i in range(4096)]
        status, _, entries = self.inspect(partition(files))
        self.assertEqual(status, 0)
        self.assertEqual(len(entries), 4096)
        data = partition([('x' * 2000, b'')])
        data[-1] = ord('x')
        self.assertEqual(self.inspect(data)[0], 3)

    def test_rejects_overflows_and_bad_name_offsets(self):
        original = partition([('a', b'x')])
        for field, value in ((16, 2**64 - 1), (24, 2**64 - 1), (32, 0xffffffff)):
            data = original.copy()
            struct.pack_into('<I' if field == 32 else '<Q', data, field, value)
            self.assertEqual(self.inspect(data)[0], 1)
        data = original.copy()
        data[41] = ord('b')  # Remove sole string terminator.
        self.assertEqual(self.inspect(data)[0], 1)

    def test_xci_rejects_missing_secure_and_bad_root(self):
        data = xci(partition([], hfs=True))
        for offset in (len(data), 2**64 - 1, 0):
            bad = data.copy()
            struct.pack_into('<Q', bad, 0x130, offset)
            self.assertNotEqual(self.inspect(bad)[0], 0)
        missing = data[:0x200] + partition([('other', b'')], hfs=True)
        self.assertEqual(self.inspect(missing)[0], 1)
        self.assertEqual(self.inspect(xci(partition([('bad/path', b'')], hfs=True)))[0], 1)

    def test_io_failure_returns_empty_output(self):
        data = xci(partition([('a', b'xyz')], hfs=True))
        # Source magic, card header, outer header/table/names, inner header/table/names.
        for call in range(1, 9):
            with self.subTest(call=call):
                self.assertEqual(self.inspect(data, call)[0], 2)

    def test_deterministic_mutated_headers_never_crash(self):
        randomizer = random.Random(34)
        original = xci(partition([('alpha', b'abc'), ('beta', b'def')], hfs=True))
        for _ in range(80):
            data = original.copy()
            for _ in range(randomizer.randrange(1, 5)):
                data[randomizer.randrange(len(data))] = randomizer.randrange(256)
            self.inspect(data)


if __name__ == '__main__':
    unittest.main()
