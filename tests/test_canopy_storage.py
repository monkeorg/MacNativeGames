"""Real Foundation storage actions; original synthetic bytes, no game data.

UIKit presentation is built by the Apple application build. This harness tests
the actual asynchronous Foundation backend and native store/cache authority.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_canopy_shader_cache import write_shader_seed

ROOT = Path(__file__).resolve().parents[1]
TITLE = '0100123456780000'
JOB = 'f' * 32


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'Native storage backend requires macOS Foundation/Metal and xcrun')
class CanopyStorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name).resolve(); cls.probe = folder / 'storage-probe'
        objects = []
        for name in ('mng_store', 'mng_crypto'):
            obj = folder / (name + '.o'); objects.append(str(obj))
            command = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                       '-I', str(ROOT / 'launcher/include')]
            if name == 'mng_store':
                command += ['-Drenameat=storage_probe_renameat', '-Dfsync=storage_probe_fsync']
            command += ['-c', str(ROOT / 'launcher/src' / (name + '.c')), '-o', str(obj)]
            run = subprocess.run(command, capture_output=True, text=True, timeout=120)
            if run.returncode: raise AssertionError(run.stdout + run.stderr)
        command = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                   '-I', str(ROOT / 'launcher/include'), '-I', str(ROOT / 'launcher/apple/Sources'),
                   str(ROOT / 'tests/canopy_storage_probe.m'),
                   str(ROOT / 'launcher/apple/Sources/CanopyStorage.m'),
                   str(ROOT / 'launcher/apple/Sources/CanopyShaderCache.m'),
                   str(ROOT / 'launcher/apple/Sources/CanopyCacheFS.m'),
                   str(ROOT / 'launcher/apple/Sources/CanopyProviderCache.m'), *objects,
                   '-framework', 'Foundation', '-framework', 'Metal', '-o', str(cls.probe)]
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if run.returncode: raise AssertionError(run.stdout + run.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.prepared = self.root / 'Prepared'; self.cache = self.root / 'Caches'
        for path in (self.prepared, self.cache): path.mkdir(mode=0o700)
        self.ids = self.call('seed')['ids']; self.assertEqual(len(self.ids), 3)

    def call(self, mode, *args, env=None):
        run = subprocess.run([str(self.probe), mode, str(self.prepared), str(self.cache), *args],
                             capture_output=True, text=True, timeout=35, env={**os.environ, **(env or {})})
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn(str(self.root), run.stdout)
        result = json.loads(run.stdout); self.assertNotIn('timeout', result)
        if result.get('accepted'):
            self.assertTrue(result['mainThread']); self.assertFalse(result['busyAtCompletion'])
            self.assertTrue(result['busyDuringOperation']); self.assertFalse(result['secondAccepted'])
        return result

    def generation(self, index=0):
        return self.prepared / 'titles' / TITLE / 'generations' / self.ids[index]

    def test_async_inventory_then_explicit_real_hash_verification(self):
        rows = self.call('reload')['snapshot']['generations']; self.assertEqual(len(rows), 3)
        self.assertTrue(all(r['logicalAssetBytes'] is None for r in rows))
        self.assertEqual(next(r['identifier'] for r in rows if r['current']), self.ids[2])
        self.assertEqual(next(r['identifier'] for r in rows if r['previous']), self.ids[1])
        result = self.call('verify', self.ids[0], TITLE); self.assertEqual(result['error'], 0)
        row = next(r for r in result['snapshot']['generations'] if r['identifier'] == self.ids[0])
        expected = sum(p.stat().st_size for p in (self.generation() / 'exefs').iterdir()) + (self.generation() / 'romfs.bin').stat().st_size
        self.assertEqual(row['logicalAssetBytes'], expected); self.assertEqual(row['assetCount'], 3)
        self.assertEqual(row['executionStatus'], 'unassessed')

    def test_real_rollback_and_authoritative_current_after_sync_error(self):
        result = self.call('select', self.ids[0], TITLE, env={'CANOPY_STORAGE_FAIL_CURRENT_SYNC': '1'})
        self.assertNotEqual(result['error'], 0)
        operation = result['snapshot']['operation']
        self.assertEqual(operation['currentReadState'], 'confirmed')
        self.assertEqual(operation['currentGenerationID'], self.ids[0])
        current = self.prepared / 'titles' / TITLE / 'current'
        self.assertEqual(current.read_text(), self.ids[0] + '\n')
        self.assertTrue(all(self.generation(i).exists() for i in range(3)))
        self.assertEqual(self.call('select', self.ids[2], TITLE)['error'], 0)

    def test_current_previous_and_pinned_generation_protected(self):
        for index in (1, 2): self.assertNotEqual(self.call('remove', self.ids[index], TITLE)['error'], 0)
        self.assertNotEqual(self.call('pinned', self.ids[0])['error'], 0)
        self.assertTrue(self.generation().exists())
        self.assertEqual(self.call('remove', self.ids[0], TITLE)['error'], 0)
        self.assertFalse(self.generation().exists()); self.assertTrue(self.generation(1).exists())

    def test_discard_only_exact_job_and_no_profile_account_save_access(self):
        sentinels = []
        for scope in ('profiles', 'saves', 'accounts'):
            path = self.prepared / scope; path.mkdir(mode=0o700); file = path / 'keep'; file.write_bytes(b'opaque sentinel'); sentinels.append(file)
        before = [(p.read_bytes(), p.stat().st_ino) for p in sentinels]
        self.assertEqual(self.call('discard', JOB, '-')['error'], 0)
        self.assertFalse((self.prepared / 'jobs' / JOB).exists())
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_ino) for p in sentinels])

    def test_root_lock_is_nonblocking_and_reports_incomplete(self):
        result = self.call('locked')['snapshot']; self.assertFalse(result['complete'])
        self.assertEqual(result['generations'], []); self.assertTrue(self.generation().exists())

    def test_exact_identifiers_and_cross_title_isolation(self):
        for mode, identifier, title in [('remove', '../outside', TITLE), ('select', self.ids[0].upper(), TITLE),
                                         ('discard', JOB, TITLE), ('verify', self.ids[0], '0' * 16)]:
            self.assertFalse(self.call(mode, identifier, title)['accepted'])
        self.assertNotEqual(self.call('remove', self.ids[0], '0100123456780001')['error'], 0)
        self.assertTrue(self.generation().exists())

    def test_unknown_entries_count_before_filter_and_are_preserved(self):
        jobs = self.prepared / 'jobs'
        for i in range(128): (jobs / ('unknown-' + str(i))).write_bytes(b'keep')
        result = self.call('reload')['snapshot']; self.assertFalse(result['complete']); self.assertEqual(result['jobs'], [])
        self.assertEqual(len(list(jobs.iterdir())), 129)

    def test_symlink_and_corrupt_tree_refused_without_outside_mutation(self):
        outside = self.root / 'outside'; outside.mkdir(); sentinel = outside / 'keep'; sentinel.write_bytes(b'untouched')
        linked = 'e' * 64; (self.generation().parent / linked).symlink_to(outside, target_is_directory=True)
        rows = self.call('reload')['snapshot']['generations']; self.assertNotIn(linked, [r['identifier'] for r in rows])
        self.assertNotEqual(self.call('remove', linked, TITLE)['error'], 0)
        asset = self.generation() / 'romfs.bin'; asset.chmod(0o600); asset.write_bytes(b'corrupt')
        self.assertNotEqual(self.call('verify', self.ids[0], TITLE)['error'], 0)
        self.assertEqual(sentinel.read_bytes(), b'untouched'); self.assertTrue((self.generation().parent / linked).is_symlink())

    def test_hardlinked_asset_and_fifo_job_preserved(self):
        target = self.generation() / 'romfs.bin'; outside = self.root / 'external-link'
        os.link(target, outside)
        self.assertNotEqual(self.call('verify', self.ids[0], TITLE)['error'], 0)
        self.assertNotEqual(self.call('remove', self.ids[0], TITLE)['error'], 0)
        self.assertEqual(target.stat().st_ino, outside.stat().st_ino)
        fifo = self.prepared / 'jobs' / ('d' * 32); os.mkfifo(fifo, 0o600)
        self.assertNotIn('d' * 32, [r['identifier'] for r in self.call('reload')['snapshot']['jobs']])
        self.assertNotEqual(self.call('discard', 'd' * 32, '-')['error'], 0)
        self.assertTrue(fifo.exists()); self.assertTrue(outside.exists())

    def test_private_root_required_and_wrong_root_never_initialized(self):
        self.prepared.chmod(0o755)
        self.assertFalse(self.call('reload')['snapshot']['complete'])
        self.prepared.chmod(0o700)
        shutil.rmtree(self.prepared); self.prepared.mkdir(mode=0o700)
        (self.prepared / 'unrelated').write_bytes(b'keep')
        self.call('reload'); self.assertEqual([p.name for p in self.prepared.iterdir()], ['unrelated'])

    def shader_seed(self, mode='shaderSeed'):
        source = self.root / 'seed'; romfs = hashlib.sha256(b'original RomFS fixture').hexdigest()
        pin = write_shader_seed(source, romfs)
        (self.cache / TITLE).mkdir(mode=0o700, exist_ok=True)
        result = self.call(mode, str(source), pin, romfs); self.assertTrue(result['seeded'])
        return result

    def test_shader_usage_clear_remove_and_active_lease_authority(self):
        active = self.shader_seed('shaderActive'); identity = active['identity']
        self.assertNotEqual(active['clear']['error'], 0); self.assertNotEqual(active['remove']['error'], 0)
        folder = self.cache / TITLE / 'shader-identities' / identity
        runtime = folder / 'runtime'; (runtime / 'original-cache.bin').write_bytes(b'original generated fixture')
        rows = self.call('reload')['snapshot']['shaders']; self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['usageState'], 'available'); self.assertGreater(rows[0]['runtimeBytes'], 0)
        self.assertEqual(self.call('clearShader', identity, TITLE)['error'], 0)
        self.assertTrue((folder / 'seed').is_dir())
        self.assertEqual([p.name for p in runtime.iterdir()], ['.canopy-private-cache'])
        self.assertEqual(self.call('removeShader', identity, TITLE)['error'], 0); self.assertFalse(folder.exists())

    def test_corrupt_shader_identity_preserved(self):
        identity = self.shader_seed()['identity']; folder = self.cache / TITLE / 'shader-identities' / identity
        target = folder / 'seed' / 'shader_map.tsv'; target.chmod(0o600); target.write_bytes(b'corrupt')
        # Management requires a valid identity receipt and bounded tree; seed
        # authenticity is rechecked by session preparation, not usage counting.
        (folder / 'unknown').write_bytes(b'keep')
        row = self.call('reload')['snapshot']['shaders'][0]; self.assertEqual(row['usageState'], 'unavailable')
        self.assertNotEqual(self.call('removeShader', identity, TITLE)['error'], 0)
        self.assertEqual((folder / 'unknown').read_bytes(), b'keep')
