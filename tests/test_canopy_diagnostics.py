"""Real Foundation/Mach diagnostic snapshots; no game/device/private inputs."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'Canopy diagnostics require macOS Foundation/Mach and Xcode tools')
class CanopyDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name).resolve()
        cls.probe = directory / 'diagnostics'
        sources = ROOT / 'launcher/apple/Sources'
        run = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            '-I', str(sources), str(ROOT / 'tests/canopy_diagnostics_probe.m'),
            str(sources / 'CanopyDiagnostics.m'), '-framework', 'Foundation',
            '-framework', 'CoreFoundation', '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=120)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    def scenario(self, name):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            fixtures = {'original.keys': b'original private-key fixture',
                        'original.save': b'original opaque save fixture'}
            for path, content in fixtures.items():
                (root / path).write_bytes(content)
            run = subprocess.run([str(self.probe), name, str(root)],
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(run.stderr, '')
            self.assertEqual(json.loads(run.stdout)['status'], 'pass')
            self.assertNotIn(str(root), run.stdout)
            self.assertEqual({path.name for path in root.iterdir()}, set(fixtures))
            for path, content in fixtures.items():
                self.assertEqual((root / path).read_bytes(), content)

    def test_default_off_user_requested_snapshot_still_available(self):
        self.scenario('default')

    def test_opt_in_history_bounded_and_cleared_on_disable(self):
        self.scenario('history')

    def test_redaction_omits_paths_keys_saves_device_ids_and_raw_errors(self):
        self.scenario('redaction')

    def test_malformed_types_counters_and_unrecognized_enums_fail_closed(self):
        self.scenario('malformed')

    def test_real_memory_thermal_and_unsupported_frame_rates_are_labeled(self):
        self.scenario('memory')

    def test_actual_runtime_and_preparation_categories_map_without_error_text(self):
        self.scenario('mapping')

    def test_preparation_completion_flags_and_progress_units_match_actual_contract(self):
        self.scenario('preparation')

    def test_snapshots_copy_mutable_inputs_and_export_is_bounded(self):
        self.scenario('bounded')

    def test_concurrent_collection_and_disable_preserve_privacy_bound(self):
        self.scenario('concurrent')

    def test_actual_provider_adapter_counts_only_listed_verified_available_rows(self):
        self.scenario('sources')

    def test_provider_storage_limits_types_and_missing_observations(self):
        self.scenario('storageBounds')

    def test_folder_inventory_is_not_exported_as_physical_container_identity(self):
        self.scenario('folder')


if __name__ == '__main__':
    unittest.main()
