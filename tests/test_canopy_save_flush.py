"""Actual guarded fs_host file lifetimes/error propagation; no private inputs.

A deterministic fcntl adapter uses actual fsync on original private tempfiles.
This verifies protected flush lifetimes and concurrent mutation serialization,
not Apple storage hardware durability, full save transactions or CPU teardown.
"""
import json
from pathlib import Path
import resource
import shutil
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
        for flagged in (False,True):
            executable=folder/('canopy' if flagged else 'standalone')
            command=['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-misleading-indentation',
                     '-fsanitize=undefined','-fno-sanitize-recover=all','-pthread',
                     '-I',str(ROOT/'games/totk/runtime'),str(source),'-o',str(executable)]
            if flagged:command.insert(1,'-DCANOPY_HOST_RUNTIME=1')
            run=subprocess.run(command,capture_output=True,text=True,timeout=60)
            if run.returncode:raise AssertionError(run.stdout+run.stderr)
            cls.probes[flagged]=executable

    def scenario(self,mode,flagged=True):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            def descriptor_budget():
                soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
                if soft<2048:resource.setrlimit(resource.RLIMIT_NOFILE,(min(2048,hard) if hard!=resource.RLIM_INFINITY else 2048,hard))
            if mode=='bound':
                _,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
                if hard!=resource.RLIM_INFINITY and hard<2048:self.skipTest('1024 pending descriptors need a child budget of2048')
            run=subprocess.run([str(self.probes[flagged]),mode,str(root)],capture_output=True,text=True,timeout=30,
                               preexec_fn=descriptor_budget if mode=='bound' else None)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertNotIn(str(root),run.stdout)
            self.assertEqual(json.loads(run.stdout)['status'],'pass')

    def test_closed_save_is_flushed_and_failure_retains_dirty_owned_descriptor(self):self.scenario('closed-error')
    def test_flush_and_write_flush_return_actual_failure(self):self.scenario('flush-error')
    def test_close_cannot_reuse_a_descriptor_during_commit(self):self.scenario('close-race')
    def test_concurrent_write_serializes_after_commit_and_remains_dirty(self):self.scenario('write-race')
    def test_resize_is_retained_until_successful_flush(self):self.scenario('resize')
    def test_cross_mount_moves_refuse_and_same_save_rename_keeps_owned_flush(self):self.scenario('namespace')
    def test_unknown_mount_does_not_clear_save_state(self):self.scenario('unknown')
    def test_pending_and_open_descriptors_share_existing_table_bound(self):self.scenario('bound')
    def test_standalone_mac_branch_retains_original_behavior(self):self.scenario('legacy',False)
