"""Linux portable subset. Use Python 3.14 and games/totk/requirements.txt.

Print every excluded Apple packaging check; keep all existing native-test skips.
This is not a substitute for the full macOS CI suite or any Apple build.
Run from any directory: python /path/to/repo/tests/run_portable.py.
"""
import pathlib
import sys
import unittest

root = pathlib.Path(__file__).resolve().parents[1]
sys.path[:0] = [str(root), str(root / 'tests')]
unavailable = {
    'test_app_game_data.KeepGameData.test_the_same_data_keeps_the_old_image',
    'test_app_game_data.KeepGameData.test_other_data_is_not_kept',
    'test_app_game_data.KeepGameData.test_a_seal_that_no_longer_verifies_puts_the_fresh_copy_back',
    'test_botw_import.BotwImport.test_bundle_without_expansion_pass',
    'test_clone.Clone.test_existing_file_is_replaced',
    'test_clone.Clone.test_existing_folder_gets_the_files_one_by_one',
    'test_clone.Clone.test_folder_is_cloned_without_starting_programs',
    'test_updates.Updates.test_bundle_contains_only_selected_game_version',
    'test_updates.Updates.test_failed_bundle_seal_preserves_previous_app',
    'test_updates.Updates.test_running_app_is_preserved_until_its_process_exits',
    'test_variant_libs.VariantLibs.test_the_app_takes_the_listed_variant_libraries',
}
def leaves(suite):
    for case in suite:
        if isinstance(case, unittest.TestSuite):
            yield from leaves(case)
        else:
            yield case
suite = unittest.TestSuite()
for path in sorted((root / 'tests').glob('test_*.py')):
    if path.stem == 'test_data_bundle':
        print('UNAVAILABLE MODULE: test_data_bundle (3 real codesign/Xcode tests; import invokes xcrun)')
        continue
    for case in leaves(unittest.defaultTestLoader.loadTestsFromName(path.stem)):
        if case.id() in unavailable:
            print('UNAVAILABLE TEST:', case.id(), '(Darwin clonefile or st_birthtime)')
        else:
            suite.addTest(case)
result = unittest.TextTestRunner(verbosity=1).run(suite)
print('PORTABLE_RESULT', result.testsRun, 'run;', len(result.skipped), 'skipped;', len(result.failures), 'failures;', len(result.errors), 'errors')
sys.exit(not result.wasSuccessful())
