"""Exercise real prepared-store/catalog and title settings using macOS Foundation."""
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
                     'Canopy catalog/settings require macOS Foundation and Apple tools')
class CanopyCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name).resolve()
        objects = []
        for name in ('mng_store', 'mng_crypto'):
            output = cls.root / (name + '.o')
            cls.build(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE',
                       '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'launcher/include'),
                       '-c', str(ROOT / ('launcher/src/' + name + '.c')), '-o', str(output)])
            objects.append(str(output))
        cls.probe = cls.root / 'canopy-catalog-probe'
        cls.build(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                   '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'),
                   str(ROOT / 'tests/canopy_catalog_probe.m'),
                   str(SOURCES / 'CanopyCatalog.m'), str(SOURCES / 'CanopySettings.m'),
                   *objects, '-framework', 'Foundation', '-framework', 'CoreFoundation',
                   '-o', str(cls.probe)])

    @staticmethod
    def build(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            result = subprocess.run([str(self.probe), name, directory],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {'status': 'pass'})

    def test_title_isolation_defaults_and_persistence(self):
        self.scenario('settings')

    def test_invalid_options_and_mapping_snapshot(self):
        self.scenario('options')

    def test_partial_schema_one_defaults_without_rewrite(self):
        self.scenario('partial')

    def test_invalid_metadata_refused_preserved_until_explicit_reset(self):
        for case in ('malformed', 'version', 'boolean_version', 'unknown_key',
                     'invalid_title', 'invalid_option', 'oversize', 'title_limit', 'symlink'):
            with self.subTest(case=case):
                self.scenario(case)

    def test_late_corruption_and_failed_writes_do_not_overwrite(self):
        self.scenario('late_corruption')
        self.scenario('write_failure')

    def test_catalog_reads_real_verified_generations_and_isolates_corruption(self):
        self.scenario('catalog')

    def test_catalog_busy_does_not_replace_existing_snapshot(self):
        self.scenario('busy')

    def test_catalog_bound_and_linked_root_refusals(self):
        self.scenario('catalog_limit')
        self.scenario('catalog_link')


if __name__ == '__main__':
    unittest.main()
