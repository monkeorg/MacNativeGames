"""Actual base preparation, DLC installer, existing V5 store, lease and reads."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
APP='0100123456780000'
DLC='0100123456781001'

@unittest.skipUnless(shutil.which('cc') and importlib.util.find_spec('cryptography'),'requires native compiler and fixture cryptography')
class CanopyInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as f
        import test_canopy_content as cf
        from test_canopy_prepare import CanopyPrepareTests
        from test_canopy_addon_prepare import CanopyAddonPrepareTests
        from extract_exefs import decrypt
        from cryptography.hazmat.primitives.ciphers import modes
        cls.f=f;cls.helper=CanopyPrepareTests();cls.helper.fixture=f;cls.helper.content_fixture=cf;cls.helper.decrypt=staticmethod(decrypt);cls.helper.modes=modes
        cls.addon=CanopyAddonPrepareTests();cls.addon.f=f;cls.addon.cf=cf;cls.addon.helper=cls.helper
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup);folder=Path(cls.build.name)
        store=folder/'store.c';store.write_text('#define _GNU_SOURCE\n#define _POSIX_C_SOURCE 200809L\n#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n#include <unistd.h>\n#include <stdio.h>\nint install_probe_fsync(int);\nint install_probe_renameat(int,const char *,int,const char *);\n#define fsync install_probe_fsync\n#define renameat install_probe_renameat\n#include "'+str(ROOT/'launcher/src/mng_store.c')+'"\n')
        index=folder/'index.c';index.write_text('#define _POSIX_C_SOURCE 200809L\n#include <sys/types.h>\n#include <unistd.h>\nssize_t install_probe_pwrite(int,const void *,size_t,off_t);\n#define pwrite install_probe_pwrite\n#include "'+str(ROOT/'launcher/src/mng_romfs_runtime.c')+'"\n')
        cls.probe=folder/'install';command=['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror','-fsanitize=undefined','-fno-sanitize-recover=all','-pthread','-I',str(ROOT/'launcher/include'),str(ROOT/'launcher/tests/install_probe.c'),str(store),str(index)]
        command += [str(ROOT/'launcher/src'/name) for name in ('mng_install.c','mng_prepare.c','mng_addon.c','mng_container.c','mng_content.c','mng_crypto.c','mng_bktr.c','mng_romfs.c')]
        if sys.platform!='darwin':command+=['-lcrypto']
        run=subprocess.run(command+['-o',str(cls.probe)],capture_output=True,text=True,timeout=90)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.store=self.root/'store';self.store.mkdir(mode=0o700)
        self.base=self.root/'base.nsp';self.base.write_bytes(self.f.partition(self.helper.identified_package()))
        report=self.call('base',self.base,'-','-');self.assertEqual(report['status'],0);self.generation=report['generation']
        self.source=self.root/'addon.nsp';self.write_addon();self.jobs=0
        self.sentinel=self.store/'identity';self.sentinel.mkdir(mode=0o700);(self.sentinel/'account.uid').write_bytes(b'identity sentinel')
        self.before=(self.store/'titles'/APP/'current').read_bytes()
    def write_addon(self,**kw):self.source.write_bytes(self.f.partition(self.addon.package(**kw)[0]))
    def call(self,mode,source=None,base=None,job=None,env=None):
        run=subprocess.run([str(self.probe),mode,str(self.store),str(source or self.source),base or self.generation,job or '-'],capture_output=True,text=True,timeout=30,env={**os.environ,**(env or {})})
        self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'');self.assertNotIn(str(self.root),run.stdout)
        report=json.loads(run.stdout)
        if not mode.startswith('base'):
            self.assertTrue(report['positionsPreserved']);self.assertEqual((self.store/'titles'/APP/'current').read_bytes(),self.before)
            self.assertEqual((self.sentinel/'account.uid').read_bytes(),b'identity sentinel')
        return report
    def test_real_install_generates_typed_v5_and_actual_readonly_mount(self):
        report=self.call('normal');self.assertEqual(report['status'],0);self.assertTrue(report['mounted'] and report['read']);self.assertEqual(report['baseVersion'],7)
        root=self.store/'titles'/DLC/'generations'/report['generation'];self.assertEqual((root/'receipt.bin').read_bytes()[:8],b'CNPYST05')
        self.assertEqual(sorted(p.name for p in root.iterdir()),['.lease','manifest.json','receipt.bin','romfs.bin','runtime-index.bin'])
        self.assertEqual(len(report['job']),32);manifest=json.loads((root/'manifest.json').read_bytes());self.assertEqual(manifest['applicationID'],APP);self.assertEqual(manifest['preparedKind'],'addOn')
    def test_real_empty_dlc_index_and_missing_file(self):
        from test_canopy_romfs import romfs
        self.write_addon(image=romfs()[0]);report=self.call('empty');self.assertEqual(report['status'],0);self.assertEqual(report['indexFiles'],0);self.assertTrue(report['mounted'] and report['read'])
    def test_cancellation_resume_preserves_completed_romfs_and_index_inodes(self):
        for version,mode in enumerate(('cancel-source','cancel-index','cancel-index-write','cancel-commit'),3):
            with self.subTest(mode=mode):
                self.write_addon(version=version)
                job={'cancel-source':'2','cancel-index':'3','cancel-index-write':'5','cancel-commit':'4'}[mode]*32
                canceled=self.call(mode,job=job);self.assertEqual(canceled['status'],6)
                stage=self.store/'jobs'/job;before={p.name:p.stat().st_ino for p in stage.iterdir() if p.name in ('romfs.bin','runtime-index.bin')}
                self.assertIn('romfs.bin',before)
                resumed=self.call('normal',job=job);self.assertEqual(resumed['status'],0)
                root=self.store/'titles'/DLC/'generations'/resumed['generation']
                for name,inode in before.items():self.assertEqual((root/name).stat().st_ino,inode)
                if mode=='cancel-commit':self.assertIn('runtime-index.bin',before)
    def test_wrong_owner_required_version_unknown_base_and_keys_refuse(self):
        self.write_addon(owner=int(APP,16)+1);self.assertNotEqual(self.call('normal')['status'],0)
        self.write_addon(required=8);self.assertEqual(self.call('normal')['status'],3)
        self.write_addon();self.assertEqual(self.call('missing-key')['status'],4)
        self.assertNotEqual(self.call('normal',base='a'*64)['status'],0)
        self.assertEqual(self.call('normal',base='../bad')['status'],1)
    def test_real_post_current_rename_io_is_uncertain_and_rereads_new_current(self):
        report=self.call('normal',env={'CANOPY_INSTALL_FAIL_CURRENT_SYNC':'1'});self.assertEqual(report['status'],2)
        self.assertTrue(report['commitAttempted'] and report['uncertain'] and report['reload'] and report['currentReadable'])
        self.assertEqual(report['generation'],'');self.assertEqual((self.store/'titles'/DLC/'current').read_text(),report['current']+'\n');self.assertTrue(report['read'])
    def test_index_write_failure_and_cancel_never_publish(self):
        for mode in ('index-error','cancel-initial'):
            with self.subTest(mode=mode):
                report=self.call(mode);self.assertNotEqual(report['status'],0);self.assertFalse((self.store/'titles'/DLC/'current').exists())
    def test_stale_controlled_index_temp_is_swept_on_resume(self):
        job='9'*32;report=self.call('cancel-source',job=job);self.assertEqual(report['status'],6)
        temp=self.store/'jobs'/job/'.runtime-index.tmp';temp.write_bytes(b'partial interrupted index');temp.chmod(0o600)
        self.assertEqual(self.call('normal',job=job)['status'],0);self.assertFalse(temp.exists())

    def test_legacy_base_has_no_version_authority(self):
        legacy=self.root/'legacy.nsp';legacy.write_bytes(self.f.partition([('program.nca',self.f.nca(title=int(APP,16)))]))
        report=self.call('base',legacy,'-','-');self.assertEqual(report['status'],0)
        self.before=(self.store/'titles'/APP/'current').read_bytes()
        self.assertEqual(self.call('normal',base=report['generation'])['status'],3)
        self.assertFalse((self.store/'titles'/DLC/'current').exists())

    def test_actual_composed_update_generation_supplies_required_base_version(self):
        base_files,patch_files,_,_=self.helper.update_pair()
        base=self.root/'paired-base.nsp';base.write_bytes(self.f.partition(base_files))
        update=self.root/'update.nsp';update.write_bytes(self.f.partition(patch_files))
        report=self.call('base-update',base,str(update),'-');self.assertEqual(report['status'],0)
        self.before=(self.store/'titles'/APP/'current').read_bytes()
        self.write_addon(required=12)
        installed=self.call('normal',base=report['generation']);self.assertEqual(installed['status'],0)
        self.assertEqual(installed['baseVersion'],12);self.assertTrue(installed['read'])

    def test_controlled_temp_links_and_fifo_refuse_without_outside_access(self):
        outside=self.root/'outside';outside.write_bytes(b'preserved external bytes')
        for kind,job in (('link','a'*32),('fifo','b'*32)):
            self.assertEqual(self.call('cancel-source',job=job)['status'],6)
            temp=self.store/'jobs'/job/'.runtime-index.tmp'
            if kind=='link':temp.symlink_to(outside)
            else:os.mkfifo(temp,0o600)
            self.assertNotEqual(self.call('normal',job=job)['status'],0)
            self.assertEqual(outside.read_bytes(),b'preserved external bytes')
            self.assertTrue(temp.is_symlink() if kind=='link' else temp.exists())
            self.assertFalse((self.store/'titles'/DLC/'current').exists())

    def test_invalid_job_and_nonprivate_root_do_not_create_staging(self):
        before=sorted(p.name for p in (self.store/'jobs').iterdir())
        self.assertEqual(self.call('normal',job='../bad')['status'],1)
        self.assertEqual(sorted(p.name for p in (self.store/'jobs').iterdir()),before)
        self.store.chmod(0o755)
        self.assertEqual(self.call('normal')['status'],1)
        self.assertEqual(sorted(p.name for p in (self.store/'jobs').iterdir()),before)
        self.store.chmod(0o700)
