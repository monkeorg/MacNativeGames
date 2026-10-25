"""Execute the actual seed consumer's guarded private read-in-place path."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NVN = ROOT / 'games/totk/third_party/d2r_gfx/gfx/nvn'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'actual native shader-seed consumer requires macOS Foundation')
class CanopyShaderInPlaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name).resolve()
        cls.probes = {}
        for flagged in (False, True):
            output = cls.root / ('canopy-consumer' if flagged else 'default-consumer')
            command = ['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                       '-Wno-deprecated-declarations', '-I', str(NVN),
                       str(ROOT / 'tests/canopy_shader_inplace_probe.m'),
                       '-framework', 'Foundation', '-o', str(output)]
            if flagged:
                command += ['-DCANOPY_HOST_RUNTIME=1', '-framework', 'Security']
            run = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if run.returncode:
                raise AssertionError(run.stdout + run.stderr)
            cls.probes[flagged] = output

    def scenario(self, flagged, mode='trusted', force=False):
        from test_canopy_shader_cache import write_shader_seed, CHAIN
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            root = Path(directory)
            source = root / 'private-seed'
            write_shader_seed(source, 'ab' * 32, CHAIN)
            cache = root / 'mutable-cache'
            cache.mkdir(mode=0o700)
            # Preserve consumer-owned private directory and avoid a clone-folder
            # path in the standalone regression case, matching actual integration.
            (cache / '.canopy-private-cache').write_bytes(b'')
            source_before = {p.name: (p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes())
                             for p in source.iterdir()}
            run = subprocess.run([str(self.probes[flagged]), mode, str(source), str(cache)],
                                 env={**os.environ, 'TOTK_SHADER_SEED_IN_PLACE': '1' if force else '0'},
                                 capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            report = json.loads(run.stdout)
            self.assertEqual(source_before, {p.name: (p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes())
                                            for p in source.iterdir()})
            self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
            if flagged and mode == 'trusted':
                self.assertIs(report['verifiedPrivate'], True)
                self.assertIs(report['readInPlace'], True)
                self.assertIs(report['sealed'], False)
                self.assertEqual(report['imported_files'], 0)
                self.assertEqual(report['fixture_digest_calls'], 1)  # Metadata fingerprint only.
                self.assertEqual({p.name for p in cache.iterdir()}, {'.canopy-private-cache'})
            else:
                self.assertGreater(report['imported_files'], 0)
                self.assertGreater(report['fixture_digest_calls'], 1)
                self.assertFalse(report.get('verifiedPrivate', False))
                self.assertFalse(report.get('sealed', False))
            return report

    def test_verified_private_source_is_not_rehashed_copied_or_called_signed(self):
        self.scenario(True)

    def test_unattested_private_source_uses_normal_verified_import(self):
        self.scenario(True, 'untrusted')

    def test_environment_override_does_not_claim_documents_are_signed(self):
        self.scenario(True, 'untrusted', force=True)

    def test_standalone_import_behavior_is_preserved(self):
        self.scenario(False)

    def test_guarded_renderer_source_compiles_with_actual_iphoneos_sdk(self):
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        sdk_version = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
        sdk_major = int(sdk_version.split('.')[0])
        target = 'arm64-apple-ios26.0' if sdk_major >= 26 else 'arm64-apple-ios18.0'
        for source in ('totk_shader_rt.m', 'nvn_mtl.m'):
            for flagged in (False, True):
                with self.subTest(source=source, canopy=flagged):
                    if source == 'nvn_mtl.m' and sdk_major < 26:
                        self.skipTest(f'Private Metal4 renderer requires iPhoneOS SDK26; available {sdk_version}')
                    command = ['xcrun', '--sdk', 'iphoneos', 'clang', '-fobjc-arc', '-fblocks', '-fsyntax-only',
                               '-target', target, '-isysroot', sdk,
                               '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                               '-I', str(NVN), '-I', str(NVN / 'include'), str(NVN / source)]
                    if flagged:
                        command.append('-DCANOPY_HOST_RUNTIME=1')
                    run = subprocess.run(command, capture_output=True, text=True, timeout=120)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)



if __name__ == '__main__':
    unittest.main()
