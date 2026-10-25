"""Run actual portable cores called by Canopy's UIKit input frontend.

These synthetic-event checks do not claim real UIKit/device interactions.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CanopyFrontend(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('native C compiler required')
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.probe = Path(cls.directory.name) / 'frontend-probe'
        result = subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pedantic', '-fsanitize=undefined', '-fno-sanitize-recover=all',
            '-I', str(ROOT / 'launcher/include'),
            *(str(ROOT / 'launcher/src' / (name + '.c')) for name in ('mng_input', 'mng_pointer', 'mng_touch')),
            str(ROOT / 'launcher/tests/frontend_probe.c'), '-lm', '-o', str(cls.probe)],
            capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '{"status":"pass"}')

    def test_actual_lock_grant_all_focus_gates_mouse_mapping_short_taps_and_look(self):
        self.scenario('pointer')

    def test_safe_area_canonical_touch_controls_late_indirect_and_rotation_cancel(self):
        self.scenario('touch')
