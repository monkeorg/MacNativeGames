"""Run the production editor URL, progress, and caption validators against Apple Foundation."""
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Apple Foundation')
class IOSSaveEditorValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='totk-editor-validation-')
        cls.probe = pathlib.Path(cls.temp.name) / 'probe'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'games/totk/ios/Sources'),
                        str(ROOT / 'tests/ios_save_editor_validation_probe.m'),
                        '-framework', 'Foundation', '-o', str(cls.probe)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def probe_case(self, name):
        result = subprocess.run([str(self.probe), name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'PASS')

    def test_real_official_url_and_https_port(self): self.probe_case('canonical')
    def test_other_origins_and_ports_refused(self): self.probe_case('origin')
    def test_credentials_including_empty_user_refused(self): self.probe_case('credentials')
    def test_noncanonical_paths_refused(self): self.probe_case('path')
    def test_queries_refused_and_same_page_fragments_allowed(self): self.probe_case('query_fragment')
    def test_progress_size_and_offset_four_header(self): self.probe_case('progress')
    def test_caption_dates_and_metadata_boundaries(self): self.probe_case('caption_valid')
    def test_zero_caption_and_missing_date_fields_refused(self): self.probe_case('caption_empty_missing')
    def test_nil_and_every_truncated_caption_refused(self): self.probe_case('caption_truncated')
    def test_zero_and_out_of_range_date_values_refused(self): self.probe_case('caption_invalid')
    def test_duplicate_date_fields_refused(self): self.probe_case('caption_duplicates')
    def test_unaligned_and_out_of_section_date_fields_ignored(self): self.probe_case('caption_bounds')
