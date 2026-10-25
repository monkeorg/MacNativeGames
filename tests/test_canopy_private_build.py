"""Original fixtures validate the private recipe; no game or Apple build claimed."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('private_canopy', ROOT / 'tools/launcher/build_private_canopy.py')
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class CanopyPrivateBuildTests(unittest.TestCase):
    def test_private_icon_uses_public_recipe_without_traversing_game_data(self):
        import plistlib
        from test_canopy_build import CanopyBuildTests
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            app = work / 'private.app';app.mkdir()
            data = app / 'GameData';data.mkdir()
            (data / 'original-fixture').write_bytes(b'unchanged private staging fixture')
            commands = []
            def run(command):
                commands.append(command)
                if '--resampleHeightWidth' in command:
                    Path(command[command.index('--out') + 1]).write_bytes(CanopyBuildTests.synthetic_png(1024, 1024))
                elif '--compile' in command:
                    output = Path(command[command.index('--compile') + 1])
                    (output / 'Assets.car').write_bytes(b'original synthetic catalog')
                    (output / 'AppIcon60x60@2x.png').write_bytes(CanopyBuildTests.synthetic_png(120, 120))
                    primary = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon', 'CFBundleIconFiles': ['AppIcon60x60']}}
                    Path(command[command.index('--output-partial-info-plist') + 1]).write_bytes(
                        plistlib.dumps({'CFBundleIcons': primary, 'CFBundleIcons~ipad': primary}))
                return 'synthetic tool version'
            icons, report = BUILDER.package_app_icon(ROOT, work, app, run)
            self.assertEqual(report['sourceSHA256'], BUILDER.PUBLIC.BRAND_SHA256)
            self.assertEqual(report['generatedSHA256'], sha(CanopyBuildTests.synthetic_png(1024, 1024)))
            self.assertEqual({p.name for p in app.iterdir()}, {'GameData', 'Assets.car', 'AppIcon60x60@2x.png'})
            self.assertEqual((data / 'original-fixture').read_bytes(), b'unchanged private staging fixture')
            self.assertEqual(icons['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'], 'AppIcon')
            self.assertEqual(commands[-2:], BUILDER.PUBLIC.icon_commands(ROOT, work / 'app-icon'))

    def test_private_icon_derivation_failure_keeps_existing_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve();app = work / 'private.app';app.mkdir()
            original = app / 'original-fixture';original.write_bytes(b'preserve')
            def run(command):
                if '--resampleHeightWidth' in command:
                    raise RuntimeError('synthetic tool failure')
                return 'synthetic tool version'
            with self.assertRaisesRegex(RuntimeError, 'synthetic tool failure'):
                BUILDER.package_app_icon(ROOT, work, app, run)
            self.assertEqual({p.name for p in app.iterdir()}, {'original-fixture'})
            self.assertEqual(original.read_bytes(), b'preserve')

    def test_display_opt_in_is_v143_only_and_plan_does_not_invent_pins(self):
        stock = BUILDER.build_plan(version='v143')
        plan = BUILDER.build_plan(version='v143', display_settings=True)
        self.assertNotIn('displaySettings', stock)
        display = plan['displaySettings']
        self.assertEqual(display['maximumScene'], '1920x1080')
        self.assertEqual(display['aspectLayout'], '1440x1080')
        self.assertEqual(display['exporterEnvironment'], BUILDER.DISPLAY_EXPORT)
        self.assertIn('unavailable', display['manifestPins'])
        with self.assertRaisesRegex(ValueError, 'only TOTK1.4.3'):
            BUILDER.build_plan(version='v121', display_settings=True)
        with mock.patch.object(BUILDER, 'expected_profile', side_effect=AssertionError('private/profile access')):
            with self.assertRaisesRegex(ValueError, 'only TOTK1.4.3'):
                BUILDER.build(argparse.Namespace(version='v121', display_settings=True))
        run = subprocess.run([sys.executable, str(ROOT / 'tools/launcher/build_private_canopy.py'),
                              '--plan', '--version', 'v121', '--display-settings'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(run.returncode, 0);self.assertIn('only TOTK1.4.3', run.stderr)

    def test_display_exporter_and_compiler_use_exact_explicit_profile(self):
        self.assertEqual(BUILDER.exporter_environment(Path('/original-modules')), {'TOTK_EXPORT_IOS': '/original-modules'})
        enabled = BUILDER.exporter_environment(Path('/original-modules'), True)
        self.assertEqual(enabled, {'TOTK_EXPORT_IOS': '/original-modules',
            'TOTK_IOS_DISPLAY_SETTINGS': '1', 'TOTK_RENDER_RES': '1280x720', 'TOTK_OUTPUT_RES': '1280x720',
            'TOTK_FIXED_RES': '1', 'TOTK_ASPECT': '0', 'TOTK_ASPECT_VERT': '1', 'TOTK_IOS_ASPECT_VERT': '1'})
        profile = BUILDER.expected_profile(ROOT, 'v143')
        args = (ROOT, Path('/private-stage'), {'clang': 'selected-clang', 'sdk': '/selected-sdk'},
                'v143', profile, 'a' * 64, Path('/local-codecs'))
        stock, _ = BUILDER.compiler_commands(*args)
        pins = {'heapManifestSHA256': 'b' * 64, 'layoutManifestSHA256': 'c' * 64}
        enabled, _ = BUILDER.compiler_commands(*args, display_profile=pins)
        self.assertFalse(any('TOTK_IOS_DISPLAY_SETTINGS' in arg for command in stock for arg in command))
        for command in enabled:
            self.assertIn('-DTOTK_IOS_DISPLAY_SETTINGS=1', command)
            self.assertIn('-DTOTK_IOS_ASPECT_VERT=1', command)
            self.assertIn('-DCANOPY_HOST_DISPLAY_HEAP_SHA256="' + 'b' * 64 + '"', command)
            self.assertIn('-DCANOPY_HOST_DISPLAY_LAYOUT_SHA256="' + 'c' * 64 + '"', command)
        with self.assertRaises(ValueError):
            BUILDER.compiler_commands(*args, display_profile={'heapManifestSHA256': 'invented'})
        with self.assertRaises(ValueError):
            BUILDER.compiler_commands(*args[:3], 'v121', *args[4:], display_profile=pins)

    def display_fixture(self, root, fault=None):
        """Synthetic orchestration outputs, not a run of private generators.

        The production runner executes the existing generators. These original
        byte fixtures test command routing and the real post-generation verifier.
        """
        stage = root / 'source';data = root / 'GameData'
        (data / 'romfs-patches-out').mkdir(parents=True, mode=0o700)
        source = stage / 'extracted/v143/romfs';source.mkdir(parents=True)
        heap_name = 'System/HeapSize/original.byml.zs';layout_name = 'UI/LayoutArchive/original.blarc.zs'
        originals = {heap_name: b'original heap fixture', layout_name: b'original layout fixture'}
        image = bytearray();files = []
        for name, content in originals.items():
            files.append({'path': name, 'offset': len(image), 'size': len(content)});image += content
        (source / 'romfs.bin').write_bytes(image)
        (source / 'index.json').write_text(json.dumps({'files': files}))
        scripts = stage / 'scripts';scripts.mkdir()
        for name in ('make_output_res_overlay.py', 'make_romfs_patches.py', 'tall_layout.py'):
            (scripts / name).write_bytes(('original public test tool fixture ' + name).encode())
        calls = []
        def runner(command):
            calls.append(command)
            if 'make_output_res_overlay.py' in command[1]:
                folder = data / BUILDER.DISPLAY_HEAP;name = heap_name
            else:
                folder = data / BUILDER.DISPLAY_LAYOUT;name = layout_name
            content = ('generated synthetic ' + name).encode()
            target = folder / name;target.parent.mkdir(parents=True);target.write_bytes(content)
            (folder / 'manifest.tsv').write_text('# Original synthetic fixture\n' +
                '\t'.join((name, str(len(content)), sha(content), sha(originals[name]))) + '\n')
            if folder.name == '1920x1080-scene-1920x1080':
                (folder / 'overlay.json').write_text(json.dumps({'script': 'make_output_res_overlay.py',
                    'script_sha256': sha((scripts / 'make_output_res_overlay.py').read_bytes()),
                    'version': 'v143', 'size': '1920x1080', 'scene': '1920x1080', 'extra_kib': 1,
                    'heapdef': None, 'heapdef_sha256': None}))
            elif fault:
                fault(folder, target, source)
        return stage, data, calls, runner

    def test_display_generation_runs_staged_tools_and_pins_exact_validated_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            stage, data, calls, runner = self.display_fixture(Path(directory).resolve())
            original = (stage / 'extracted/v143/romfs/romfs.bin').read_bytes()
            result = BUILDER.generate_display_resources(stage, data, runner)
            self.assertEqual(calls[0], [sys.executable, str(stage / 'scripts/make_output_res_overlay.py'),
                '1920x1080', '--scene', '1920x1080', '--version', 'v143', '--output-root', str(data / 'romfs-patches-out')])
            self.assertEqual(calls[1], [sys.executable, str(stage / 'scripts/make_romfs_patches.py'),
                '--version', 'v143', '--aspect', '1440x1080', '--output-dir', str(data / BUILDER.DISPLAY_LAYOUT)])
            for key, folder in [('heapManifestSHA256', BUILDER.DISPLAY_HEAP), ('layoutManifestSHA256', BUILDER.DISPLAY_LAYOUT)]:
                self.assertEqual(result[key], sha((data / folder / 'manifest.tsv').read_bytes()))
            self.assertEqual(result['generatorSHA256']['scripts/tall_layout.py'], sha((stage / 'scripts/tall_layout.py').read_bytes()))
            self.assertEqual((stage / 'extracted/v143/romfs/romfs.bin').read_bytes(), original)

    def test_display_app_tree_omits_generator_metadata_but_private_proof_keeps_it(self):
        with tempfile.TemporaryDirectory() as directory:
            stage, data, _, runner = self.display_fixture(Path(directory).resolve())
            metadata = {}
            def observe(command):
                runner(command)
                path = data / BUILDER.DISPLAY_HEAP / 'overlay.json'
                if path.exists():
                    metadata['bytes'] = path.read_bytes()
            result = BUILDER.generate_display_resources(stage, data, observe)
            heap = data / BUILDER.DISPLAY_HEAP
            self.assertFalse((heap / 'overlay.json').exists())
            self.assertEqual(result['heap']['overlayMetadataSHA256'], sha(metadata['bytes']))
            self.assertEqual(result['heap']['overlayMetadata'], json.loads(metadata['bytes']))
            self.assertEqual(result['heap']['generatedTreeBytes'], result['heap']['treeBytes'] + len(metadata['bytes']))
            self.assertEqual({str(p.relative_to(heap)) for p in heap.rglob('*') if p.is_file()},
                             {'manifest.tsv', *result['heap']['members']})

    def test_display_resource_verifier_rejects_tampering_links_extras_ranges_and_aliases(self):
        def corrupt(folder, target, source): target.write_bytes(b'changed')
        def extra(folder, target, source): (folder / 'unexpected').write_bytes(b'keep')
        def extra_directory(folder, target, source): (folder / 'unexpected-directory').mkdir()
        def linked(folder, target, source):
            content = target.read_bytes();target.unlink();outside = source / 'outside';outside.write_bytes(content);target.symlink_to(outside)
        def hardlinked(folder, target, source):
            import os
            os.link(target, source / 'external-hardlink')
        def bad_original(folder, target, source):
            file = folder / 'manifest.tsv';text = file.read_text();file.write_text(text.rsplit('\t', 1)[0] + '\t' + '0' * 64 + '\n')
        def alias(folder, target, source):
            file = folder / 'manifest.tsv';file.write_text(file.read_text() + file.read_text().splitlines()[-1] + '\n')
        def traversal(folder, target, source):
            file = folder / 'manifest.tsv';file.write_text(file.read_text().replace('UI/LayoutArchive/original.blarc.zs', '../outside'))
        def bad_range(folder, target, source):
            file = source / 'index.json';value = json.loads(file.read_bytes());value['files'][1]['offset'] = 1 << 63;file.write_text(json.dumps(value))
        def wrong_metadata(folder, target, source):
            metadata = folder.parent / BUILDER.DISPLAY_HEAP / 'overlay.json'
            value = json.loads(metadata.read_bytes());value['heapdef'] = '/unreviewed replacement';metadata.write_text(json.dumps(value))
        def oversize(folder, target, source):
            manifest = folder / 'manifest.tsv';fields = manifest.read_text().splitlines()[-1].split('\t');fields[1] = str((64 << 20) + 1)
            manifest.write_text('\t'.join(fields) + '\n')
        for failure in (corrupt, extra, extra_directory, linked, hardlinked, bad_original, alias, traversal, bad_range, wrong_metadata, oversize):
            with self.subTest(failure=failure.__name__), tempfile.TemporaryDirectory() as directory:
                stage, data, _, runner = self.display_fixture(Path(directory).resolve(), failure)
                with self.assertRaises((ValueError, OSError)):
                    BUILDER.generate_display_resources(stage, data, runner)

    def test_portable_plans_bind_exact_public_profiles_and_canopy_entry(self):
        for version in ('v121', 'v143'):
            plan = BUILDER.build_plan(version=version)
            expected = BUILDER.expected_profile(ROOT, version)
            self.assertEqual(plan['originalMainSHA256'], expected['exefs_sha256']['main'])
            self.assertEqual(plan['romfsSHA256'], expected['romfs']['sha256'])
            self.assertEqual(plan['titleID'], '0100f2c0115b6000')
            self.assertEqual(plan['entry'], 'launcher/apple/Sources/CanopyApp.m')
            self.assertNotIn('games/totk/ios/Sources/main.m', plan['sources'])
            self.assertNotIn('games/totk/runtime/frontend.m', plan['sources'])
            patch = 'game_patches_v143.c' if version == 'v143' else 'game_patches.c'
            other = 'game_patches.c' if version == 'v143' else 'game_patches_v143.c'
            self.assertIn('games/totk/runtime/' + patch, plan['sources'])
            self.assertNotIn('games/totk/runtime/' + other, plan['sources'])
            self.assertEqual(plan['signing'], 'none')
        with self.assertRaises(ValueError):
            BUILDER.build_plan(version='arbitrary')
        with self.assertRaises(ValueError):
            BUILDER.build_plan(identifier='org.example.totk')

    def test_loader_rename_is_per_source_and_pins_are_separate(self):
        profile = BUILDER.expected_profile(ROOT, 'v121')
        commands, objects = BUILDER.compiler_commands(ROOT, Path('/private-stage'),
            {'clang': 'selected-apple-clang', 'sdk': '/selected-sdk'}, 'v121', profile, 'a' * 64, Path('/local-codecs'))
        renamed = [c for c in commands if '-Dmain=totk_host_main' in c]
        self.assertEqual(len(renamed), 1)
        self.assertEqual(renamed[0][renamed[0].index('-c') + 1], str(ROOT / 'games/totk/runtime/loader.c'))
        self.assertEqual(len(objects), len(commands))
        self.assertTrue(any(str(ROOT / 'launcher/apple/Sources/CanopyApp.m') in c for c in commands))
        self.assertTrue(all('-DCANOPY_HOST_RUNTIME=1' in c for c in commands))
        self.assertTrue(all('-DCANOPY_HOST_ORIGINAL_MAIN_SHA256="' + profile['exefs_sha256']['main'] + '"' in c for c in commands))
        self.assertTrue(all('-DCANOPY_HOST_SHADER_SEED_MANIFEST_SHA256="' + 'a' * 64 + '"' in c for c in commands))
        self.assertFalse(any(any('codesign' in part or 'install_device' in part for part in c) for c in commands))

    def test_stable_regular_private_copy_refuses_mismatch_links_and_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve();source = root / 'original';output = root / 'copy'
            source.write_bytes(b'original source fixture')
            self.assertEqual(BUILDER.digest(source, output, sha(source.read_bytes())), sha(source.read_bytes()))
            self.assertEqual(output.read_bytes(), source.read_bytes())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                BUILDER.digest(source, output)
            with self.assertRaises(ValueError):
                BUILDER.digest(source, expected='0' * 64)
            with self.assertRaises(ValueError):
                BUILDER.digest(root)
            linked = root / 'linked';linked.symlink_to(source)
            with self.assertRaises(ValueError):
                BUILDER.digest(linked)
            ancestor = root / 'ancestor';ancestor.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                BUILDER.digest(ancestor / 'original')
            self.assertEqual(source.read_bytes(), b'original source fixture')

    def make_retained_fixture(self, root):
        """Synthetic expected table passed directly to the internal copy verifier.

        CLI profile selection has no expected-table override and always loads
        checked-in real identities. These invented bytes cannot select a title.
        """
        version = 'v121';profile = {'exefs_sha256': {}, 'rewritten_sha256': {}, 'shared_fonts_sha256': {}}
        hashes = {}
        def write(name, data):
            path = root / name;path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(data)
            return sha(data)
        for name in ('main', 'subsdk0', 'sdk'):
            key = f'extracted/{version}/exefs/{name}';hashes[key] = write(key, ('invented original ' + name).encode())
            profile['exefs_sha256'][name] = hashes[key]
            key = f'rewritten/{version}/{name}.patched.bin';hashes[key] = write(key, ('invented rewritten ' + name).encode())
            profile['rewritten_sha256'][name + '.patched.bin'] = hashes[key]
            write(f'rewritten/{version}/{name}.fixups.tsv', b'original fixture metadata')
            write(f'rewritten/{version}/{name}.gates.tsv', b'original fixture gate metadata')
            write(f'extracted/{version}/elf/{name}-inventory.json', b'{}')
        report = {'status': 'pass', 'rom_version': version, 'module_file_sha256': hashes}
        write(f'analysis/{version}-port/phase12-validation.json', json.dumps(report).encode())
        image = b'invented original RomFS';profile['romfs'] = {'sha256': sha(image), 'size': len(image)}
        write(f'extracted/{version}/romfs/romfs.bin', image)
        write(f'extracted/{version}/romfs/index.json', json.dumps({'status': 'pass', 'romfs_sha256': sha(image), 'romfs_size': len(image)}).encode())
        fonts = []
        for i in range(6):
            name = f'fixture-{i}';data = ('invented font ' + name).encode();profile['shared_fonts_sha256'][name] = sha(data)
            fonts.append({'type': i, 'name': name, 'sha256': sha(data)})
            write(f'extracted/firmware/shared-fonts/{i}-{name}.bfttf', data)
        write('extracted/firmware/shared-fonts/manifest.json', json.dumps({'status': 'pass', 'fonts': fonts}).encode())
        return profile

    def test_retained_handoff_checks_actual_bytes_without_changing_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve();tree = root / 'retained';stage = root / 'staged'
            profile = self.make_retained_fixture(tree)
            before = {str(p.relative_to(tree)): p.read_bytes() for p in tree.rglob('*') if p.is_file()}
            records = BUILDER.stage_inputs(tree, stage, 'v121', profile)
            self.assertEqual(set(records), set(before))
            self.assertEqual({name: (stage / name).read_bytes() for name in records}, before)
            self.assertEqual({str(p.relative_to(tree)): p.read_bytes() for p in tree.rglob('*') if p.is_file()}, before)

    def test_retained_handoff_rejects_original_rewrite_romfs_font_and_report_changes(self):
        members = ('extracted/v121/exefs/main', 'rewritten/v121/main.patched.bin',
                   'extracted/v121/romfs/romfs.bin', 'extracted/firmware/shared-fonts/0-fixture-0.bfttf',
                   'analysis/v121-port/phase12-validation.json')
        for member in members:
            with self.subTest(member=member), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve();tree = root / 'retained';profile = self.make_retained_fixture(tree)
                path = tree / member
                if member.endswith('.json'):
                    report = json.loads(path.read_bytes());report['status'] = 'failed';path.write_text(json.dumps(report))
                else:
                    path.write_bytes(b'changed bytes')
                with self.assertRaises(ValueError):
                    BUILDER.stage_inputs(tree, root / 'staged', 'v121', profile)

    def test_explicit_shader_pin_authenticates_seed_and_map(self):
        from test_canopy_shader_cache import write_shader_seed
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve();source = root / 'source';romfs = sha(b'original fixture RomFS')
            pin = write_shader_seed(source, romfs)
            from test_canopy_shader_cache import CHAIN
            BUILDER.stage_seed(source, root / 'output', pin, romfs, CHAIN)
            self.assertEqual((source / 'shader_map.tsv').read_bytes(), (root / 'output/shader_map.tsv').read_bytes())
            with self.assertRaises(ValueError):
                BUILDER.stage_seed(source, root / 'bad-pin', '0' * 64, romfs, CHAIN)
            with self.assertRaises(ValueError):
                BUILDER.stage_seed(source, root / 'bad-source', pin, '0' * 64, CHAIN)
            (source / 'shader_map.tsv').write_bytes(b'changed mapping')
            with self.assertRaises(ValueError):
                BUILDER.stage_seed(source, root / 'bad-map', pin, romfs, CHAIN)

    def test_seed_parses_only_verified_staged_manifest_after_source_replacement(self):
        from test_canopy_shader_cache import write_shader_seed, CHAIN
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve();source = root / 'source';romfs = sha(b'original fixture RomFS')
            pin = write_shader_seed(source, romfs);original = BUILDER.digest
            def copy_then_replace(path, destination=None, expected=None, limit=64 << 30):
                result = original(path, destination, expected, limit)
                if Path(path) == source / 'seed-manifest.json':
                    replaced = json.loads(Path(path).read_bytes())
                    replaced['files'] = {'unverified-replacement.json': sha(b'unverified')}
                    Path(path).write_text(json.dumps(replaced))
                return result
            with mock.patch.object(BUILDER, 'digest', side_effect=copy_then_replace):
                BUILDER.stage_seed(source, root / 'output', pin, romfs, CHAIN)
            self.assertEqual(sha((root / 'output/seed-manifest.json').read_bytes()), pin)
            self.assertTrue(list((root / 'output').glob('*_b.metal')))
            self.assertFalse((root / 'output/unverified-replacement.json').exists())

    def test_codec_headers_and_libraries_are_private_stable_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve();source = root / 'codecs';output = root / 'snapshot'
            members = ('include/opus/opus.h', 'include/vpx/vpx_decoder.h', 'lib/libopus.a', 'lib/libvpx.a')
            for name in members:
                path = source / name;path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(('original fixture ' + name).encode())
            records = BUILDER.stage_codecs(source, output)
            self.assertEqual(set(records), set(members))
            before = {name: (output / name).read_bytes() for name in members}
            for name in members:
                (source / name).write_bytes(b'changed external input')
            self.assertEqual({name: (output / name).read_bytes() for name in members}, before)
            (source / 'include/linked').symlink_to(source / 'include/opus', target_is_directory=True)
            with self.assertRaises(ValueError):
                BUILDER.stage_codecs(source, root / 'linked-snapshot')

    def test_portable_cli_does_not_assume_private_inputs(self):
        run = subprocess.run([sys.executable, str(ROOT / 'tools/launcher/build_private_canopy.py'), '--plan', '--version', 'v121'],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(run.stdout)['status'], 'plan only; no private inputs or Apple compilation used')
        if sys.platform != 'darwin':
            with self.assertRaisesRegex(ValueError, 'Apple silicon Mac'):
                BUILDER.build(argparse.Namespace())


if __name__ == '__main__':
    unittest.main()
