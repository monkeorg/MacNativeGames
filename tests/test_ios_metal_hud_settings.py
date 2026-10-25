"""Validate Metal HUD preferences and documented layer-property mappings."""
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'games/totk/ios/Sources'


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Apple Foundation')
class IOSMetalHUDSettingsTests(unittest.TestCase):
    def test_validated_preferences_and_layer_properties(self):
        with tempfile.TemporaryDirectory(prefix='totk-metal-hud-settings-') as temp:
            probe = pathlib.Path(temp) / 'probe'
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-I', str(SOURCES), str(ROOT / 'tests/ios_metal_hud_settings_probe.m'),
                            str(SOURCES / 'launcher_settings.m'), '-framework', 'Foundation', '-o', str(probe)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(probe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS:', result.stdout)
