"""Exercise signed iOS display patches with synthetic ARM64 words and read-only device text."""
import shutil
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class IOSDisplayTests(unittest.TestCase):
    def check_patch_contracts(self, profiles, compiler):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for device, profile, vert in profiles:
                with self.subTest(device=device, profile=profile, vert=vert):
                    (root / 'TargetConditionals.h').write_text(f'#undef TARGET_OS_IPHONE\n#define TARGET_OS_IPHONE {int(device)}\n')
                    binary = root / 'probe'
                    build = subprocess.run([
                        *compiler, '-std=gnu11', '-O1', '-Wall', '-Wextra', '-Werror',
                        *(['-Wno-misleading-indentation'] if sys.platform != 'darwin' else []),
                        '-Wno-unused-function', '-Wno-unused-parameter', '-Wno-sign-compare',
                        '-DTOTK_GAME_V143=1', *(['-DTOTK_IOS_DISPLAY_SETTINGS=1'] if profile else []), '-I', str(root),
                        *(['-DTOTK_TEST_VERT=1'] if vert else []),
                        *(['-DTOTK_IOS_ASPECT_VERT=1'] if vert and device else []),
                        str(ROOT / 'tests/ios_display_probe.c'), '-lm', '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
                    scenarios = ('baseline', 'full', 'oversize', 'oversize_scene', 'bad_output', 'bad_render', 'bad_fixed', 'bad_aspect', 'bad_output_preserved', 'bad_output_resume', 'bad_output_veneer', 'bad_aspect_veneer') if profile else ('stock',)
                    if vert:
                        scenarios += ('bad_vert_veneer', 'bad_vert_branch', 'bad_vert_pattern')
                    for scenario in scenarios:
                        with self.subTest(scenario=scenario):
                            run = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=20)
                            self.assertEqual(run.returncode, 0 if scenario in ('baseline', 'full', 'stock') else 78,
                                             run.stdout + run.stderr)
                            if run.returncode == 0:
                                self.assertIn('display profile pass', run.stdout)

    def test_device_signed_patch_contracts(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('A C compiler is required')
        self.check_patch_contracts(((True, True, False), (True, False, False), (True, True, True)), [compiler])

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS command line tools')
    def test_export_patch_contracts(self):
        self.check_patch_contracts(((False, True, False), (False, True, True)), ['xcrun', 'clang'])


class IOSDisplayBuildGateTests(unittest.TestCase):
    def test_other_versions_refuse_display_profile_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = subprocess.run([
                sys.executable, str(ROOT / 'games/totk/ios/tools/build_ipa.py'),
                '--tree', str(root), '--out', str(root / 'test.app'), '--logs', str(root),
                '--version', 'v112', '--display-settings',
            ], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
            self.assertIn('--display-settings supports only TOTK1.4.3', run.stderr)


    def test_explicit_flag_controls_actual_export_environment(self):
        tools = ROOT / 'games/totk/ios/tools'
        sys.path.insert(0, str(tools))
        try:
            spec = importlib.util.spec_from_file_location('ios_display_packager', tools / 'build_ipa.py')
            packager = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(packager)
        finally:
            sys.path.pop(0)

        class ExportCaptured(Exception):
            pass

        for enabled, inherited in ((False, '1'), (True, '0')):
            with self.subTest(enabled=enabled, inherited=inherited), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                captured = []

                def stop_at_export(args, cwd, log, env):
                    self.assertEqual(args[-1], 'export-ios')
                    captured.append(dict(env))
                    raise ExportCaptured

                argv = ['build_ipa.py', '--tree', str(root), '--out', str(root / 'test.app'),
                        '--logs', str(root / 'logs'), '--version', 'v143']
                if enabled:
                    argv.append('--display-settings')
                with mock.patch.object(sys, 'argv', argv), \
                     mock.patch.dict(os.environ, {'TOTK_IOS_DISPLAY_SETTINGS': inherited}), \
                     mock.patch.object(packager, 'developer_dir', return_value='/fake/Xcode'), \
                     mock.patch.object(packager.subprocess, 'check_output', return_value='/fake/sdk'), \
                     mock.patch.object(packager.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                     mock.patch.object(packager.shutil, 'which', return_value='/fake/xcodegen'), \
                     mock.patch.object(packager, 'clone'), \
                     mock.patch.object(packager, 'run', side_effect=stop_at_export):
                    with self.assertRaises(ExportCaptured):
                        packager.main()
                self.assertEqual(len(captured), 1)
                self.assertEqual(captured[0].get('TOTK_IOS_DISPLAY_SETTINGS'), '1' if enabled else None)
                if enabled:
                    self.assertEqual(captured[0]['TOTK_OUTPUT_RES'], '1280x720')
                    self.assertEqual(captured[0]['TOTK_RENDER_RES'], '1280x720')
                    self.assertEqual(captured[0]['TOTK_ASPECT'], '0')
                    self.assertEqual(captured[0]['TOTK_ASPECT_VERT'], '1')
                    self.assertEqual(captured[0]['TOTK_IOS_ASPECT_VERT'], '1')
