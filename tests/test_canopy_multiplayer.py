"""Real bounded guest HID service; original native client, no game content."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]


class CanopyMultiplayerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('cc')
        if not cc:raise unittest.SkipTest('C compiler unavailable')
        cls.temp=tempfile.TemporaryDirectory(prefix='canopy-multiplayer-');cls.addClassCleanup(cls.temp.cleanup)
        cls.directory=Path(cls.temp.name).resolve();cls.probe=cls.directory/'probe';cls.module=cls.directory/'original-native-client.dylib'
        flags=[cc,'-std=c11','-O2','-g','-Wall','-Wextra','-Wpedantic','-Werror',
               '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include')]
        fixture=str(ROOT/'launcher/tests/multiplayer_probe.c');service=str(ROOT/'launcher/src/mng_multiplayer.c')
        commands=[flags+['-DMNG_MULTIPLAYER_MODULE',fixture,service,'-pthread','-lm',
                        *(['-dynamiclib'] if sys.platform=='darwin' else ['-shared','-fPIC']),'-o',str(cls.module)],
                  flags+[fixture,service,str(ROOT/'launcher/src/mng_players.c'),str(ROOT/'launcher/src/mng_session.c'),
                         str(ROOT/'launcher/src/mng_crypto.c'),'-pthread','-lm',
                         *(['-framework','Security'] if sys.platform=='darwin' else ['-lcrypto','-ldl']),'-o',str(cls.probe)]]
        for command in commands:
            run=subprocess.run(command,capture_output=True,text=True,timeout=120)
            if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def scenario(self,name,*args):
        run=subprocess.run([str(self.probe),name,*map(str,args)],capture_output=True,text=True,timeout=30)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertEqual(json.loads(run.stdout)['status'],'pass')

    def test_four_distinct_controllers_reach_actual_guest_fullkey_calls(self):self.scenario('four')
    def test_portable_native_button_and_stick_abi(self):self.scenario('mapping')
    def test_stale_duplicate_nonfinite_out_of_range_and_system_inputs_rejected_atomically(self):self.scenario('invalid')
    def test_guest_supported_ids_styles_and_invalid_filter_fail_closed(self):self.scenario('filters')
    def test_history_disconnect_replacement_and_cancel_do_not_replay_held_buttons(self):self.scenario('history')
    def test_guest_disconnect_latch_survives_owner_pause_but_reassignment_reconnects(self):self.scenario('latch')
    def test_exclusive_binding_and_single_player_capacity_do_not_expand(self):self.scenario('binding')
    def test_concurrent_guest_reads_host_updates_and_detachment(self):self.scenario('concurrency')
    def test_actual_router_verified_module_loader_guest_hid_pause_resume(self):
        data=self.module.read_bytes()
        self.scenario('session',self.directory,self.module.name,len(data),hashlib.sha256(data).hexdigest())
