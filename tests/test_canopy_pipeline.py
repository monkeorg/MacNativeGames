"""Shipping CLI: invented encrypted input -> real assets -> atomic generations."""
import hashlib
import importlib.util
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


@unittest.skipUnless(importlib.util.find_spec('cryptography') and shutil.which('cc'),
                     'encrypted native fixtures require cc and cryptography')
class CanopyPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        cls.fixture = fixture
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        cls.cli = Path(cls.build.name) / 'canopy'
        sources = ['launcher/cli/main.c', 'launcher/src/mng_container.c',
                   'launcher/src/mng_file.c', 'launcher/src/mng_crypto.c',
                   'launcher/src/mng_keys.c', 'launcher/src/mng_prepare.c',
                   'launcher/src/mng_store.c', 'launcher/src/mng_content.c', 'launcher/src/mng_bktr.c']
        command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                   '-I', str(ROOT / 'launcher/include'), *[str(ROOT / p) for p in sources],
                   '-o', str(cls.cli)]
        if sys.platform != 'darwin':
            command.append('-lcrypto')
        run = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)
        # Deliver a real SIGINT after one real store asset completes. Intercept
        # only the CLI's preparation call; the native preparer/store stay intact.
        instrumented = Path(cls.build.name) / 'interrupt-main.c'
        instrumented.write_text('#define mng_prepare_fd pipeline_prepare\n#define mng_store_commit pipeline_commit\n#include "' +
                                str(ROOT / 'launcher/cli/main.c') + '"\n')
        wrapper = Path(cls.build.name) / 'interrupt-prepare.c'
        wrapper.write_text(r'''#include "mng_prepare.h"
#include "mng_store.h"
#include "mng_crypto.h"
#include <signal.h>
#include <stdlib.h>
#include <string.h>
static int committing,signal_sent;
struct forwarding { const struct mng_asset_sink *sink; int sent; };
static int begin(void *p,const char *n,uint64_t z) {struct forwarding *f=p;return f->sink->begin(f->sink->context,n,z);}
static int write_bytes(void *p,const void *b,size_t n) {struct forwarding *f=p;return f->sink->write(f->sink->context,b,n);}
static int end(void *p,const unsigned char h[32]) {struct forwarding *f=p;int r=f->sink->end(f->sink->context,h);if(!r && !f->sent && !getenv("PIPELINE_SIGNAL")){f->sent=1;raise(SIGINT);}return r;}
static int cancel(void *p) {struct forwarding *f=p;return f->sink->cancelled(f->sink->context);}
static void progress(void *p,const char *s,uint64_t d,uint64_t n) {struct forwarding *f=p;if(f->sink->progress)f->sink->progress(f->sink->context,s,d,n);}
enum mng_prepare_status pipeline_prepare(int fd,const struct mng_key_provider *k,const struct mng_asset_sink *s,struct mng_prepare_result *r) {
    struct forwarding f={s,0};struct mng_asset_sink wrapped={&f,begin,write_bytes,end,cancel,progress};
    return mng_prepare_fd(fd,k,&wrapped,r);
}
int pipeline_store_sha_update(struct mng_sha256 *state,const void *bytes,size_t size) {
    int result=mng_sha256_update(state,bytes,size);
    const char *mode=getenv("PIPELINE_SIGNAL");
    if(!signal_sent && mode && ((committing && !strcmp(mode,"verify")) || (!committing && !strcmp(mode,"resume")))) {
        signal_sent=1;raise(SIGINT);
    }
    return result;
}
enum mng_prepare_status pipeline_commit(struct mng_store *store,const struct mng_prepare_result *r,char generation[65]) {
    committing=1;
    enum mng_prepare_status status=mng_store_commit(store,r,generation);
    committing=0;
    const char *mode=getenv("PIPELINE_SIGNAL");
    if(mode && !strcmp(mode,"published") && status==MNG_PREPARE_OK)raise(SIGINT);
    return status;
}
''')
        cls.interrupt_cli = Path(cls.build.name) / 'interrupt-canopy'
        command[command.index(str(cls.cli))] = str(cls.interrupt_cli)
        command[command.index(str(ROOT / 'launcher/cli/main.c'))] = str(instrumented)
        command.append(str(wrapper))
        # Intercept only store hashing, leaving the real crypto implementation
        # and all preparation integrity verification unchanged.
        store_source = Path(cls.build.name) / 'interrupt-store.c'
        store_source.write_text('#define _GNU_SOURCE\n#define _DARWIN_C_SOURCE\n'
                                '#define _POSIX_C_SOURCE 200809L\n'
                                '#include "mng_crypto.h"\n'
                                'int pipeline_store_sha_update(struct mng_sha256 *,const void *,size_t);\n'
                                '#define mng_sha256_update pipeline_store_sha_update\n#include "' +
                                str(ROOT / 'launcher/src/mng_store.c') + '"\n')
        command[command.index(str(ROOT / 'launcher/src/mng_store.c'))] = str(store_source)
        run = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.store = self.directory / 'store'
        self.keys = self.directory / 'invented.keys'
        f = self.fixture
        self.keys.write_text('\n'.join(f'{name} = {value.hex()}' for name, value in
                                     [('header_key', f.HEADER), ('key_area_key_application_00', f.AREA),
                                      ('titlekek_00', f.TITLEKEK)]))
        self.source = self.directory / 'invented.nsp'
        self.source.write_bytes(f.game_image('nsp'))

    def prepare(self, extra=(), success=True):
        run = subprocess.run([str(self.cli), 'prepare', str(self.source), '--keys', str(self.keys),
                              '--store', str(self.store), *extra], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)
        for private in (str(self.directory), self.fixture.HEADER.hex(), self.fixture.AREA.hex()):
            self.assertNotIn(private, run.stdout + run.stderr)
        if success:
            self.assertEqual(run.stderr, '')
            report = json.loads(run.stdout)
            self.assertFalse(report['execution_verified'])
            self.assertFalse(report['signature_verified'])
            self.assertTrue(report['exefs_verified'])
            self.assertTrue(report['romfs_verified'])
            self.assertEqual(report['source_sha256'], hashlib.sha256(self.source.read_bytes()).hexdigest())
            return report
        self.assertEqual(run.stdout, '')
        return json.loads(run.stderr)

    def generation(self, report):
        return self.store / 'titles' / report['title_id'] / 'generations' / report['generation']

    def test_encrypted_input_produces_exact_assets_and_reuses_generation(self):
        report = self.prepare()
        root = self.generation(report)
        self.assertEqual((root / 'exefs/main').read_bytes(), b'synthetic main')
        self.assertEqual((root / 'exefs/main.npdm').read_bytes(), b'synthetic metadata')
        self.assertEqual((root / 'romfs.bin').read_bytes(), self.fixture.romfs())
        self.assertEqual(report['asset_count'], 3)
        current = root.parent.parent / 'current'
        self.assertEqual(current.read_text().strip(), report['generation'])
        paths = [root / 'exefs/main', root / 'exefs/main.npdm', root / 'romfs.bin']
        before = [(p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in paths]
        repeated = self.prepare()
        self.assertEqual(repeated['generation'], report['generation'])
        self.assertEqual(before, [(p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in paths])

    def update_fixture(self, **options):
        # Reuse the independent encrypted-format fixture generator, without
        # executing another test class or replacing the production pipeline.
        from test_canopy_prepare import CanopyPrepareTests
        import test_canopy_content
        from cryptography.hazmat.primitives.ciphers import modes
        from extract_exefs import decrypt
        helper = CanopyPrepareTests('test_real_two_source_update_composes_romfs_and_selects_update_exefs')
        helper.fixture = self.fixture
        helper.content_fixture = test_canopy_content
        helper.modes = modes
        helper.decrypt = decrypt
        return helper.update_pair(**options)

    def test_update_pipeline_publishes_composed_assets_and_separate_source_provenance(self):
        base, patch, original, updated = self.update_fixture(shared_control=True, managed_update=True)
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory / 'invented-update.nsp'
        update.write_bytes(self.fixture.partition(patch))
        report = self.prepare(('--update', str(update)))
        self.assertTrue(report['update_applied'])
        self.assertIs(report['version_identified'], True)
        self.assertEqual((report['base_title_version'], report['title_version']), (7, 12))
        self.assertEqual(report['update_source_sha256'], hashlib.sha256(update.read_bytes()).hexdigest())
        root = self.generation(report)
        self.assertEqual((root/'romfs.bin').read_bytes(), updated)
        self.assertNotEqual(updated, original)
        self.assertEqual((root/'exefs/main').read_bytes(), b'updated native bytes')
        manifest = json.loads((root/'manifest.json').read_text())
        self.assertEqual((manifest['schemaVersion'], manifest['recipeID']), (3, 'canopy-assets-v3'))
        self.assertEqual([entry['role'] for entry in manifest['sources']], ['base', 'update'])
        self.assertEqual(manifest['sources'][0]['sourceSHA256'], report['source_sha256'])
        self.assertEqual(manifest['sources'][1]['sourceSHA256'], report['update_source_sha256'])
        repeated = self.prepare(('--update', str(update)))
        self.assertEqual(repeated['generation'], report['generation'])

    def test_explicit_update_revision_differs_from_latest_and_bad_input_preserves_current(self):
        base, lower, _, _ = self.update_fixture(patch_version=12, patch_main=b'lower')
        _, higher, _, _ = self.update_fixture(patch_version=13, patch_main=b'higher')
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory/'two-updates.nsp'
        update.write_bytes(self.fixture.partition(lower + [('higher-'+name, data) for name, data in higher]))
        latest = self.prepare(('--update', str(update), '--version', 'latest'))
        self.assertEqual(latest['title_version'], 13)
        self.assertEqual((self.generation(latest)/'exefs/main').read_bytes(), b'higher')
        exact = self.prepare(('--version', '12', '--update', str(update)))
        self.assertEqual(exact['title_version'], 12)
        self.assertEqual((self.generation(exact)/'exefs/main').read_bytes(), b'lower')
        current = self.generation(exact).parent.parent/'current'
        before = current.read_bytes()
        self.prepare(('--update', str(update), '--version', '11'), success=False)
        broken = bytearray(update.read_bytes())
        count, names_size = struct.unpack_from('<II', broken, 4)
        first_nca = 16 + count*24 + names_size + struct.unpack_from('<Q', broken, 16)[0]
        broken[first_nca + 0xc00 + 3] ^= 1
        update.write_bytes(broken)
        self.prepare(('--update', str(update)), success=False)
        self.assertEqual(current.read_bytes(), before)
        self.assertEqual((self.generation(exact)/'exefs/main').read_bytes(), b'lower')

    def test_literal_update_revision_boundaries_and_invalid_cli_options(self):
        update = self.directory/'boundary-update.nsp'
        for version in (0, 0xffffffff):
            base, patch, _, _ = self.update_fixture(base_version=0, patch_version=version)
            self.source.write_bytes(self.fixture.partition(base)); update.write_bytes(self.fixture.partition(patch))
            self.assertEqual(self.prepare(('--update', str(update), '--version', str(version)))['title_version'], version)
        for arguments in (('--version', '12'), ('--update', str(update), '--version', '4294967296'),
                          ('--update', str(update), '--version', '-1'), ('--update', str(update), '--version', '1x')):
            self.assertEqual(self.prepare(arguments, success=False)['error'], 'usage')

    def test_update_commit_cancellation_resumes_and_late_signal_keeps_success(self):
        base, patch, _, updated = self.update_fixture()
        self.source.write_bytes(self.fixture.partition(base))
        first = self.prepare()
        current = self.generation(first).parent.parent/'current'
        before = current.read_bytes()
        update = self.directory/'cancel-update.nsp'; update.write_bytes(self.fixture.partition(patch))
        job = 'ea'*16
        command = [str(self.interrupt_cli), 'prepare', str(self.source), '--keys', str(self.keys),
                   '--store', str(self.store), '--update', str(update), '--job', job]
        cancelled = subprocess.run(command, env={**os.environ, 'PIPELINE_SIGNAL': 'verify'},
                                   capture_output=True, text=True, timeout=20)
        self.assertEqual(cancelled.returncode, 130, cancelled.stdout+cancelled.stderr)
        self.assertEqual(current.read_bytes(), before)
        staged = self.store/'jobs'/job/'exefs/main'
        inode = staged.stat().st_ino
        resumed = self.prepare(('--update', str(update), '--job', job))
        self.assertEqual((self.generation(resumed)/'exefs/main').stat().st_ino, inode)
        self.assertEqual((self.generation(resumed)/'romfs.bin').read_bytes(), updated)
        late = subprocess.run(command, env={**os.environ, 'PIPELINE_SIGNAL': 'published'},
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(late.returncode, 0, late.stdout+late.stderr)
        self.assertTrue(json.loads(late.stdout)['update_applied'])

    def test_corruption_preserves_current_and_second_title_isolated(self):
        first = self.prepare()
        current = self.generation(first).parent.parent / 'current'
        before = current.read_bytes()
        corrupt = bytearray(self.source.read_bytes())
        # Mutate ciphertext in the program NCA's first filesystem section.
        count, names_size = struct.unpack_from('<II', corrupt, 4)
        program_offset = 16 + count * 24 + names_size
        corrupt[program_offset + 0xc00 + 3] ^= 1
        self.source.write_bytes(corrupt)
        self.prepare(success=False)
        self.assertEqual(current.read_bytes(), before)
        second_title = 0x0100123456780000
        self.source.write_bytes(self.fixture.partition([('program.nca', self.fixture.nca(title=second_title))]))
        second = self.prepare()
        self.assertEqual(second['title_id'], f'{second_title:016x}')
        self.assertNotEqual(second['generation'], first['generation'])
        self.assertEqual(current.read_bytes(), before)
        self.assertTrue((self.generation(first) / 'romfs.bin').is_file())
        self.assertTrue((self.generation(second) / 'romfs.bin').is_file())

    def test_explicit_job_and_bad_key_sources(self):
        report = self.prepare(('--job', 'ab' * 16))
        self.assertEqual(report['job'], 'ab' * 16)
        self.assertEqual(self.prepare(('--job', 'not-hex'), success=False)['error'], 'usage')
        real = self.keys.with_suffix('.real')
        self.keys.rename(real)
        self.keys.symlink_to(real)
        self.assertEqual(self.prepare(success=False)['error'], 'keys_invalid')
        self.keys.unlink()
        os.mkfifo(self.keys)
        self.assertEqual(self.prepare(success=False)['error'], 'keys_invalid')
        self.keys.unlink()
        self.keys.write_bytes(b'x' * (1048576 + 1))
        self.assertEqual(self.prepare(success=False)['error'], 'keys_invalid')

    def test_signal_cancellation_preserves_current_and_explicit_resume_replays(self):
        first = self.prepare()
        current = self.generation(first).parent.parent / 'current'
        before = current.read_bytes()
        # Use a distinct title so the successful resume moves the job intact,
        # allowing its retained first-asset inode to be checked after publish.
        self.source.write_bytes(self.fixture.partition([
            ('program.nca', self.fixture.nca(title=0x0100123456780000))]))
        job = 'cd' * 16
        run = subprocess.run([str(self.interrupt_cli), 'prepare', str(self.source),
                              '--keys', str(self.keys), '--store', str(self.store), '--job', job],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 130, run.stdout + run.stderr)
        self.assertEqual(run.stdout, '')
        self.assertEqual(json.loads(run.stderr)['error'], 'cancelled')
        self.assertEqual(current.read_bytes(), before)
        staged = self.store / 'jobs' / job / 'exefs' / 'main'
        inode = staged.stat().st_ino
        interrupted_resume = subprocess.run(
            [str(self.interrupt_cli), 'prepare', str(self.source), '--keys', str(self.keys),
             '--store', str(self.store), '--job', job],
            env={**os.environ, 'PIPELINE_SIGNAL': 'resume'},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(interrupted_resume.returncode, 130,
                         interrupted_resume.stdout + interrupted_resume.stderr)
        self.assertEqual(interrupted_resume.stdout, '')
        self.assertEqual(json.loads(interrupted_resume.stderr)['error'], 'cancelled')
        self.assertEqual(staged.stat().st_ino, inode)
        self.assertEqual(current.read_bytes(), before)
        resumed = self.prepare(('--job', job))
        self.assertEqual((self.generation(resumed) / 'exefs' / 'main').stat().st_ino, inode)
        self.assertEqual(current.read_bytes(), before)

    def test_sigint_during_real_commit_verification_cancels_before_publish(self):
        first = self.prepare()
        current = self.generation(first).parent.parent / 'current'
        before = current.read_bytes()
        run = subprocess.run([str(self.interrupt_cli), 'prepare', str(self.source),
                              '--keys', str(self.keys), '--store', str(self.store)],
                             env={**os.environ, 'PIPELINE_SIGNAL': 'verify'},
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 130, run.stdout + run.stderr)
        self.assertEqual(run.stdout, '')
        self.assertEqual(json.loads(run.stderr)['error'], 'cancelled')
        self.assertEqual(current.read_bytes(), before)

    def test_sigint_after_successful_publication_preserves_success_result(self):
        run = subprocess.run([str(self.interrupt_cli), 'prepare', str(self.source),
                              '--keys', str(self.keys), '--store', str(self.store)],
                             env={**os.environ, 'PIPELINE_SIGNAL': 'published'},
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stderr, '')
        report = json.loads(run.stdout)
        self.assertEqual((self.generation(report).parent.parent / 'current').read_text().strip(), report['generation'])
        self.assertEqual((self.generation(report) / 'exefs/main').read_bytes(), b'synthetic main')

    def test_inspection_command_stays_available(self):
        run = subprocess.run([str(self.cli), 'inspect', str(self.source)], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)['format'], 'nsp')
        self.assertFalse(json.loads(run.stdout)['execution_verified'])


if __name__ == '__main__':
    unittest.main()
