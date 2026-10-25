"""Real native decryption/extraction with invented keys and encrypted fixtures.

cryptography generates independent fixture ciphertext; the native implementation
uses the platform crypto adapter. No user keys, games or downloaded inputs.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HAS_FIXTURE_CRYPTO = importlib.util.find_spec('cryptography') is not None


@unittest.skipUnless(HAS_FIXTURE_CRYPTO and shutil.which('cc'),
                     'native encrypted fixtures require cc and Python cryptography')
class CanopyPrepareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        from cryptography.hazmat.primitives.ciphers import modes
        from extract_exefs import decrypt
        cls.fixture = fixture
        cls.modes = modes
        cls.decrypt = staticmethod(decrypt)
        cls.build_temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build_temp.cleanup)
        build = Path(cls.build_temp.name)
        include = ['-I', str(ROOT / 'launcher/include')]
        common = ['cc', '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror', *include]
        prepare_object = build / 'prepare.o'
        # Include system declarations before interception macros. Defining the
        # macros on the command line lets glibc redirect them to pread64/fstat64
        # and silently bypasses the intended failure injection.
        instrumented = build / 'instrumented_prepare.c'
        instrumented.write_text(
            '#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n'
            '#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n'
            '#include <sys/stat.h>\n#include <unistd.h>\n'
            'ssize_t prepare_probe_pread(int,void *,size_t,off_t);\n'
            'int prepare_probe_fstat(int,struct stat *);\n'
            '#define pread prepare_probe_pread\n#define fstat prepare_probe_fstat\n'
            '#include "' + str(ROOT / 'launcher/src/mng_prepare.c') + '"\n')
        result = subprocess.run([*common, '-c', str(instrumented),
            '-o', str(prepare_object)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.probe = build / 'prepare-probe'
        libraries = [] if sys.platform == 'darwin' else ['-lcrypto']
        result = subprocess.run([*common, str(ROOT / 'launcher/tests/prepare_probe.c'),
            str(ROOT / 'launcher/src/mng_container.c'), str(ROOT / 'launcher/src/mng_crypto.c'),
            str(prepare_object), *libraries, '-o', str(cls.probe)],
            capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.index = 0

    def inspect(self, data, mode='normal', expected='ok'):
        self.index += 1
        source = self.root / f'fixture-{self.index}.nsp'
        source.write_bytes(data)
        before = source.read_bytes()
        output = self.root / f'staging-{self.index}'
        output.mkdir()
        run = subprocess.run([str(self.probe), str(source), str(output), mode],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], expected, run.stdout + run.stderr)
        self.assertTrue(report['descriptor_preserved'])
        for key in (self.fixture.HEADER, self.fixture.AREA, self.fixture.CONTENT, self.fixture.TITLEKEK):
            self.assertNotIn(key.hex(), run.stdout + run.stderr)
        if expected == 'ok':
            self.assertFalse(report['result_empty'])
            self.assertEqual(report['source_size'], len(data))
            self.assertEqual(report['source_sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(report['exefs_verified'], 1)
            self.assertEqual(report['romfs_verified'], 1)
            self.assertGreater(report['progress_calls'], 0)
        else:
            self.assertTrue(report['result_empty'])
        if mode != 'mutate':
            self.assertEqual(source.read_bytes(), before)
        return output, report

    def change_header(self, nca, change, rehash=True):
        f = self.fixture
        header = bytearray(b''.join(self.decrypt(f.HEADER, self.modes.XTS(i.to_bytes(16, 'big')),
                                                 nca[i*512:(i+1)*512]) for i in range(6)))
        change(header)
        if rehash:
            for i in range(4):
                header[0x280+i*32:0x2a0+i*32] = hashlib.sha256(header[0x400+i*512:0x600+i*512]).digest()
        return b''.join(f.encrypt(f.HEADER, self.modes.XTS(i.to_bytes(16, 'big')),
                                 header[i*512:(i+1)*512]) for i in range(6)) + nca[0xc00:]

    def custom_nca(self, files=None, image=None, title=0x0100123456780000, pad_hash_table=False):
        f = self.fixture
        if files is None:
            files = [('main', b'invented executable bytes'), ('main.npdm', b'invented metadata')]
        if image is None:
            image = f.romfs()
        pfs = f.partition(files)
        hashes = b''.join(hashlib.sha256(pfs[i:i+4096]).digest() for i in range(0, len(pfs), 4096))
        if pad_hash_table:
            hashes = hashes.ljust((len(hashes)+511)//512*512, b'\0')
        padded_hashes = hashes.ljust((len(hashes)+511)//512*512, b'\0')
        exefs = padded_hashes + pfs.ljust((len(pfs)+511)//512*512, b'\0')
        fs = bytearray(512)
        fs[2:5] = bytes([1, 2, 3])
        fs[8:40] = hashlib.sha256(hashes).digest()
        struct.pack_into('<IIQQQQ', fs, 0x28, 4096, 2, 0, len(hashes), len(padded_hashes), len(pfs))
        rom_header, rom_section = f.ivfc(image)
        header = bytearray(0xc00)
        header[0x200:0x204] = b'NCA3'
        header[0x206] = 1
        struct.pack_into('<Q', header, 0x210, title)
        header[0x300:0x340] = f.encrypt(f.AREA, self.modes.ECB(), bytes(32) + f.CONTENT + bytes(16))
        body = b''
        for index, (section_header, payload) in enumerate(((fs, exefs), (rom_header, rom_section))):
            start = len(header) + len(body)
            struct.pack_into('<II', header, 0x240+index*16, start//512, (start+len(payload))//512)
            header[0x400+index*512:0x600+index*512] = section_header
            header[0x280+index*32:0x2a0+index*32] = hashlib.sha256(section_header).digest()
            body += f.encrypt(f.CONTENT, self.modes.CTR(bytes(8)+(start//16).to_bytes(8,'big')), payload)
        struct.pack_into('<Q', header, 0x208, len(header)+len(body))
        return b''.join(f.encrypt(f.HEADER, self.modes.XTS(i.to_bytes(16,'big')),
                                 header[i*512:(i+1)*512]) for i in range(6)) + body

    def test_exact_plaintext_key_area_common_ticket_and_xci(self):
        f = self.fixture
        for kind, managed in (('nsp', False), ('nsp', True), ('xci', False), ('xci', True)):
            with self.subTest(kind=kind, managed=managed):
                output, report = self.inspect(f.game_image(kind, managed))
                self.assertEqual((output/'exefs/main').read_bytes(), b'synthetic main')
                self.assertEqual((output/'exefs/main.npdm').read_bytes(), b'synthetic metadata')
                self.assertEqual((output/'romfs.bin').read_bytes(), f.romfs())
                self.assertEqual(report['title_id'], f'{f.TITLE:016x}')
                self.assertEqual(report['asset_count'], 3)
                self.assertEqual(report['asset_bytes'], len(b'synthetic main')+len(b'synthetic metadata')+len(f.romfs()))

    def test_generic_title_and_multiblock_streaming(self):
        main = bytes(range(251)) * 800
        image = bytes(range(253)) * 1000
        data = self.fixture.partition([('invented.nca', self.custom_nca(
            [('main', main), ('main.npdm', b'npdm')], image))])
        output, report = self.inspect(data)
        self.assertEqual((output/'exefs/main').read_bytes(), main)
        self.assertEqual((output/'romfs.bin').read_bytes(), image)
        self.assertEqual(report['title_id'], '0100123456780000')

    def test_padded_exefs_hash_table_is_fully_authenticated(self):
        f = self.fixture
        nca = self.custom_nca(pad_hash_table=True)
        output, _ = self.inspect(f.partition([('p.nca', nca)]))
        self.assertEqual((output/'exefs/main').read_bytes(), b'invented executable bytes')
        # This byte is outside the one required block hash, but inside the
        # declared hash-table span. Its master SHA must still be checked.
        corrupted = bytearray(nca)
        corrupted[0xc00+100] ^= 1
        self.inspect(f.partition([('p.nca', bytes(corrupted))]), expected='integrity')

    def test_missing_and_wrong_keys_fail_without_success_result(self):
        f = self.fixture
        for mode, managed, status in (('missingkeys', False, 'key'), ('wrongheader', False, 'key'),
                                      ('wrongarea', False, 'integrity'), ('wrongtitlekek', True, 'integrity')):
            with self.subTest(mode=mode):
                self.inspect(f.game_image('nsp', managed), mode, status)

    def test_header_exefs_hash_table_and_data_corruption(self):
        f = self.fixture
        header_bad = self.change_header(f.nca(), lambda h: h.__setitem__(0x410, h[0x410]^1), rehash=False)
        variants = [header_bad]
        for offset in (0xc00, 0xc00+512):
            nca = bytearray(f.nca())
            nca[offset] ^= 1
            variants.append(bytes(nca))
        for index, nca in enumerate(variants):
            with self.subTest(index=index):
                self.inspect(f.partition([('program.nca', nca)]), expected='integrity')

    def test_all_six_ivfc_levels_are_verified(self):
        f = self.fixture
        for level in range(6):
            nca = bytearray(f.nca())
            nca[0x1000+level*4096] ^= 1
            with self.subTest(level=level):
                self.inspect(f.partition([('program.nca', bytes(nca))]), expected='integrity')

    def test_cancel_read_failure_sink_quota_and_sink_failure(self):
        data = self.fixture.game_image('nsp')
        for mode, status in (('cancelinitial','cancelled'), ('cancel','cancelled'),
                             ('cancelwrite','cancelled'), ('readfailure','io'),
                             ('quota','io'), ('sinkwrite','io'), ('sinkend','io')):
            with self.subTest(mode=mode):
                self.inspect(data, mode, status)

    def test_partial_reads_and_interrupted_reads_complete(self):
        for mode in ('short', 'eintr'):
            with self.subTest(mode=mode):
                output, _ = self.inspect(self.fixture.game_image('nsp'), mode)
                self.assertEqual((output/'romfs.bin').read_bytes(), self.fixture.romfs())

    def test_source_mutation_and_each_stable_stat_field_rejected(self):
        for mode in ('mutate', 'statfailure', 'stat-size', 'stat-inode', 'stat-device', 'stat-mtime', 'stat-ctime'):
            with self.subTest(mode=mode):
                self.inspect(self.fixture.game_image('nsp'), mode, 'io')

    def test_bktr_mixed_titles_multiple_programs_and_unsupported_layouts(self):
        f = self.fixture
        variants = [f.partition([('p.nca', f.bktr(f.nca()))]),
                    f.partition([('a.nca', f.nca()), ('b.nca', f.nca())]),
                    f.partition([('a.nca', f.nca()), ('b.nca', f.nca(title=f.TITLE+0x800, content=1))]),
                    f.partition([('p.nca', self.change_header(f.nca(), lambda h: h.__setitem__(0x404, 1)))]),
                    f.partition([('p.nca', self.change_header(f.nca(), lambda h: h.__setitem__(0x614, 8)))])]
        for index, data in enumerate(variants):
            with self.subTest(index=index):
                self.inspect(data, expected='unsupported')

    def test_common_ticket_missing_personalized_conflicting_wrong(self):
        f = self.fixture
        for tickets, status in (([], 'key'), ([('a.tik', f.ticket(True))], 'unsupported'),
                                ([('a.tik', f.ticket()), ('b.tik', f.ticket(bad_key=True))], 'invalid'),
                                ([('a.tik', f.ticket(bad_key=True))], 'integrity')):
            with self.subTest(status=status):
                self.inspect(f.partition([('p.nca', f.nca(True))] + tickets), expected=status)

    def test_bounded_metadata_and_output_names(self):
        f = self.fixture
        quota = self.change_header(f.nca(), lambda h: struct.pack_into('<Q', h, 0x448, 512*1024*1024+1))
        self.inspect(f.partition([('p.nca', quota)]), expected='limit')
        for files, status in (([('main', b'a')], 'unsupported'),
                              ([('main', b'a'), ('main.npdm', b'b'), ('bad:name', b'c')], 'unsupported'),
                              ([('main', b'a'), ('main.npdm', b'b'), ('MAIN', b'c')], 'invalid'),
                              ([('../escape', b'a'), ('main.npdm', b'b')], 'invalid')):
            with self.subTest(files=files):
                self.inspect(f.partition([('p.nca', self.custom_nca(files))]), expected=status)
        self.inspect(b'PFS0'+struct.pack('<III', 4097, 0, 0), expected='limit')

    def test_sparse_source_quota_fails_without_reading_payload(self):
        self.index += 1
        source = self.root / 'oversize-source'
        with source.open('wb') as stream:
            stream.truncate(128*1024*1024*1024+1)
        output = self.root / 'oversize-staging'
        output.mkdir()
        run = subprocess.run([str(self.probe), str(source), str(output), 'normal'],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], 'limit')
        self.assertTrue(report['result_empty'])
        self.assertEqual(report['progress_calls'], 0)


if __name__ == '__main__':
    unittest.main()
