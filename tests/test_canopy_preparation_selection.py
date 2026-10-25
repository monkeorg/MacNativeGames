"""Production picker state machine; this is not UIKit/provider acceptance."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'), 'requires an existing C compiler')
class PreparationSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / 'selection'
        subprocess.run(['cc', '-std=c11', '-O3', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=undefined', '-fno-sanitize-recover=all',
                        '-I', str(ROOT / 'launcher/include'),
                        str(ROOT / 'launcher/tests/preparation_selection_probe.c'),
                        '-o', str(cls.probe)], check=True, capture_output=True, text=True)

    def scenario(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {'passed': True})

    def test_all_original_and_resume_modes_deliver_exact_job_once(self):
        self.scenario('routes')

    def test_stale_picker_and_dismissal_epochs_cannot_replace_new_selection(self):
        self.scenario('stale')

    def test_background_cancel_clears_ownership_at_every_stage(self):
        self.scenario('cancel')

    def test_resume_reserves_mode_before_navigation_and_cancels_failed_transition(self):
        self.scenario('reserve')

    def test_invalid_ids_modes_duplicate_callbacks_and_epoch_overflow_refused(self):
        self.scenario('invalid')

    def test_selected_update_copies_exact_ids_and_requires_epoch_origin_and_paired_route(self):
        self.scenario('reuse')

    def test_selected_update_cancel_clears_candidate_before_generic_resume_or_folder(self):
        self.scenario('reuse-cancel')

    def test_selected_update_invalid_ids_origin_and_active_flow_refuse_atomically(self):
        self.scenario('reuse-invalid')
