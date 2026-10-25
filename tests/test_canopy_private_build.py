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
