"""Native bridge tests on macOS; snapshot controllers, not physical gameplay."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'GameController bridge execution requires macOS frameworks')
class CanopyControllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.probe = Path(cls.directory.name) / 'controllers'
        sources = ROOT / 'launcher/apple/Sources'
        players = Path(cls.directory.name) / 'players.o'
        core = subprocess.run([
            'xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-I', str(ROOT / 'launcher/include'), '-c',
            str(ROOT / 'launcher/src/mng_players.c'), '-o', str(players),
        ], capture_output=True, text=True, timeout=120)
        if core.returncode:
            raise AssertionError(core.stdout + core.stderr)
        result = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
            '-I', str(sources), '-I', str(ROOT / 'launcher/include'),
            str(ROOT / 'tests/canopy_controllers_probe.m'),
            str(sources / 'CanopyControllers.m'), str(players),
            '-framework', 'Foundation', '-framework', 'GameController', '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        if report['status'] == 'skip':
            self.skipTest(report['reason'])
        self.assertEqual(report['status'], 'pass')

    def test_real_notifications_and_independent_snapshot_routing(self):
        self.scenario('independent')

    def test_disconnect_reconnect_releases_only_affected_player(self):
        self.scenario('disconnect')

    def test_swap_invalidates_queued_callbacks(self):
        self.scenario('swap')

    def test_focus_clears_held_input_and_rejects_old_callbacks(self):
        self.scenario('focus')

    def test_reassign_preserves_other_player_handler_sequence(self):
        self.scenario('reassign')

    def test_teardown_releases_observers_and_handlers(self):
        self.scenario('teardown')

    def test_home_commands_survive_capture_without_replaying_held_buttons(self):
        self.scenario('commands')


if __name__ == '__main__':
    unittest.main()
