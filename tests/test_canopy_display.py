"""Portable real startup display resolution, not graphics/gameplay acceptance."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('cc'),'portable display checks require native compiler')
class CanopyDisplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup);cls.probe=Path(cls.temp.name)/'display'
        run=subprocess.run(['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror','-fsanitize=undefined','-fno-sanitize-recover=all',
            '-I',str(ROOT/'launcher/include'),str(ROOT/'launcher/src/mng_display.c'),str(ROOT/'launcher/tests/display_probe.c'),'-lm','-o',str(cls.probe)],
            capture_output=True,text=True,timeout=60)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
    def scenario(self,name):
        run=subprocess.run([str(self.probe),name],capture_output=True,text=True,timeout=10)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'');self.assertEqual(json.loads(run.stdout)['status'],'pass')
    def test_presentation_resize_preserves_scene_and_native_width(self):self.scenario('layout-wide')
    def test_stock_presentation_retains_actual_width_not_scene_target(self):self.scenario('layout-stock')
    def test_full_projection_rejects_incompatible_layout_then_allows_return(self):self.scenario('layout-full')
    def test_invalid_presentation_and_unrepresentable_sizes_preserve_output(self):self.scenario('layout-invalid')
    def test_stock_v121_only_720_sixteen_nine(self):self.scenario('stock')
    def test_unsupported_stock_requests_have_explicit_fallback_outcomes(self):self.scenario('stock-fallback')
    def test_checked_scene_profile_1080_and_separate_four_three_capability(self):self.scenario('wide')
    def test_exact_four_three_720_and_experimental_1440x1080(self):self.scenario('four-three')
    def test_other_and_portrait_ratios_remain_sixteen_nine(self):self.scenario('other-ratios')
    def test_nonfinite_bounds_unknown_profiles_and_invalid_requests_preserve_output(self):self.scenario('invalid')
    def test_host_revalidation_rejects_forged_configuration_or_changed_view(self):self.scenario('tamper')

@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'actual host query requires macOS Foundation/Metal')
class CanopyDisplayHostTests(unittest.TestCase):
    def test_actual_unconfigured_host_never_claims_display_or_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            probe=Path(temporary)/'display-host'
            run=subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-DCANOPY_HOST_RUNTIME=1',
                '-I',str(ROOT/'launcher/include'),'-I',str(ROOT/'games/totk/runtime'),
                str(ROOT/'tests/canopy_display_host_probe.m'),str(ROOT/'games/totk/runtime/canopy_host.m'),
                '-framework','Foundation','-framework','Metal','-o',str(probe)],capture_output=True,text=True,timeout=120)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            run=subprocess.run([str(probe)],capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'');self.assertEqual(json.loads(run.stdout)['status'],'pass')
