"""Native consumer tests; fixtures never establish commercial-game acceptance."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'launcher/apple/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun') and
                     importlib.util.find_spec('cryptography'),
                     'native Foundation runtime consumer requires macOS Apple tools')
class CanopyRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        cls.fixture = fixture
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.build = Path(cls.temp.name).resolve()
        objects = []
        for name in ('mng_container', 'mng_file', 'mng_crypto', 'mng_keys', 'mng_prepare',
                     'mng_store', 'mng_display', 'mng_content', 'mng_bktr', 'mng_folder', 'mng_romfs', 'mng_romfs_runtime', 'mng_addon', 'mng_install'):
            output = cls.build / (name + '.o')
            cls.compile(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror',
                         '-I', str(ROOT / 'launcher/include'), '-c', str(ROOT / f'launcher/src/{name}.c'), '-o', str(output)])
            objects.append(str(output))
        cls.objects = tuple(objects)
        cls.cli = cls.build / 'canopy'
        cls.compile(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                     '-I', str(ROOT / 'launcher/include'), str(ROOT / 'launcher/cli/main.c'),
                     *objects, '-o', str(cls.cli)])
        cls.probe = cls.build / 'runtime-probe'
        cls.compile(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                     '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'),
                     str(ROOT / 'tests/canopy_runtime_probe.m'), str(SOURCES / 'CanopyRuntime.m'), str(SOURCES / 'CanopyShaderCache.m'),
                     *objects, '-framework', 'Foundation', '-framework', 'CoreFoundation',
                     '-framework', 'Metal', '-framework', 'QuartzCore', '-o', str(cls.probe)])

    @staticmethod
    def compile(command):
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    def scenario(self, mode):
        with tempfile.TemporaryDirectory(dir=self.build) as directory:
            root = Path(directory)
            source = root / 'invented.nsp'
            from test_canopy_romfs import romfs as make_romfs
            contents = [('icon_AmericanEnglish.dat', b'synthetic icon payload'),
                        ('fixture-layout.bin', b'original layout source')]
            image, image_layout = make_romfs(contents)
            with mock.patch.object(self.fixture, 'romfs', return_value=image):
                source.write_bytes(self.fixture.partition([
                    ('program.nca', self.fixture.nca(title=0x0100123456780000))]))
            keys = root / 'invented.keys'
            keys.write_text(f'header_key = {self.fixture.HEADER.hex()}\n'
                            f'key_area_key_application_00 = {self.fixture.AREA.hex()}\n')
            store = root / 'prepared'
            run = subprocess.run([str(self.cli), 'prepare', str(source), '--keys', str(keys), '--store', str(store)],
                                 capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            report = json.loads(run.stdout)
            if mode in ('corrupt-main', 'corrupt-romfs'):
                generation = store / 'titles/0100123456780000/generations' / report['generation']
                asset = generation / ('exefs/main' if mode == 'corrupt-main' else 'romfs.bin')
                data = asset.read_bytes();asset.chmod(0o600)
                asset.write_bytes(bytes([data[0] ^ 1]) + data[1:]);asset.chmod(0o400)
            resources = root / 'trusted-host-assets'
            resources.mkdir(mode=0o700)
            from test_canopy_shader_cache import write_shader_seed
            seed = resources / 'shader-seed'
            manifest_sha = write_shader_seed(seed, hashlib.sha256(image).hexdigest(),
                                             chain='original-fixture-chain')
            seed.chmod(0o700)
            for leaf in seed.iterdir():
                leaf.chmod(0o600)
            # Wholly original overlay fixtures; compiled pins are test-only.
            def overlay(relative, name, content, original):
                folder = resources / relative
                folder.mkdir(parents=True, mode=0o700)
                (folder / name).write_bytes(content)
                row = f'{name}\t{len(content)}\t{hashlib.sha256(content).hexdigest()}\t{original}\n'.encode()
                manifest = folder / 'manifest.tsv'
                manifest.write_bytes(b'# original Canopy display fixture\n' + row)
                return folder, hashlib.sha256(manifest.read_bytes()).hexdigest()
            original = hashlib.sha256(b'synthetic icon payload').hexdigest()
            heap, heap_sha = overlay('romfs-patches-out/1920x1080-scene-1920x1080', 'icon_AmericanEnglish.dat',
                                     b'original heap overlay fixture', '0' * 64 if mode == 'overlay-wrong-original' else original)
            layout, layout_sha = overlay('romfs-patches-4x3', 'fixture-layout.bin', b'original layout fixture', hashlib.sha256(b'original layout source').hexdigest())
            member = heap / 'icon_AmericanEnglish.dat'
            if mode == 'overlay-corrupt':
                member.write_bytes(b'corrupt member')
            elif mode == 'overlay-extra':
                (heap / 'extra').write_bytes(b'unlisted')
            elif mode == 'overlay-missing':
                member.unlink()
            elif mode == 'overlay-symlink':
                target = resources / 'linked-member'
                member.rename(target)
                member.symlink_to(target)
            elif mode == 'overlay-hardlink':
                import os
                os.link(member, resources / 'extra-link')
            elif mode == 'overlay-unpinned-manifest':
                (heap / 'manifest.tsv').write_bytes(b'# changed manifest\n')
            # Independent reproduction of the existing runtime index format.
            offsets = {}; cursor = image_layout['data_start']
            for name, payload in contents:
                offsets[name] = cursor; cursor += len(payload)
            rows = b''; strings = b''
            for name, payload in sorted(contents):
                raw = name.encode() + b'\0'
                rows += struct.pack('<QQII', offsets[name], len(payload), len(strings), len(raw))
                strings += raw
            index = struct.pack('<8sQQ', b'TOTKRFS1', len(contents), 24 + len(rows)) + rows + strings
            romfs_sha = hashlib.sha256(image).hexdigest()
            index_sha = hashlib.sha256(index).hexdigest()
            cache_file = root / 'cache/totk-runtime-index-v1' / index_sha / 'runtime-index.bin'
            if mode in ('corrupt-cache', 'cache-reuse', 'public-cache'):
                cache_file.parent.mkdir(mode=0o700, parents=True)
                # Parent creation mode is explicit for every private component.
                (root / 'cache').chmod(0o700)
                (root / 'cache/totk-runtime-index-v1').chmod(0o700)
                cache_file.write_bytes(b'corrupt retained index' if mode == 'corrupt-cache' else index)
                cache_file.chmod(0o600)
                if mode == 'public-cache':
                    cache_file.parent.chmod(0o755)
                before = (cache_file.stat().st_ino, cache_file.stat().st_mtime_ns, cache_file.read_bytes())
            cache_argument = root / 'cache'
            if mode == 'cache-leaf-symlink':
                target = root / 'separate-cache'
                target.mkdir(mode=0o700)
                cache_argument.symlink_to(target, target_is_directory=True)
            if mode == 'cache-parent-alias':
                alias = root / 'trusted-base-alias'
                alias.symlink_to(root, target_is_directory=True)
                cache_argument = alias / 'cache'
            run = subprocess.run([str(self.probe), mode, str(store), report['generation'], str(resources),
                                  str(root / 'profiles'), str(cache_argument), romfs_sha, index_sha, manifest_sha, heap_sha, layout_sha],
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            result = json.loads(run.stdout)
            if result['status'] == 'skip':
                raise unittest.SkipTest(result['reason'])
            self.assertEqual(result['status'], 'pass')
            if mode == 'success':
                self.assertEqual(cache_file.read_bytes(), index)
            if mode in ('corrupt-cache', 'cache-reuse', 'public-cache'):
                self.assertEqual((cache_file.stat().st_ino, cache_file.stat().st_mtime_ns, cache_file.read_bytes()), before)
            return result

    def test_real_consumer_applies_settings_input_focus_and_single_use_lifetime(self):
        self.assertEqual(self.scenario('success')['starts'], 1)

    def test_unavailable_and_wrong_pins_never_reach_native_entry(self):
        for mode in ('unavailable', 'wrong-main', 'wrong-romfs', 'wrong-index', 'corrupt-main', 'corrupt-romfs'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 0)

    def test_trusted_cache_parent_alias_is_canonicalized_before_strict_import(self):
        self.assertEqual(self.scenario('cache-parent-alias')['starts'], 1)

    def test_shader_seed_import_with_actual_device_identity(self):
        self.assertEqual(self.scenario('actual-shader-device')['starts'], 0)

    def test_verified_index_cache_reuse(self):
        self.assertEqual(self.scenario('cache-reuse')['starts'], 1)

    def test_corrupt_or_public_index_cache_is_refused(self):
        for mode in ('corrupt-cache', 'public-cache', 'cache-leaf-symlink'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 0)

    def test_async_preflight_cancellation_never_invokes_native_entry(self):
        self.assertFalse(self.scenario('cancel')['nativeEntryInvoked'])

    def test_native_entry_failure_does_not_invent_teardown(self):
        self.assertTrue(self.scenario('entry-failure')['nativeEntryInvoked'])

    def test_display_configuration_and_checked_patch_evidence_are_distinct(self):
        for mode in ('display-1080', 'display-full', 'display-full-fallback', 'display-stock-fallback', 'display-live', 'display-bad-state', 'display-bad-start-state', 'display-unknown-aspect'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 1)

    def test_display_descriptor_and_overlay_resources_fail_closed(self):
        for mode in ('abi1', 'display-bad-record', 'display-bad-flags', 'display-bad-pin', 'display-v121-flags',
                     'overlay-corrupt', 'overlay-extra', 'overlay-missing', 'overlay-symlink', 'overlay-hardlink',
                     'overlay-unpinned-manifest', 'overlay-wrong-original'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 0)

    def test_main_worker_end_and_join_observations_keep_protections(self):
        for mode in ('lifecycle-ended', 'lifecycle-returned', 'lifecycle-joined', 'lifecycle-join-error',
                     'lifecycle-invalid-state', 'lifecycle-start-ended', 'lifecycle-start-invalid', 'lifecycle-not-started'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 1)

    def test_lifecycle_record_and_host_abi_are_strict(self):
        for mode in ('lifecycle-bad-record', 'lifecycle-abi2'):
            with self.subTest(mode=mode):
                self.assertEqual(self.scenario(mode)['starts'], 0)

    def test_public_runtime_links_with_explicit_unavailable_provider(self):
        source = self.build / 'public-runtime.m'
        source.write_text(r'''#import <Foundation/Foundation.h>
#import "CanopyRuntime.h"
#include <stdio.h>
int main(void) {@autoreleasepool {
    CanopyRuntime *runtime=[[CanopyRuntime alloc] initWithPreparedRootURL:[NSURL fileURLWithPath:@"/not-used"]];
    if([CanopyRuntime trustedProfileForTitleID:@"0100f2c0115b6000"]!=nil ||
       [runtime.capabilities[@"available"] boolValue] || runtime.nativeEntryInvoked)return 2;
    puts("{\"status\":\"pass\",\"available\":false}");return 0;
}}
''')
        output = self.build / 'public-runtime'
        self.compile(['xcrun', 'clang', '-O2', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                      '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'), str(source),
                      str(SOURCES / 'CanopyRuntime.m'), str(SOURCES / 'CanopyShaderCache.m'),
                      *self.objects, '-framework', 'Foundation', '-framework', 'CoreFoundation',
                      '-framework', 'Metal', '-framework', 'QuartzCore', '-o', str(output)])
        run = subprocess.run([str(output)], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), {'status': 'pass', 'available': False})

    def test_actual_renderer_device_helper_has_no_private_fallback(self):
        source = self.build / 'renderer-device.m'
        source.write_text(r'''#import <Foundation/Foundation.h>
#import "canopy_metal_device.h"
#include <stdio.h>
int main(void) {@autoreleasepool {
    id<MTLDevice> actual=MTLCreateSystemDefaultDevice();
#if defined(CANOPY_HOST_RUNTIME)
    if(canopy_renderer_metal_device()!=nil || !canopy_host_bind_metal_device(nil))return 2;
    if(actual) {
        if(canopy_host_bind_metal_device(actual) || runtime_canopy_metal_device()!=actual ||
           canopy_renderer_metal_device()!=actual || canopy_host_bind_metal_device(actual))return 3;
        if(!canopy_host_bind_metal_device(nil) || runtime_canopy_metal_device()!=actual)return 4;
        for(id<MTLDevice> other in MTLCopyAllDevices())if(other.registryID!=actual.registryID) {
            if(!canopy_host_bind_metal_device(other) || runtime_canopy_metal_device()!=actual)return 5;
        }
    }
#else
    id<MTLDevice> selected=canopy_renderer_metal_device();
    if((selected==nil)!=(actual==nil) || (selected && selected.registryID!=actual.registryID))return 6;
#endif
    puts("{\"status\":\"pass\"}");return 0;
}}
''')
        for flagged in (False, True):
            output = self.build / ('flagged-device' if flagged else 'default-device')
            command = ['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                       '-I', str(ROOT / 'games/totk/runtime'), '-I', str(ROOT / 'launcher/include'), str(source),
                       '-framework', 'Foundation', '-framework', 'Metal', '-o', str(output)]
            if flagged:
                command += ['-DCANOPY_HOST_RUNTIME=1', str(ROOT / 'games/totk/runtime/canopy_host.m')]
            self.compile(command)
            run = subprocess.run([str(output)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(json.loads(run.stdout), {'status': 'pass'})

    def test_actual_flagged_host_pins_safe_compile_environment(self):
        source = self.build / 'host-environment.m'
        source.write_text(r'''#include "canopy_host.h"
#include <stdlib.h>
#include <stdio.h>
int main(void) {
    const char *keys[]={"TOTK_FAST_MATH","TOTK_SHADER_XLATE","TOTK_SHADER_SERVICE","TOTK_SHADER_DEBUGMODE",NULL};
    for(unsigned i=0;keys[i];i++)if(setenv(keys[i],"1",1))return 2;
    if(canopy_host_pin_compile_environment())return 3;
    for(unsigned i=0;keys[i];i++)if(getenv(keys[i]))return 4;
    puts("{\"status\":\"pass\",\"overridesCleared\":true}");return 0;
}
''')
        output = self.build / 'host-environment'
        self.compile(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                      '-DCANOPY_HOST_RUNTIME=1', '-I', str(ROOT / 'games/totk/runtime'), '-I', str(ROOT / 'launcher/include'),
                      str(source), str(ROOT / 'games/totk/runtime/canopy_host.m'),
                      '-framework', 'Foundation', '-framework', 'Metal', '-o', str(output)])
        run = subprocess.run([str(output)], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout), {'status': 'pass', 'overridesCleared': True})

    def test_opt_in_private_host_source_compiles_for_iphoneos(self):
        synthetic = self.build / 'generated-fixture'
        synthetic.mkdir(exist_ok=True)
        (synthetic / 'romfs_config.h').write_text('#define ROMFS_IMAGE_SHA256 "' + '01' * 32 + '"\n'
                                                '#define ROMFS_INDEX_SHA256 "' + '02' * 32 + '"\n')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        sdk_version = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
        sdk_major = int(sdk_version.split('.')[0])
        target = 'arm64-apple-ios26.0' if sdk_major >= 26 else 'arm64-apple-ios18.0'
        for name in ('canopy_host.m', 'frontend_ios.m', 'gamepad.m', 'input.c', 'fs_host.c'):
            for flagged in ((True,) if name == 'canopy_host.m' else (False, True)):
                command = ['xcrun', '--sdk', 'iphoneos', 'clang', '-fsyntax-only',
                           '-target', target, '-isysroot', sdk, '-Wall', '-Wextra', '-Werror',
                           '-DTOTK_GAME_V121=1', '-I', str(synthetic), '-I', str(ROOT / 'launcher/include'),
                           '-I', str(ROOT / 'games/totk/runtime'),
                           '-I', str(ROOT / 'games/totk/third_party/d2r_gfx/gfx/nvn'),
                           '-I', str(ROOT / 'games/totk/third_party/d2r_gfx/gfx/nvn/include')]
                if name.endswith('.m'):
                    command += ['-fobjc-arc', '-fblocks']
                if flagged:
                    command += ['-DCANOPY_HOST_RUNTIME=1']
                with self.subTest(source=name, canopy=flagged):
                    if name == 'frontend_ios.m' and sdk_major < 26:
                        self.skipTest(f'Private Metal4 frontend requires iPhoneOS SDK26; available {sdk_version}')
                    self.compile(command + [str(ROOT / 'games/totk/runtime' / name)])


# Compile and execute the actual fs_host.c path/mount implementation. Other
# service hooks below are original-source unused providers, not guest execution.
FS_PATH_PROBE = r'''
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#ifndef __APPLE__
/* Only path/mount/create are exercised; Darwin's flush command is not called. */
#define F_FULLFSYNC 0
#endif
#include "FS_HOST_SOURCE"
_Noreturn void runtime_fail(const char *message) {(void)message;exit(3);}
void runtime_account_uid(uint64_t out[2]) {out[0]=1;out[1]=2;}
uint64_t runtime_now_ns(void) {return 1;}
void dm_guest_write_prepare(void *p,size_t n) {(void)p;(void)n;}
void runtime_autoload_save_file_opened(const char *path) {(void)path;}
void runtime_fs_log(const char *what,const char *path) {(void)what;(void)path;}
int runtime_romfs_owns(const char *p) {(void)p;return 0;}
int runtime_romfs_handle(uint64_t h) {(void)h;return 0;}
unsigned runtime_romfs_open(uint64_t *o,const char *p,int m) {(void)o;(void)p;(void)m;return 1;}
unsigned runtime_romfs_read(uint64_t *o,uint64_t h,int64_t f,void *b,uint64_t n) {(void)o;(void)h;(void)f;(void)b;(void)n;return 1;}
unsigned runtime_romfs_size(int64_t *o,uint64_t h) {(void)o;(void)h;return 1;}
void runtime_romfs_close(uint64_t h) {(void)h;}
unsigned runtime_romfs_entry_type(int *o,const char *p) {(void)o;(void)p;return 1;}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    setenv("TOTK_PROFILE_DIR",argv[1],1);setenv("CANOPY_SAVE_DIR",argv[2],1);
    uint64_t uid[2]={1,2};
    if(mount_save("save",uid) || create_file("save:/probe.bin",4))return 4;
    puts("{\"status\":\"pass\"}");return 0;
}
'''


@unittest.skipUnless(shutil.which('cc'), 'native save path probe requires cc')
class CanopyNativeSavePathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name).resolve()
        source = cls.root / 'save-path.c'
        source.write_text(FS_PATH_PROBE.replace('FS_HOST_SOURCE', str(ROOT / 'games/totk/runtime/fs_host.c')))
        cls.probes = {}
        for flagged in (False, True):
            output = cls.root / ('canopy-save-path' if flagged else 'default-save-path')
            command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                       '-Wno-misleading-indentation',  # Existing compact fs_host.c style, unchanged.
                       '-I', str(ROOT / 'games/totk/runtime'),
                       str(source), '-o', str(output), '-pthread']
            if flagged:
                command.append('-DCANOPY_HOST_RUNTIME=1')
            run = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if run.returncode:
                raise AssertionError(run.stdout + run.stderr)
            cls.probes[flagged] = output

    def run_path(self, flagged, invalid=False):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            root = Path(directory)
            identity = root / 'identity'
            active = root / 'active'
            identity.mkdir(mode=0o700)
            active.mkdir(mode=0o700)
            (identity / 'account.uid').write_bytes(b'original identity')
            path = str(active) + '/..' if invalid else str(active)
            run = subprocess.run([str(self.probes[flagged]), str(identity), path],
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual((identity / 'account.uid').read_bytes(), b'original identity')
            if invalid:
                self.assertEqual(run.returncode, 3)
                self.assertFalse((root / 'probe.bin').exists())
            else:
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(json.loads(run.stdout)['status'], 'pass')
                if flagged:
                    self.assertEqual((active / 'probe.bin').read_bytes(), bytes(4))
                    self.assertFalse((identity / 'save').exists())
                    self.assertNotIn(str(root), run.stderr)
                else:
                    default = identity / 'save/00000000000000020000000000000001/probe.bin'
                    self.assertEqual(default.read_bytes(), bytes(4))
                    self.assertFalse((active / 'probe.bin').exists())

    def test_actual_canopy_save_mount_separates_active_data_and_identity(self):
        self.run_path(True)

    def test_unflagged_native_save_layout_is_preserved(self):
        self.run_path(False)

    def test_canopy_relative_and_parent_component_paths_refuse(self):
        self.run_path(True, invalid=True)


if __name__ == '__main__':
    unittest.main()
