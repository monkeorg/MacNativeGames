"""Portable recipe/orchestration tests; fake compiler output is not Apple evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import struct
import zlib
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('canopy_build', ROOT / 'tools/launcher/build_canopy.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class CanopyBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # macOS /var is a symlink to /private/var. Match the builder's required
        # canonical output ancestry without weakening its symlink safeguard.
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        for name in builder.INPUTS:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'synthetic public input')
        (self.repo / builder.BRAND).write_bytes((ROOT / builder.BRAND).read_bytes())
        self.output = self.root / 'output'
        self.executed = []

    @staticmethod
    def synthetic_png(width, height):
        # Entirely invented command-runner output; not an Apple/branding result.
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        pixels = (b'\0' + b'\x22\x44\x66\xff' * width) * height
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
                chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))

    def fake_runner(self, command):
        self.executed.append(command)
        if command[-1] == '--show-sdk-path':
            stdout = '/synthetic/iPhoneOS.sdk\n'
        elif command[-1] == '--show-sdk-version':
            stdout = 'synthetic-sdk-version\n'
        elif command[-1] == '--version':
            stdout = 'synthetic-tool-version\n'
        elif '--resampleHeightWidth' in command:
            target = Path(command[command.index('--out') + 1])
            target.write_bytes(self.synthetic_png(1024, 1024));stdout = ''
        elif 'actool' in command and '--compile' in command:
            app = Path(command[command.index('--compile') + 1])
            (app / 'Assets.car').write_bytes(b'synthetic compiled catalog; not Apple evidence')
            (app / 'AppIcon60x60@2x.png').write_bytes(self.synthetic_png(120, 120))
            (app / 'AppIcon76x76@2x~ipad.png').write_bytes(self.synthetic_png(152, 152))
            partial = Path(command[command.index('--output-partial-info-plist') + 1])
            partial.write_bytes(plistlib.dumps({
                'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon', 'CFBundleIconFiles': ['AppIcon60x60']}},
                'CFBundleIcons~ipad': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon', 'CFBundleIconFiles': ['AppIcon76x76']}}}))
            stdout = ''
        else:
            stdout = ''
            target = Path(command[command.index('-o') + 1])
            target.write_bytes(b'synthetic object, not an Apple executable')
        return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr='')

    def test_plan_is_fixed_public_host_only_and_does_not_run_apple(self):
        plan = builder.build_plan(self.repo)
        self.assertEqual(plan['status'], 'plan only; Apple compilation not performed')
        self.assertEqual(plan['bundle_identifier'], 'org.monkeorg.canopy')
        self.assertEqual(set(row['path'] for row in plan['input_files']), set(builder.INPUTS))
        command_text = json.dumps(plan['commands'])
        self.assertIn('arm64-apple-ios16.0', command_text)
        self.assertIn('UniformTypeIdentifiers', command_text)
        self.assertEqual([name for name in builder.SOURCES if name.startswith('games/')],
                         ['games/totk/ios/Sources/save_validation.m'])
        self.assertNotIn('games/totk/runtime/canopy_host.m', command_text)
        self.assertIn('Metal', command_text)
        self.assertIn('QuartzCore', command_text)
        self.assertNotIn('gen_embed', command_text)
        self.assertNotIn('codesign', ' '.join(plan['commands'][0]))
        self.assertFalse(self.output.exists())

    def test_custom_identifiers_require_canopy_suffix(self):
        for value in ('org.macnativegames.totk', 'org.monkeorg.Canopy', 'canopy',
                      'org..canopy', 'org/canopy', 'x.canopy;echo bad'):
            with self.subTest(value=value), self.assertRaises(builder.BuildError):
                builder.build_plan(self.repo, value)
        self.assertEqual(builder.build_plan(self.repo, 'org.example.canopy')['bundle_identifier'],
                         'org.example.canopy')

    def test_fake_compiler_orchestration_records_unreviewed_observation(self):
        # This validates file handling and the recipe, never actual Apple compilation.
        report = builder.build(self.repo, self.output, runner=self.fake_runner)
        self.assertIn('pending', report['status'])
        self.assertEqual(report['provenance_review'], 'unreviewed build observation')
        app = self.output / 'Canopy.app'
        self.assertEqual({p.name for p in app.iterdir()}, {'Canopy', 'Canopy.png', 'Info.plist', 'Assets.car',
                                                              'AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png'})
        self.assertEqual((app / 'Canopy.png').read_bytes(), (self.repo / builder.BRAND).read_bytes())
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'org.monkeorg.canopy')
        self.assertEqual(info['MinimumOSVersion'], '16.0')
        self.assertEqual(info['UIApplicationSceneManifest'],
                         {'UIApplicationSupportsMultipleScenes': False})
        self.assertEqual(info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'], 'AppIcon')
        self.assertEqual(info['CFBundleIcons~ipad']['CFBundlePrimaryIcon']['CFBundleIconName'], 'AppIcon')
        self.assertEqual(json.loads((self.output / 'build-observation.json').read_text()), report)
        self.assertEqual(len(report['commands']), len(builder.SOURCES) + 8)
        self.assertFalse(any(p.name.startswith('.canopy-stage-') for p in self.output.iterdir()))
        output_hashes = {row['path']: row['sha256'] for row in report['output_files']}
        self.assertEqual(output_hashes['Canopy'], hashlib.sha256((app / 'Canopy').read_bytes()).hexdigest())
        self.assertEqual({row['path'] for row in report['app_icon']['compiled_files']},
                         {'Assets.car', 'AppIcon60x60@2x.png', 'AppIcon76x76@2x~ipad.png'})
        self.assertEqual(report['app_icon']['source_dimensions'], [1254, 1254])
        self.assertEqual(report['app_icon']['generated_dimensions'], [1024, 1024])
        self.assertEqual(report['app_icon']['generated_sha256'], hashlib.sha256(self.synthetic_png(1024, 1024)).hexdigest())

    def test_icon_plan_records_exact_tools_and_no_invented_generated_hash(self):
        plan = builder.build_plan(self.repo)
        self.assertEqual(plan['app_icon']['source_sha256'], builder.BRAND_SHA256)
        self.assertEqual(plan['app_icon']['source_dimensions'], [1254, 1254])
        self.assertEqual(plan['app_icon']['generated_dimensions'], [1024, 1024])
        self.assertIsNone(plan['app_icon']['generated_sha256'])
        self.assertEqual(plan['commands'][0][:4], ['/usr/bin/sips', '--resampleHeightWidth', '1024', '1024'])
        self.assertEqual(plan['commands'][1][:4], ['xcrun', '--sdk', 'iphoneos', 'actool'])
        self.assertIn('--output-partial-info-plist', plan['commands'][1])
        self.assertIn('--app-icon', plan['commands'][1])
        self.assertIn('launcher/src/mng_display.c', builder.SOURCES)
        self.assertIn('launcher/include/mng_display.h', builder.HEADERS)

    def test_wrong_derivative_geometry_prevents_asset_compilation_and_publication(self):
        def wrong_size(command):
            result = self.fake_runner(command)
            if '--resampleHeightWidth' in command:
                Path(command[command.index('--out') + 1]).write_bytes(self.synthetic_png(512, 512))
            return result
        with self.assertRaisesRegex(builder.BuildError, '1024x1024'):
            builder.build(self.repo, self.output, runner=wrong_size)
        self.assertFalse(any('actool' in c and '--compile' in c for c in self.executed))
        self.assertFalse((self.output / 'Canopy.app').exists())

    def test_asset_metadata_cannot_replace_bundle_identity(self):
        def wrong_info(command):
            result = self.fake_runner(command)
            if 'actool' in command and '--compile' in command:
                partial = Path(command[command.index('--output-partial-info-plist') + 1])
                metadata = plistlib.loads(partial.read_bytes());metadata['CFBundleIdentifier'] = 'org.example.other'
                partial.write_bytes(plistlib.dumps(metadata))
            return result
        with self.assertRaisesRegex(builder.BuildError, 'metadata keys'):
            builder.build(self.repo, self.output, runner=wrong_info)
        self.assertFalse((self.output / 'Canopy.app').exists())

    def test_unlisted_asset_output_cannot_be_published(self):
        def extra_output(command):
            result = self.fake_runner(command)
            if 'actool' in command and '--compile' in command:
                (Path(command[command.index('--compile') + 1]) / 'unlisted.bin').write_bytes(b'extra')
            return result
        with self.assertRaisesRegex(builder.BuildError, 'unexpected application output'):
            builder.build(self.repo, self.output, runner=extra_output)
        self.assertFalse((self.output / 'Canopy.app').exists())

    def test_generated_asset_inputs_and_outputs_remain_stable_through_compile(self):
        for target in ('input', 'output'):
            with self.subTest(target=target):
                output = self.root / ('unstable-' + target)
                def mutate(command):
                    result = self.fake_runner(command)
                    if '-c' in command:
                        work = Path(command[command.index('-o') + 1]).parent
                        path = work / ('Assets.xcassets/AppIcon.appiconset/Canopy-1024.png' if target == 'input' else 'Canopy.app/Assets.car')
                        path.write_bytes(b'changed during compile')
                    return result
                with self.assertRaisesRegex(builder.BuildError, 'changed during build'):
                    builder.build(self.repo, output, runner=mutate)
                self.assertFalse((output / 'Canopy.app').exists())

    def test_asset_compiler_failure_never_publishes_app(self):
        def fail(command):
            if 'actool' in command and '--compile' in command:
                raise subprocess.CalledProcessError(1, command, stderr='synthetic asset failure')
            return self.fake_runner(command)
        with self.assertRaises(subprocess.CalledProcessError):
            builder.build(self.repo, self.output, runner=fail)
        self.assertFalse((self.output / 'Canopy.app').exists())
        self.assertEqual((self.repo / builder.BRAND).read_bytes(), (ROOT / builder.BRAND).read_bytes())

    def test_existing_output_never_overwritten_or_compiled(self):
        self.output.mkdir()
        marker = self.output / 'marker'
        marker.write_text('preserve')
        with self.assertRaisesRegex(builder.BuildError, 'already exists'):
            builder.build(self.repo, self.output, runner=self.fake_runner)
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertEqual(self.executed, [])

    def test_changed_brand_and_symlinked_source_fail_before_output(self):
        brand = self.repo / builder.BRAND
        original = brand.read_bytes()
        brand.write_bytes(b'changed')
        with self.assertRaisesRegex(builder.BuildError, 'branding'):
            builder.build(self.repo, self.output, runner=self.fake_runner)
        self.assertFalse(self.output.exists())
        brand.write_bytes(original)
        source = self.repo / builder.SOURCES[0]
        source.unlink()
        source.symlink_to(self.repo / builder.SOURCES[1])
        with self.assertRaisesRegex(builder.BuildError, 'linked'):
            builder.build(self.repo, self.output, runner=self.fake_runner)
        self.assertFalse(self.output.exists())

    def test_source_change_during_compile_rejects_artifact(self):
        def mutate(command):
            result = self.fake_runner(command)
            if '-c' in command:
                (self.repo / builder.SOURCES[0]).write_bytes(b'changed during compile')
            return result
        with self.assertRaisesRegex(builder.BuildError, 'repository inputs changed'):
            builder.build(self.repo, self.output, runner=mutate)
        self.assertFalse((self.output / 'Canopy.app').exists())
        self.assertEqual(json.loads((self.output / 'build-observation.json').read_text())['status'],
                         'failed; no artifact accepted')

    def test_staged_source_change_rejects_artifact(self):
        def mutate(command):
            result = self.fake_runner(command)
            if '-c' in command:
                Path(command[command.index('-c') + 1]).write_bytes(b'changed staged input')
            return result
        with self.assertRaisesRegex(builder.BuildError, 'staged inputs changed'):
            builder.build(self.repo, self.output, runner=mutate)
        self.assertFalse((self.output / 'Canopy.app').exists())

    def test_compiler_failure_does_not_publish_app(self):
        def fail(command):
            raise subprocess.CalledProcessError(1, command, stderr='synthetic failure')
        with self.assertRaises(subprocess.CalledProcessError):
            builder.build(self.repo, self.output, runner=fail)
        self.assertFalse((self.output / 'Canopy.app').exists())
        self.assertTrue((self.output / 'build-observation.json').exists())

    def test_output_symlink_and_missing_parent_rejected(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.repo, target_is_directory=True)
        with self.assertRaises(builder.BuildError):
            builder.build(self.repo, alias / 'new-build', runner=self.fake_runner)
        with self.assertRaises(builder.BuildError):
            builder.build(self.repo, self.root / 'missing' / 'new-build', runner=self.fake_runner)
        self.assertEqual(self.executed, [])


if __name__ == '__main__':
    unittest.main()
