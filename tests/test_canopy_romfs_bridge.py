"""Foundation generation->verified private folder bridge; invented inputs only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT/'launcher/apple/Sources'


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun') and
                     importlib.util.find_spec('cryptography'),
                     'RomFS Foundation bridge requires macOS, xcrun and fixture cryptography')
class CanopyRomFSBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        from test_canopy_prepare import CanopyPrepareTests
        from cryptography.hazmat.primitives.ciphers import modes
        cls.fixture=fixture
        # Reuse independent encrypted fixture generation without invoking that
        # suite's compiler/setup. This helper emits no production game bytes.
        cls.builder=CanopyPrepareTests('test_generic_title_and_multiblock_streaming')
        cls.builder.fixture=fixture
        cls.builder.modes=modes
        cls.build=tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory=Path(cls.build.name).resolve()
        objects=[]
        for name in ('mng_container','mng_crypto','mng_keys','mng_content','mng_prepare','mng_store','mng_romfs'):
            output=directory/(name+'.o')
            cls.compile(['xcrun','clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror',
                '-I',str(ROOT/'launcher/include'),'-c',str(ROOT/f'launcher/src/{name}.c'),'-o',str(output)])
            objects.append(str(output))
        cls.probe=directory/'romfs-bridge-probe'
        cls.compile(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',
            '-I',str(SOURCES),'-I',str(ROOT/'launcher/include'),str(ROOT/'tests/canopy_romfs_bridge_probe.m'),
            str(SOURCES/'CanopyRomFS.m'),*objects,'-framework','Foundation','-framework','CoreFoundation',
            '-o',str(cls.probe)])

    @staticmethod
    def compile(command):
        run=subprocess.run(command,capture_output=True,text=True,timeout=120)
        if run.returncode:
            raise AssertionError(run.stdout+run.stderr)

    def setUp(self):
        from test_canopy_romfs import romfs
        self.workspace=tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root=Path(self.workspace.name).resolve()
        self.source,self.keys=self.root/'invented.nsp',self.root/'invented.keys'
        self.prepared,self.derived=self.root/'prepared',self.root/'derived'
        self.files=[('root.txt',b'invented root'),('nested/large.bin',bytes(range(251))*900),
                    ('nested/\u00e9.txt',b'invented unicode')]
        self.image,_=romfs(self.files,['empty'])
        self.write_source(self.image)
        f=self.fixture
        self.keys.write_text('\n'.join(f'{name} = {key.hex()}' for name,key in
            [('header_key',f.HEADER),('key_area_key_application_00',f.AREA),('titlekek_00',f.TITLEKEK)]))

    def write_source(self,image):
        self.source.write_bytes(self.fixture.partition([('program.nca',self.builder.custom_nca(image=image))]))

    def job(self,mode='success'):
        original_source=self.source.read_bytes();original_keys=self.keys.read_bytes()
        run=subprocess.run([str(self.probe),str(self.source),str(self.keys),str(self.prepared),
                            str(self.derived),mode],capture_output=True,text=True,timeout=40)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        report=json.loads(run.stdout)
        self.assertEqual(report['status'],'pass')
        self.assertEqual(self.source.read_bytes(),original_source)
        self.assertEqual(self.keys.read_bytes(),original_keys)
        for secret in (self.fixture.HEADER,self.fixture.AREA,self.fixture.TITLEKEK):
            self.assertNotIn(secret.hex(),run.stdout+run.stderr)
        if 'error' in report:
            self.assertNotIn(str(self.root),json.dumps(report['error']))
        self.assertFalse(any(p.name.startswith('.romfs-stage-') for p in self.derived.iterdir()))
        return report

    def test_real_store_materialization_and_verified_reuse_preserve_inodes(self):
        first=self.job()
        folder=Path(first['folder'])
        self.assertIn(first['generation'],folder.name)
        self.assertIn('romfs-folders-v1',folder.name)
        for path,content in self.files:
            self.assertEqual((folder/path).read_bytes(),content)
            self.assertEqual((folder/path).stat().st_nlink,1)
        self.assertTrue((folder/'empty').is_dir())
        inodes={p.relative_to(folder).as_posix():p.stat().st_ino for p in folder.rglob('*')}
        second=self.job()
        self.assertEqual(second['folder'],str(folder))
        self.assertEqual(inodes,{p.relative_to(folder).as_posix():p.stat().st_ino for p in folder.rglob('*')})

    def test_source_generation_change_gets_separate_immutable_folder(self):
        from test_canopy_romfs import romfs
        first=self.job();old=Path(first['folder'])/'root.txt'
        self.write_source(romfs([('different',b'new invented content')])[0])
        second=self.job()
        self.assertNotEqual(first['generation'],second['generation'])
        self.assertNotEqual(first['folder'],second['folder'])
        self.assertEqual(old.read_bytes(),b'invented root')
        self.assertEqual((Path(second['folder'])/'different').read_bytes(),b'new invented content')

    def test_cancellation_cleans_only_unpublished_staging_then_retry_succeeds(self):
        report=self.job('cancel')
        self.assertTrue(report['cancel_sent'])
        self.assertFalse(any(p.name.startswith('romfs-folders-') for p in self.derived.iterdir()))
        first=self.job()
        cached=Path(first['folder']);before=(cached/'root.txt').read_bytes()
        self.job('cancelverify')
        self.assertEqual((cached/'root.txt').read_bytes(),before)
        self.assertEqual(self.job()['folder'],str(cached))

    def test_corrupt_reuse_payload_and_missing_empty_directory_are_refused(self):
        first=self.job();folder=Path(first['folder'])
        (folder/'root.txt').write_bytes(b'corrupt bytes')
        self.job('failure')
        self.assertEqual((folder/'root.txt').read_bytes(),b'corrupt bytes')
        (folder/'root.txt').write_bytes(b'invented root')
        (folder/'empty').rmdir()
        self.job('failure')
        self.assertFalse((folder/'empty').exists())

    def test_extra_empty_directory_symlink_and_hardlink_are_refused_preserved(self):
        first=self.job();folder=Path(first['folder'])
        outside=self.root/'outside';outside.write_bytes(b'preserve')
        for kind in ('directory','symlink','hardlink'):
            with self.subTest(kind=kind):
                extra=folder/'unexpected'
                if kind=='directory': extra.mkdir()
                elif kind=='symlink': extra.symlink_to(outside)
                else: os.link(outside,extra)
                self.job('failure')
                self.assertTrue(extra.exists())
                self.assertEqual(outside.read_bytes(),b'preserve')
                extra.rmdir() if kind=='directory' else extra.unlink()

    def test_expected_payload_symlink_and_hardlink_are_refused(self):
        first=self.job();folder=Path(first['folder'])
        outside=self.root/'outside-payload';outside.write_bytes(b'invented root')
        outside.chmod(0o600)
        payload=folder/'root.txt'
        for kind in ('symlink','hardlink'):
            with self.subTest(kind=kind):
                payload.unlink()
                if kind=='symlink': payload.symlink_to(outside)
                else: os.link(outside,payload)
                self.job('failure')
                self.assertEqual(outside.read_bytes(),b'invented root')
                payload.unlink()
                payload.write_bytes(b'invented root')
                payload.chmod(0o600)

    def test_changed_prepared_asset_is_refused_before_derivation(self):
        self.job('sourcecorrupt')
        self.assertFalse(any(p.name.startswith('romfs-folders-') for p in self.derived.iterdir()))

    def test_foundation_normalizer_refuses_canonical_aliases(self):
        from test_canopy_romfs import romfs
        self.write_source(romfs([('\u00e9',b'a'),('e\u0301',b'b')])[0])
        self.job('failure')
        self.assertFalse(any(p.name.startswith('romfs-folders-') for p in self.derived.iterdir()))

    def test_second_start_is_refused_and_private_root_contract_enforced(self):
        self.job('busy')
        target=self.root/'target';target.mkdir(mode=0o700)
        # Use a fresh alias URL; the existing successful cache remains untouched.
        alias=self.root/'alias';alias.symlink_to(target,target_is_directory=True)
        self.derived=alias
        self.job('failure')
        self.assertEqual(list(target.iterdir()),[])


if __name__=='__main__':
    unittest.main()
