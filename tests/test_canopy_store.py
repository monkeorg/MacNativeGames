"""Execute immutable POSIX generation storage using original synthetic bytes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
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
