"""Original synthetic reference-family records, never real-save acceptance."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TOTKSaveCandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('native C compiler required')
        cls.folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.folder.cleanup)
        cls.probe = Path(cls.folder.name) / 'save'
        result = subprocess.run([
            compiler, '-std=c11', '-O3', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
            '-fsanitize=undefined', '-fno-sanitize-recover=all',
            '-I', str(ROOT / 'launcher/include'), str(ROOT / 'launcher/src/mng_totk_save.c'),
            str(ROOT / 'launcher/tests/totk_save_probe.c'), '-o', str(cls.probe),
        ], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def call(self, mode):
        result = subprocess.run([str(self.probe), mode], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'PASS')
        self.assertEqual(result.stderr, '')

    def test_candidate_roundtrip_preserves_source_and_all_other_bytes(self): self.call('roundtrip')
    def test_unknown_tuple_or_length_is_refused(self): self.call('signature')
    def test_missing_duplicate_and_out_of_policy_records_are_refused(self): self.call('structure')
    def test_later_payload_remains_explicitly_opaque(self): self.call('opaque')
    def test_failed_serialization_leaves_output_unchanged_and_aliases_refused(self): self.call('refusal')
