"""Original native restart-control fixture, never game-only restart acceptance."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('cc'),'native C compiler required')
class CanopyRestartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup);cls.probe=Path(cls.temp.name)/'restart'
        run=subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-pthread',
            '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),
            str(ROOT/'launcher/src/mng_restart.c'),str(ROOT/'launcher/tests/restart_probe.c'),'-o',str(cls.probe)],
            capture_output=True,text=True,timeout=60)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
    def scenario(self,name):
        run=subprocess.run([str(self.probe),name],capture_output=True,text=True,timeout=10)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'')
        self.assertEqual(json.loads(run.stdout)['status'],'pass')
    def test_first_confirmation_cancel_leaves_fixture_session_untouched(self):self.scenario('cancel-first')
    def test_second_confirmation_cancel_leaves_fixture_session_untouched(self):self.scenario('cancel-second')
    def test_actual_original_engine_thread_transition_and_single_flight(self):self.scenario('transition')
    def test_dispatch_refusal_is_failure(self):self.scenario('refused')
    def test_noop_submission_is_not_completion(self):self.scenario('noop')
    def test_synchronous_completion_does_not_deadlock_or_allow_overlap(self):self.scenario('synchronous')

if __name__=='__main__':unittest.main()
