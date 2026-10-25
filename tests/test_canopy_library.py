"""Execute the production Foundation metadata store on macOS, with synthetic files."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'launcher/apple/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'CanopyLibrary requires macOS Foundation and Xcode command-line tools')
class CanopyLibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name).resolve()
        cls.probe = cls.root / 'canopy-library-probe'
        build = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
            '-I', str(SOURCES), str(ROOT / 'tests/canopy_library_probe.m'),
            str(SOURCES / 'CanopyLibrary.m'), '-framework', 'Foundation',
            '-framework', 'CoreFoundation', '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def probe_scenario(self, scenario):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            result = subprocess.run([str(self.probe), scenario, directory],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {'status': 'pass'})

    def test_valid_roundtrip_remove_and_reset(self):
        self.probe_scenario('roundtrip')

    def test_corruption_preserves_bytes_and_blocks_mutation(self):
        for scenario in ('malformed', 'unknown_schema', 'oversize', 'duplicate_uuid',
                         'too_many_records', 'boolean_schema', 'unknown_key'):
            with self.subTest(scenario=scenario):
                self.probe_scenario(scenario)

    def test_invalid_record_fields_require_recovery(self):
        for scenario in ('invalid_uuid', 'invalid_name', 'invalid_format', 'invalid_date',
                         'boolean_size', 'negative_size', 'fractional_count', 'oversize_count'):
            with self.subTest(scenario=scenario):
                self.probe_scenario(scenario)

    def test_confirmed_reset_recovers_corrupt_index(self):
        self.probe_scenario('recovery_reset')

    def test_failed_persistence_retains_memory_and_source(self):
        self.probe_scenario('failed_persistence')

    def test_exact_record_limit_is_accepted(self):
        self.probe_scenario('record_limit')


if __name__ == '__main__':
    unittest.main()
