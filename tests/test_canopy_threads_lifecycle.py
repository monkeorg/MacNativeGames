"""Actual production SVC/pthread child ownership, not whole-runtime teardown."""
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'games/totk'


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64' and shutil.which('xcrun'),
                     'actual native ARM64 SVC/stack-switch fixture requires Apple tools')
class CanopyThreadsLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probes = {}
        for canopy in (False, True):
            output = Path(cls.temp.name) / ('canopy' if canopy else 'standalone')
            source = ROOT / 'tests/canopy_threads_lifecycle_probe.c' if canopy else GAME / 'scripts/thread_probe.c'
            command = ['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                       '-I', str(GAME / 'runtime'), '-I', str(GAME / 'third_party/d2r_gfx/gfx/nvn/include'),
                       str(source), str(GAME / 'runtime/threads.c'), str(GAME / 'runtime/thread_enter.S'), '-o', str(output)]
            if canopy:
                command.insert(2, '-DCANOPY_HOST_RUNTIME=1')
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
            cls.probes[canopy] = output

    def run_probe(self, scenario=None):
        result = subprocess.run([str(self.probes[scenario is not None]), *([scenario] if scenario else [])],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_handle_close_and_guest_exit_retain_owner_until_tls_destructors_join(self):
        self.run_probe('lifetime')

    def test_spawn_admission_close_race_retains_every_admitted_child(self):
        self.run_probe('race')

    def test_unstarted_child_remains_pending_without_injected_exit(self):
        self.run_probe('unstarted')

    def test_standalone_original_native_dispatcher_and_stack_switch_unchanged(self):
        self.run_probe()
