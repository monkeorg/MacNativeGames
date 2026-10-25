"""Check iPad frame-cap deadlines and the existing TAA frame-boundary latch without a device."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
GFX=ROOT/'games/totk/third_party/d2r_gfx/gfx/nvn'

class IOSGraphicsControls(unittest.TestCase):
    def build_and_run(self, command):
        with tempfile.TemporaryDirectory(prefix='totk-graphics-controls-') as folder:
            binary=Path(folder)/'probe'
            build=subprocess.run([*command,'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertEqual(run.stdout.strip(),'PASS')

    @unittest.skipUnless(shutil.which('cc'),'requires a C compiler')
    def test_supported_rates_deadlines_and_hitch_recovery(self):
        self.build_and_run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(ROOT/'tests/ios_fps_policy_probe.c')])

    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'requires Apple MetalFX SDK')
    def test_actual_taa_request_validation_and_frame_latch(self):
        self.build_and_run(['xcrun','clang','-fobjc-arc','-fmodules','-Wall','-Wextra','-Werror',
                            '-I',str(GFX),str(ROOT/'tests/ios_taa_request_probe.m'),str(GFX/'totk_taa.m'),
                            '-framework','Foundation','-framework','Metal','-framework','MetalFX'])
