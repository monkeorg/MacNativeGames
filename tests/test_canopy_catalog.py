"""Exercise real prepared-store/catalog and title settings using macOS Foundation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'launcher/apple/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'),
                     'Canopy catalog/settings require macOS Foundation and Apple tools')
class CanopyCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name).resolve()
        objects = []
        for name in ('mng_store', 'mng_crypto'):
            output = cls.root / (name + '.o')
            cls.build(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE',
                       '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'launcher/include'),
                       '-c', str(ROOT / ('launcher/src/' + name + '.c')), '-o', str(output)])
            objects.append(str(output))
        cls.probe = cls.root / 'canopy-catalog-probe'
        cls.build(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                   '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'),
                   str(ROOT / 'tests/canopy_catalog_probe.m'),
                   str(SOURCES / 'CanopyCatalog.m'), str(SOURCES / 'CanopySettings.m'),
                   *objects, '-framework', 'Foundation', '-framework', 'CoreFoundation',
                   '-o', str(cls.probe)])

    @classmethod
    def build_folder_cli(cls):
        cls.cli=cls.root/'canopy-cli'
        names=('mng_container','mng_file','mng_crypto','mng_keys','mng_prepare','mng_store',
               'mng_content','mng_bktr','mng_folder','mng_romfs')
        cls.build(['xcrun','clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror',
                   '-I',str(ROOT/'launcher/include'),str(ROOT/'launcher/cli/main.c'),
                   *(str(ROOT/'launcher/src'/(name+'.c')) for name in names),'-o',str(cls.cli)])

    @staticmethod
    def build(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            result = subprocess.run([str(self.probe), name, directory],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {'status': 'pass'})

    def test_title_isolation_defaults_and_persistence(self):
        self.scenario('settings')

    def test_invalid_options_and_mapping_snapshot(self):
        self.scenario('options')

    def test_partial_schema_one_defaults_without_rewrite(self):
        self.scenario('partial')

    def test_invalid_metadata_refused_preserved_until_explicit_reset(self):
        for case in ('malformed', 'version', 'boolean_version', 'unknown_key',
                     'invalid_title', 'invalid_option', 'oversize', 'title_limit', 'symlink'):
            with self.subTest(case=case):
                self.scenario(case)

    def test_late_corruption_and_failed_writes_do_not_overwrite(self):
        self.scenario('late_corruption')
        self.scenario('write_failure')

    def test_catalog_reads_real_verified_generations_and_isolates_corruption(self):
        self.scenario('catalog')

    @unittest.skipUnless(importlib.util.find_spec('cryptography'),'encrypted folder fixture requires cryptography')
    def test_catalog_observes_actual_folder_generations_and_honest_provenance(self):
        import test_game_containers as fixture
        from test_canopy_folder import nso,npdm
        from test_canopy_romfs import romfs
        self.build_folder_cli()
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            directory=Path(temporary).resolve();prepared=directory/'prepared';keys=directory/'invented.keys'
            keys.write_text('\n'.join(f'{name} = {value.hex()}' for name,value in (
                ('header_key',fixture.HEADER),('key_area_key_application_00',fixture.AREA),('titlekek_00',fixture.TITLEKEK))))
            source_records={}
            for kind in ('nca','assets'):
                source=directory/kind;source.mkdir()
                if kind=='nca':
                    files={'program.nca':fixture.nca(managed=True),'common.tik':fixture.ticket()}
                else:
                    (source/'exefs').mkdir();(source/'romfs').mkdir()
                    files={'exefs/main':nso(),'exefs/main.npdm':npdm(),'romfs/romfs.bin':romfs([('original',b'fixture')])[0]}
                for path,data in files.items():(source/path).write_bytes(data)
                run=subprocess.run([str(self.cli),'prepare',str(source),'--store',str(prepared),
                    *(['--keys',str(keys)] if kind=='nca' else [])],capture_output=True,text=True,timeout=30)
                self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                report=json.loads(run.stdout);source_records[report['title_id']]=(report,files)
            run=subprocess.run([str(self.probe),'folder',str(directory)],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            observed=json.loads(run.stdout);self.assertEqual(observed['status'],'pass')
            self.assertEqual(len(observed['entries']),2)
            for entry in observed['entries']:
                report,files=source_records[entry['titleID']]
                self.assertEqual(entry['generationID'],report['generation'])
                self.assertEqual(entry['memberInventorySHA256'],report['member_inventory_sha256'])
                self.assertEqual(entry['sourceMemberCount'],len(files))
                self.assertEqual(entry['sourceMemberBytes'],sum(map(len,files.values())))
                root=prepared/'titles'/entry['titleID']/'generations'/entry['generationID']
                self.assertEqual(entry['memberInventorySHA256'],hashlib.sha256((root/'input-members.json').read_bytes()).hexdigest())
                self.assertNotIn('sourceSHA256',entry);self.assertNotIn('sourceSize',entry)
                self.assertIs(entry['integrity']['exefsVerified'],entry['sourceKind']=='nca-folder')
                self.assertIs(entry['integrity']['romfsVerified'],entry['sourceKind']=='nca-folder')
                self.assertIs(entry['integrity']['assetHashesVerified'],True)
                self.assertIs(entry['integrity']['romfsStructureVerified'],entry['sourceKind']=='asset-folder')
            for secret in (str(directory),fixture.HEADER.hex(),fixture.TITLEKEK.hex()):
                self.assertNotIn(secret,run.stdout+run.stderr)

    def test_catalog_busy_does_not_replace_existing_snapshot(self):
        self.scenario('busy')

    def test_catalog_bound_and_linked_root_refusals(self):
        self.scenario('catalog_limit')
        self.scenario('catalog_link')


if __name__ == '__main__':
    unittest.main()
