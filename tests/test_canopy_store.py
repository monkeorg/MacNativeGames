"""Execute immutable POSIX generation storage using original synthetic bytes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TITLE = '0100f2c0115b6000'
OTHER = '01007ef00011e000'


class CanopyStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('native C compiler required')
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.build = Path(cls.workspace.name)
        cls.probe = cls.build / 'store-probe'
        adapter = cls.build / 'store.c'
        adapter.write_text(
            '#define _GNU_SOURCE\n'
            '#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)\n#define _DARWIN_C_SOURCE\n#endif\n'
            '#define _POSIX_C_SOURCE 200809L\n#include <sys/statvfs.h>\n'
            '#include <unistd.h>\n#include <stdio.h>\n'
            'int probe_fstatvfs(int,struct statvfs *);\n#define fstatvfs probe_fstatvfs\n'
            'ssize_t probe_read(int,void *,size_t);\nint probe_fsync(int);\n'
            'int probe_renameat(int,const char *,int,const char *);\n'
            '#define read probe_read\n#define fsync probe_fsync\n#define renameat probe_renameat\n'
            '#ifdef __linux__\n#include <sys/syscall.h>\nlong probe_syscall(long,...);\n#define syscall probe_syscall\n'
            '#elif defined(__APPLE__)\nint probe_renameatx_np(int,const char *,int,const char *,unsigned);\n'
            '#define renameatx_np probe_renameatx_np\n#endif\n'
            '#include "' + str(ROOT / 'launcher/src/mng_store.c') + '"\n')
        command = [compiler, '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                   '-I', str(ROOT / 'launcher/include'), str(adapter),
                   str(ROOT / 'launcher/src/mng_crypto.c'),
                   str(ROOT / 'launcher/tests/store_probe.c')]
        if sys.platform != 'darwin':
            command += ['-lcrypto']
        subprocess.run([*command, '-fsanitize=undefined', '-fno-sanitize-recover=all',
                        '-o', str(cls.probe)], check=True, capture_output=True, text=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.jobs = 0

    def job(self):
        self.jobs += 1
        return f'{self.jobs:032x}'

    def run_probe(self, mode, *args, env=None):
        result = subprocess.run([str(self.probe), mode, str(self.root), *args],
                                capture_output=True, text=True, timeout=15,
                                env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1', **(env or {})})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout)

    def commit(self, variant='A', title=TITLE, job=None):
        result = self.run_probe('commit', job or self.job(), title, variant)
        self.assertEqual(result['status'], 0, result)
        self.assertEqual(len(result['generation']), 64)
        return result['generation']

    def generation(self, generation, title=TITLE):
        return self.root / 'titles' / title / 'generations' / generation

    def known(self, version, variant='A', job=None):
        result = self.run_probe('known', job or self.job(), TITLE, variant, str(version))
        self.assertEqual(result['status'], 0, result)
        return result['generation']

    def updated(self, version=2, base_version=1, job=None, env=None):
        result = self.run_probe('updated', job or self.job(), TITLE, 'A', str(version),
                                env={'CANOPY_TEST_BASE_VERSION': str(base_version), **(env or {})})
        self.assertEqual(result['status'], 0, result)
        return result['generation']

    def legacy_fixture(self, version=None):
        """Pre-v2 on-disk encoding, independent of the current store writer."""
        payloads = {'exefs/main': b'nonproprietary main fixture A',
                    'exefs/main.npdm': b'nonproprietary metadata fixture',
                    'romfs.bin': b'nonproprietary romfs fixture'}
        header = bytearray(80 if version is None else 104)
        header[:8] = b'CNPYST01' if version is None else b'CNPYST02'
        struct.pack_into('<QQQQ', header, 8, int(TITLE, 16), 1000, 3, sum(map(len, payloads.values())))
        header[40:72] = hashlib.sha256(b'A').digest()
        header[72:74] = b'\x01\x01'
        if version is not None:
            struct.pack_into('<QIBB', header, 80, int(TITLE, 16), version, 1, 0x80)
        records, assets = bytearray(), []
        for path, data in sorted(payloads.items()):
            digest = hashlib.sha256(data)
            records += path.encode().ljust(80, b'\0') + struct.pack('<Q', len(data)) + digest.digest()
            assets.append({'path': path, 'size': len(data), 'sha256': digest.hexdigest()})
        receipt = bytes(header + records)
        recipe = 'canopy-assets-v1' if version is None else 'canopy-assets-v2'
        generation = hashlib.sha256(recipe.encode() + b'\0' + receipt).hexdigest()
        manifest = {'schemaVersion': 1 if version is None else 2, 'titleID': TITLE, 'generationID': generation,
                    'recipeID': recipe, 'sourceSHA256': hashlib.sha256(b'A').hexdigest(), 'sourceSize': 1000}
        if version is not None:
            manifest.update(applicationID=TITLE, titleVersion=version, versionIdentified=True, contentRole=0x80)
        manifest.update(assets=assets,
                        integrity={'exefsVerified': True, 'romfsVerified': True, 'signatureVerified': False},
                        executionVerified=False)
        directory = self.generation(generation)
        (directory / 'exefs').mkdir(parents=True, mode=0o700)
        for path, data in payloads.items():
            (directory / path).write_bytes(data)
            (directory / path).chmod(0o400)
        (directory / 'receipt.bin').write_bytes(receipt)
        (directory / 'manifest.json').write_text(json.dumps(manifest, separators=(',', ':')) + '\n')
        (directory / '.lease').touch(mode=0o400)
        (self.root / 'titles' / TITLE / 'current').write_text(generation + '\n')
        return generation

    def current(self, title=TITLE):
        return (self.root / 'titles' / title / 'current').read_text().strip()

    def test_committed_generation_manifest_and_assets_are_verified(self):
        generation = self.commit()
        directory = self.generation(generation)
        manifest = json.loads((directory / 'manifest.json').read_text())
        self.assertEqual(manifest['schemaVersion'], 1)
        self.assertEqual(manifest['recipeID'], 'canopy-assets-v1')
        self.assertEqual(manifest['titleID'], TITLE)
        self.assertEqual(manifest['generationID'], generation)
        self.assertEqual(manifest['sourceSHA256'], hashlib.sha256(b'A').hexdigest())
        self.assertFalse(manifest['executionVerified'])
        self.assertEqual(manifest['integrity'], {'exefsVerified': True, 'romfsVerified': True, 'signatureVerified': False})
        self.assertEqual({item['path'] for item in manifest['assets']}, {'exefs/main', 'exefs/main.npdm', 'romfs.bin'})
        for asset in manifest['assets']:
            data = (directory / asset['path']).read_bytes()
            self.assertEqual(len(data), asset['size'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), asset['sha256'])
        self.assertEqual(self.current(), generation)
        self.assertEqual(self.run_probe('verify', TITLE, generation)['status'], 0)

    def test_existing_v1_fixture_keeps_exact_fingerprint_and_unknown_version(self):
        generation = self.legacy_fixture()
        directory = self.generation(generation)
        before = {name: (directory / name).read_bytes() for name in ('receipt.bin', 'manifest.json')}
        inode = (directory / 'romfs.bin').stat().st_ino
        result = self.run_probe('verify', TITLE, generation)
        self.assertEqual(result['status'], 0)
        self.assertEqual(result['applicationID'], TITLE)
        self.assertFalse(result['versionIdentified'])
        self.assertEqual((result['titleVersion'], result['contentRole']), (0, 0))
        self.assertFalse(result['updateApplied'])
        self.assertEqual((result['updateSourceSize'], result['baseTitleVersion']), (0, 0))
        self.assertEqual(result['updateSourceSHA256'], '0' * 64)
        self.assertEqual(result['patchTitleID'], '0' * 16)
        self.assertEqual(self.commit(), generation)  # Unknown application_id=0 accepted.
        inferred = self.run_probe('legacy_inferred', self.job(), TITLE, 'A')
        self.assertEqual(inferred['status'], 0)
        self.assertEqual(inferred['generation'], generation)  # Inferred base id also accepted.
        self.assertEqual((directory / 'romfs.bin').stat().st_ino, inode)
        for name, data in before.items():
            self.assertEqual((directory / name).read_bytes(), data)

    def test_existing_v2_fixture_keeps_exact_fingerprint_without_update_fields(self):
        generation = self.legacy_fixture(version=65536)
        directory = self.generation(generation)
        before = {name: (directory / name).read_bytes() for name in ('receipt.bin', 'manifest.json')}
        inode = (directory / 'romfs.bin').stat().st_ino
        result = self.run_probe('verify', TITLE, generation)
        self.assertEqual(result['status'], 0)
        self.assertTrue(result['versionIdentified'])
        self.assertEqual(result['titleVersion'], 65536)
        self.assertFalse(result['updateApplied'])
        self.assertEqual((result['updateSourceSize'], result['baseTitleVersion']), (0, 0))
        self.assertEqual(result['updateSourceSHA256'], '0' * 64)
        self.assertEqual(result['patchTitleID'], '0' * 16)
        self.assertEqual(self.known(65536), generation)
        self.assertEqual((directory / 'romfs.bin').stat().st_ino, inode)
        for name, data in before.items():
            self.assertEqual((directory / name).read_bytes(), data)

    def test_v3_roundtrip_binds_exact_base_and_update_identities_in_order(self):
        generation = self.updated()
        directory = self.generation(generation)
        receipt = (directory / 'receipt.bin').read_bytes()
        self.assertEqual(receipt[:8], b'CNPYST03')
        self.assertEqual(len(receipt), 160 + 3 * 120)
        self.assertEqual(struct.unpack_from('<QIBB', receipt, 80), (int(TITLE, 16), 2, 1, 0x81))
        patch = int(TITLE, 16) + 0x800
        self.assertEqual(struct.unpack_from('<QQIB', receipt, 104), (777, patch, 1, 1))
        self.assertEqual(receipt[125:128], bytes(3))
        self.assertEqual(receipt[128:160], hashlib.sha256(b'original update container A').digest())
        self.assertEqual(hashlib.sha256(b'canopy-assets-v3\0' + receipt).hexdigest(), generation)
        result = self.run_probe('verify', TITLE, generation)
        self.assertEqual(result['status'], 0)
        self.assertTrue(result['updateApplied'])
        self.assertEqual((result['titleVersion'], result['baseTitleVersion'], result['contentRole']), (2, 1, 0x81))
        self.assertEqual(result['sourceSHA256'], hashlib.sha256(b'A').hexdigest())
        self.assertEqual(result['sourceSize'], 1000)
        self.assertEqual(result['updateSourceSHA256'], hashlib.sha256(b'original update container A').hexdigest())
        self.assertEqual(result['updateSourceSize'], 777)
        self.assertEqual(result['patchTitleID'], f'{patch:016x}')
        manifest = json.loads((directory / 'manifest.json').read_text())
        self.assertEqual((manifest['schemaVersion'], manifest['recipeID']), (3, 'canopy-assets-v3'))
        self.assertTrue(manifest['updateApplied'])
        self.assertEqual(manifest['sourceSHA256'], hashlib.sha256(b'A').hexdigest())
        self.assertEqual(manifest['sources'], [
            {'role': 'base', 'titleID': TITLE, 'titleVersion': 1, 'sourceSHA256': hashlib.sha256(b'A').hexdigest(), 'sourceSize': 1000},
            {'role': 'update', 'titleID': f'{patch:016x}', 'titleVersion': 2,
             'sourceSHA256': hashlib.sha256(b'original update container A').hexdigest(), 'sourceSize': 777}])
        self.assertFalse(manifest['executionVerified'])
        self.assertFalse(manifest['integrity']['signatureVerified'])

    def test_v3_identity_changes_cannot_alias_or_overwrite_generations(self):
        first = self.updated()
        asset = self.generation(first) / 'romfs.bin'
        before = asset.stat()
        self.assertEqual(self.updated(), first)
        self.assertEqual((asset.stat().st_ino, asset.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        generations = {first, self.updated(version=3), self.updated(base_version=0),
                       self.updated(env={'CANOPY_TEST_UPDATE_TEXT': 'original update container B'}),
                       self.updated(env={'CANOPY_TEST_UPDATE_SIZE': '778'}),
                       self.updated(env={'CANOPY_TEST_PATCH_ID': f'{int(TITLE, 16) + 0x1000:016x}'})}
        self.assertEqual(len(generations), 6)
        self.assertNotIn(self.known(2), generations)
        self.assertNotIn(self.commit(), generations)

    def test_v3_accepts_zero_equal_and_maximum_declared_versions(self):
        for base, final in ((0, 0), (0, 1), (1, 1), (0xffffffff, 0xffffffff)):
            with self.subTest(base=base, final=final):
                generation = self.updated(version=final, base_version=base)
                result = self.run_probe('verify', TITLE, generation)
                self.assertEqual(result['status'], 0)
                self.assertEqual((result['baseTitleVersion'], result['titleVersion']), (base, final))

    def test_v3_illegal_metadata_and_legacy_field_leaks_are_refused(self):
        original = self.commit()
        for suffix in ('flag', 'unknown', 'role', 'app', 'patch_zero', 'patch_same', 'downgrade', 'size',
                       'legacy_size', 'legacy_patch', 'legacy_baseversion', 'legacy_sha', 'unknown_sha'):
            with self.subTest(suffix=suffix):
                result = self.run_probe('invalid_update_' + suffix, self.job(), TITLE, 'A')
                self.assertEqual(result['status'], 1)
                self.assertEqual(self.current(), original)

    def test_v3_receipt_provenance_and_manifest_corruption_is_rejected(self):
        generation = self.updated()
        directory = self.generation(generation)
        receipt = directory / 'receipt.bin'
        original = receipt.read_bytes()
        for offset, value in ((7, ord('4')), (94, 1), (104, 0), (112, original[112] ^ 1), (120, 3),
                              (124, 0), (124, 2), (125, 1), (128, original[128] ^ 1)):
            with self.subTest(offset=offset, value=value):
                changed = bytearray(original)
                changed[offset] = value
                receipt.write_bytes(changed)
                self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        for length in (80, 103, 104, 127, 159, 160, len(original) - 1):
            with self.subTest(length=length):
                receipt.write_bytes(original[:length])
                self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        receipt.write_bytes(original)
        manifest = directory / 'manifest.json'
        before = manifest.read_bytes()
        changed = json.loads(before)
        changed['sources'].reverse()
        manifest.write_text(json.dumps(changed, separators=(',', ':')) + '\n')
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        manifest.write_bytes(before)
        self.assertEqual(self.run_probe('verify', TITLE, generation)['status'], 0)

    def test_v3_failed_publication_job_resumes_without_rewriting_complete_assets(self):
        original = self.commit('Z')
        job = self.job()
        result = self.run_probe('updated', job, TITLE, 'A', '2', env={'CANOPY_TEST_FAULT': 'generation_rename'})
        self.assertEqual(result['status'], 2)
        staged = self.root / 'jobs' / job
        self.assertEqual((staged / 'receipt.bin').read_bytes()[:8], b'CNPYST03')
        before = (staged / 'exefs/main').stat().st_ino
        self.assertEqual(self.current(), original)
        generation = self.updated(job=job)
        self.assertEqual((self.generation(generation) / 'exefs/main').stat().st_ino, before)
        result = self.run_probe('verify', TITLE, generation)
        self.assertTrue(result['updateApplied'])
        self.assertEqual(result['baseTitleVersion'], 1)

    def test_known_metadata_v2_roundtrip_including_version_zero_and_maximum(self):
        for version in (0, 65536, 0xffffffff):
            with self.subTest(version=version):
                generation = self.known(version)
                result = self.run_probe('verify', TITLE, generation)
                self.assertEqual(result['status'], 0)
                self.assertEqual(result['applicationID'], TITLE)
                self.assertTrue(result['versionIdentified'])
                self.assertEqual((result['titleVersion'], result['contentRole']), (version, 0x80))
                directory = self.generation(generation)
                receipt = (directory / 'receipt.bin').read_bytes()
                self.assertEqual(receipt[:8], b'CNPYST02')
                self.assertEqual(len(receipt), 104 + 3 * 120)
                self.assertEqual(struct.unpack_from('<QIBB', receipt, 80), (int(TITLE, 16), version, 1, 0x80))
                manifest = json.loads((directory / 'manifest.json').read_text())
                self.assertEqual((manifest['schemaVersion'], manifest['recipeID']), (2, 'canopy-assets-v2'))
                self.assertEqual(manifest['applicationID'], TITLE)
                self.assertEqual(manifest['titleVersion'], version)
                self.assertTrue(manifest['versionIdentified'])
                self.assertEqual(manifest['contentRole'], 0x80)
                self.assertFalse(manifest['executionVerified'])
                self.assertFalse(manifest['integrity']['signatureVerified'])

    def test_known_identity_is_committed_into_generation_and_reuses_only_exact_identity(self):
        legacy = self.commit()
        zero, one = self.known(0), self.known(1)
        self.assertEqual(len({legacy, zero, one}), 3)
        image = self.generation(one) / 'romfs.bin'
        before = image.stat()
        self.assertEqual(self.known(1), one)
        self.assertEqual((image.stat().st_ino, image.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(self.run_probe('verify', TITLE, legacy)['status'], 0)

    def test_illegal_identity_combinations_fail_without_changing_current(self):
        original = self.commit()
        for suffix in ('app', 'role', 'flag', 'missing_app', 'unknown_app', 'unknown_version', 'unknown_role'):
            with self.subTest(suffix=suffix):
                result = self.run_probe('invalid_identity_' + suffix, self.job(), TITLE, 'B')
                self.assertEqual(result['status'], 1)
                self.assertEqual(self.current(), original)

    def test_v2_metadata_receipt_and_manifest_corruption_is_rejected(self):
        generation = self.known(65536)
        directory = self.generation(generation)
        receipt = directory / 'receipt.bin'
        original = receipt.read_bytes()
        for offset, value in ((7, ord('3')), (74, 1), (80, 1), (88, 1), (92, 0), (92, 2), (93, 0), (94, 1)):
            with self.subTest(offset=offset, value=value):
                changed = bytearray(original)
                changed[offset] = value
                receipt.write_bytes(changed)
                self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        receipt.write_bytes(original[:-1])
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        receipt.write_bytes(original)
        manifest = directory / 'manifest.json'
        before = manifest.read_bytes()
        manifest.write_bytes(before.replace(b'"titleVersion":65536', b'"titleVersion":65537'))
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        manifest.write_bytes(before)
        self.assertEqual(self.run_probe('verify', TITLE, generation)['status'], 0)

    def test_interrupted_v2_receipt_can_resume_with_exact_identity(self):
        original = self.commit('Z')
        job = self.job()
        result = self.run_probe('known', job, TITLE, 'A', '65536', env={'CANOPY_TEST_FAULT': 'generation_rename'})
        self.assertEqual(result['status'], 2)
        staged = self.root / 'jobs' / job
        self.assertEqual((staged / 'receipt.bin').read_bytes()[:8], b'CNPYST02')
        before = (staged / 'exefs/main').stat().st_ino
        self.assertEqual(self.current(), original)
        generation = self.known(65536, job=job)
        self.assertEqual((self.generation(generation) / 'exefs/main').stat().st_ino, before)
        verified = self.run_probe('verify', TITLE, generation)
        self.assertTrue(verified['versionIdentified'])
        self.assertEqual(verified['titleVersion'], 65536)

    def test_same_input_reuses_immutable_generation(self):
        generation = self.commit()
        image = self.generation(generation) / 'romfs.bin'
        before = image.stat()
        self.assertEqual(self.commit(), generation)
        after = image.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_duplicate_current_retains_distinct_rollback_reference(self):
        first = self.commit('A')
        second = self.commit('B')
        self.assertEqual(self.commit('B'), second)
        self.assertEqual((self.root / 'titles' / TITLE / 'previous').read_text().strip(), first)
        self.assertNotEqual(self.run_probe('prune', TITLE, first)['status'], 0)

    def test_rollback_and_cross_title_isolation(self):
        first, second = self.commit('A'), self.commit('B')
        other = self.commit('A', OTHER)
        self.assertNotEqual(first, other)
        self.assertEqual(self.run_probe('select', TITLE, first)['status'], 0)
        self.assertEqual(self.current(), first)
        self.assertEqual(self.current(OTHER), other)
        self.assertEqual(self.run_probe('verify', OTHER, second)['status'], 2)
        self.assertEqual(self.run_probe('select', TITLE, other)['status'], 2)

    def test_cancelled_job_is_unpublished_and_resumes_without_rewriting(self):
        original = self.commit('B')
        job = self.job()
        result = self.run_probe('cancel', job, TITLE, 'A')
        self.assertEqual(result['status'], 6)
        staged = self.root / 'jobs' / job / 'exefs/main'
        before = staged.stat()
        self.assertEqual(self.current(), original)
        new = self.commit('A', job=job)
        after = (self.generation(new) / 'exefs/main').stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_process_crash_preserves_current_and_recovers_partial_job(self):
        original = self.commit('B')
        job = self.job()
        crashed = subprocess.run([str(self.probe), 'crash', str(self.root), job], capture_output=True, timeout=15)
        self.assertEqual(crashed.returncode, 23)
        partial = self.root / 'jobs' / job
        self.assertTrue((partial / '.asset.tmp').exists())
        before = (partial / 'exefs/main').stat()
        self.assertEqual(self.current(), original)
        recovered = self.commit('A', job=job)
        self.assertEqual((self.generation(recovered) / 'exefs/main').stat().st_ino, before.st_ino)
        self.assertEqual(self.current(), recovered)
        self.assertFalse(partial.exists())

    def test_bad_prepare_result_never_publishes(self):
        original = self.commit()
        for mode in ('badcount', 'badbytes', 'badflags'):
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_probe(mode, self.job(), TITLE, 'B')['status'], 0)
                self.assertEqual(self.current(), original)

    def test_untracked_job_entries_are_rejected_before_publication(self):
        original = self.commit()
        self.assertNotEqual(self.run_probe('inject', self.job(), TITLE, 'B')['status'], 0)
        self.assertEqual(self.current(), original)

    def test_cancellation_during_commit_and_at_publication_boundary(self):
        original = self.commit()
        for phase in ('cancel_hash', 'cancel_before_current'):
            with self.subTest(phase=phase):
                result = self.run_probe('commit', self.job(), TITLE, 'B', env={'CANOPY_TEST_FAULT': phase})
                self.assertEqual(result['status'], 6)
                self.assertEqual(self.current(), original)
        result = self.run_probe('commit', self.job(), TITLE, 'C', env={'CANOPY_TEST_FAULT': 'cancel_after_current'})
        self.assertEqual(result['status'], 0)
        self.assertEqual(self.current(), result['generation'])

    def test_normal_context_cancel_hook_during_hash_and_before_publication(self):
        original = self.commit()
        for phase in ('hook_hash', 'hook_before_current'):
            with self.subTest(phase=phase):
                result = self.run_probe('commit', self.job(), TITLE, 'B', env={'CANOPY_TEST_FAULT': phase})
                self.assertEqual(result['status'], 6)
                self.assertEqual(self.current(), original)
        result = self.run_probe('commit', self.job(), TITLE, 'C', env={'CANOPY_TEST_FAULT': 'hook_after_current'})
        self.assertEqual(result['status'], 0)
        self.assertEqual(self.current(), result['generation'])

    def test_prebegin_cancel_and_cleared_callback_remain_cancelled(self):
        for phase in ('atomic_before_begin', 'hook_before_begin', 'hook_clear'):
            with self.subTest(phase=phase):
                job = self.job()
                result = self.run_probe('commit', job, TITLE, 'A', env={'CANOPY_TEST_FAULT': phase})
                self.assertEqual(result['status'], 6)
                self.assertFalse((self.root / 'jobs' / job).exists())

    def test_resume_hash_polls_cancel_hook_and_keeps_completed_inode(self):
        original = self.commit('B')
        job = self.job()
        crashed = subprocess.run([str(self.probe), 'crash', str(self.root), job], capture_output=True, timeout=15)
        self.assertEqual(crashed.returncode, 23)
        staged = self.root / 'jobs' / job / 'exefs/main'
        before = staged.stat()
        result = self.run_probe('commit', job, TITLE, 'A', env={'CANOPY_TEST_FAULT': 'hook_resume'})
        self.assertEqual(result['status'], 6)
        self.assertEqual(self.current(), original)
        self.assertEqual(staged.stat().st_ino, before.st_ino)
        recovered = self.commit('A', job=job)
        self.assertEqual((self.generation(recovered) / 'exefs/main').stat().st_ino, before.st_ino)

    def test_store_root_refuses_group_or_other_permissions_without_mutation(self):
        for mode in (0o755, 0o750, 0o707, 0o777):
            with self.subTest(mode=oct(mode)):
                self.root.chmod(mode)
                self.assertEqual(self.run_probe('commit', self.job(), TITLE, 'A')['status'], 1)
                self.assertEqual(list(self.root.iterdir()), [])
        self.root.chmod(0o700)
        self.commit()

    def test_reused_handle_is_cancellable_after_successful_publication(self):
        for mode in ('reuse_verify', 'reuse_select', 'reuse_begin'):
            with self.subTest(mode=mode):
                result = self.run_probe(mode, self.job(), TITLE, mode)
                self.assertEqual(result['status'], 6)
                self.assertEqual(self.current(), result['generation'])
        self.assertFalse((self.root / 'jobs' / ('f' * 32)).exists())

    def test_reused_handle_can_prepare_another_generation(self):
        result = self.run_probe('reuse_prepare', self.job(), TITLE, 'A')
        self.assertEqual(result['status'], 0)
        self.assertEqual(self.current(), result['generation'])
        self.assertNotEqual((self.root / 'titles' / TITLE / 'previous').read_text().strip(), result['generation'])

    def test_reused_handle_is_cancellable_after_postpublication_io(self):
        self.commit('Z')
        result = self.run_probe('reuse_after_io', self.job(), TITLE, 'A', env={'CANOPY_TEST_FAULT': 'current_sync'})
        self.assertEqual(result['status'], 6)
        self.assertEqual(self.current(), result['generation'])
        self.assertEqual(self.run_probe('verify', TITLE, result['generation'])['status'], 0)

    def test_crashes_at_exclusive_asset_and_generation_rename_recover(self):
        original = self.commit('Z')
        for phase, exit_code in (('before_asset_rename', 24), ('after_asset_rename', 25), ('after_generation_rename', 26)):
            with self.subTest(phase=phase):
                job = self.job()
                crashed = subprocess.run([str(self.probe), 'commit', str(self.root), job, TITLE, phase],
                                         capture_output=True, timeout=15,
                                         env={**os.environ, 'CANOPY_TEST_FAULT': phase})
                self.assertEqual(crashed.returncode, exit_code, crashed.stderr)
                self.assertEqual(self.current(), original)
                recovered = self.commit(phase, job=job)
                self.assertEqual(self.run_probe('verify', TITLE, recovered)['status'], 0)
                self.assertEqual(self.current(), recovered)
                self.assertEqual(self.run_probe('select', TITLE, original)['status'], 0)

    def test_interrupted_asset_publication_can_be_explicitly_discarded(self):
        original = self.commit('Z')
        for phase in ('before_asset_rename', 'after_asset_rename'):
            with self.subTest(phase=phase):
                job = self.job()
                crashed = subprocess.run([str(self.probe), 'commit', str(self.root), job, TITLE, phase],
                                         capture_output=True, timeout=15,
                                         env={**os.environ, 'CANOPY_TEST_FAULT': phase})
                self.assertIn(crashed.returncode, (24, 25))
                self.assertEqual(self.run_probe('discard', job)['status'], 0)
                self.assertFalse((self.root / 'jobs' / job).exists())
                self.assertEqual(self.current(), original)

    def test_publication_failures_reconcile_current_and_retain_previous(self):
        original = self.commit('A')
        for phase in ('generation_sync', 'previous_rename', 'previous_sync', 'current_rename'):
            with self.subTest(phase=phase):
                result = self.run_probe('commit', self.job(), TITLE, phase, env={'CANOPY_TEST_FAULT': phase})
                self.assertEqual(result['status'], 2)
                self.assertEqual(self.current(), original)
        result = self.run_probe('commit', self.job(), TITLE, 'after-current', env={'CANOPY_TEST_FAULT': 'current_sync'})
        self.assertEqual(result['status'], 2)
        selected = self.current()
        self.assertNotEqual(selected, original)
        self.assertEqual(self.run_probe('verify', TITLE, selected)['status'], 0)
        self.assertEqual((self.root / 'titles' / TITLE / 'previous').read_text().strip(), original)
        self.assertEqual(self.run_probe('select', TITLE, original)['status'], 0)

    def test_external_hardlinks_are_rejected_during_resume_and_gc(self):
        job = self.job()
        self.run_probe('path', job, 'romfs.bin')
        target = self.root / 'retain'
        target.write_bytes(b'outside hardlink')
        os.link(target, self.root / 'jobs' / job / 'romfs.bin')
        self.assertNotEqual(self.run_probe('commit', job, TITLE, 'A')['status'], 0)
        self.assertNotEqual(self.run_probe('discard', job)['status'], 0)
        self.assertEqual(target.read_bytes(), b'outside hardlink')

    def test_low_space_and_actual_writer_failure_preserve_current(self):
        original = self.commit()
        result = self.run_probe('commit', self.job(), TITLE, 'B', env={'CANOPY_TEST_NO_SPACE': '1'})
        self.assertNotEqual(result['status'], 0)
        self.assertEqual(self.current(), original)
        self.assertNotEqual(self.run_probe('writer_failure', self.job(), 'exefs/main')['status'], 0)
        self.assertEqual(self.current(), original)

    def test_paths_and_case_collisions_are_bounded(self):
        for path in ('../outside', 'exefs/..', 'exefs/.', 'exefs/a/b', 'exefs/a\\b', 'exefs/a"', 'romfs/data.bin'):
            with self.subTest(path=path):
                self.assertNotEqual(self.run_probe('path', self.job(), path)['status'], 0)
        self.assertNotEqual(self.run_probe('path', '../bad-job', 'romfs.bin')['status'], 0)
        job = self.job()
        crashed = subprocess.run([str(self.probe), 'crash', str(self.root), job], capture_output=True, timeout=15)
        self.assertEqual(crashed.returncode, 23)
        self.assertNotEqual(self.run_probe('path', job, 'exefs/MAIN')['status'], 0)

    def test_asset_sizes_are_bounded_before_payload_io(self):
        for path, size in (('romfs.bin', (64 << 30) + 1), ('exefs/main', (512 << 20) + 1)):
            with self.subTest(path=path):
                self.assertNotEqual(self.run_probe('path', self.job(), path, str(size))['status'], 0)

    def test_asset_or_manifest_tampering_is_rejected_without_replacement(self):
        generation = self.commit()
        directory = self.generation(generation)
        manifest = directory / 'manifest.json'
        before = manifest.read_bytes()
        manifest.write_bytes(before.replace(b'false', b'true ', 1))
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        self.assertNotEqual(self.run_probe('commit', self.job(), TITLE, 'A')['status'], 0)
        self.assertEqual(manifest.read_bytes(), before.replace(b'false', b'true ', 1))
        manifest.write_bytes(before)
        asset = directory / 'romfs.bin'
        asset.chmod(0o600)
        asset.write_bytes(b'X' * asset.stat().st_size)
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)

    def test_gc_never_touches_profiles_saves_accounts_or_symlink_targets(self):
        for name in ('profiles', 'saves', 'accounts'):
            (self.root / name).mkdir()
            (self.root / name / 'retain').write_text('untouched')
        job = self.job()
        self.run_probe('path', job, 'romfs.bin')
        outside = self.root / 'profiles'
        (self.root / 'jobs' / job / 'trap').symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_probe('discard', job)['status'], 0)
        for name in ('profiles', 'saves', 'accounts'):
            self.assertEqual((self.root / name / 'retain').read_text(), 'untouched')

    def test_symlinked_owned_directories_and_assets_are_refused(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / 'jobs').symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_probe('commit', self.job(), TITLE, 'A')['status'], 0)
        self.assertEqual(list(outside.iterdir()), [])
        (self.root / 'jobs').unlink()
        generation = self.commit()
        asset = self.generation(generation) / 'romfs.bin'
        asset.unlink()
        target = outside / 'retain'
        target.write_text('outside data')
        asset.symlink_to(target)
        self.assertNotEqual(self.run_probe('verify', TITLE, generation)['status'], 0)
        self.assertEqual(target.read_text(), 'outside data')

    def test_current_previous_and_live_session_pin_protect_gc(self):
        first = self.commit('A')
        pinned = subprocess.Popen([str(self.probe), 'pin', str(self.root), TITLE, first],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(pinned.stdout.readline().strip(), 'ready')
            second, third = self.commit('B'), self.commit('C')
            self.assertNotEqual(self.run_probe('prune', TITLE, third)['status'], 0)
            self.assertNotEqual(self.run_probe('prune', TITLE, second)['status'], 0)
            self.assertNotEqual(self.run_probe('prune', TITLE, first)['status'], 0)
            pinned.stdin.write('\n'); pinned.stdin.flush()
            pinned.wait(timeout=10)
            self.assertEqual(self.run_probe('prune', TITLE, first)['status'], 0)
            self.assertFalse(self.generation(first).exists())
        finally:
            if pinned.poll() is None:
                pinned.kill(); pinned.wait()
            pinned.stdin.close(); pinned.stdout.close(); pinned.stderr.close()

    def test_store_lock_serializes_processes_and_releases_after_crash(self):
        holder = subprocess.Popen([str(self.probe), 'hold', str(self.root)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), 'ready')
            self.assertNotEqual(self.run_probe('commit', self.job(), TITLE, 'A')['status'], 0)
            holder.kill(); holder.wait(timeout=10)
            self.commit()
        finally:
            if holder.poll() is None:
                holder.kill(); holder.wait()
            holder.stdin.close(); holder.stdout.close(); holder.stderr.close()


if __name__ == '__main__':
    unittest.main()
