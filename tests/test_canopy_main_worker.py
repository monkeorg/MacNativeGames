"""Actual Canopy main-worker observation; no full stop or relaunch acceptance."""
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'games/totk'


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64' and shutil.which('xcrun'),
                     'actual main-worker and ARM64 SVC fixture requires Apple tools')
class CanopyMainWorkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / 'main-worker'
        command = ['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE', '-DCANOPY_HOST_RUNTIME=1',
                   '-fobjc-arc', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                   '-I', str(ROOT / 'launcher/include'), '-I', str(GAME / 'runtime'),
                   '-I', str(GAME / 'third_party/d2r_gfx/gfx/nvn/include'),
                   str(ROOT / 'tests/canopy_main_worker_probe.m'), str(GAME / 'runtime/threads.c'),
                   str(GAME / 'runtime/thread_enter.S'), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(cls.probe)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(json.loads(result.stdout)['passed'])

    def test_natural_return_cleanup_precedes_actual_tls_join(self):
        self.scenario('return')

    def test_actual_main_svc_exit_cleanup_is_not_function_return(self):
        self.scenario('svc-exit')

    def test_joined_main_retains_live_guest_children_and_closes_admission(self):
        self.scenario('child-pending')
