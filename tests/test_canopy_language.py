"""Real shared language resolution/environment; Apple preferred-locale gate."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'games/totk/runtime'


@unittest.skipUnless(shutil.which('cc'), 'requires an existing C compiler')
class NativeLanguageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / 'language'
        build = subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-O3', '-Wall', '-Wextra', '-Werror',
                                '-fsanitize=undefined', '-fno-sanitize-recover=all', '-I', str(RUNTIME),
                                str(ROOT / 'launcher/tests/language_probe.c'), '-o', str(cls.probe)], capture_output=True, text=True)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def scenario(self, mode):
        run = subprocess.run([str(self.probe), mode], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), {'passed': True})

    def test_system_and_legacy_non_chinese_locale_canonicalization(self): self.scenario('system')
    def test_traditional_script_region_and_explicit_script_precedence(self): self.scenario('chinese')
    def test_brazil_support_stays_version_gated(self): self.scenario('brazil')
    def test_all_existing_native_explicit_codes_and_developer_spelling_unchanged(self): self.scenario('explicit')
    def test_input_bounds_output_padding_and_failure_unchanged(self): self.scenario('bounds')
    def test_actual_environment_system_unset_and_original_developer_override(self): self.scenario('environment')


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'requires existing Apple Foundation/Metal tools; no installs')
class AppleLanguageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / 'preferred'
        build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                                '-DCANOPY_HOST_RUNTIME=1', '-I', str(RUNTIME), '-I', str(ROOT / 'launcher/include'),
                                str(ROOT / 'tests/canopy_language_probe.m'), str(RUNTIME / 'canopy_host.m'),
                                '-framework', 'Foundation', '-framework', 'Metal', '-o', str(cls.probe)],
                               capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def test_actual_foundation_preferred_languages_feed_system_resolution(self):
        for tag, expected in (('zh-Hant-TW', 'zh-Hant'), ('zh-HK', 'zh-Hant'), ('zh-Hans-CN', 'zh-Hans'), ('de-DE', 'de')):
            with self.subTest(locale=tag):
                run = subprocess.run([str(self.probe), 'preferred', expected, '-AppleLanguages', '(' + tag + ')'],
                                     capture_output=True, text=True, timeout=15)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(json.loads(run.stdout), {'passed': True})

    def test_actual_canopy_only_experiment_reset_preserves_taa(self):
        run = subprocess.run([str(self.probe), 'reset', '-'], capture_output=True, text=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), {'passed': True})
