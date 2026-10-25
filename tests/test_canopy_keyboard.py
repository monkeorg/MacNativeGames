"""Exercise the real HID adapter with original public synthetic events."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CanopyKeyboard(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('native C compiler required')
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.probe = Path(cls.directory.name) / 'keyboard-probe'
        result = subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pedantic', '-fsanitize=undefined', '-fno-sanitize-recover=all',
            '-I', str(ROOT / 'launcher/include'), str(ROOT / 'launcher/src/mng_keyboard.c'),
            str(ROOT / 'launcher/tests/keyboard_probe.c'), '-o', str(cls.probe)],
            capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '{"status":"pass"}')

    def test_duplicate_sources_short_taps_and_capture_clear(self):
        self.scenario('dedup')

    def test_remap_atomicity_reserved_keys_and_original_release(self):
        self.scenario('bindings')

    def test_all_actions_reach_canonical_guest_schema(self):
        self.scenario('schema')
