"""Actual native return adapter; original fixtures never claim a private SDK ran."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'),'native C compiler required')
class CanopySdkReturnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup)
        cls.probe=Path(cls.temp.name)/'sdk-return'
        command=['cc','-std=c11','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-fsanitize=undefined',
                 '-fno-sanitize-recover=all','-pthread','-I',str(ROOT/'games/totk/runtime'),
                 str(ROOT/'tests/canopy_sdk_return_probe.c'),'-o',str(cls.probe)]
        run=subprocess.run(command,capture_output=True,text=True,timeout=60)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def scenario(self,mode):
        run=subprocess.run([str(self.probe),mode],capture_output=True,text=True,timeout=10)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertEqual(run.stderr,'');self.assertEqual(json.loads(run.stdout)['status'],'pass')

    def test_natural_native_call_return_preserves_arguments_and_reports_error(self):self.scenario('return')
    def test_real_pthread_exit_and_tls_join_do_not_inject_return_or_finalizers(self):self.scenario('pthread-exit')

    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'actual loader SDK compile requires installed Apple SDKs')
    def test_production_loader_compiles_with_original_nonexecutable_metadata(self):
        # This metadata is ONLY a compilation fixture, never accepted game data.
        # No game addresses, expected hashes, instructions or payloads are used.
        with tempfile.TemporaryDirectory() as folder:
            generated=Path(folder)
            # Compile the byte-for-byte production caller beside these explicit
            # fixtures, so no private same-named header can be selected first.
            source=generated/'loader.c'
            source.write_bytes((ROOT/'games/totk/runtime/loader.c').read_bytes())
            (generated/'runtime_tables.h').write_text('''/* Original nonexecutable compilation fixture. */
static Module modules[]={{.name="original-compilation-fixture",.digest="not-a-game-image",.file_size=0,.nsym=0}};
#define PROBE_PLT 0ULL
#define PROBE_SLOT 0ULL
''')
            (generated/'ios_embed.h').write_text('''/* Original nonexecutable compilation fixture. */
typedef struct { const char *name,*x0,*w,*x1; } IosEmbed;
static const IosEmbed ios_embed[]={{"original-compilation-fixture","not-a-pin","not-a-pin","not-a-pin"}};
''')
            for sdk_name,target in (('macosx','arm64-apple-macos14.0'),('iphoneos','arm64-apple-ios16.0')):
                sdk=subprocess.run(['xcrun','--sdk',sdk_name,'--show-sdk-path'],capture_output=True,text=True,timeout=30)
                self.assertEqual(sdk.returncode,0,sdk.stderr)
                for version in ('V121','V143'):
                    for canopy in (False,True):
                        with self.subTest(sdk=sdk_name,version=version,canopy=canopy):
                            command=['xcrun','--sdk',sdk_name,'clang','-fsyntax-only','-target',target,'-isysroot',sdk.stdout.strip(),
                                     '-std=gnu11','-Wall','-Wextra','-Werror=implicit-function-declaration',
                                     '-DTOTK_GAME_'+version+'=1','-I',str(generated),'-I',str(ROOT/'launcher/include'),
                                     '-I',str(ROOT/'games/totk/runtime'),
                                     '-I',str(ROOT/'games/totk/third_party/d2r_gfx/gfx/nvn/include')]
                            if canopy:command.append('-DCANOPY_HOST_RUNTIME=1')
                            run=subprocess.run(command+[str(source)],capture_output=True,text=True,timeout=60)
                            self.assertEqual(run.returncode,0,run.stdout+run.stderr)


if __name__=='__main__':unittest.main()
