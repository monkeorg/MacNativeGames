import importlib.util
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'games/totk/scripts/summarize_frame_trace.py'
SPEC = importlib.util.spec_from_file_location('frame_trace', SCRIPT)
TRACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRACE)


class FrameTraceSummaryTests(unittest.TestCase):
    def test_percentiles_and_defined_low(self):
        summary = TRACE.summarize(io.StringIO(''.join(
            f'{i}\t@frame_ms\t{i}\n' for i in range(1, 201))), 1, 200)
        metric = summary['metrics']['@frame_ms']
        self.assertTrue(metric['complete'])
        stats = metric['statistics']
        self.assertEqual(stats['median_ms'], 100.5)
        self.assertEqual(stats['p95_ms'], 190)
        self.assertEqual(stats['p99_ms'], 198)
        self.assertAlmostEqual(stats['low_1_percent_hz'], 1000 / 199.5)
        self.assertEqual(summary['native_rendered_fps'], 'unverified')

    def test_delayed_metrics_and_integrity(self):
        stream = io.StringIO('''# kind: nvn-per-frame
frame\tname\tvalue
1\t@frame_ms\t16
3\t@frame_ms\t18
1\t@gpu_ms\t8
3\t@gpu_ms\t0
2\t@frame_ms\tNaN
3\t@frame_ms\t19
2\t@presented_ms\t-1
3\t@presented_ms\t0
1\t@presented_ms\t17
4\t@frame_ms\t99
3\t@draws\t1000
truncated
''')
        report = TRACE.summarize(stream, 1, 3)
        self.assertEqual(report['malformed_lines'], 1)
        frame = report['metrics']['@frame_ms']
        self.assertEqual(frame['duplicate_frame_ids'], 1)
        self.assertEqual(frame['invalid_frame_ids'], 1)
        self.assertEqual(frame['statistics']['samples'], 1)
        self.assertFalse(frame['complete'])
        gpu = report['metrics']['@gpu_ms']
        self.assertEqual(gpu['missing_frame_ids'], 1)
        self.assertNotIn('cadence_hz', gpu['statistics'])
        present = report['metrics']['@presented_ms']
        self.assertEqual(present['discarded_frame_ids'], 1)
        self.assertEqual(present['invalid_frame_ids'], 2)

    def test_empty_and_bad_range(self):
        report = TRACE.summarize(io.StringIO(''), 1, 3)
        self.assertEqual(report['metrics']['@frame_ms']['missing_frame_ids'], 3)
        self.assertIsNone(report['metrics']['@frame_ms']['statistics'])
        for first, last in ((-1, 2), (4, 3)):
            with self.assertRaises(ValueError):
                TRACE.summarize(io.StringIO(''), first, last)

    def test_invalid_numbers_never_escape_json(self):
        import json
        report = TRACE.summarize(io.StringIO('1\t@frame_ms\tinf\n2\t@gpu_ms\tbad\n'), 1, 2)
        json.dumps(report, allow_nan=False)
        self.assertEqual(report['metrics']['@frame_ms']['invalid_frame_ids'], 1)

    def test_selected_bounds_exclude_warmup_and_use_real_timestamps(self):
        stream = io.StringIO('1\t@frame_ms\t9000\n1\t@call_ms\t0\n'
                             '2\t@frame_ms\t16\n2\t@call_ms\t9000\n'
                             '4\t@call_ms\t9032\n3\t@call_ms\t9016\n'
                             '3\t@frame_ms\t16\n4\t@frame_ms\t16\n')
        report = TRACE.summarize(stream, 2, 4)
        self.assertEqual(report['metrics']['@frame_ms']['statistics']['longest_ms'], 16)
        self.assertAlmostEqual(report['guest_call_timestamp_span']['seconds'], .032)
        self.assertAlmostEqual(report['metrics']['@frame_ms']['statistics']['sampled_interval_seconds'], .048)

    def test_partial_and_nonmonotonic_timestamp_series(self):
        report = TRACE.summarize(io.StringIO('2\t@call_ms\t40\n4\t@call_ms\t20\n'), 1, 5)
        self.assertEqual(report['guest_call_timestamp_span']['missing_frame_ids'], 3)
        self.assertFalse(report['guest_call_timestamp_span']['strictly_increasing'])
        self.assertIsNone(report['guest_call_timestamp_span']['seconds'])

    def test_cli_plain_and_gzip_match(self):
        with tempfile.TemporaryDirectory() as directory:
            plain = Path(directory) / 'frames.tsv'
            packed = Path(directory) / 'frames.tsv.gz'
            text = 'frame\tname\tvalue\n1\t@frame_ms\t16\n'
            plain.write_text(text)
            with gzip.open(packed, 'wt') as stream:
                stream.write(text)
            reports = [json.loads(subprocess.check_output(
                [sys.executable, str(SCRIPT), str(path), '--first-frame', '1', '--last-frame', '2'],
                text=True)) for path in (plain, packed)]
            self.assertEqual(reports[0], reports[1])
            self.assertEqual(reports[0]['metrics']['@frame_ms']['missing_frame_ids'], 1)


if __name__ == '__main__':
    unittest.main()
