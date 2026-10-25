"""Actual fs_host lifetimes in Canopy, original-iOS and standalone Mac modes.

The original-iOS host fixture selects TARGET_OS_IPHONE without Canopy; it is
conditional/path simulation, not Apple SDK or device execution. A separate
iPhoneOS object compile runs on Apple CI when xcrun is installed.

A deterministic fcntl adapter uses actual fsync on original private tempfiles.
This verifies protected flush lifetimes and concurrent mutation serialization,
not Apple storage hardware durability, full save transactions or CPU teardown.
"""
import json
from pathlib import Path
import resource
import shutil
import sys
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'),'C compiler required')
class CanopySaveFlushTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        folder=Path(cls.build.name)
        source=folder/'probe.c'
        source.write_text((ROOT/'tests/canopy_save_flush_probe.c').read_text().replace('FS_HOST_SOURCE',str(ROOT/'games/totk/runtime/fs_host.c')))
        cls.probes={}
        for target in ('standalone','canopy','original-ios'):
            executable=folder/target
            command=['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-misleading-indentation',
                     '-fsanitize=undefined','-fno-sanitize-recover=all','-pthread',
                     '-I',str(ROOT/'games/totk/runtime'),str(source),'-o',str(executable)]
            if target=='canopy':command.insert(1,'-DCANOPY_HOST_RUNTIME=1')
            if target=='original-ios':command.insert(1,'-DPROBE_ORIGINAL_IOS=1')
            run=subprocess.run(command,capture_output=True,text=True,timeout=60)
            if run.returncode:raise AssertionError(run.stdout+run.stderr)
            cls.probes[target]=executable

    def scenario(self,mode,target=None):
        if target is None:
            for platform_mode in ('canopy','original-ios'):
                with self.subTest(platform_mode=platform_mode):self.scenario(mode,platform_mode)
            return
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            def descriptor_budget():
                soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
                if soft<2048:resource.setrlimit(resource.RLIMIT_NOFILE,(min(2048,hard) if hard!=resource.RLIM_INFINITY else 2048,hard))
            if mode=='bound':
                _,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
                if hard!=resource.RLIM_INFINITY and hard<2048:self.skipTest('1024 pending descriptors need a child budget of2048')
            run=subprocess.run([str(self.probes[target]),mode,str(root)],capture_output=True,text=True,timeout=30,
                               preexec_fn=descriptor_budget if mode=='bound' else None)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertNotIn(str(root),run.stdout)
            result=json.loads(run.stdout)
            self.assertEqual(result['status'],'pass')
            self.assertEqual(result['mode'],target)

    def test_closed_save_is_flushed_and_failure_retains_dirty_owned_descriptor(self):self.scenario('closed-error')
    def test_flush_and_write_flush_return_actual_failure(self):self.scenario('flush-error')
    def test_close_cannot_reuse_a_descriptor_during_commit(self):self.scenario('close-race')
    def test_concurrent_write_serializes_after_commit_and_remains_dirty(self):self.scenario('write-race')
    def test_resize_is_retained_until_successful_flush(self):self.scenario('resize')
    def test_cross_mount_moves_refuse_and_same_save_rename_keeps_owned_flush(self):self.scenario('namespace')
    def test_unknown_mount_does_not_clear_save_state(self):self.scenario('unknown')
    def test_pending_and_open_descriptors_share_existing_table_bound(self):self.scenario('bound')
    def test_standalone_mac_branch_retains_original_behavior(self):self.scenario('legacy','standalone')

    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'requires installed iPhoneOS SDK; no SDK download')
    def test_original_iphoneos_sdk_object_compiles_without_canopy(self):
        sdk=subprocess.run(['xcrun','--sdk','iphoneos','--show-sdk-path'],capture_output=True,text=True,timeout=30)
        self.assertEqual(sdk.returncode,0,sdk.stderr)
        with tempfile.TemporaryDirectory() as temporary:
            run=subprocess.run(['xcrun','--sdk','iphoneos','clang','-target','arm64-apple-ios16.0',
                '-isysroot',sdk.stdout.strip(),'-std=gnu11','-Wall','-Wextra','-Werror',
                '-Wno-misleading-indentation','-I',str(ROOT/'games/totk/runtime'),
                '-c',str(ROOT/'games/totk/runtime/fs_host.c'),'-o',str(Path(temporary)/'original-ios.o')],
                capture_output=True,text=True,timeout=60)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertGreater((Path(temporary)/'original-ios.o').stat().st_size,0)
