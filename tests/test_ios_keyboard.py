"""Exercise the production keyboard preferences and physical-key state machine."""
import pathlib
import os
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'games/totk/ios/Sources'


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Apple Foundation')
class IOSKeyboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='totk-keyboard-')
        cls.probe = pathlib.Path(cls.temp.name) / 'probe'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-I', str(SOURCES), str(ROOT / 'tests/ios_keyboard_probe.m'),
                        str(SOURCES / 'keyboard_input.m'), '-framework', 'Foundation',
                        '-o', str(cls.probe)], check=True, capture_output=True, text=True)
        cls.runtime_probe = pathlib.Path(cls.temp.name) / 'runtime-probe'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-Wl,-undefined,dynamic_lookup', str(ROOT / 'tests/ios_keyboard_runtime_probe.c'),
                        '-o', str(cls.runtime_probe)], check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def probe_case(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'PASS')

    def test_defaults_and_malformed_preferences(self): self.probe_case('preferences')
    def test_persisted_binding_and_none(self): self.probe_case('persistence')
    def test_conflict_and_reserved_key_refusal(self): self.probe_case('conflicts')
    def test_only_game_actions_reach_runtime(self): self.probe_case('safe_translation')
    def test_duplicate_sources_and_repeated_down(self): self.probe_case('sources')
    def test_either_tracked_source_releases_without_other_channel_up(self): self.probe_case('missing_source_release')
    def test_release_retains_original_action(self): self.probe_case('release_mapping')
    def test_shared_output_reference_counts(self): self.probe_case('references')
    def test_menu_focus_cleanup_is_idempotent(self): self.probe_case('cleanup')

    def test_production_keyboard_clear_flushes_pending_without_controller_clear(self):
        env = os.environ.copy()
        env.pop('TOTK_INPUT_SCRIPT', None)
        env.pop('TOTK_INPUT_FILE', None)
        result = subprocess.run([str(self.runtime_probe)], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'PASS')
