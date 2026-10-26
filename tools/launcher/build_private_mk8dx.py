#!/usr/bin/env python3
"""Source-only private MK8DX4.0.0 Canopy recipe. Never downloads or signs.

--plan consumes no game inputs. --build requires an explicitly trusted local
pin manifest, original ExeFS, original MIT source export and prebuilt private
shader seed. No public title label or imported preparation JSON authorizes code.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TITLE = '0100152000022000'
COMMIT = '7861e7c1a9913e020600b1cc7f65132427e9cc50'
RECIPE = 'canopy-mk8dx4-original-host-v1'
ENVIRONMENT_POLICY = 'closed-private-home-path-C-locale-v1'
MODULES = {'main': '2c336a9bcf79c3040ce506cdd391b578',
           'subsdk0': 'd9de423efc1512328c3c05378c7cb031',
           'sdk': 'ba520906609c503227871a314a94fb5f'}
GLUE = ('canopy_host.m', 'canopy_prepare.m', 'canopy_frontend.m', 'canopy_input.c')
FRAMEWORKS = ('UIKit', 'Foundation', 'Metal', 'MetalFX', 'QuartzCore', 'CoreFoundation',
              'GameController', 'CoreGraphics', 'CoreHaptics', 'AudioToolbox', 'AVFAudio',
              'VideoToolbox', 'CoreMedia', 'CoreVideo', 'ImageIO', 'UniformTypeIdentifiers', 'CoreText', 'WebKit')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pin(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) and value != '0' * 64


def read(path, limit=64 << 20):
    path = Path(path).absolute()
    require(all(not p.is_symlink() for p in (path, *path.parents)), 'linked input refused')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= limit,
                'input is not a bounded single-link regular file')
        chunks = []; total = 0
        while part := os.read(fd, 1 << 20):
            total += len(part); require(total <= limit, 'input exceeds bound'); chunks.append(part)
        after = os.fstat(fd)
        attrs = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(total == before.st_size and all(getattr(before, x) == getattr(after, x) for x in attrs),
                'input changed during read')
        return b''.join(chunks)
    finally:
        os.close(fd)


def write(path, data, mode=0o600):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, 'wb') as out:
        out.write(data); out.flush(); os.fsync(out.fileno())


def source_snapshot(export, destination):
    metadata = json.loads(read(ROOT / 'games/mk8dx/source-allowlist.json', 1 << 20))
    require(metadata['commit'] == COMMIT, 'source export recipe differs')
    records = {}
    for name, expected in metadata['files'].items():
        data = read(export / name, 8 << 20)
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        require(blob == expected['gitBlobSHA1'] and len(data) == expected['size'], 'original source export differs')
        write(destination / name, data); records[name] = sha(data)
    return records


def replace_once(path, old, new):
    data = path.read_text(); require(data.count(old) == 1, 'original host adaptation anchor differs')
    path.write_text(data.replace(old, new))


def adapt(source):
    """Exact guarded adaptations of reviewed original host functions, not a forked HLE.

    The private snapshot is modified; user exports and the standalone Mac host
    are untouched. Every pre-adaptation source is pinned by its Git blob above.
    """
    hid = source / 'dm/host/hle_hid.c'
    replace_once(hid, 'static int reported(int p) { return p == 0 ||',
                 'static int reported(int p) { return\n#ifdef CANOPY_MK8DX_HOST\n        p >= 0 && p < 4 &&\n#else\n        p == 0 ||\n#endif\n')
    replace_once(hid, 'static uint32_t merged_players(void) { return one_player() ? unsupported_players() : 0; }',
                 'static uint32_t merged_players(void) {\n#ifdef CANOPY_MK8DX_HOST\nreturn 0;\n#else\nreturn one_player() ? unsupported_players() : 0;\n#endif\n}')
    replace_once(hid, 'if (id == connected_id()) return 0;',
                 'if (id == connected_id()\n#ifdef CANOPY_MK8DX_HOST\n && reported(0)\n#endif\n) return 0;')
    replace_once(hid, 'mask = (mask | 1u) & ((1u << DM_PLAYERS) - 1);',
                 '#ifdef CANOPY_MK8DX_HOST\nmask &= 15u;\n#else\nmask = (mask | 1u) & ((1u << DM_PLAYERS) - 1);\n#endif')
    replace_once(hid, 'for (int p = 1; p < DM_PLAYERS; p++) if ((old ^ mask)',
                 'for (int p =\n#ifdef CANOPY_MK8DX_HOST\n0\n#else\n1\n#endif\n; p < DM_PLAYERS; p++) if ((old ^ mask)')
    replace_once(hid, 'Result, h_hid_ShowCtrl, int32_t *info, const int8_t *arg) {',
                 'Result, h_hid_ShowCtrl, int32_t *info, const int8_t *arg) {\n#ifdef CANOPY_MK8DX_HOST\nextern uint32_t MKControllerSupport(int32_t *,const int8_t *);return MKControllerSupport(info,arg);\n#endif')
    replace_once(hid, 'Result, h_hid_ShowCtrl0, const void *arg) { (void)arg; return RES_OK; }',
                 'Result, h_hid_ShowCtrl0, const void *arg) {\n#ifdef CANOPY_MK8DX_HOST\nextern uint32_t MKControllerSupport(int32_t *,const int8_t *);return MKControllerSupport(NULL,arg);\n#else\n(void)arg; return RES_OK;\n#endif\n}')
    with hid.open('a') as out:
        out.write('''\n#ifdef CANOPY_MK8DX_HOST
void MKInputResetSeat(unsigned p) { if (p >= 4) return;
 atomic_store(&g_pad_btn[p],0); atomic_store(&g_pad_axes[p],0); atomic_store(&g_pad_latch[p],0);
 if (!p) { atomic_store(&g_btn,0); atomic_store(&g_axes,0); atomic_store(&g_latch,0); }
}
uint32_t dm_canopy_reported_mask(void) { uint32_t m=0;
 if (!(g_styles_supported & STYLE_FULLKEY)) return 0;
 for (int p=0;p<4;p++) if (reported(p)) m |= 1u << p;
 return m;
}
#endif
''')
    replace_once(hid, 'static uint32_t g_styles_supported = 0xffffffffu;',
                 'static _Atomic uint32_t g_styles_supported = 0xffffffffu;')
    account = source / 'dm/host/hle_account.c'
    old = 'static const Uid k_uid = {{0x78626c0000000001ull, 0x53574e4154495645ull}};'
    replace_once(account, old, '#ifdef CANOPY_MK8DX_HOST\nextern void MKCopyUID(uint64_t out[2]);\nstatic Uid canopy_uid(void) { Uid uid;MKCopyUID(uid.v);return uid; }\n#define k_uid canopy_uid()\n#else\n' + old + '\n#endif')
    renderer = source / 'dm/gfx/nvn/nvn_mtl.m'
    replace_once(renderer, 'g_dev = MTLCreateSystemDefaultDevice();',
                 '#ifdef CANOPY_MK8DX_HOST\nextern void *MKMetalDevice(void);g_dev=(__bridge id<MTLDevice>)MKMetalDevice();\nif (!g_dev) abort();\n#else\ng_dev = MTLCreateSystemDefaultDevice();\n#endif')
    imports = source / 'dm/host/hle.c'
    replace_once(imports, 'uint64_t unimpl_c(unsigned idx, uint64_t *regs) {',
                 'uint64_t unimpl_c(unsigned idx, uint64_t *regs) {\n#ifdef CANOPY_MK8DX_HOST\n(void)idx;(void)regs;extern _Noreturn void MKUnsupportedService(void);MKUnsupportedService();\n#endif')
    # Diagnostic input constructors cannot become a competing source owner.
    replace_once(hid, 'void hid_keys_init(void) {',
                 'void hid_keys_init(void) {\n#ifdef CANOPY_MK8DX_HOST\nreturn;\n#endif')
    return {str(p.relative_to(source)): sha(p.read_bytes()) for p in (hid, account, renderer, imports)}


def tree(folder, grammar, total_limit=16 << 30):
    rows = {}; total = 0
    for parent, dirs, names in os.walk(folder, followlinks=False):
        for name in dirs:
            require(not (Path(parent) / name).is_symlink(), 'linked asset directory refused')
        for name in names:
            relative = (Path(parent) / name).relative_to(folder).as_posix()
            require(grammar.fullmatch(relative), 'unexpected private asset filename')
            data = read(Path(parent) / name); total += len(data)
            require(total <= total_limit and len(rows) < 100000, 'private asset tree exceeds bound')
            rows[relative] = {'sha256': sha(data), 'size': len(data)}
    require(rows, 'empty private asset tree'); return rows


def python_dependencies(folder, manifest_path, manifest_sha, destination):
    """Only explicitly trusted local Capstone/LZ4 dependencies, privately copied.

    These are host tools, not game payload. The full manifest hash is a caller
    trust decision; neither package discovery nor public metadata approves code.
    Python runs with -S against this snapshot, excluding inherited site packages.
    """
    raw = read(manifest_path, 1 << 20)
    require(pin(manifest_sha) and sha(raw) == manifest_sha, 'Python dependency manifest differs')
    manifest = json.loads(raw)
    require(set(manifest) == {'schema', 'files'} and manifest['schema'] == 1 and
            isinstance(manifest['files'], dict) and 0 < len(manifest['files']) <= 4096,
            'invalid Python dependency manifest')
    total = 0
    for name, expected in manifest['files'].items():
        require(isinstance(name, str) and re.fullmatch(r'(?:capstone|lz4)/[A-Za-z0-9_./+-]{1,512}', name) and
                all(part not in ('', '.', '..') for part in name.split('/')) and pin(expected),
                'invalid Python dependency name')
        data = read(folder / name, 128 << 20); total += len(data)
        require(total <= 256 << 20 and sha(data) == expected, 'Python dependency differs')
        write(destination / name, data)
    require('capstone/__init__.py' in manifest['files'] and 'lz4/__init__.py' in manifest['files'],
            'required Python dependency missing')
    return manifest


def trusted_inputs(path, expected, exefs, stage):
    require(pin(expected), 'an explicit trusted local pin-manifest hash is required')
    raw = read(path, 65536); require(sha(raw) == expected, 'trusted input manifest differs')
    pins = json.loads(raw)
    require(set(pins) == {'schema', 'titleID', 'titleVersion', 'romfs', 'modules'} and
            pins['schema'] == 1 and pins['titleID'] == TITLE and pins['titleVersion'] == 1441792,
            'trusted original-input profile differs')
    require(set(pins['modules']) == set(MODULES), 'original module set differs')
    for name, build in MODULES.items():
        entry = pins['modules'][name]
        require(set(entry) == {'sha256', 'size'} and pin(entry['sha256']) and type(entry['size']) is int,
                'invalid original module identity')
        data = read(exefs / name)
        require(len(data) >= 80 and data[:4] == b'NSO0' and data[64:80].hex() == build and
                sha(data) == entry['sha256'] and len(data) == entry['size'], 'original module is not the selected build')
        write(stage / 'original' / name, data)
    romfs = pins['romfs']; require(set(romfs) == {'sha256', 'size'} and pin(romfs['sha256']) and
                                  type(romfs['size']) is int and 0 < romfs['size'] <= 64 << 30,
                                  'invalid original RomFS identity')
    write(stage / 'trusted-inputs.json', raw)
    return pins


def plan():
    return {'recipe': RECIPE, 'titleID': TITLE, 'version': '4.0.0', 'titleVersion': 1441792,
            'originalSourceRepository': 'seedds/nxnative', 'originalSourceCommit': COMMIT,
            'moduleBuildIDs': MODULES, 'entry': 'CanopyApp.m -> CanopyRuntime -> CanopyRuntimeRegistry -> strong MK host -> nxnative_host_main -> front_run -> guest_main',
            'originalFullHashes': 'required explicitly trusted local inputs; unavailable in public metadata',
            'status': 'source recipe only; no private inputs/Apple compilation/device acceptance',
            'signing': 'none', 'maxRoutedSeats': 4,
            'limits': ['Games multi-seat capability gate and Storage MK namespace management require caller integration',
                       'unsupported/terminal controller requests fail the native provider, never invent an SDK Result',
                       'no safe stop/relaunch, no network service claim']}


def build(args):
    require(sys.platform == 'darwin' and os.uname().machine == 'arm64', 'private build requires Apple silicon macOS')
    require(args.output.parent.is_dir() and not args.output.exists() and not args.output.is_symlink(), 'new output directory required')
    require(all(not p.is_symlink() for p in args.output.absolute().parents), 'linked output parent refused')
    args.output.mkdir(mode=0o700); work = args.output / 'private-work'; work.mkdir(mode=0o700)
    observation = plan(); observation['status'] = 'started; no accepted output'; observation['commands'] = []
    record = args.output / 'build-observation.json'
    try:
        source = work / 'source'; source.mkdir(mode=0o700)
        observation['originalSources'] = source_snapshot(args.source_export, source)
        # Snapshot public production app + original glue. Executed helpers are
        # imported from their captured source bytes, never a mutable export.
        helper = read(ROOT / 'tools/launcher/build_canopy.py', 1 << 20)
        spec = importlib.util.spec_from_loader('mk_public_builder', loader=None)
        public = importlib.util.module_from_spec(spec); public.__file__ = str(ROOT / 'tools/launcher/build_canopy.py')
        exec(compile(helper, public.__file__, 'exec'), public.__dict__)
        public.bundle_identifier(args.bundle_id)
        appsource = work / 'canopy'; inputs = public.capture_inputs(ROOT)
        for name, data in inputs.items(): write(appsource / name, data)
        for path in (ROOT / 'games/mk8dx/runtime').iterdir():
            require(path.suffix in ('.h', '.m', '.c'), 'unexpected MK source')
            write(appsource / 'games/mk8dx/runtime' / path.name, read(path, 1 << 20))
        pins = trusted_inputs(args.input_manifest, args.input_manifest_sha256, args.exefs, work)
        observation['trustedInputManifestSHA256'] = args.input_manifest_sha256
        observation['adaptedSources'] = adapt(source)
        recipe_bytes = encode({'recipe': RECIPE, 'environmentPolicy': ENVIRONMENT_POLICY, 'sourceCommit': COMMIT, 'sourceHashes': observation['originalSources'],
                              'adaptedHashes': observation['adaptedSources'], 'builderSHA256': sha(read(Path(__file__), 1 << 20)),
                              'pythonDependenciesManifestSHA256': args.python_dependencies_manifest_sha256,
                              'publicSourceHashes': {name: sha(data) for name, data in inputs.items()},
                              'glueHashes': {p.name: sha(read(p, 1 << 20)) for p in (appsource / 'games/mk8dx/runtime').iterdir()}})
        recipe_sha = sha(recipe_bytes); observation['sourceRecipeSHA256'] = recipe_sha
        # Pinned game.py selectors are DM_GAME/DM_GAMES_DIR/DM_GAMES_FIRST;
        # Makefile also obeys ordinary make environment variables. Inherit NONE
        # of them (or MAKEFLAGS, compiler flags, loader injection or Python hooks).
        # Toolchain selection uses the system xcode-select configuration only.
        home = work / 'tool-home'; home.mkdir(mode=0o700)
        temporary = work / 'tool-temp'; temporary.mkdir(mode=0o700)
        env = {'HOME': str(home), 'TMPDIR': str(temporary), 'LANG': 'C', 'LC_ALL': 'C'}
        observation['environmentPolicy'] = ENVIRONMENT_POLICY
        dependencies = work / 'python-dependencies'
        observation['pythonDependencies'] = python_dependencies(args.python_dependencies, args.python_dependencies_manifest,
            args.python_dependencies_manifest_sha256, dependencies)
        env.update({'GAME': TITLE, 'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONPATH': str(dependencies),
                    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
        def run(command, cwd=None):
            observation['commands'].append(command)
            result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, check=True)
            return result.stdout.strip()
        native = work / 'native'; native.mkdir(mode=0o700)
        for name in MODULES:
            run([sys.executable, '-S', str(source / 'dm/tools/patch_nso.py'), str(work / 'original' / name), str(native), name])
        # The generated rewrites are private build products, never public inputs.
        native_files = {}
        for name in MODULES:
            for ext in ('patched.bin', 'fixups.tsv', 'gates.tsv', 'cuts.tsv', 'obs.tsv'):
                key = f'{name}.{ext}'; data = read(native / key)
                native_files[key] = {'sha256': sha(data), 'size': len(data)}
        native_manifest = encode({'schema': 1, 'sourceRecipeSHA256': recipe_sha, 'files': native_files})
        write(native / 'native-manifest.json', native_manifest)
        chain_data = read(source / 'dm/gfx/nvn/dmsh_chain.h', 65536).decode()
        match = re.search(r'^#define\s+DMSH_CHAIN\s+"([A-Za-z0-9_-]{1,128})"', chain_data, re.M)
        require(match, 'missing original renderer chain'); chain = match[1]
        shader_grammar = re.compile(r'(?:shader_map\.tsv|pso_manifest\.tsv|shader_pairs\.tsv|shader_facts\.tsv|bf_want\.tsv|c1_full\.tsv|cb_extent\.tsv|b-' + re.escape(chain) + r'/(?:inputs\.tsv|[0-9a-f]{64}_b\.(?:metallib|json)))')
        shader_rows = tree(args.shader_seed, shader_grammar)
        require('shader_map.tsv' in shader_rows and 'pso_manifest.tsv' in shader_rows, 'required private shader metadata missing')
        seed = work / 'seed'; seed.mkdir(mode=0o700)
        for name, row in shader_rows.items():
            data = read(args.shader_seed / name); require(sha(data) == row['sha256'], 'shader input changed'); write(seed / name, data)
        seed_manifest = encode({'schema': 1, 'titleID': TITLE, 'chain': chain, 'sourceRomFSSHA256': pins['romfs']['sha256'],
                                'sourceRecipeSHA256': recipe_sha, 'files': shader_rows})
        write(seed / 'seed-manifest.json', seed_manifest)
        header = ['/* Private locally trusted build pins. No public approval. */',
                  f'#define MK_ROMFS_SIZE UINT64_C({pins["romfs"]["size"]})',
                  f'#define MK_ROMFS_SHA256 "{pins["romfs"]["sha256"]}"', f'#define MK_SOURCE_RECIPE_SHA256 "{recipe_sha}"',
                  f'#define MK_SHADER_MANIFEST_SHA256 "{sha(seed_manifest)}"', f'#define MK_SHADER_CHAIN "{chain}"',
                  f'#define MK_NATIVE_MANIFEST_SHA256 "{sha(native_manifest)}"']
        for name in MODULES: header.append(f'#define MK_{name.upper()}_SHA256 "{pins["modules"][name]["sha256"]}"')
        write(work / 'mk8dx_pins.h', ('\n'.join(header) + '\n').encode())
        embedded = work / 'embedded.S'
        linkflags = shlex.split(run([sys.executable, '-S', str(source / 'dm/ios/tools/gen_embed.py'), str(native), str(embedded), *MODULES]))
        require(all(re.fullmatch(r'-Wl,-segprot,__DM(?:main|subsdk0|sdk)W,rw,rw', x) for x in linkflags) and len(linkflags) == 3,
                'unexpected native embedding linker flags')
        gen = work / 'Gen'
        config = run([sys.executable, '-S', str(source / 'dm/ios/tools/gen_build.py'), str(source / 'dm/host'), str(gen)])
        config_lines = dict(line.split(' = ', 1) for line in config.splitlines() if ' = ' in line)
        includes = [x for x in shlex.split(config_lines['HEADER_SEARCH_PATHS']) if x != '$(inherited)']
        defs = [x for x in shlex.split(config_lines['OTHER_CFLAGS']) if x != '$(inherited)']
        require(all(re.fullmatch(r'-D[A-Za-z_][A-Za-z0-9_]*(?:=[A-Za-z0-9_]+)?', x) for x in defs), 'unexpected upstream definition')
        framework_tokens = shlex.split(config_lines['DM_FRAMEWORKS'])
        require(len(framework_tokens) % 2 == 0 and
                all(framework_tokens[i] == '-framework' and framework_tokens[i + 1] in FRAMEWORKS
                    for i in range(0, len(framework_tokens), 2)), 'unexpected original framework graph')
        frameworks = sorted(set(FRAMEWORKS) | set(framework_tokens[1::2]))
        observation['originalBuildConfiguration'] = config_lines

        for name in includes: require(Path(name).is_relative_to(source), 'header directory escapes source snapshot')
        generated_sources = []
        for link in sorted((gen / 'src').iterdir()):
            target = link.resolve(); require(target.is_relative_to(source) and target.suffix in ('.c', '.m', '.S'), 'source graph escapes snapshot')
            generated_sources.append(target)
        main = source / 'dm/host/main.c'
        sources = [appsource / x for x in public.SOURCES] + generated_sources + [main, embedded] + [appsource / 'games/mk8dx/runtime' / x for x in GLUE]
        require(len(sources) == len(set(sources)), 'duplicate source compilation')
        sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']); require(Path(sdk).is_absolute() and '\n' not in sdk, 'invalid SDK')
        app = work / 'Canopy.app'; app.mkdir(mode=0o700)
        catalog = work / 'Assets.xcassets/AppIcon.appiconset'; catalog.mkdir(parents=True)
        write(catalog.parent / 'Contents.json', public.catalog_root()); write(catalog / 'Contents.json', public.icon_catalog())
        for command in public.icon_commands(appsource, work): run(command)
        icons = public.icon_metadata(work / 'icon-info.plist')
        info = plistlib.loads(public.plist(args.bundle_id, icons)); info['MinimumOSVersion'] = '26.0'
        write(app / 'Info.plist', plistlib.dumps(info)); write(app / 'Canopy.png', inputs[public.BRAND])
        resources = app / 'GameData/MK8DX'; resources.mkdir(parents=True, mode=0o700)
        for original, name in (('LICENSE', 'nxnative-MIT.txt'),
                               ('dm/third_party/libvpx/LICENSE', 'libvpx-LICENSE.txt'),
                               ('dm/third_party/libvpx/PATENTS', 'libvpx-PATENTS.txt'),
                               ('dm/third_party/stb_vorbis/LICENSE', 'stb_vorbis-LICENSE.txt'),
                               ('dm/third_party/vulkan-headers/LICENSE.md', 'Vulkan-Headers-LICENSE.txt')):
            write(app / 'CanopyNativeNotices' / name, read(source / original, 1 << 20))
        # Only runtime-consumed rewrite products enter resources. Diagnostic
        # sites/build_src files stay in private build work, never the app tree.
        for name in (*native_files, 'native-manifest.json'): write(resources / 'native' / name, read(native / name))
        for name in (*shader_rows, 'seed-manifest.json'): write(resources / 'shader-seed' / name, read(seed / name))
        common = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk, '-O2', '-Wall', '-Wextra',
                  '-Werror=implicit-function-declaration', '-fno-common', '-DCANOPY_MK8DX_HOST=1', '-I', str(work),
                  '-I', str(appsource / 'launcher/include'), '-I', str(appsource / 'launcher/apple/Sources'),
                  '-I', str(appsource / 'games/mk8dx/runtime'), *sum((['-I', x] for x in includes), []), *defs]
        objects = []
        for i, path in enumerate(sources):
            obj = work / f'object-{i}.o'
            # Keep original host/codec C in its production Clang default GNU
            # dialect; only public Canopy C uses its existing explicit C11 flag.
            flags = ['-fobjc-arc'] if path.suffix == '.m' else ['-std=c11'] if path.suffix == '.c' and path.is_relative_to(appsource) else []
            if path == main: flags += ['-Dmain=nxnative_host_main']
            run([*common, *flags, '-c', str(path), '-o', str(obj)]); objects.append(str(obj))
        run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', sdk, *objects, *linkflags,
             *sum((['-framework', f] for f in frameworks), []), '-lz', '-liconv', '-Wl,-no_adhoc_codesign', '-o', str(app / 'Canopy')])
        observation['appFiles'] = {p.relative_to(app).as_posix(): {'size': p.stat().st_size, 'sha256': sha(read(p, 1 << 30))}
                                   for p in app.rglob('*') if p.is_file()}
        app.rename(args.output / 'Canopy.app'); observation['status'] = 'unsigned private app produced; Apple/device/game acceptance unverified'
    except Exception:
        observation['status'] = 'failed; no accepted artifact'
        raise
    finally:
        record.write_bytes(encode(observation))
    return observation


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan', action='store_true'); p.add_argument('--build', action='store_true')
    p.add_argument('--source-export', type=Path); p.add_argument('--input-manifest', type=Path)
    p.add_argument('--input-manifest-sha256'); p.add_argument('--exefs', type=Path)
    p.add_argument('--python-dependencies', type=Path); p.add_argument('--python-dependencies-manifest', type=Path)
    p.add_argument('--python-dependencies-manifest-sha256')
    p.add_argument('--shader-seed', type=Path); p.add_argument('--output', type=Path)
    p.add_argument('--bundle-id', default='org.monkeorg.canopy')
    a = p.parse_args(); require(a.plan != a.build, 'select --plan or --build')
    if a.build:
        require(all((a.source_export, a.input_manifest, a.input_manifest_sha256, a.exefs, a.shader_seed, a.output, a.python_dependencies, a.python_dependencies_manifest, a.python_dependencies_manifest_sha256)), 'private inputs are required')
        result = build(a)
    else: result = plan()
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError):
        print('Private MK8DX build refused; no accepted artifact.', file=sys.stderr); sys.exit(1)
