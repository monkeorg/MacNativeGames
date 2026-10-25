"""Real immutable-source COW reuse and ordinary streaming, no game bytes.

Clone-success scenarios explicitly skip on filesystems without native clone
support. Failure hooks refuse actual syscalls; none fabricates clone success.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TITLE='0100123456780000'
SIZE=3*65536+17


class CanopyStoreReuseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('cc')
        if not cc:raise unittest.SkipTest('native C compiler required')
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup);folder=Path(cls.build.name)
        adapter=folder/'store.c';adapter.write_text(
            '#define _GNU_SOURCE\n#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n'
            '#include <sys/types.h>\n#include <unistd.h>\n#include <sys/statvfs.h>\n'
            'ssize_t reuse_pwrite(int,const void*,size_t,off_t);\nint reuse_statvfs(int,struct statvfs*);\n'
            'int reuse_ftruncate(int,off_t);\nssize_t reuse_pread(int,void*,size_t,off_t);\n'
            '#define pwrite reuse_pwrite\n#define fstatvfs reuse_statvfs\n#define ftruncate reuse_ftruncate\n#define pread reuse_pread\n'
            '#ifdef __linux__\n#include <sys/ioctl.h>\nint reuse_ioctl(int,unsigned long,...);\n#define ioctl reuse_ioctl\n'
            '#elif defined(__APPLE__)\n#include <sys/clonefile.h>\nint reuse_fclonefileat(int,int,const char*,uint32_t);\n#define fclonefileat reuse_fclonefileat\n#endif\n'
            '#include "'+str(ROOT/'launcher/src/mng_store.c')+'"\n')
        cls.probe=folder/'reuse';command=[cc,'-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror',
            '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),str(adapter),
            str(ROOT/'launcher/src/mng_crypto.c'),str(ROOT/'launcher/tests/store_reuse_probe.c')]
        if sys.platform!='darwin':command+=['-lcrypto']
        run=subprocess.run(command+['-o',str(cls.probe)],capture_output=True,text=True,timeout=90)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name);self.jobs=0
        self.source=self.call('seed',variant='A')['generation'];self.assertTrue(self.source)
        self.directory=self.root/'titles'/TITLE/'generations'/self.source
        self.before={str(p.relative_to(self.directory)):(p.stat().st_ino,p.stat().st_mtime_ns,p.read_bytes())
                     for p in self.directory.rglob('*') if p.is_file()}

    def call(self,mode,source=None,job=None,variant='B',env=None,expected=0):
        self.jobs+=1
        run=subprocess.run([str(self.probe),mode,str(self.root),source or getattr(self,'source','-'),
                            job or f'{self.jobs:032x}',TITLE,variant],capture_output=True,text=True,timeout=20,
                           env={**os.environ,**(env or {})})
        self.assertEqual(run.returncode,expected,run.stdout+run.stderr)
        if expected:return None
        self.assertEqual(run.stderr,'');return json.loads(run.stdout)

    def unchanged(self):
        self.assertEqual(self.before,{str(p.relative_to(self.directory)):(p.stat().st_ino,p.stat().st_mtime_ns,p.read_bytes())
                                     for p in self.directory.rglob('*') if p.is_file()})

    def require_clone(self):
        result=self.call('normal')
        self.assertEqual(result['status'],0,result)
        if not result['cloneAssets']:self.skipTest('filesystem does not support native COW clone; fallback checked separately')
        return result

    def image(self,mode):
        size={'grow':SIZE+1,'different-size':SIZE+1,'grow-changed':SIZE+1,'grow-boundary':SIZE+65536+7,
              'grow-zero':SIZE+65536+7,'shrink':SIZE-1,'shrink-boundary':65536-1,'shrink-zero':0}[mode]
        data=bytearray(b'r'*size)
        if mode=='grow-zero':data[SIZE:]=b'\0'*(size-SIZE)
        if mode=='grow-changed':data[65536+5]=ord('s')
        return bytes(data)

    def assert_image(self,result,mode):
        path=self.root/'titles'/TITLE/'generations'/result['generation']/'romfs.bin'
        self.assertEqual(path.read_bytes(),self.image(mode));self.assertEqual(path.stat().st_mode&0o777,0o400)

    def test_real_fallback_streaming_keeps_source_immutable_and_metrics_honest(self):
        result=self.call('normal',env={'REUSE_FORCE_FALLBACK':'1'})
        self.assertEqual(result['verifiedTitle'],TITLE)
        self.assertEqual(result['status'],0);self.assertEqual(result['written'],SIZE+42)
        self.assertEqual(result['cloned'],0);self.assertEqual(result['equal'],0);self.assertEqual(result['fallbackAssets'],3)
        self.unchanged()

    def test_real_same_size_clone_skips_identical_payload_writes(self):
        result=self.require_clone();self.assertEqual(result['cloned'],SIZE+42)
        self.assertEqual(result['equal'],SIZE+42);self.assertEqual(result['written'],0);self.unchanged()

    def test_real_changed_clone_writes_only_changed_comparison_span(self):
        self.require_clone();result=self.call('changed',variant='C')
        self.assertEqual(result['status'],0);self.assertEqual(result['written'],65536)
        self.assertEqual(result['equal'],SIZE+42-65536);self.unchanged()

    def test_different_size_fallback_streams_every_byte(self):
        result=self.call('different-size',env={'REUSE_FORCE_FALLBACK':'1'});self.assertEqual(result['status'],0)
        self.assertEqual(result['written'],SIZE+1+42);self.assertEqual(result['cloned'],0);self.unchanged()

    def test_growth_shrink_zero_and_boundary_fallbacks_consider_old_size_candidate(self):
        for mode in ('grow','grow-boundary','grow-zero','shrink','shrink-boundary','shrink-zero'):
            with self.subTest(mode=mode):
                result=self.call(mode,env={'REUSE_FORCE_FALLBACK':'1'})
                self.assertEqual(result['status'],0);self.assertEqual(result['fallbackAssets'],3)
                self.assertEqual(result['streamed'],42+len(self.image(mode)));self.assertEqual(result['written'],result['streamed'])
                self.assertEqual(result['cloned'],0);self.assertEqual(result['equal'],0);self.assertEqual(result['comparedReads'],0)
                self.assert_image(result,mode);self.unchanged()

    def test_new_target_bounds_refuse_before_clone_or_allocation(self):
        before=(self.root/'titles'/TITLE/'current').read_bytes()
        for mode in ('limit','exefs-limit'):
            result=self.call(mode);self.assertEqual(result['status'],1);self.assertEqual(result['cloned'],0);self.assertEqual(result['written'],0)
        self.assertEqual((self.root/'titles'/TITLE/'current').read_bytes(),before);self.unchanged()

    def test_real_resized_clone_compares_strict_overlap_and_streams_all_tail_bytes(self):
        self.require_clone()
        for mode in ('grow','grow-boundary','grow-zero','shrink','shrink-boundary','shrink-zero'):
            with self.subTest(mode=mode):
                result=self.call(mode,env={'REUSE_CHECK_ZERO_EXTENSION':'1'})
                target=len(self.image(mode));overlap=min(SIZE,target)
                self.assertEqual(result['status'],0);self.assertEqual(result['cloneAssets'],3)
                self.assertEqual(result['cloned'],42+SIZE);self.assertEqual(result['streamed'],42+target)
                self.assertEqual(result['equal'],42+overlap);self.assertEqual(result['comparedReads'],42+overlap)
                self.assertEqual(result['written'],max(0,target-SIZE))
                self.assertEqual(result['zeroExtensionChecked'],int(target>SIZE))
                self.assert_image(result,mode);self.unchanged()

    def test_real_changed_prefix_plus_growth_and_short_writes_are_exact(self):
        self.require_clone();result=self.call('grow-changed',env={'REUSE_SHORT_WRITE':'1'})
        self.assertEqual(result['status'],0);self.assertEqual(result['written'],65536+1)
        self.assertEqual(result['equal'],42+SIZE-65536);self.assertEqual(result['comparedReads'],42+SIZE)
        self.assert_image(result,'grow-changed');self.unchanged()

    def test_real_empty_old_snapshot_grows_without_comparing_extension(self):
        self.require_clone();empty=self.call('seed-empty',variant='E')['generation']
        source=self.root/'titles'/TITLE/'generations'/empty
        before={str(p.relative_to(source)):(p.stat().st_ino,p.read_bytes()) for p in source.rglob('*') if p.is_file()}
        result=self.call('grow',source=empty,env={'REUSE_CHECK_ZERO_EXTENSION':'1'})
        self.assertEqual(result['status'],0)
        if result['fallbackAssets']:self.skipTest('filesystem cannot natively clone an empty asset; ordinary fallback is separate')
        self.assertEqual(result['cloned'],42);self.assertEqual(result['equal'],42);self.assertEqual(result['comparedReads'],42)
        self.assertEqual(result['written'],SIZE+1);self.assertEqual(result['zeroExtensionChecked'],1)
        self.assert_image(result,'grow')
        self.assertEqual(before,{str(p.relative_to(source)):(p.stat().st_ino,p.read_bytes()) for p in source.rglob('*') if p.is_file()});self.unchanged()

    def test_real_resize_failure_cancel_and_crash_never_fall_back_or_publish(self):
        self.require_clone();current=self.root/'titles'/TITLE/'current';before=current.read_bytes()
        failed=self.call('grow',env={'REUSE_TRUNCATE_FAIL':'1'})
        self.assertNotEqual(failed['status'],0);self.assertEqual(failed['cloned'],42+SIZE)
        self.assertEqual(failed['fallbackAssets'],0);self.assertEqual(failed['written'],0)
        canceled=self.call('grow',env={'REUSE_CANCEL_TRUNCATE':'1'});self.assertEqual(canceled['status'],6)
        self.assertEqual(canceled['fallbackAssets'],0)
        job='d'*32;self.call('grow',job=job,env={'REUSE_CRASH_TRUNCATE':'1'},expected=29)
        self.assertEqual((self.root/'jobs'/job/'.asset.tmp').stat().st_size,SIZE+1)
        self.assertEqual(current.read_bytes(),before)
        resumed=self.call('grow',job=job,variant='R');self.assertEqual(resumed['status'],0)
        self.assertEqual(resumed['resumed'],42);self.assertEqual(resumed['cloned'],SIZE);self.assertEqual(resumed['written'],1)
        self.assert_image(resumed,'grow');self.unchanged()

    def test_real_appended_write_enospc_and_compare_failure_preserve_current(self):
        self.require_clone();current=self.root/'titles'/TITLE/'current';before=current.read_bytes()
        for environment in ({'REUSE_WRITE_FAIL':'1'},{'REUSE_COMPARE_FAIL':'1'}):
            failed=self.call('grow',env=environment);self.assertNotEqual(failed['status'],0)
            self.assertEqual(failed['fallbackAssets'],0);self.assertEqual(current.read_bytes(),before);self.unchanged()

    def test_resumed_completed_size_mismatch_is_refused_without_overwriting(self):
        job='e'*32;failed=self.call('cancel-after-assets',job=job);self.assertEqual(failed['status'],6)
        staged=self.root/'jobs'/job/'romfs.bin';before=(staged.stat().st_ino,staged.read_bytes())
        current=(self.root/'titles'/TITLE/'current').read_bytes()
        result=self.call('grow',job=job);self.assertNotEqual(result['status'],0)
        self.assertEqual((staged.stat().st_ino,staged.read_bytes()),before)
        self.assertEqual((self.root/'titles'/TITLE/'current').read_bytes(),current);self.unchanged()

    def test_existing_job_resume_takes_precedence_over_generation_clone(self):
        job='b'*32;failed=self.call('cancel-after-assets',job=job);self.assertEqual(failed['status'],6)
        stage=self.root/'jobs'/job;before={str(p.relative_to(stage)):p.stat().st_ino for p in stage.rglob('*') if p.name in ('main','main.npdm','romfs.bin')}
        result=self.call('normal',job=job);self.assertEqual(result['status'],0)
        self.assertEqual(result['resumed'],SIZE+42);self.assertEqual(result['cloned'],0);self.assertEqual(result['written'],0)
        final=self.root/'titles'/TITLE/'generations'/result['generation']
        for name,inode in before.items():self.assertEqual((final/name).stat().st_ino,inode)
        self.unchanged()

    def test_corrupt_or_linked_candidate_fails_before_staging(self):
        image=self.directory/'romfs.bin';image.chmod(0o600);image.write_bytes(b'corrupt')
        result=self.call('normal');self.assertEqual(result['status'],5)
        self.assertEqual(result['verifiedTitle'],'0000000000001234')
        self.assertEqual(len(list((self.root/'jobs').iterdir())),0)

    def test_cross_title_commit_is_rejected(self):
        result=self.call('cross-title');self.assertEqual(result['status'],1)
        self.assertFalse((self.root/'titles'/'0100123456780001').exists());self.unchanged()

    def test_clone_write_failure_cancel_and_real_crash_preserve_old_current(self):
        self.require_clone();current=self.root/'titles'/TITLE/'current';before=current.read_bytes()
        failed=self.call('changed',env={'REUSE_WRITE_FAIL':'1'});self.assertNotEqual(failed['status'],0)
        canceled=self.call('cancel',env={'REUSE_CANCEL_WRITE':'1'});self.assertEqual(canceled['status'],6)
        job='c'*32;self.call('crash',job=job,env={'REUSE_CRASH_WRITE':'1'},expected=27)
        self.assertEqual(current.read_bytes(),before)
        resumed=self.call('changed',job=job,variant='D');self.assertEqual(resumed['status'],0);self.unchanged()

    def test_low_space_ordinary_fallback_preserves_current(self):
        current=(self.root/'titles'/TITLE/'current').read_bytes()
        result=self.call('normal',env={'REUSE_FORCE_FALLBACK':'1','REUSE_LOW_SPACE':'1'})
        self.assertNotEqual(result['status'],0);self.assertEqual(result['written'],0)
        self.assertEqual((self.root/'titles'/TITLE/'current').read_bytes(),current);self.unchanged()

    def test_reuse_owner_holds_real_shared_generation_lease_until_cleared(self):
        self.call('seed',variant='B');self.call('seed',variant='C')
        result=self.call('lease');self.assertNotEqual(result['held'],0)
        self.assertEqual(result['released'],0);self.assertFalse(self.directory.exists())

    def test_candidate_configuration_cannot_change_during_active_job(self):
        result=self.call('configure-active');self.assertEqual(result['status'],1)
        self.assertEqual(result['verifiedTitle'],TITLE);self.unchanged()
