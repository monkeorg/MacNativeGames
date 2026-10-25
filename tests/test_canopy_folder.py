"""Native folder preparation using invented assets/keys, never private inputs.

Plaintext tests require no fixture crypto package; encrypted cases explicitly
skip if Python cryptography is absent. Native crypto uses the platform backend.
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

from test_canopy_romfs import romfs

ROOT = Path(__file__).resolve().parents[1]
CRYPTO = importlib.util.find_spec('cryptography') is not None
TITLE = 0x0100123456780000


def nso():
    data = bytearray(0x130)
    data[:4] = b'NSO0'
    for i in range(3):
        struct.pack_into('<III', data, 0x10+i*16, 0x100+i*16, i*0x1000, 16)
        data[0x100+i*16:0x110+i*16] = bytes([65+i])*16
    return bytes(data)


def npdm():
    data = bytearray(0xa0)
    data[:4] = b'META'
    struct.pack_into('<II', data, 0x70, 0x80, 0x20)
    data[0x80:0x84] = b'ACI0'
    struct.pack_into('<Q', data, 0x90, TITLE)
    return bytes(data)


@unittest.skipUnless(shutil.which('cc'), 'native folder tests require cc')
class CanopyFolderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build_temp.cleanup)
        build = Path(cls.build_temp.name)
        wrapper = build/'instrumented.c'
        wrapper.write_text('#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n'
            '#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n'
            '#include <sys/stat.h>\n#include <unistd.h>\n'
            'ssize_t folder_probe_pread(int,void *,size_t,off_t);\n'
            '#define pread folder_probe_pread\n'
            '#include "'+str(ROOT/'launcher/src/mng_folder.c')+'"\n')
        cls.probe = build/'folder-probe'
        sources = ['mng_prepare.c','mng_container.c','mng_crypto.c','mng_content.c',
                   'mng_bktr.c','mng_romfs.c']
        result = subprocess.run(['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror',
            '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),
            str(wrapper),str(ROOT/'launcher/tests/folder_probe.c'),
            *(str(ROOT/'launcher/src'/name) for name in sources),
            *([] if sys.platform == 'darwin' else ['-lcrypto']),'-o',str(cls.probe)],
            capture_output=True,text=True,timeout=90)
        if result.returncode:
            raise AssertionError(result.stdout+result.stderr)
        if CRYPTO:
            import test_game_containers as f
            import test_canopy_content as cf
            from test_canopy_prepare import CanopyPrepareTests
            from extract_exefs import decrypt
            from cryptography.hazmat.primitives.ciphers import modes
            cls.fixture = f
            helper = CanopyPrepareTests()
            helper.fixture,helper.content_fixture,helper.modes,helper.decrypt = f,cf,modes,decrypt
            cls.helper = helper

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.serial = 0

    def plain(self, image=None):
        self.serial += 1
        source = self.root/f'input-{self.serial}'
        (source/'exefs').mkdir(parents=True)
        (source/'romfs').mkdir()
        files = {'exefs/main':nso(),'exefs/main.npdm':npdm(),
                 'exefs/rtld':nso(),'romfs/romfs.bin':image if image is not None else
                 romfs([('nested/file.bin',b'original payload')],['empty'])[0]}
        for path,data in files.items():
            (source/path).write_bytes(data)
        return source,files

    def ncas(self, managed=False, identified=False):
        self.serial += 1
        source = self.root/f'input-{self.serial}'
        source.mkdir()
        f = self.fixture
        files = dict(self.helper.identified_package(with_patch=True,with_dlc=True)) if identified else {
            'program.nca':f.nca(managed),'control.nca':f.nca(content=2)}
        if managed:
            files['common.tik'] = f.ticket()
        for path,data in files.items():
            (source/path).write_bytes(data)
        return source,files

    def run_folder(self, source, mode='normal', status='ok', kind=0):
        self.serial += 1
        output = self.root/f'stage-{self.serial}'
        output.mkdir()
        result = subprocess.run([str(self.probe),str(source),str(output),mode,str(kind)],
                                capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['status'],status,result.stdout+result.stderr)
        self.assertTrue(report['descriptorPreserved'])
        if status != 'ok':
            self.assertTrue(report['resultEmpty'])
        else:
            self.assertFalse(report['resultEmpty'])
            self.assertEqual(report['sourceSize'],0)
            self.assertEqual(report['sourceSHA256'],'0'*64)
            self.assertGreater(report['progressCalls'],0)
        return output,report

    def inventory(self, output, report, files, kind):
        raw = (output/'input-members.json').read_bytes()
        data = json.loads(raw)
        expected = {'schemaVersion':1,'sourceKind':kind,'members':[
            {'path':path,'size':len(content),'sha256':hashlib.sha256(content).hexdigest()}
            for path,content in sorted(files.items())]}
        self.assertEqual(data,expected)
        self.assertEqual(raw,(json.dumps(expected,separators=(',',':'))+'\n').encode())
        self.assertEqual(report['inventorySHA256'],hashlib.sha256(raw).hexdigest())
        self.assertEqual(report['memberCount'],len(files))
        self.assertEqual(report['memberBytes'],sum(map(len,files.values())))
        self.assertNotIn(str(self.root).encode(),raw)
        return raw

    def test_plaintext_byte_exact_and_honest_integrity(self):
        source,files = self.plain()
        (source/'extraction-manifest.json').write_text('{"titleID":"false","verified":true}')
        (source/'romfs/index.json').write_text('{"source":"/private/ignored"}')
        (source/'exefs/.DS_Store').write_bytes(b'ignored report')
        output,r = self.run_folder(source)
        self.inventory(output,r,files,'asset-folder')
        self.assertEqual(r['sourceKind'],2)
        self.assertEqual(r['titleID'],f'{TITLE:016x}')
        self.assertFalse(r['versionIdentified'])
        self.assertEqual((r['exefsVerified'],r['romfsVerified']), (0,0))
        self.assertEqual((r['assetHashesVerified'],r['romfsStructureVerified']), (1,1))
        self.assertEqual(r['assetCount'],len(files)+1)
        for path,content in files.items():
            target = 'romfs.bin' if path == 'romfs/romfs.bin' else path
            self.assertEqual((output/target).read_bytes(),content)
            self.assertEqual((source/path).read_bytes(),content)
        self.assertEqual(sorted(p.name for p in output.iterdir()),['exefs','input-members.json','romfs.bin'])

    @unittest.skipUnless(CRYPTO,'encrypted fixtures require Python cryptography')
    def test_nca_folder_keyarea_and_common_ticket(self):
        for managed in (False,True):
            with self.subTest(managed=managed):
                source,files = self.ncas(managed)
                output,r = self.run_folder(source)
                raw = self.inventory(output,r,files,'nca-folder')
                self.assertEqual(r['sourceKind'],1)
                self.assertEqual((r['exefsVerified'],r['romfsVerified']), (1,1))
                self.assertEqual((r['assetHashesVerified'],r['romfsStructureVerified']), (1,0))
                self.assertFalse(r['versionIdentified'])
                self.assertEqual((output/'exefs/main').read_bytes(),b'synthetic main')
                self.assertEqual((output/'romfs.bin').read_bytes(),self.fixture.romfs())
                self.assertNotIn(self.fixture.HEADER.hex().encode(),raw)
                self.assertFalse((output/'common.tik').exists())

    @unittest.skipUnless(CRYPTO,'encrypted fixtures require Python cryptography')
    def test_nca_metadata_selects_base_and_binds_all_members(self):
        source,files = self.ncas(identified=True)
        output,r = self.run_folder(source)
        self.inventory(output,r,files,'nca-folder')
        self.assertEqual(r['titleID'],f'{TITLE:016x}')
        self.assertTrue(r['versionIdentified'])
        self.assertEqual(r['titleVersion'],7)
        self.assertEqual((output/'exefs/main').read_bytes(),b'invented executable bytes')

    def test_plaintext_nso_and_npdm_bounds(self):
        for path,offset,bytes_ in [('exefs/main',0,b'BAD!'),('exefs/main',0x10,struct.pack('<I',0xfffffff0)),
                ('exefs/main.npdm',0,b'BAD!'),('exefs/main.npdm',0x70,struct.pack('<I',0xfffffff0)),
                ('exefs/main.npdm',0x80,b'BAD!'),('exefs/main.npdm',0x90,bytes(8))]:
            with self.subTest(path=path,offset=offset):
                source,_ = self.plain()
                data = bytearray((source/path).read_bytes());data[offset:offset+len(bytes_)] = bytes_
                (source/path).write_bytes(data)
                self.run_folder(source,status='unsupported' if path.endswith('/main') and offset==0 else 'invalid')

    def test_romfs_structure_not_imported_report(self):
        image,layout = romfs([('x',b'x')],['child'])
        broken = bytearray(image)
        struct.pack_into('<I',broken,layout['dir_start']+layout['dirs'][1]+4,layout['dirs'][1])
        source,_ = self.plain(bytes(broken))
        (source/'romfs/index.json').write_text('{"verified":true}')
        self.run_folder(source,status='invalid')

    def test_unicode_normalizer_required_and_aliases_rejected(self):
        source,_ = self.plain(romfs([('é',b'x')])[0])
        self.run_folder(source,status='unsupported')
        self.run_folder(source,mode='unicode')
        source,_ = self.plain(romfs([('é',b'x'),('e\u0301',b'y')])[0])
        self.run_folder(source,mode='unicode',status='invalid')

    def test_cancel_io_short_reads_and_sink_quota(self):
        for mode,status in [('cancel-prehash','cancelled'),('cancel-metadata','cancelled'),
                            ('read-error','io'),('quota','io'),('short','ok'),('eintr','ok')]:
            with self.subTest(mode=mode):
                source,_ = self.plain()
                self.run_folder(source,mode=mode,status=status)

    def test_detectable_mutation_refuses_publication(self):
        for mode in ('mutate-after-hash','mutate-copy'):
            with self.subTest(mode=mode):
                source,_ = self.plain()
                self.run_folder(source,mode=mode,status='io')

    @unittest.skipUnless(CRYPTO,'encrypted fixtures require Python cryptography')
    def test_nca_key_failure_corruption_and_core_cancel(self):
        for mode,status in [('missing-key','key'),('wrong-key','key'),('cancel-core','cancelled')]:
            with self.subTest(mode=mode):
                source,_ = self.ncas()
                self.run_folder(source,mode=mode,status=status)
        source,_ = self.ncas()
        data = bytearray((source/'program.nca').read_bytes());data[0xc00] ^= 1
        (source/'program.nca').write_bytes(data)
        self.run_folder(source,status='integrity')

    def test_consumed_symlink_fifo_and_directory_refused(self):
        for special in ('symlink','fifo','directory'):
            with self.subTest(special=special):
                source,_ = self.plain()
                member = source/'exefs/main';member.unlink()
                if special == 'symlink':
                    member.symlink_to(source/'exefs/rtld')
                elif special == 'fifo':
                    os.mkfifo(member)
                else:
                    member.mkdir()
                self.run_folder(source,status='invalid')

    @unittest.skipUnless(CRYPTO,'encrypted fixtures require Python cryptography')
    def test_case_alias_unknown_and_ambiguous_layouts(self):
        source,_ = self.ncas()
        alias = source/'PROGRAM.NCA'
        alias.write_bytes(self.fixture.nca())
        if os.path.samefile(alias,source/'program.nca'):
            self.skipTest('filesystem cannot represent case-distinct aliases')
        self.run_folder(source,status='invalid')
        source,_ = self.ncas();(source/'prod.keys').write_bytes(b'not consumed')
        self.run_folder(source,status='unsupported')
        source,_ = self.ncas();(source/'exefs').mkdir();(source/'romfs').mkdir()
        self.run_folder(source,status='unsupported')

    def test_ignored_report_directory_entries_are_bounded(self):
        source,_ = self.plain()
        for i in range(513):
            (source/'romfs'/f'ignored-{i}.json').touch()
        _,r = self.run_folder(source,status='limit')
        self.assertEqual(r['reads'],0)

    def test_controlled_raw_layout_case_alias_refused(self):
        source,_ = self.plain()
        alias = source/'romfs/ROMFS.BIN'
        alias.write_bytes(b'ignored alias')
        if os.path.samefile(alias,source/'romfs/romfs.bin'):
            self.skipTest('filesystem cannot represent case-distinct aliases')
        self.run_folder(source,status='invalid')

    def test_count_and_sparse_size_quotas_before_payload_read(self):
        source = self.root/'too-many';source.mkdir()
        for i in range(513):
            (source/f'{i:03}.cert').touch()
        _,r = self.run_folder(source,status='limit',kind=1)
        self.assertEqual(r['reads'],0)
        source = self.root/'too-large';source.mkdir()
        with (source/'large.nca').open('wb') as stream:
            stream.truncate((128<<30)+1)
        _,r = self.run_folder(source,status='limit',kind=1)
        self.assertEqual(r['reads'],0)
        source,_ = self.plain()
        with (source/'romfs/romfs.bin').open('wb') as stream:
            stream.truncate((64<<30)+1)
        _,r = self.run_folder(source,status='limit')
        self.assertEqual(r['reads'],0)


if __name__ == '__main__':
    unittest.main()
