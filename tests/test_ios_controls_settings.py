"""Actual Foundation controls preparation with synthetic preferences and files.

Only the Application Support lookup is redirected. This is not UIKit/device
acceptance: production settings, mapping parser, environment and save seal run.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'games/totk/ios/Sources'


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Apple Foundation')
class IOSControlsSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='totk-controls-settings-')
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        adapter = folder / 'settings.m'
        adapter.write_text(
            '#import <Foundation/Foundation.h>\n'
            'NSArray<NSString *> *TOTKControlsProbeSearchPath(NSSearchPathDirectory,NSSearchPathDomainMask,BOOL);\n'
            '#define NSSearchPathForDirectoriesInDomains TOTKControlsProbeSearchPath\n'
            '#include "' + str(SOURCES / 'launcher_settings.m') + '"\n')
        cls.probe = folder / 'probe'
        build = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
            '-I', str(SOURCES), str(ROOT / 'tests/ios_controls_settings_probe.m'),
            str(adapter), str(SOURCES / 'save_store.m'), str(SOURCES / 'save_validation.m'),
            '-framework', 'Foundation', '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def run_probe(self, scenario):
        with tempfile.TemporaryDirectory(prefix='totk-controls-files-') as folder:
            environment = dict(os.environ)
            for key in ('TOTK_CONTROLS', 'TOTK_MOUSE_SENSITIVITY', 'TOTK_MOUSE_INVERT_Y'):
                environment.pop(key, None)
            run = subprocess.run([
                str(self.probe), scenario, folder, 'TOTKControlsProbe.' + uuid.uuid4().hex,
            ], env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(run.stdout.strip(), 'PASS')

    def test_sensitivity_inversion_and_malformed_recovery(self):
        self.run_probe('values')

    def test_controller_types_and_invalid_mapping_recovery(self):
        self.run_probe('types')

    def test_untouched_defaults_do_not_generate_controls_or_replace_runtime_modes(self):
        self.run_probe('defaults')

    def test_default_none_and_custom_bindings_feed_real_runtime_parser(self):
        self.run_probe('mapping')

    def test_type_only_configuration_and_return_to_automatic(self):
        self.run_probe('type-only')

    def test_developer_environment_precedence_preserves_external_file(self):
        self.run_probe('override')

    def test_directory_write_failure_retry_precedes_actual_save_seal(self):
        self.run_probe('directory-failure')

    def test_companion_write_failure_retry_precedes_actual_save_seal(self):
        self.run_probe('companion-failure')
