"""Portable real add-on RomFS/index reads; wholly original test data."""
import hashlib
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
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('cc'), 'native C compiler required')
class CanopyAddonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        cls.probe=Path(cls.build.name)/'addon'
        command=['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror',
                 '-fsanitize=undefined','-fno-sanitize-recover=all','-pthread','-I',str(ROOT/'launcher/include'),
                 str(ROOT/'launcher/tests/addon_probe.c')]
        command += [str(ROOT/'launcher/src'/name) for name in ('mng_addon.c','mng_content.c','mng_crypto.c','mng_romfs.c','mng_romfs_runtime.c')]
        if sys.platform!='darwin':command+=['-lcrypto']
        subprocess.run(command+['-o',str(cls.probe)],check=True,capture_output=True,text=True)
    def run_case(self,mode='ok',index=None,special=None):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);image=root/'romfs';raw,layout=romfs([] if mode=='empty' else [('nested/data.bin',b'original payload')]);image.write_bytes(raw);image.chmod(0o600)
            if special and index is None:
                name=b'nested/data.bin\0'
                index=struct.pack('<8sQQQQII',b'TOTKRFS1',1,48,layout['data_start'],16,0,len(name))+name
            table=root/'index';table.write_bytes(index or b'');table.chmod(0o600)
            pin=root/'lease';pin.touch(mode=0o600)
            if special=='public':image.chmod(0o644)
            if special=='hardlink':os.link(image,root/'link')
            args=[str(self.probe),str(image),str(table),str(pin),mode]
            if mode=='isolation':
                other=root/'other';other.write_bytes(romfs([('nested/data.bin',b'separate payload')])[0]);other.chmod(0o600)
                other_index=root/'other-index';other_index.touch(mode=0o600);args += [str(other),str(other_index)]
            run=subprocess.run(args,capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'')
            return json.loads(run.stdout)['status']
    def test_actual_index_generation_mount_read_eof_paths_and_owned_pin(self):self.assertEqual(self.run_case(),0)
    def test_distinct_addons_read_independent_images(self):self.assertEqual(self.run_case('isolation'),0)
    def test_concurrent_real_reads(self):self.assertEqual(self.run_case('concurrent'),0)
    def test_actual_empty_romfs_and_canonical_zero_row_index(self):self.assertEqual(self.run_case('empty'),0)
    def test_empty_index_rejects_noncanonical_strings_and_trailing_bytes(self):
        for index in (struct.pack('<8sQQ',b'TOTKRFS1',0,23),struct.pack('<8sQQ',b'TOTKRFS1',0,24)+b'X'):
            with self.subTest(index=index):self.assertNotEqual(self.run_case('empty',index=index),0)
    def test_live_handle_capacity_and_stale_handles(self):self.assertEqual(self.run_case('capacity'),0)
    def test_cancel_mount_and_actual_read(self):
        self.assertEqual(self.run_case('cancel'),6);self.assertEqual(self.run_case('cancel-hash'),6);self.assertEqual(self.run_case('cancel-read'),0)
    def test_detected_source_mutation_refuses_read(self):self.assertEqual(self.run_case('mutate'),0)
    def test_receipt_bindings_and_integrity_required(self):
        for mode in ('wrong-hash','wrong-owner','wrong-addon','requires','unverified'):
            with self.subTest(mode=mode):self.assertNotEqual(self.run_case(mode),0)
    def test_private_single_link_inputs(self):
        for special in ('public','hardlink'):
            with self.subTest(special=special):self.assertNotEqual(self.run_case(special=special),0)
    def test_hash_valid_malformed_index_bounds_names_order_and_utf8(self):
        def table(paths,offset=0,size=1):
            strings=b'';rows=b''
            for path in paths:
                raw=path+b'\0';rows+=struct.pack('<QQII',offset,size,len(strings),len(raw));strings+=raw
            return struct.pack('<8sQQ',b'TOTKRFS1',len(paths),24+len(rows))+rows+strings
        cases=[b'X'*24,table([b'../bad']),table([b'/absolute']),table([b'bad\xc0\x80']),table([b'z',b'a']),
               table([b'a',b'a']),table([b'a',b'a-',b'a/b']),table([b'a',b'a-',b'a/b/c']),
               table([b'/'.join([b'x']*65)]),table([b'a'],offset=2**64-1),table([b'a'],size=2**64-1),table([b'a'])+b'X']
        for index in cases:
            with self.subTest(index=index):self.assertNotEqual(self.run_case(index=index),0)
    def test_latest_per_addon_sorted_and_dependency_refusals(self):
        for mode in ('plan','plan-owner','plan-requires','plan-unknown-base','plan-duplicate','plan-dependency','plan-role','plan-missing-highest'):
            run=subprocess.run([str(self.probe),mode],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr);report=json.loads(run.stdout)
            if mode=='plan':self.assertEqual((report['status'],report['count']),(0,2))
            else:self.assertNotEqual(report['status'],0);self.assertEqual(report['count'],0)
