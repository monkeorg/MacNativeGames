"""Real native save transactions on macOS; original opaque fixture bytes only."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'CanopySaveStore requires macOS Foundation and Darwin atomic exchange')
class CanopySaves(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        crypto = directory / 'crypto.o'
        cls.compile(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                     '-I', str(ROOT / 'launcher/include'), '-c',
                     str(ROOT / 'launcher/src/mng_crypto.c'), '-o', str(crypto)])
        # Only this test translation unit intercepts real Darwin calls. No
        # production environment switches or fake save backend are introduced.
        adapter = directory / 'save-store.m'
        adapter.write_text('#include <fcntl.h>\n#include <stdio.h>\n#include <unistd.h>\n'
                           'int canopy_test_save_fsync(int);\n'
                           'int canopy_test_save_unlink(int,const char *,int);\n'
                           'ssize_t canopy_test_save_read(int,void *,size_t);\n'
                           'int canopy_test_save_rename(int,const char *,int,const char *,unsigned);\n'
                           '#define fsync canopy_test_save_fsync\n'
                           '#define unlinkat canopy_test_save_unlink\n'
                           '#define read canopy_test_save_read\n'
                           '#define renameatx_np canopy_test_save_rename\n'
                           '#include "' + str(ROOT / 'launcher/apple/Sources/CanopySaveStore.m') + '"\n')
        cls.probe = directory / 'saves'
        cls.compile(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                     '-I', str(ROOT / 'launcher/include'), '-I', str(ROOT / 'launcher/apple/Sources'),
                     '-I', str(ROOT / 'games/totk/ios/Sources'),
                     str(ROOT / 'tests/canopy_saves_probe.m'), str(adapter), str(crypto),
                     str(ROOT / 'games/totk/ios/Sources/save_validation.m'),
                     '-framework', 'Foundation', '-o', str(cls.probe)])

    @staticmethod
    def compile(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name).resolve()

    def run_probe(self, scenario, exit_code=0):
        result = subprocess.run([str(self.probe), scenario, str(self.root)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        if exit_code == 0:
            self.assertEqual(result.stderr, '')
            self.assertEqual(json.loads(result.stdout)['status'], 'pass')

    def test_roundtrip_restore_empty_directories_and_identity_separation(self):
        self.run_probe('roundtrip')

    def test_profile_title_and_process_lock_isolation(self):
        self.run_probe('isolation')

    def test_symlinked_root_ancestor_refused_without_creating_outside_child(self):
        self.run_probe('root_symlink')

    def test_session_seal_and_stale_teardown_tokens(self):
        self.run_probe('seal')

    def test_process_crash_releases_session_ownership(self):
        self.run_probe('session_crash', 27)
        self.run_probe('after_session_crash')

    def test_tampered_and_raw_import_refused_before_mutation(self):
        self.run_probe('tamper')

    def test_external_replacement_requires_trusted_title_validator(self):
        self.run_probe('validator')

    def test_raw_totk_folder_uses_real_validator_backup_and_exact_replacement(self):
        self.run_probe('raw_success')

    def test_raw_invalid_slot_missing_file_and_nested_profile_refuse_before_backup(self):
        for scenario in ('raw_invalid_slot', 'raw_missing', 'raw_nested_profile', 'raw_store_root'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_raw_account_identity_links_and_quota_are_refused_without_mutation(self):
        for scenario in ('raw_account', 'raw_nested_account', 'raw_symlink', 'raw_hardlink', 'raw_large'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_raw_unknown_title_and_sealed_session_refuse_before_backup(self):
        for scenario in ('raw_unknown', 'raw_sealed'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_raw_import_ambiguous_publication_recovers_pretransaction_bytes(self):
        self.run_probe('raw_rollback')

    def test_symlinks_and_hardlinks_refused_without_target_changes(self):
        self.run_probe('links')

    def test_sparse_file_quota_and_explicit_backup_retention(self):
        self.run_probe('quota')

    def test_deep_valid_save_runs_on_small_native_worker_stack(self):
        self.run_probe('deep_worker')

    def test_status_reads_complete_while_real_copy_is_blocked(self):
        self.run_probe('status_nonblocking')

    def test_export_and_backup_final_rename_ambiguity_is_reported(self):
        self.run_probe('copy_sync')

    def test_committed_journal_unlink_failures_finalize_without_rollback(self):
        for scenario in ('journal_unlink_fail', 'journal_unlink_sync'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_failed_swap_and_ambiguous_sync_recover_previous_bytes(self):
        for scenario in ('swap_fail', 'after_swap_sync'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_real_process_exit_after_swap_rolls_back_on_reopen(self):
        self.run_probe('crash', 29)
        self.run_probe('recover')

    def test_process_exit_with_durable_committed_intent_keeps_new_save(self):
        self.run_probe('committed_crash', 30)
        self.run_probe('recover_committed')

    def test_process_exit_after_journal_unlink_keeps_new_save(self):
        self.run_probe('cleanup_crash', 31)
        self.run_probe('after_cleanup_crash')

    def editor_scenarios(self, scenarios):
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as isolated:
                previous = self.root
                self.root = Path(isolated).resolve()
                try:
                    self.run_probe(scenario)
                finally:
                    self.root = previous

    def test_editor_default_has_preview_but_no_publication_authority(self):
        self.run_probe('edit_default')

    def test_editor_actual_backup_publish_and_restore_preserve_other_bytes(self):
        self.run_probe('edit_roundtrip')

    def test_editor_active_tree_cas_and_foreign_profile_refusal(self):
        self.editor_scenarios(('edit_stale', 'edit_foreign', 'edit_tamper'))

    def test_editor_session_seal_invalidates_prior_snapshot(self):
        self.run_probe('edit_seal')

    def test_editor_field_policy_and_post_validator_rehash(self):
        self.editor_scenarios(('edit_reject', 'edit_validator_mutation'))

    def test_editor_write_failure_retry_and_mandatory_backup(self):
        self.editor_scenarios(('edit_write_failure', 'edit_backup_limit'))

    def test_editor_linked_input_refused_without_outside_changes(self):
        self.run_probe('edit_links')

    def test_editor_actual_crash_after_swap_rolls_back_original(self):
        self.run_probe('edit_crash', 29)
        self.run_probe('edit_recover')

    def test_editor_actual_crash_after_commit_keeps_confirmed_edit(self):
        self.run_probe('edit_crash_committed', 30)
        self.run_probe('edit_recover_committed')

    def test_editor_ambiguous_postswap_io_uses_existing_recovery(self):
        self.run_probe('edit_ambiguous')


if __name__ == '__main__':
    unittest.main()
