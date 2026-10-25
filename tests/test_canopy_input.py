"""Run real portable mapping/mixing logic using synthetic input, no game data."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CanopyInput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('native C compiler required')
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.probe = Path(cls.directory.name) / 'input-probe'
        result = subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-pedantic', '-fsanitize=undefined', '-fno-sanitize-recover=all',
            '-I', str(ROOT / 'launcher/include'), str(ROOT / 'launcher/src/mng_input.c'),
            str(ROOT / 'launcher/tests/input_probe.c'), '-lm', '-o', str(cls.probe)],
            capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'status': 'pass'})

    def test_explicit_bit_conversion_face_defaults_and_environment_independence(self):
        self.scenario('layouts')

    def test_production_map_grammar_bounds_and_atomic_refusal(self):
        self.scenario('parser')

    def test_hold_tap_toggle_aim_time_saturation_and_device_isolation(self):
        self.scenario('modes')

    def test_invalid_axes_bits_maps_and_clock_regression_leave_state_unchanged(self):
        self.scenario('invalid')

    def test_aim_suppresses_all_fire_modes_and_cancels_delayed_attacks(self):
        self.scenario('aim-fire')

    def test_same_player_mixing_tie_policy_and_atomic_invalid_refusal(self):
        self.scenario('mixer')


if __name__ == '__main__':
    unittest.main()
