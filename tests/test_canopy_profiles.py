"""Actual Foundation registry and native SaveStore; no UIKit/account mock."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'profile registry and actual SaveStore require existing Apple Foundation tools')
class CanopyProfilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        work = Path(cls.temp.name)
        objects = []
        for name in ('mng_crypto', 'mng_keyboard'):
            output = work / (name + '.o')
            cls.build(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                       '-I', str(ROOT / 'launcher/include'), '-c',
                       str(ROOT / 'launcher/src' / (name + '.c')), '-o', str(output)])
            objects.append(str(output))
        adapter = work / 'profiles.m'
        adapter.write_text('#include <sys/types.h>\n#include <unistd.h>\n#include <fcntl.h>\n'
                           'int canopy_profiles_test_fsync(int);\n'
                           'int canopy_profiles_test_rename(int,const char*,int,const char*);\n'
                           'int canopy_profiles_test_open(const char*,int,...);\n'
                           '#define fsync canopy_profiles_test_fsync\n'
                           '#define renameat canopy_profiles_test_rename\n'
                           '#define open canopy_profiles_test_open\n'
                           '#include "' + str(ROOT / 'launcher/apple/Sources/CanopyProfiles.m') + '"\n')
        cls.probe = work / 'profiles'
        cls.build(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                   '-I', str(ROOT / 'launcher/include'), '-I', str(ROOT / 'launcher/apple/Sources'),
                   str(ROOT / 'tests/canopy_profiles_probe.m'), str(adapter),
                   str(ROOT / 'launcher/apple/Sources/CanopySaveStore.m'),
                   str(ROOT / 'launcher/apple/Sources/CanopySettings.m'), *objects,
                   '-framework', 'Foundation', '-o', str(cls.probe)])

    @staticmethod
    def build(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, mode):
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run([str(self.probe), mode, str(Path(temp).resolve())],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {'passed': True})

    def test_implicit_existing_default_does_not_write_metadata(self): self.scenario('default')
    def test_known_container_path_opens_when_readable_system_ancestors_are_denied(self): self.scenario('ancestor')
    def test_actual_profile_isolation_preserves_default_bytes_identity_backups_and_inode(self): self.scenario('isolation')
    def test_actual_settings_reset_preserves_profile_registry(self): self.scenario('settings')
    def test_stale_selection_refused_and_other_titles_retained(self): self.scenario('stale')
    def test_actual_rename_and_postrename_sync_failures_preserve_old_store_and_previous(self): self.scenario('fault')
    def test_profile_count_bound_preserves_existing_registry(self): self.scenario('limit')
    def test_symlink_and_hardlink_registry_refused(self): self.scenario('unsafe')
    def test_unknown_corrupt_oversize_or_missing_primary_never_reset(self): self.scenario('invalid')
