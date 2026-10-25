"""Compile and execute actual portable routing; no GameController/device claim."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CanopyPlayers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
        if not compiler:
            raise unittest.SkipTest('C compiler unavailable')
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.probe = Path(cls.directory.name) / 'players'
        flags = ['-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic']
        supported = subprocess.run([compiler, '-x', 'c', '-', '-fsanitize=undefined',
                                    '-o', str(Path(cls.directory.name) / 'sanitizer')],
                                   input='int main(void){return 0;}\n', text=True,
                                   capture_output=True).returncode == 0
        if supported:
            flags += ['-fsanitize=undefined', '-fno-sanitize-recover=all']
        subprocess.run([compiler, *flags, '-I', str(ROOT / 'launcher/include'),
                        str(ROOT / 'launcher/src/mng_players.c'),
                        str(ROOT / 'launcher/tests/players_probe.c'), '-o', str(cls.probe)],
                       check=True, capture_output=True, text=True)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(json.loads(result.stdout)['status'], 'pass')

    def test_opposing_simultaneous_players_remain_separate(self):
        self.scenario('opposing')

    def test_disconnect_reconnect_reassign_release_only_affected_player(self):
        self.scenario('disconnect')

    def test_assignment_conflicts_and_explicit_swap(self):
        self.scenario('swap')

    def test_focus_cancels_held_and_queued_input(self):
        self.scenario('focus')

    def test_invalid_ids_buttons_axes_and_stale_updates_are_atomic(self):
        self.scenario('invalid')

    def test_capacity_clamping_sequence_and_token_exhaustion(self):
        self.scenario('limits')

    def test_short_taps_are_delivered_once_without_changing_peek_or_held(self):
        self.scenario('taps')

    def test_reset_focus_swap_disconnect_clear_latched_edges_and_epochs(self):
        self.scenario('edge-cancel')


if __name__ == '__main__':
    unittest.main()
