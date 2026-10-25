"""Real Foundation preparation job with invented encrypted inputs; Mac only."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'launcher/apple/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun') and
                     importlib.util.find_spec('cryptography'),
                     'native preparation jobs require macOS Foundation, xcrun and cryptography')
class CanopyPreparationJobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        cls.fixture = fixture
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name).resolve()
        objects = []
        for name in ('mng_container', 'mng_crypto', 'mng_keys', 'mng_prepare', 'mng_store', 'mng_content', 'mng_bktr'):
            output = directory / (name + '.o')
            cls.compile(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE',
                         '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'launcher/include'),
                         '-c', str(ROOT / ('launcher/src/' + name + '.c')), '-o', str(output)])
            objects.append(str(output))
        cls.probe = directory / 'canopy-preparation-probe'
        cls.compile(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                     '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'),
                     str(ROOT / 'tests/canopy_preparation_probe.m'),
                     str(SOURCES / 'CanopyPreparation.m'), *objects,
                     '-framework', 'Foundation', '-framework', 'CoreFoundation', '-o', str(cls.probe)])

    @staticmethod
    def compile(command):
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.store = self.directory / 'prepared'
        self.source = self.directory / 'invented.nsp'
        self.source.write_bytes(self.fixture.game_image('nsp'))
        self.keys = self.directory / 'invented.keys'
        f = self.fixture
        self.key_text = '\n'.join(f'{name} = {value.hex()}' for name, value in
                                  [('header_key', f.HEADER), ('key_area_key_application_00', f.AREA),
                                   ('titlekek_00', f.TITLEKEK)])
        self.keys.write_text(self.key_text)

    def job(self, mode='success', job=None, update=None):
        inputs = (self.source, self.keys) + ((update,) if update is not None else ())
        originals = {p: p.read_bytes() for p in inputs if p.is_file() and not p.is_symlink()}
        run = subprocess.run([str(self.probe), mode, str(self.source), str(self.keys),
                              str(self.store), job or '-', *([str(update)] if update is not None else [])],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for p, data in originals.items():
            self.assertEqual(p.read_bytes(), data)
        for private in (self.fixture.HEADER.hex(), self.fixture.AREA.hex(), self.fixture.TITLEKEK.hex()):
            self.assertNotIn(private, run.stdout + run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], 'pass')
        if 'error' in report:
            self.assertNotIn(str(self.directory), json.dumps(report['error']))
        if 'result' in report:
            result = report['result']
            self.assertRegex(result['titleID'], r'^[0-9a-f]{16}$')
            self.assertRegex(result['generationID'], r'^[0-9a-f]{64}$')
            self.assertRegex(result['jobID'], r'^[0-9a-f]{32}$')
            self.assertEqual(result['sourceSHA256'], hashlib.sha256(self.source.read_bytes()).hexdigest())
            self.assertEqual(result['assetCount'], 3)
            self.assertGreater(result['assetBytes'], 0)
            self.assertIs(result['exefsVerified'], True)
            self.assertIs(result['romfsVerified'], True)
            self.assertIs(result['signatureVerified'], False)
            self.assertIs(result['executionVerified'], False)
            if job:
                self.assertEqual(result['jobID'], job)
        return report

    def current(self, title=None):
        return self.store / 'titles' / f'{title or self.fixture.TITLE:016x}' / 'current'

    def generation(self, report, title=None):
        generation = self.current(title).read_text().strip()
        self.assertEqual(generation, report['result']['generationID'])
        self.assertEqual(report['result']['titleID'], f'{title or self.fixture.TITLE:016x}')
        return self.current(title).parent / 'generations' / generation

    def test_success_has_real_private_assets_current_and_result(self):
        report = self.job()
        root = self.generation(report)
        self.assertEqual((root / 'exefs/main').read_bytes(), b'synthetic main')
        self.assertEqual((root / 'exefs/main.npdm').read_bytes(), b'synthetic metadata')
        self.assertEqual((root / 'romfs.bin').read_bytes(), self.fixture.romfs())
        self.assertTrue((root / 'manifest.json').is_file())
        self.assertGreater(report['progress_calls'], 0)
        self.assertIsInstance(report['result'], dict)
        self.assertTrue(report['result'])

    def test_two_coordinated_inputs_publish_actual_updated_assets_and_provenance(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base, patch, _, updated = CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory/'invented-update.nsp'
        update.write_bytes(self.fixture.partition(patch))
        report = self.job(update=update)
        self.assertIs(report['result']['updateApplied'], True)
        self.assertEqual((report['result']['baseTitleVersion'], report['result']['titleVersion']), (7, 12))
        self.assertEqual(report['result']['updateSourceSHA256'], hashlib.sha256(update.read_bytes()).hexdigest())
        root = self.generation(report, 0x0100123456780000)
        self.assertEqual((root/'exefs/main').read_bytes(), b'updated native bytes')
        self.assertEqual((root/'romfs.bin').read_bytes(), updated)
        self.assertEqual(json.loads((root/'manifest.json').read_text())['schemaVersion'], 3)

    def test_update_cancellation_waits_for_completion_and_resumes_verified_work(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base, patch, _, updated = CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory/'invented-update.nsp'; update.write_bytes(self.fixture.partition(patch))
        before = self.job()
        current = self.current(0x0100123456780000)
        identifier = 'ef'*16
        cancelled = self.job('cancel', identifier, update)
        self.assertEqual(cancelled['error']['code'], 6)
        self.assertEqual(current.read_text().strip(), before['result']['generationID'])
        retained = self.store/'jobs'/identifier/'exefs/main'
        inode = retained.stat().st_ino
        resumed = self.job(job=identifier, update=update)
        root = self.generation(resumed, 0x0100123456780000)
        self.assertEqual((root/'exefs/main').stat().st_ino, inode)
        self.assertEqual((root/'romfs.bin').read_bytes(), updated)

    def test_cancellation_from_main_progress_preserves_current_and_resumes_job(self):
        first = self.job()
        original_current = self.current().read_bytes()
        original_main = (self.generation(first) / 'exefs/main').read_bytes()
        second_title = 0x0100123456780000
        self.source.write_bytes(self.fixture.partition([('program.nca', self.fixture.nca(title=second_title))]))
        identifier = 'ef' * 16
        cancelled = self.job('cancel', identifier)
        self.assertTrue(cancelled['cancel_sent'])
        self.assertEqual(self.current().read_bytes(), original_current)
        self.assertFalse(self.current(second_title).exists())
        staged = self.store / 'jobs' / identifier / 'exefs/main'
        self.assertTrue(staged.is_file())
        inode = staged.stat().st_ino
        resumed = self.job('success', identifier)
        self.assertEqual((self.generation(resumed, second_title) / 'exefs/main').stat().st_ino, inode)
        self.assertEqual(self.current().read_bytes(), original_current)
        self.assertEqual((self.generation(first) / 'exefs/main').read_bytes(), original_main)

    def test_wrong_malformed_and_missing_keys_do_not_publish_or_leak(self):
        for mode in ('wrong', 'malformed', 'missing', 'empty_provider'):
            with self.subTest(mode=mode):
                self.keys.unlink(missing_ok=True)
                if mode == 'wrong':
                    self.keys.write_text(self.key_text.replace(self.fixture.HEADER.hex(), 'ff' * 32))
                elif mode == 'malformed':
                    self.keys.write_text('header_key = not-hex\n')
                elif mode == 'empty_provider':
                    self.keys.write_text('invented_unused_key = 00\n')
                self.job('failure')
                self.assertFalse(self.current().exists())

    def test_invalid_source_and_key_symlink_do_not_replace_existing_current(self):
        self.job()
        original = self.current().read_bytes()
        self.source.write_bytes(b'not a container')
        self.job('failure')
        self.assertEqual(self.current().read_bytes(), original)
        self.source.write_bytes(self.fixture.game_image('nsp'))
        real = self.keys.with_suffix('.original')
        self.keys.rename(real)
        self.keys.symlink_to(real)
        self.job('failure')
        self.assertEqual(self.current().read_bytes(), original)

    def test_second_start_is_refused_while_worker_is_busy(self):
        self.job('busy')
        self.assertTrue(self.current().exists())


if __name__ == '__main__':
    unittest.main()
