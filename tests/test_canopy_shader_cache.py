"""Private native shader-cache import; wholly original public Metal fixture.

Foundation/Metal linkage requires macOS. These component fixtures do not claim
shader translation, GPU execution or game compatibility.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
CHAIN='totk-native-v7-unverified'
TITLE='0100123456780000'


def shader_seed_files(romfs_sha,chain=CHAIN):
    key=hashlib.sha256(b'original Canopy shader fixture').hexdigest()
    variant=key+'-'+hashlib.sha256(b'invented bind answers').hexdigest()[:12]
    deps={'tex':{},'img':{},'attr':{},'fout':{}}
    reflection={'key':variant+'_b','route':'B','chain':chain,'stage':'cs','entry':'fixture_main',
                'bindings':[],'vertex_inputs':[],'threadgroup_size':[1,1,1],'c1':'','notes':[],
                'drv_reads':{},'drv_unfillable':[],'raster':{},'deps':deps,'softfloat64':False,'compare_slots':[]}
    encode=lambda value:json.dumps(value,sort_keys=True,separators=(',',':')).encode()
    files={variant+'_b.metal':b'#include <metal_stdlib>\nusing namespace metal;\nkernel void fixture_main(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i; }\n',
           variant+'_b.json':encode(reflection),key+'.variants':encode([{'variant':variant,'deps':deps}]),
           'pso_manifest.tsv':b'# Original Canopy test fixture\n',
           'shader-keys.json':encode({'schema':1,'chain':chain,'version':'v0','source_romfs_sha256':romfs_sha,'keys':[key]})}
    mapping=b'# TOTK control-code-sha256-v1\n'
    manifest={'schema':1,'chain':chain,'shaders':1,'game':'totk','version':'v0',
              'source_romfs_sha256':romfs_sha,'translator_sha256':hashlib.sha256(b'invented translator recipe').hexdigest(),
              'spirv_cross_sha256':hashlib.sha256(b'invented SPIRV-Cross recipe').hexdigest(),
              'preparation_sha256':hashlib.sha256(b'invented preparation recipe').hexdigest(),
              'shader_map_sha256':hashlib.sha256(mapping).hexdigest(),
              'files':{name:hashlib.sha256(data).hexdigest() for name,data in files.items()}}
    files['shader_map.tsv']=mapping
    return files,manifest


def write_shader_seed(folder,romfs_sha,chain=CHAIN):
    """Reusable consumer-test fixture: returns the compiled expected manifest pin."""
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=True)
    files,manifest=shader_seed_files(romfs_sha,chain)
    for name,data in files.items():(folder/name).write_bytes(data)
    raw=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()
    (folder/'seed-manifest.json').write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),
                     'Native shader cache requires macOS Foundation/Metal and xcrun')
class CanopyShaderCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        folder=Path(cls.build.name).resolve();obj=folder/'crypto.o';cls.probe=folder/'shader-probe'
        for command in (
            ['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'launcher/include'),
             '-c',str(ROOT/'launcher/src/mng_crypto.c'),'-o',str(obj)],
            ['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',
             '-I',str(ROOT/'launcher/include'),'-I',str(ROOT/'launcher/apple/Sources'),
             str(ROOT/'tests/canopy_shader_cache_probe.m'),str(ROOT/'launcher/apple/Sources/CanopyShaderCache.m'),
             str(ROOT/'launcher/apple/Sources/CanopyCacheFS.m'),
             str(obj),'-framework','Foundation','-framework','Metal','-o',str(cls.probe)]):
            run=subprocess.run(command,capture_output=True,text=True,timeout=120)
            if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.source=self.root/'source';self.cache=self.root/'cache'
        self.romfs=hashlib.sha256(b'invented RomFS source').hexdigest()
        self.pin=write_shader_seed(self.source,self.romfs)

    def job(self,mode='import',pin=None,title=TITLE,device='original fixture GPU'):
        run=subprocess.run([str(self.probe),str(self.source),str(self.cache),pin or self.pin,self.romfs,
                            mode,title,device],capture_output=True,text=True,timeout=40)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr);result=json.loads(run.stdout)
        self.assertNotIn(str(self.root),run.stdout);self.assertNotIn(device,run.stdout)
        if self.cache.exists():self.assertFalse(list(self.cache.glob('.shader-stage-*')))
        return result

    def rewrite(self,name,data):
        (self.source/name).write_bytes(data)
        path=self.source/'seed-manifest.json';manifest=json.loads(path.read_bytes())
        if name=='shader_map.tsv':manifest['shader_map_sha256']=hashlib.sha256(data).hexdigest()
        else:manifest['files'][name]=hashlib.sha256(data).hexdigest()
        raw=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode();path.write_bytes(raw)
        self.pin=hashlib.sha256(raw).hexdigest()

    def test_copy_reuse_exact_bytes_and_inode(self):
        first=self.job();self.assertTrue(first['ok']);identity=first['identity'];seed=self.cache/identity/'seed'
        total=sum(p.stat().st_size for p in self.source.iterdir())
        self.assertEqual(first['metrics']['seedCopiedBytes'],total)
        self.assertEqual(first['metrics']['seedReusedBytes'],0)
        before={p.name:p.stat().st_ino for p in seed.iterdir()}
        for p in self.source.iterdir():self.assertEqual((seed/p.name).read_bytes(),p.read_bytes())
        second=self.job();self.assertTrue(second['ok']);self.assertEqual(second['identity'],identity)
        self.assertIs(first['metrics']['cacheReused'],False);self.assertIs(second['metrics']['cacheReused'],True)
        self.assertEqual(second['metrics']['seedReusedBytes'],total);self.assertEqual(second['metrics']['seedCopiedBytes'],0)
        self.assertEqual(before,{p.name:p.stat().st_ino for p in seed.iterdir()})
        self.assertEqual(seed.stat().st_mode&0o077,0)

    def test_compiled_pin_and_map_authentication(self):
        self.assertFalse(self.job(pin='0'*64)['ok'])
        (self.source/'shader_map.tsv').write_bytes(b'changed map')
        self.assertFalse(self.job()['ok'])

    def test_device_title_and_recipe_namespace(self):
        first=self.job()['identity'];second=self.job(device='another invented GPU')['identity']
        third=self.job(title='0100123456780001')['identity'];self.assertEqual(len({first,second,third}),3)
        manifest=json.loads((self.source/'seed-manifest.json').read_bytes());manifest['preparation_sha256']='1'*64
        raw=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()
        (self.source/'seed-manifest.json').write_bytes(raw);self.pin=hashlib.sha256(raw).hexdigest()
        self.assertNotEqual(first,self.job()['identity'])

    def test_structural_reflection_and_dependencies_refused(self):
        name=next(p.name for p in self.source.glob('*_b.json'))
        data=json.loads((self.source/name).read_bytes());data['deps']['tex']['0']='2D'
        self.rewrite(name,json.dumps(data).encode())
        self.assertFalse(self.job()['ok'])

    def test_malformed_scope_and_variant_types_refused(self):
        self.rewrite('shader-keys.json',b'[]');self.assertFalse(self.job()['ok'])
        self.pin=write_shader_seed(self.source,self.romfs)
        name=next(p.name for p in self.source.glob('*.variants'))
        self.rewrite(name,b'[1]');self.assertFalse(self.job()['ok'])

    def test_corrupt_published_seed_refused_without_replacement(self):
        result=self.job();seed=self.cache/result['identity']/'seed';file=next(seed.glob('*_b.metal'))
        inode=file.stat().st_ino;file.chmod(0o600);file.write_bytes(b'corrupt')
        self.assertFalse(self.job()['ok']);self.assertEqual(file.stat().st_ino,inode)
        self.assertEqual(file.read_bytes(),b'corrupt')

    def test_cancel_early_copy_and_before_publication(self):
        for mode in ('cancel-early','cancel-copy','cancel-final'):
            result=self.job(mode);self.assertFalse(result['ok']);self.assertEqual(result['errorCode'],2)
            if self.cache.exists():self.assertFalse([p for p in self.cache.iterdir() if len(p.name)==64])

    def test_leases_clear_remove_and_title_isolation(self):
        result=self.job('active');self.assertTrue(result['clearRefused']);self.assertTrue(result['removeRefused'])
        identity=result['identity'];runtime=self.cache/identity/'runtime';(runtime/'output').write_bytes(b'cache bytes')
        self.assertFalse(self.job('clear:'+identity,title='0100123456780001')['ok'])
        self.assertEqual(self.job('usage:'+identity)['value']['runtimeBytes'],11)
        self.assertTrue(self.job('clear:'+identity)['ok']);self.assertEqual([p.name for p in runtime.iterdir()],['.canopy-private-cache'])
        self.assertTrue(self.job('remove:'+identity)['ok']);self.assertFalse((self.cache/identity).exists())

    def test_source_symlink_refused_hardlink_allowed(self):
        import os
        file=next(self.source.glob('*_b.metal'));data=file.read_bytes();file.unlink()
        outside=self.root/'original.metal';outside.write_bytes(data);file.symlink_to(outside)
        self.assertFalse(self.job()['ok']);file.unlink();os.link(outside,file)
        self.assertTrue(self.job()['ok'])

    def test_runtime_symlink_and_hardlink_refused(self):
        import os
        identity=self.job()['identity'];runtime=self.cache/identity/'runtime';outside=self.root/'outside';outside.write_bytes(b'private')
        bad=runtime/'bad';bad.symlink_to(outside);self.assertFalse(self.job()['ok']);bad.unlink()
        os.link(outside,bad);self.assertFalse(self.job('clear:'+identity)['ok']);self.assertEqual(outside.read_bytes(),b'private')

    def test_per_file_quota(self):
        file=next(self.source.glob('*_b.metal'))
        with file.open('wb') as stream:stream.truncate((64<<20)+1)
        self.assertFalse(self.job()['ok'])

    def test_listing_bounds_all_invalid_names(self):
        self.cache.mkdir(mode=0o700)
        for index in range(4097):
            (self.cache/f'invalid-stage-{index}').touch()
        result=self.job('list');self.assertFalse(result['ok'])
        self.assertEqual(result['errorCode'],1)
