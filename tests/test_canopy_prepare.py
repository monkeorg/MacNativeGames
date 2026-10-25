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
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HAS_FIXTURE_CRYPTO = importlib.util.find_spec('cryptography') is not None


@unittest.skipUnless(HAS_FIXTURE_CRYPTO and shutil.which('cc'),
                     'native encrypted fixtures require cc and Python cryptography')
class CanopyPrepareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        import test_canopy_content as content_fixture
        from cryptography.hazmat.primitives.ciphers import modes
        from extract_exefs import decrypt
        cls.fixture = fixture
        cls.content_fixture = content_fixture
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
            str(ROOT / 'launcher/src/mng_content.c'),
            str(ROOT / 'launcher/src/mng_bktr.c'),
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

    @staticmethod
    def observed_record(nca, role=1):
        digest = hashlib.sha256(nca).digest()
        return {'sha': digest, 'id': digest[:16], 'size': len(nca), 'role': role, 'offset': 0}

    def metadata_nca(self, records=None, *, kind=0x80, title=None, version=7,
                     application=None, payload=None, member=None):
        cf = self.content_fixture
        title = title if title is not None else cf.APP
        application = application if application is not None else cf.APP
        if payload is None:
            payload, name, _ = cf.cnmt(title=title, application=application, kind=kind,
                                       version=version, contents=records)
            member = member or name
        else:
            member = member or f'Application_{title:016x}.cnmt'
        nca = self.custom_nca([(member, payload)], title=title)
        header = bytearray(b''.join(self.decrypt(self.fixture.HEADER,
            self.modes.XTS(i.to_bytes(16,'big')), nca[i*512:(i+1)*512]) for i in range(6)))
        end = struct.unpack_from('<I', header, 0x244)[0]*512
        header[0x205] = 1
        header[0x250:0x280] = bytes(48)
        header[0x2a0:0x300] = bytes(96)
        header[0x600:0xc00] = bytes(1536)
        struct.pack_into('<Q', header, 0x208, end)
        return b''.join(self.fixture.encrypt(self.fixture.HEADER,
            self.modes.XTS(i.to_bytes(16,'big')), header[i*512:(i+1)*512]) for i in range(6))+nca[0xc00:end]

    def identified_package(self, with_patch=False, with_dlc=False):
        f, cf = self.fixture, self.content_fixture
        program = self.custom_nca()
        control = f.nca(title=cf.APP, content=2)
        metadata = self.metadata_nca([self.observed_record(program), self.observed_record(control,3)])
        files = [('renamed-program.nca', program), ('control.nca', control), ('base-meta.nca', metadata)]
        if with_patch:
            patch = f.bktr(self.custom_nca([('main',b'patch must not be emitted'),('main.npdm',b'metadata')]))
            patch_meta = self.metadata_nca([self.observed_record(patch)], kind=0x81,
                                           title=cf.PATCH, version=12)
            files += [('update-program.nca',patch), ('patch-meta.nca',patch_meta)]
        if with_dlc:
            data = f.nca(title=cf.DLC, content=4)
            dlc_meta = self.metadata_nca([self.observed_record(data,2)], kind=0x82,
                                         title=cf.DLC, version=3)
            files += [('addon-data.nca',data), ('addon-meta.nca',dlc_meta)]
        return files

    def update_pair(self, image=None, shared_control=False, managed_update=False, patch_transform=None,
                    base_version=7, patch_version=12, patch_main=b'updated native bytes'):
        """Independent encrypted BKTR NCA with real base and patch CNMTs."""
        import test_canopy_bktr as bk
        f,cf=self.fixture,self.content_fixture
        original=image if image is not None else f.romfs()
        updated=original[:-1]+bytes((original[-1]^0x55,))
        fs,virtual=f.ivfc(updated)
        virtual=bytes(virtual)
        base_program=self.custom_nca(image=original)
        template=self.custom_nca([('main',patch_main),('main.npdm',b'updated metadata')],image=updated)
        header=bytearray(b''.join(self.decrypt(f.HEADER,self.modes.XTS(i.to_bytes(16,'big')),
                                              template[i*512:(i+1)*512]) for i in range(6)))
        section_start=struct.unpack_from('<I',header,0x250)[0]*512
        change=5*4096+len(original)-1
        relocations=[(0,0,1),(5*4096,5*4096,0),(change,5*4096,1),(change+1,change+1,0)]
        physical_end=2*bk.PAGE
        physical=bytearray(physical_end)
        physical[:5*4096]=virtual[:5*4096]
        physical[5*4096:5*4096+1]=virtual[change:change+1]
        subsections=[(0,0,0x1020304),(0x100,0,0xaabbccdd),(0x4000,0,0x02030405)]
        reloc=bk.table(relocations,len(virtual),True)
        subs=bk.table(subsections,physical_end,False)
        plaintext=physical+reloc+subs
        fs[4]=4;fs[0x140:0x148]=bk.PREFIX[::-1]
        struct.pack_into('<QQ4sIII',fs,0x100,physical_end,len(reloc),b'BKTR',1,len(relocations),0)
        struct.pack_into('<QQ4sIII',fs,0x120,physical_end+len(reloc),len(subs),b'BKTR',1,len(subsections),0)
        encrypted=bytearray(len(plaintext))
        with mock.patch.object(bk,'KEY',f.CONTENT):
            for i,(start,_,counter) in enumerate(subsections):
                end=subsections[i+1][0] if i+1<len(subsections) else physical_end
                encrypted[start:end]=bk.ctr(bytes(plaintext[start:end]),section_start+start,
                                           bk.PREFIX[:4]+counter.to_bytes(4,'big'))
            encrypted[physical_end:]=bk.ctr(bytes(plaintext[physical_end:]),section_start+physical_end,bk.PREFIX)
        header[0x600:0x800]=fs
        header[0x2a0:0x2c0]=hashlib.sha256(fs).digest()
        struct.pack_into('<I',header,0x254,(section_start+len(encrypted))//512)
        struct.pack_into('<Q',header,0x208,section_start+len(encrypted))
        if managed_update:
            header[0x230:0x240]=f.RIGHTS
        patch_program=b''.join(f.encrypt(f.HEADER,self.modes.XTS(i.to_bytes(16,'big')),
                                        header[i*512:(i+1)*512]) for i in range(6))+template[0xc00:section_start]+encrypted
        if patch_transform:
            patch_program=patch_transform(patch_program)
        base_records=[self.observed_record(base_program)]
        patch_records=[self.observed_record(patch_program)]
        base_files=[('base-program.nca',base_program)]
        patch_files=[('update-program.nca',patch_program)]
        if shared_control:
            control=f.nca(title=cf.APP,content=2)
            base_files.append(('control.nca',control));patch_files.append(('same-control.nca',control))
            base_records.append(self.observed_record(control,3));patch_records.append(self.observed_record(control,3))
        base_files.append(('base-meta.nca',self.metadata_nca(base_records,version=base_version)))
        patch_files.append(('patch-meta.nca',self.metadata_nca(patch_records,kind=0x81,title=cf.PATCH,version=patch_version)))
        if managed_update:
            patch_files.append(('common.tik',f.ticket()))
        return base_files,patch_files,original,updated

    def compose(self,base_data,patch_data,mode='normal',target=12,expected='ok',base_version=7,latest=False):
        self.index+=1
        base=self.root/f'base-{self.index}.nsp';patch=self.root/f'update-{self.index}.nsp'
        base.write_bytes(base_data);patch.write_bytes(patch_data)
        output=self.root/f'composed-{self.index}';output.mkdir()
        run=subprocess.run([str(self.probe),str(base),str(output),mode,str(patch),'latest' if latest else str(target)],
                            capture_output=True,text=True,timeout=30)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        report=json.loads(run.stdout)
        self.assertEqual(report['status'],expected,report)
        self.assertTrue(report['descriptor_preserved'])
        if not mode.startswith('mutate'):
            self.assertEqual(base.read_bytes(),base_data)
            self.assertEqual(patch.read_bytes(),patch_data)
        for secret in (self.fixture.HEADER,self.fixture.AREA,self.fixture.TITLEKEK,self.fixture.CONTENT):
            self.assertNotIn(secret.hex(),run.stdout+run.stderr)
        if expected=='ok':
            self.assertFalse(report['result_empty'])
            self.assertTrue(report['update_applied'])
            self.assertTrue(report['version_identified'])
            self.assertEqual((report['title_version'],report['base_title_version'],report['content_role']),(target,base_version,0x81))
            self.assertEqual(report['source_size'],len(base_data))
            self.assertEqual(report['source_sha256'],hashlib.sha256(base_data).hexdigest())
            self.assertEqual(report['update_source_size'],len(patch_data))
            self.assertEqual(report['update_source_sha256'],hashlib.sha256(patch_data).hexdigest())
            self.assertEqual(report['patch_title_id'],f'{self.content_fixture.PATCH:016x}')
            self.assertEqual((report['exefs_verified'],report['romfs_verified']),(1,1))
        else:
            self.assertTrue(report['result_empty'])
        return output,report

    def test_exact_plaintext_key_area_common_ticket_and_xci(self):
        f = self.fixture
        for kind, managed in (('nsp', False), ('nsp', True), ('xci', False), ('xci', True)):
            with self.subTest(kind=kind, managed=managed):
                output, report = self.inspect(f.game_image(kind, managed))
                self.assertEqual((output/'exefs/main').read_bytes(), b'synthetic main')
                self.assertEqual((output/'exefs/main.npdm').read_bytes(), b'synthetic metadata')
                self.assertEqual((output/'romfs.bin').read_bytes(), f.romfs())
                self.assertEqual(report['title_id'], f'{f.TITLE:016x}')
                self.assertEqual(report['application_id'], f'{f.TITLE:016x}')
                self.assertFalse(report['version_identified'])
                self.assertEqual(report['title_version'], 0)
                self.assertEqual(report['content_role'], 0)
                self.assertFalse(report['update_applied'])
                self.assertEqual(report['update_source_sha256'], '0'*64)
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

    def test_verified_metadata_identifies_base_and_binds_renamed_nca_bytes(self):
        files = self.identified_package()
        output, report = self.inspect(self.fixture.partition(files))
        self.assertEqual(report['application_id'], f'{self.content_fixture.APP:016x}')
        self.assertTrue(report['version_identified'])
        self.assertEqual(report['title_version'], 7)
        self.assertEqual(report['content_role'], 0x80)
        self.assertEqual((output/'exefs/main').read_bytes(), b'invented executable bytes')
        self.assertEqual({p.relative_to(output).as_posix() for p in output.rglob('*') if p.is_file()},
                         {'exefs/main','exefs/main.npdm','romfs.bin'})

    def test_base_cartridge_with_bundled_update_and_dlc_stays_base_only(self):
        files = self.identified_package(with_patch=True, with_dlc=True)
        for ordered in (files, list(reversed(files))):
            output, report = self.inspect(self.fixture.card_with_update(ordered))
            self.assertEqual(report['title_version'], 7)
            self.assertEqual(report['content_role'], 0x80)
            self.assertEqual((output/'exefs/main').read_bytes(), b'invented executable bytes')
            self.assertEqual(report['asset_count'], 3)

    def test_corrupt_present_metadata_never_falls_back_to_unidentified(self):
        f, cf = self.fixture, self.content_fixture
        program = self.custom_nca()
        record = self.observed_record(program)
        cnmt, member, _ = cf.cnmt(version=7, contents=[record])
        corrupt_digest = bytearray(cnmt)
        corrupt_digest[-1] ^= 1
        bad_pfs = bytearray(self.metadata_nca([record]))
        bad_pfs[0xc00+512] ^= 1
        for metadata, status in ((self.metadata_nca(payload=bytes(corrupt_digest)), 'integrity'),
                                 (bytes(bad_pfs), 'integrity'),
                                 (self.metadata_nca([record], member=f'Application_{cf.APP+1:016x}.cnmt'),'invalid'),
                                 (self.metadata_nca([record], payload=b'x'*(1024*1024+1)), 'limit')):
            with self.subTest(status=status):
                output, _ = self.inspect(f.partition([('p.nca',program),('meta.nca',metadata)]), expected=status)
                self.assertEqual(list((output/'exefs').iterdir()), [])

    def test_exact_cnmt_hash_size_and_raw_role_bindings_are_required(self):
        f = self.fixture
        program = self.custom_nca()
        for alteration in ('hash','size','role'):
            record = self.observed_record(program)
            if alteration == 'hash':
                record['sha'] = hashlib.sha256(b'other encrypted bytes').digest()
                record['id'] = record['sha'][:16]
            elif alteration == 'size':
                record['size'] += 512
            else:
                record['role'] = 2
            with self.subTest(alteration=alteration):
                metadata = self.metadata_nca([record])
                self.inspect(f.partition([('p.nca',program),('meta.nca',metadata)]), expected='integrity')

    def test_unapplied_bundled_update_is_still_bound_and_mixed_apps_refused(self):
        f, cf = self.fixture, self.content_fixture
        files = self.identified_package(with_patch=True)
        changed = bytearray(files[3][1])
        changed[-1] ^= 1
        files[3] = ('update-program.nca',bytes(changed))
        self.inspect(f.partition(files), expected='integrity')
        files = self.identified_package()
        unrelated = self.custom_nca(title=cf.APP+0x10000)
        unrelated_meta = self.metadata_nca([self.observed_record(unrelated)],
                                           title=cf.APP+0x10000, application=cf.APP+0x10000)
        self.inspect(f.partition(files+[('other.nca',unrelated),('other-meta.nca',unrelated_meta)]), expected='integrity')

    def test_standalone_patch_and_undeclared_content_do_not_prepare(self):
        f, cf = self.fixture, self.content_fixture
        update = f.bktr(self.custom_nca())
        metadata = self.metadata_nca([self.observed_record(update)], kind=0x81, title=cf.PATCH, version=12)
        self.inspect(f.partition([('u.nca',update),('m.nca',metadata)]), expected='unsupported')
        files = self.identified_package()
        extra = f.nca(content=4, title=cf.APP)
        self.inspect(f.partition(files+[('undeclared.nca',extra)]), expected='integrity')

    def test_every_declared_control_patch_and_addon_header_title_is_bound(self):
        f, cf = self.fixture, self.content_fixture
        base = self.custom_nca()
        foreign_control = f.nca(title=cf.APP+0x10000, content=2)
        metadata = self.metadata_nca([self.observed_record(base), self.observed_record(foreign_control,3)])
        self.inspect(f.partition([('p.nca',base),('foreign.nca',foreign_control),('m.nca',metadata)]),
                     expected='integrity')
        for role in (1,3):
            with self.subTest(patch_role=role):
                foreign = f.bktr(self.custom_nca(title=cf.APP+0x10000)) if role==1 else foreign_control
                patch_meta = self.metadata_nca([self.observed_record(foreign,role)], kind=0x81,
                                               title=cf.PATCH, version=12)
                self.inspect(f.partition(self.identified_package()+[('u.nca',foreign),('um.nca',patch_meta)]),
                             expected='integrity')
        foreign_data = f.nca(title=cf.APP, content=4)
        addon_meta = self.metadata_nca([self.observed_record(foreign_data,2)], kind=0x82,
                                       title=cf.DLC, version=3)
        self.inspect(f.partition(self.identified_package()+[('d.nca',foreign_data),('dm.nca',addon_meta)]),
                     expected='integrity')

    def test_unimplemented_content_index_and_addon_role_are_explicit(self):
        f, cf = self.fixture, self.content_fixture
        base = self.custom_nca()
        record = self.observed_record(base)
        record['offset'] = 1
        metadata = self.metadata_nca([record])
        self.inspect(f.partition([('p.nca',base),('m.nca',metadata)]), expected='unsupported')
        addon_program = self.custom_nca(title=cf.DLC)
        metadata = self.metadata_nca([self.observed_record(addon_program)], kind=0x82,
                                     title=cf.DLC, version=3)
        self.inspect(f.partition(self.identified_package()+[('d.nca',addon_program),('dm.nca',metadata)]),
                     expected='unsupported')

    def test_real_two_source_update_composes_romfs_and_selects_update_exefs(self):
        f=self.fixture
        for common,shared in ((False,False),(True,True)):
            with self.subTest(common=common,shared=shared):
                base,patch,original,updated=self.update_pair(shared_control=shared,managed_update=common)
                output,report=self.compose(f.partition(base),f.partition(patch))
                self.assertEqual((output/'exefs/main').read_bytes(),b'updated native bytes')
                self.assertEqual((output/'exefs/main.npdm').read_bytes(),b'updated metadata')
                self.assertEqual((output/'romfs.bin').read_bytes(),updated)
                self.assertNotEqual(updated,original)
                self.assertEqual(report['asset_count'],3)

    def test_update_streaming_crosses_chunks_and_inputs_may_be_xci(self):
        from test_canopy_romfs import romfs
        base,patch,_,updated=self.update_pair(image=romfs([('large',bytes(range(251))*900)])[0])
        output,_=self.compose(self.fixture.card_with_update(base),self.fixture.partition(patch),'short')
        self.assertEqual((output/'romfs.bin').read_bytes(),updated)

    def test_update_exact_version_and_verified_metadata_are_mandatory(self):
        f=self.fixture
        base,patch,_,_=self.update_pair()
        for target in (0,11,13,0xffffffff):
            with self.subTest(target=target):
                self.compose(f.partition(base),f.partition(patch),target=target,expected='unsupported')
        self.compose(f.game_image('nsp'),f.partition(patch),expected='unsupported')
        self.compose(f.partition(base),f.partition(patch[:-1]),expected='unsupported')
        changed=bytearray(patch[-1][1]);changed[0xc00+512]^=1
        self.compose(f.partition(base),f.partition(patch[:-1]+[('bad-meta.nca',bytes(changed))]),expected='integrity')

    def test_update_bktr_and_wrong_base_fail_after_exact_cnmt_binding(self):
        f=self.fixture
        def corrupt_payload(data):
            altered=bytearray(data)
            # Patch physical byte0 contains updated IVFC root data. Its NCA
            # hash is rebound in valid metadata, so composed-IVFC must reject.
            altered[0x1000]^=1
            return bytes(altered)
        base,patch,_,_=self.update_pair(patch_transform=corrupt_payload)
        self.compose(f.partition(base),f.partition(patch),expected='integrity')
        base,patch,original,_=self.update_pair()
        wrong=bytearray(original);wrong[-2]^=1
        wrong_program=self.custom_nca(image=bytes(wrong))
        wrong_meta=self.metadata_nca([self.observed_record(wrong_program)],version=7)
        self.compose(f.partition([('base.nca',wrong_program),('meta.nca',wrong_meta)]),f.partition(patch),expected='integrity')

    def test_update_cancellation_io_quotas_and_both_source_stability(self):
        f=self.fixture;base,patch,_,_=self.update_pair()
        for mode,status in (('cancelinitial','cancelled'),('cancel-merge','cancelled'),
                            ('cancel-updatehash','cancelled'),('readfailure','io'),('quota','io'),
                            ('mutate','io'),('mutateupdate','io'),('mutateaftermerge','io')):
            with self.subTest(mode=mode):
                self.compose(f.partition(base),f.partition(patch),mode,expected=status)

    def test_update_literal_zero_maximum_and_same_source_refusal(self):
        f=self.fixture
        for base_version,patch_version in ((0,0),(7,0xffffffff)):
            with self.subTest(version=patch_version):
                base,patch,_,_=self.update_pair(base_version=base_version,patch_version=patch_version)
                self.compose(f.partition(base),f.partition(patch),target=patch_version,base_version=base_version)
        base,patch,_,_=self.update_pair()
        self.compose(f.partition(base),f.partition(patch),'same-source',expected='invalid')

    def test_new_result_fields_must_be_empty_for_all_entrypoints(self):
        f=self.fixture;base_files,patch_files,_,_=self.update_pair()
        for entrypoint in ('base','exact','latest'):
            self.index+=1
            base=self.root/f'dirty-base-{self.index}';base.write_bytes(f.partition(base_files))
            patch=self.root/f'dirty-update-{self.index}';patch.write_bytes(f.partition(patch_files))
            output=self.root/f'dirty-output-{self.index}';output.mkdir()
            args=[str(self.probe),str(base),str(output),'dirty-updatefield']
            if entrypoint!='base': args += [str(patch),'latest' if entrypoint=='latest' else '12']
            run=subprocess.run(args,capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stderr)
            report=json.loads(run.stdout)
            self.assertEqual(report['status'],'invalid')
            self.assertEqual(report['update_source_size'],1)
            self.assertTrue(report['descriptor_preserved'])
            self.assertEqual(list((output/'exefs').iterdir()),[])

    def test_folder_result_fields_must_be_empty_for_all_physical_entrypoints(self):
        f=self.fixture;base_files,patch_files,_,_=self.update_pair()
        for entrypoint in ('base','exact','latest'):
            for field in ('kind','hash','bytes','count','assets','structure'):
                with self.subTest(entrypoint=entrypoint,field=field):
                    self.index+=1
                    base=self.root/f'base-{self.index}';base.write_bytes(f.partition(base_files))
                    patch=self.root/f'patch-{self.index}';patch.write_bytes(f.partition(patch_files))
                    output=self.root/f'output-{self.index}';output.mkdir()
                    args=[str(self.probe),str(base),str(output),'dirty-folder-'+field]
                    if entrypoint!='base': args += [str(patch),'latest' if entrypoint=='latest' else '12']
                    run=subprocess.run(args,capture_output=True,text=True,timeout=10)
                    self.assertEqual(run.returncode,0,run.stderr)
                    report=json.loads(run.stdout)
                    self.assertEqual(report['status'],'invalid')
                    self.assertFalse(report['result_empty'])
                    self.assertTrue(report['descriptor_preserved'])
                    self.assertEqual(list((output/'exefs').iterdir()),[])

    def test_explicit_latest_selects_highest_while_exact_can_select_lower(self):
        f=self.fixture
        base,lower,_,_=self.update_pair(patch_version=12,patch_main=b'lower version code')
        _,higher,_,_=self.update_pair(patch_version=13,patch_main=b'higher version code')
        combined=[('lower-'+name,data) for name,data in lower]+[('higher-'+name,data) for name,data in higher]
        output,_=self.compose(f.partition(base),f.partition(combined),target=12)
        self.assertEqual((output/'exefs/main').read_bytes(),b'lower version code')
        output,_=self.compose(f.partition(base),f.partition(combined),target=13,latest=True)
        self.assertEqual((output/'exefs/main').read_bytes(),b'higher version code')

    def test_latest_corrupt_highest_is_not_replaced_by_lower_version(self):
        f=self.fixture
        base,lower,_,_=self.update_pair(patch_version=12)
        def corrupt_authenticated_virtual_data(data):
            altered=bytearray(data);altered[0x1000]^=1;return bytes(altered)
        _,higher,_,_=self.update_pair(patch_version=13,patch_transform=corrupt_authenticated_virtual_data)
        combined=[('lower-'+name,data) for name,data in lower]+[('higher-'+name,data) for name,data in higher]
        # Higher content hash/CNMT is valid, but reconstruction fails IVFC.
        self.compose(f.partition(base),f.partition(combined),latest=True,expected='integrity')
        # Present metadata is always verified, even if a lower exact version
        # could be selected; a damaged higher CNMT cannot be silently ignored.
        _,higher,_,_=self.update_pair(patch_version=13)
        damaged=bytearray(higher[-1][1]);damaged[0xc00+512]^=1
        higher[-1]=(higher[-1][0],bytes(damaged))
        combined=[('lower-'+name,data) for name,data in lower]+[('higher-'+name,data) for name,data in higher]
        self.compose(f.partition(base),f.partition(combined),latest=True,expected='integrity')
        self.compose(f.partition(base),f.partition(combined),target=12,expected='integrity')


if __name__ == '__main__':
    unittest.main()
