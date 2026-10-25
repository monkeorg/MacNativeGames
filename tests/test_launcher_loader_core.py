"""Real Apple production module core + original rewritten ARM64 fixture.

Mac native execution does not establish iOS signing. The unsigned iPhoneOS app
build proves compilation/linking only; no SDK installs, simulator or device use.
"""
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from test_launcher_execution_fixture import fixture, apple_probe, HAVE_REWRITE_DEPS
ROOT=Path(__file__).resolve().parents[1]
HERE=ROOT/'tools/launcher/fixture'
RUNTIME=ROOT/'games/totk/runtime'


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun') and HAVE_REWRITE_DEPS,
                     'requires installed Apple SDKs and existing rewrite dependencies; no downloads')
class ProductionLoaderFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup)
        cls.work=Path(cls.temp.name).resolve();cls.artifact=cls.work/'fixture';fixture.build(cls.artifact)
        cls.binary=cls.work/'native-loader-fixture'
        sdk=cls.run_command(['xcrun','--sdk','macosx','--show-sdk-path']).stdout.strip()
        common=['xcrun','--sdk','macosx','clang','-target','arm64-apple-macos14.0','-isysroot',sdk,
                '-O2','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
                '-I'+str(RUNTIME),'-I'+str(apple_probe.COMPAT),'-I'+str(HERE),'-I'+str(cls.artifact/'generated')]
        objects=[]
        for i,source in enumerate((HERE/'fixture_runner.c',HERE/'native_probe.c',RUNTIME/'gate.S')):
            output=cls.work/(str(i)+'.o')
            cls.run_command([*common,*(['-std=gnu11'] if source.suffix=='.c' else []),'-c',str(source),'-o',str(output)])
            objects.append(str(output))
        cls.run_command([*common,*objects,'-o',str(cls.binary)])

    @staticmethod
    def run_command(command):
        run=subprocess.run(command,capture_output=True,text=True,timeout=120)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
        return run

    def native(self,mode):
        if platform.machine().lower() not in ('arm64','aarch64'):
            self.skipTest('actual native ARM64 execution requires Apple silicon; no translation fallback')
        return subprocess.run([str(self.binary),str(self.artifact/'rewritten'),mode],
                              capture_output=True,text=True,timeout=20)

    def test_actual_mac_mapper_relocation_seal_symbols_and_service_gate_execute(self):
        run=self.native('positive');self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        report=json.loads(run.stdout);self.assertEqual(report['status'],'pass')
        self.assertEqual([report[k] for k in ('answer','tls_answer','relocated_answer','service_answer')],[17,0x12345678,27,111])
        self.assertEqual(report['host_calls'],1);self.assertEqual(report['service_calls'],1)
        self.assertIs(report['permissions_verified'],True)

    def test_actual_production_checks_refuse_bad_digest_layout_relocation_and_gate(self):
        for mode,reason in (('bad-digest','image SHA256'),('bad-layout','key and patch layout'),
                            ('bad-relocation','relocation bounds'),('bad-gate','unknown gate return address')):
            with self.subTest(mode=mode):
                run=self.native(mode);self.assertEqual(run.returncode,2,run.stdout+run.stderr)
                self.assertEqual(run.stdout,'');self.assertIn('FIXTURE_FAILURE '+reason,run.stderr)

    def test_unsigned_iphoneos_app_links_actual_shared_signed_mapper_and_gate(self):
        output=self.work/'OriginalLoaderFixture.app'
        report=apple_probe.build(self.artifact,output)
        self.assertEqual(report['status'],'built_unsigned');self.assertEqual(report['native_execution'],'not_run')
        self.assertEqual(report['apple_signing'],'not_run')
        expected={'games/totk/runtime/loader_module_core.h','games/totk/runtime/gate.S',
                  'tools/launcher/fixture/fixture_runner.c'}
        self.assertTrue(expected.issubset(report['production_inputs']))
        for name,digest in report['production_inputs'].items():
            self.assertEqual(hashlib.sha256((ROOT/name).read_bytes()).hexdigest(),digest)
        self.assertGreater((output/'ExecutionFixture').stat().st_size,0)
