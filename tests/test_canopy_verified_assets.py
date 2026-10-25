"""One actual store verification supplies receipt-bound asset facts and a lease.

Invented store-only payloads establish IO/hash/lease behavior, not NCA integrity
or title compatibility. No private inputs, cache shortcuts or mmap assumptions.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'),'native C compiler required')
class CanopyVerifiedAssetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup);build=Path(cls.temp.name)
        wrapper=build/'store.c';wrapper.write_text('#define _GNU_SOURCE\n#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n'
            '#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n#include <unistd.h>\n#include <sys/file.h>\n'
            'ssize_t verified_assets_read(int,void *,size_t);\nint verified_assets_flock(int,int);\n'
            '#define read verified_assets_read\n#define flock verified_assets_flock\n#include "'+str(ROOT/'launcher/src/mng_store.c')+'"\n')
        cls.probe=build/'verified-assets'
        run=subprocess.run(['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror',
            '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),
            str(wrapper),str(ROOT/'launcher/tests/verified_assets_probe.c'),str(ROOT/'launcher/src/mng_crypto.c'),
            *([] if sys.platform=='darwin' else ['-lcrypto']),'-o',str(cls.probe)],capture_output=True,text=True,timeout=60)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def scenario(self,mode,success=True):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();root.chmod(0o700)
            run=subprocess.run([str(self.probe),mode,str(root)],capture_output=True,text=True,timeout=15)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertEqual(run.stderr,'');self.assertNotIn(str(root),run.stdout)
            report=json.loads(run.stdout);self.assertEqual(report['status']==0,success,report)
            return report

    def test_actual_asset_facts_equal_hashed_payloads_and_preparation(self):self.scenario('normal')
    def test_every_call_rehashes_once_and_avoids_the_duplicate_consumer_pass(self):
        result=self.scenario('reads')
        self.assertEqual(result['verifiedMainBytes'],131101);self.assertEqual(result['verifiedRomfsBytes'],262181)
        self.assertEqual(result['oldWithConsumerMainBytes'],2*131101)
        self.assertEqual(result['oldWithConsumerRomfsBytes'],2*262181)
    def test_corrupt_assets_receipt_and_manifest_refuse_without_output_changes(self):
        for mode in ('main-corrupt','romfs-corrupt','npdm-corrupt','receipt-corrupt','manifest-corrupt'):
            with self.subTest(mode=mode):self.scenario(mode,False)
    def test_failed_real_lease_acquisition_keeps_outputs_and_closes_descriptor(self):self.scenario('lease-error',False)
    def test_invalid_arguments_keep_outputs_unchanged(self):self.scenario('invalid',False)
    def test_cancellation_during_actual_hash_keeps_outputs(self):self.scenario('cancel',False)
    def test_genuine_shared_lease_protects_gc_after_store_reopen(self):self.scenario('gc')
    def test_v5_addon_without_main_preserves_old_pin_compatibility(self):self.scenario('addon')
    def test_zero_size_main_is_present_with_exact_empty_digest(self):self.scenario('empty')
