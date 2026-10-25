"""Native preference validation and persistence for the graphics menu."""
import pathlib
import platform
import subprocess
import tempfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'games/totk/ios/Sources'


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Apple Foundation')
class IOSGraphicsSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='totk-graphics-settings-')
        cls.probe = pathlib.Path(cls.temp.name) / 'probe'
        result = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                                 '-I', str(SOURCES), str(ROOT / 'tests/ios_graphics_settings_probe.m'),
                                 str(SOURCES / 'launcher_settings.m'), '-framework', 'Foundation', '-o', str(cls.probe)],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_probe(self, mode, suite):
        result = subprocess.run([str(self.probe), mode, suite], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'PASS')

    def test_defaults_allowed_values_and_malformed_recovery(self):
        self.run_probe('defaults', 'TOTKGraphicsProbe.' + uuid.uuid4().hex)

    def test_preferences_persist_between_processes(self):
        suite = 'TOTKGraphicsProbe.' + uuid.uuid4().hex
        self.run_probe('write', suite)
        self.run_probe('read', suite)

    def test_scene_output_dimensions_and_signed_capacity(self):
        self.run_probe('dimensions', 'TOTKGraphicsProbe.' + uuid.uuid4().hex)

    def test_native_ipad_and_4k_display_plans(self):
        self.run_probe('plans', 'TOTKGraphicsProbe.' + uuid.uuid4().hex)
