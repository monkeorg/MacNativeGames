"""Run the iOS save transfer and preference code against synthetic files on macOS."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'games/totk/ios/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'needs macOS and the Xcode command line tools')
class IOSSaveStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        cls.probe = cls.root / 'probe'
        # Redirect only production reads for deterministic mutations after the
        # initial metadata checks. Probe wrappers otherwise call the real APIs.
        # Include system headers first to preserve Darwin's symbol aliases.
        hook = cls.root / 'directory_hook.h'
        hook.write_text('#include <dirent.h>\n#include <unistd.h>\n'
                        'struct dirent *TOTKProbeReadDirectory(DIR *);\n'
                        'ssize_t TOTKProbeRead(int, void *, size_t);\n'
                        '#define readdir TOTKProbeReadDirectory\n'
                        '#define read TOTKProbeRead\n')
        save_object = cls.root / 'save_store.o'
        build_save = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
            '-include', str(hook), '-c',
            str(SOURCES / 'save_store.m'), '-o', str(save_object),
        ], capture_output=True, text=True, timeout=120)
        if build_save.returncode:
            raise AssertionError(build_save.stderr)
        build = subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
            '-I', str(SOURCES),
            str(ROOT / 'tests/ios_save_store_probe.m'),
            str(save_object), str(SOURCES / 'launcher_settings.m'),
            '-framework', 'Foundation', '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stderr)

    def run_probe(self, scenario, root=None):
        root = root or self.root / scenario
        root.mkdir(exist_ok=True)
        run = subprocess.run([str(self.probe), scenario, str(root)],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout.strip().splitlines()[-1])['status'], 'pass')

    def test_complete_transfer_and_restore(self):
        self.run_probe('roundtrip')

    def test_complete_transfer_on_small_worker_stack(self):
        self.run_probe('small_stack_roundtrip')

    def test_transfer_without_ancestor_directory_access(self):
        self.run_probe('sandbox_roundtrip')

    def test_backup_failure_preserves_active_save(self):
        self.run_probe('backup_refused')

    def test_publish_failure_preserves_active_save_and_backup(self):
        self.run_probe('publish_refused')

    def test_import_refuses_enclosing_profile_directory(self):
        self.run_probe('ancestor_source')

    def test_directory_change_refuses_incomplete_transfer(self):
        self.run_probe('directory_changed')

    def test_file_change_with_restored_mtime_preserves_active_save(self):
        self.run_probe('file_changed_mtime_restored')

    def test_file_link_added_during_copy_preserves_active_save(self):
        self.run_probe('file_hardlinked_during_copy')

    def test_provider_read_failure_preserves_active_save(self):
        self.run_probe('provider_read_refused')

    def test_export_read_failure_removes_partial_copy(self):
        self.run_probe('export_read_refused')

    def test_first_import_without_active_save(self):
        self.run_probe('first_import')

    def test_darwin_temporary_directory_alias(self):
        canonical = self.root / 'var_alias'
        alias = Path(str(canonical).replace('/private/var/', '/var/', 1))
        if alias == canonical:
            self.skipTest('temporary directory is outside /private/var')
        self.run_probe('roundtrip', alias)

    def test_invalid_imports_preserve_active_save(self):
        for scenario in ('empty', 'incomplete', 'invalid_slot', 'account',
                         'zero_required', 'oversize', 'deep', 'symlink', 'hardlink', 'root_symlink',
                         'ancestor_symlink', 'fifo'):
            with self.subTest(scenario=scenario):
                self.run_probe(scenario)

    def test_seal_blocks_all_transfers(self):
        self.run_probe('sealed')

    def test_restore_refuses_external_directory(self):
        self.run_probe('external_restore')

    def test_preferences_recover_from_malformed_values(self):
        self.run_probe('settings_invalid')

    def test_preferences_persist_across_processes(self):
        root = self.root / 'settings_persist'
        self.run_probe('settings_write', root)
        try:
            self.run_probe('settings_read', root)
        finally:
            self.run_probe('settings_clean', root)


if __name__ == '__main__':
    unittest.main()
