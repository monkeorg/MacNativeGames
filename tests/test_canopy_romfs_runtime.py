"""Actual native TOTKRFS1 production; only invented RomFS fixture bytes."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from test_canopy_romfs import romfs

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'), 'native compiler unavailable')
class CanopyRomfsRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        instrumented = directory / 'runtime.c'
        instrumented.write_text('#define pwrite index_probe_pwrite\n#include "' +
                                str(ROOT / 'launcher/src/mng_romfs_runtime.c') + '"\n')
        cls.probe = directory / 'probe'
        command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                   '-fsanitize=undefined', '-I', str(ROOT / 'launcher/include'),
                   str(ROOT / 'launcher/tests/romfs_runtime_probe.c'), str(instrumented),
                   str(ROOT / 'launcher/src/mng_romfs.c'),
                   str(ROOT / 'launcher/src/mng_crypto.c'), '-o', str(cls.probe)]
        if sys.platform != 'darwin':
            command.append('-lcrypto')
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_index(self, image, mode='ok', existing=None, permissions=None):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'romfs.bin'
            output = Path(temporary) / 'runtime-index.bin'
            source.write_bytes(image)
            if existing is not None:
                output.write_bytes(existing)
                output.chmod(0o600 if permissions is None else permissions)
            result = subprocess.run([str(self.probe), str(source), str(output), mode],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('runtime error:', result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['positionsPreserved'])
            if mode == 'mutate-image':
                self.assertEqual(source.read_bytes(), b'X' + image[1:])
            else:
                self.assertEqual(source.read_bytes(), image)
            return report, output.read_bytes()

    def test_exact_existing_runtime_format_and_trusted_hash(self):
        image, _ = romfs([('z/file', b'last'), ('alpha', b'first'), ('z/empty', b'')])
        report, data = self.run_index(image)
        self.assertEqual(report['status'], 'ok')
        self.assertEqual(report['files'], 3)
        self.assertEqual(report['size'], len(data))
        self.assertEqual(report['sha256'], hashlib.sha256(data).hexdigest())
        magic, count, strings = struct.unpack_from('<8sQQ', data)
        self.assertEqual((magic, count, strings), (b'TOTKRFS1', 3, 24 + 3*24))
        names, payloads = [], []
        for i in range(count):
            offset, size, name, length = struct.unpack_from('<QQII', data, 24 + i*24)
            encoded = data[strings+name:strings+name+length]
            self.assertEqual(encoded[-1:], b'\0')
            names.append(encoded[:-1].decode())
            payloads.append(image[offset:offset+size])
        self.assertEqual(names, ['alpha', 'z/empty', 'z/file'])
        self.assertEqual(payloads, [b'first', b'', b'last'])
        expected_strings = b''.join(name.encode()+b'\0' for name in names)
        self.assertEqual(data[strings:], expected_strings)

    def test_existing_or_public_output_is_not_replaced(self):
        image, _ = romfs([('a', b'x')])
        for existing, permissions in ((b'keep', 0o600), (b'', 0o644)):
            with self.subTest(permissions=permissions):
                report, data = self.run_index(image, existing=existing, permissions=permissions)
                self.assertEqual(report['status'], 'invalid')
                self.assertEqual(data, existing)
                self.assertEqual(report['sha256'], '0'*64)

    def test_cancellation_and_write_error_publish_no_result(self):
        image, _ = romfs([('a', b'x'), ('b', b'y')])
        for mode, status in (('cancel', 'cancelled'), ('cancel-write', 'cancelled'), ('write-error', 'io')):
            with self.subTest(mode=mode):
                report, data = self.run_index(image, mode)
                self.assertEqual(report['status'], status)
                self.assertEqual((report['files'], report['size'], report['sha256']), (0, 0, '0'*64))
                self.assertEqual(len(data), 24 if mode == 'cancel-write' else 0)

    def test_empty_and_malformed_images_are_not_runtime_indexes(self):
        for image in (romfs()[0], b'not a RomFS'):
            report, data = self.run_index(image)
            self.assertNotEqual(report['status'], 'ok')
            self.assertEqual(data, b'')

    def test_last_write_cancellation_and_late_source_mutation_have_no_result(self):
        image, _ = romfs([('a', b'x'), ('b', b'y')])
        for mode, status in (('cancel-final', 'cancelled'), ('mutate-image', 'io')):
            with self.subTest(mode=mode):
                report, data = self.run_index(image, mode)
                self.assertEqual(report['status'], status)
                self.assertEqual((report['files'], report['size'], report['sha256']), (0, 0, '0'*64))
                self.assertGreater(len(data), 24)


if __name__ == '__main__':
    unittest.main()
