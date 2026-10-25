"""Portable recipe checks only; these do not compile or execute Apple objects."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'games/totk/ios/tools/build_sources.py'
spec = importlib.util.spec_from_file_location('ios_public_source_build', SCRIPT)
BUILDER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BUILDER)


class IOSSourceMatrixTests(unittest.TestCase):
    def command(self, source, profile):
        return BUILDER.compile_command(BUILDER.PROFILES[profile], source, Path('/original-fixture-output'),
                                       {'clang': '/installed-apple-clang', 'sdk': '/installed-iphoneos-sdk'},
                                       Path('/original-fixture-output/unit.o'), Path('/original-fixture-output/unit.d'))

    def test_both_public_profiles_include_actual_runtime_and_isolated_fixture_sources(self):
        self.assertEqual(set(BUILDER.PROFILES), {'v143-default', 'v143-display-settings'})
        sources = {str(source.relative_to(ROOT)) for source in BUILDER.SOURCES}
        self.assertEqual(len(sources), len(BUILDER.SOURCES))
        for name in ('fs_host.c', 'threads.c', 'input.c'):
            self.assertIn('games/totk/runtime/' + name, sources)
        fixture = 'games/totk/tests/ios_mouse_release/probe.m'
        self.assertIn(fixture, sources)
        self.assertEqual(BUILDER.ISOLATED_FIXTURES, {ROOT / fixture})
        self.assertFalse(any(source.name == 'loader.c' for source in BUILDER.SOURCES))
        self.assertEqual({p for p in (BUILDER.TOTK / 'ios/Sources').glob('*.m')},
                         {p for p in BUILDER.SOURCES if p.parent == BUILDER.TOTK / 'ios/Sources'})

    def test_c_and_objc_commands_use_their_actual_languages_without_canopy_or_platform_substitution(self):
        for profile in BUILDER.PROFILES:
            for source in BUILDER.SOURCES:
                with self.subTest(profile=profile, source=source.name):
                    command = self.command(source, profile)
                    self.assertEqual(command[command.index('-target') + 1], 'arm64-apple-ios26.0')
                    self.assertEqual(command[command.index('-isysroot') + 1], '/installed-iphoneos-sdk')
                    self.assertEqual(command[command.index('-c') + 1], str(source))
                    self.assertIn('-std=gnu11', command)
                    self.assertIn('-DTOTK_GAME_V143=1', command)
                    self.assertFalse(any('CANOPY_HOST_RUNTIME' in part or 'TARGET_OS_IPHONE=' in part or
                                         'simulator' in part for part in command))
                    if source.suffix == '.c':
                        self.assertIn('-D_DARWIN_C_SOURCE', command)
                        self.assertFalse(any(part.startswith(('-fobjc', '-fmodule', '-fblocks')) for part in command))
                    else:
                        self.assertIn('-fobjc-arc', command)
                        self.assertIn('-fblocks', command)
                        self.assertIn('-fmodules', command)
                    enabled = profile == 'v143-display-settings'
                    self.assertEqual('-DTOTK_IOS_DISPLAY_SETTINGS=1' in command, enabled)
                    self.assertEqual('-DTOTK_IOS_ASPECT_VERT=1' in command, enabled)

    def test_unsupported_source_language_is_not_silently_compiled_as_objc(self):
        with self.assertRaisesRegex(RuntimeError, 'source language'):
            self.command(ROOT / 'games/totk/runtime/loader.S', 'v143-default')

    @unittest.skipIf(sys.platform == 'darwin', 'non-Apple refusal only; actual Apple source gate owns object compilation')
    def test_non_apple_preflight_reports_no_build_or_fixture_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'object-output'
            result = subprocess.run([sys.executable, str(SCRIPT), '--output', str(output)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((output / 'report.json').read_bytes())
            self.assertFalse(report['success'])
            self.assertEqual(report['compiled_object_count'], 0)
            for field in ('full_app_build', 'linked', 'signed', 'executed', 'tests_run', 'simulator_used', 'generated_header_stubs'):
                self.assertIs(report[field], False)
            self.assertEqual(report['expected_fixture_object_count'], 2)
            self.assertEqual(report['expected_object_count'], 2 * len(BUILDER.SOURCES))
            self.assertEqual(report['expected_production_object_count'], 2 * (len(BUILDER.SOURCES) - 1))
            self.assertIn('physical iPhoneOS host', report['fixture_execution_gate'])
            self.assertEqual(report['results'], [])
