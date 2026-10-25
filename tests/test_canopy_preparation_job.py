"""Real Foundation preparation job with invented encrypted inputs; Mac only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'launcher/apple/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun') and
                     importlib.util.find_spec('cryptography'),
                     'native preparation jobs require macOS Foundation, xcrun and cryptography')
class CanopyPreparationJobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as fixture
        cls.fixture = fixture
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name).resolve()
        objects = []
        for name in ('mng_container', 'mng_crypto', 'mng_keys', 'mng_prepare', 'mng_store', 'mng_content', 'mng_bktr', 'mng_folder', 'mng_romfs', 'mng_romfs_runtime', 'mng_install'):
            output = directory / (name + '.o')
            source = ROOT / ('launcher/src/' + name + '.c')
            if name == 'mng_store':
                source = directory / 'instrumented-store.c'
                source.write_text('#ifndef _DARWIN_C_SOURCE\n#define _DARWIN_C_SOURCE\n#endif\n#include <unistd.h>\n#include <stdio.h>\n'
                    'int preparation_probe_fsync(int);\nint preparation_probe_renameat(int,const char *,int,const char *);\n'
                    '#define fsync preparation_probe_fsync\n#define renameat preparation_probe_renameat\n'
                    '#include "'+str(ROOT/'launcher/src/mng_store.c')+'"\n')
            cls.compile(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE',
                         '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'launcher/include'),
                         '-c', str(source), '-o', str(output)])
            objects.append(str(output))
        cls.probe = directory / 'canopy-preparation-probe'
        cls.compile(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                     '-I', str(SOURCES), '-I', str(ROOT / 'launcher/include'),
                     str(ROOT / 'tests/canopy_preparation_probe.m'),
                     str(SOURCES / 'CanopyPreparation.m'), *objects,
                     '-framework', 'Foundation', '-framework', 'CoreFoundation', '-o', str(cls.probe)])

    @staticmethod
    def compile(command):
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.store = self.directory / 'prepared'
        self.source = self.directory / 'invented.nsp'
        self.source.write_bytes(self.fixture.game_image('nsp'))
        self.keys = self.directory / 'invented.keys'
        f = self.fixture
        self.key_text = '\n'.join(f'{name} = {value.hex()}' for name, value in
                                  [('header_key', f.HEADER), ('key_area_key_application_00', f.AREA),
                                   ('titlekek_00', f.TITLEKEK)])
        self.keys.write_text(self.key_text)

    def job(self, mode='success', job=None, update=None, folder=False, keys=True, reuse=None):
        inputs = (self.source, self.keys) + ((update,) if update is not None else ())
        originals = {p: p.read_bytes() for p in inputs if p.is_file() and not p.is_symlink()}
        if folder and self.source.is_dir():
            originals.update({p:p.read_bytes() for p in self.source.rglob('*') if p.is_file() and not p.is_symlink()})
        run = subprocess.run([str(self.probe), ('reuse-' if reuse is not None else '')+('folder-' if folder else '')+mode, str(self.source), str(self.keys) if keys else '-',
                              str(self.store), job or '-', *([value or '-' for value in reuse] if reuse is not None else []),
                              *([str(update)] if update is not None else [])],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for p, data in originals.items():
            self.assertEqual(p.read_bytes(), data)
        for private in (self.fixture.HEADER.hex(), self.fixture.AREA.hex(), self.fixture.TITLEKEK.hex()):
            self.assertNotIn(private, run.stdout + run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], 'pass')
        if 'error' in report:
            self.assertNotIn(str(self.directory), json.dumps(report['error']))
        if 'result' in report:
            result = report['result']
            self.assertRegex(result['titleID'], r'^[0-9a-f]{16}$')
            self.assertRegex(result['generationID'], r'^[0-9a-f]{64}$')
            self.assertRegex(result['jobID'], r'^[0-9a-f]{32}$')
            if not folder:
                self.assertEqual(result['sourceSHA256'], hashlib.sha256(self.source.read_bytes()).hexdigest())
                self.assertEqual(result['assetCount'], 3)
            else:
                self.assertNotIn('sourceSHA256', result)
                self.assertNotIn('sourceSize', result)
                self.assertEqual(result['assetCount'], 4)
                self.assertIs(result['assetHashesVerified'], True)
            self.assertGreater(result['assetBytes'], 0)
            expected_nca = not folder or result['sourceKind']=='nca-folder'
            self.assertIs(result['exefsVerified'], expected_nca)
            self.assertIs(result['romfsVerified'], expected_nca)
            self.assertIs(result['signatureVerified'], False)
            self.assertIs(result['executionVerified'], False)
            if job:
                self.assertEqual(result['jobID'], job)
        return report

    def current(self, title=None):
        return self.store / 'titles' / f'{title or self.fixture.TITLE:016x}' / 'current'

    def generation(self, report, title=None):
        generation = self.current(title).read_text().strip()
        self.assertEqual(generation, report['result']['generationID'])
        self.assertEqual(report['result']['titleID'], f'{title or self.fixture.TITLE:016x}')
        return self.current(title).parent / 'generations' / generation

    def test_success_has_real_private_assets_current_and_result(self):
        report = self.job()
        root = self.generation(report)
        self.assertEqual((root / 'exefs/main').read_bytes(), b'synthetic main')
        self.assertEqual((root / 'exefs/main.npdm').read_bytes(), b'synthetic metadata')
        self.assertEqual((root / 'romfs.bin').read_bytes(), self.fixture.romfs())
        self.assertTrue((root / 'manifest.json').is_file())
        self.assertGreater(report['progress_calls'], 0)
        self.assertIsInstance(report['result'], dict)
        self.assertTrue(report['result'])
        self.assertEqual(report['result']['ioMetrics']['scope'],'logicalPayloadIO')

    def test_selected_generation_reuse_real_update_preserves_original_generation(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base,patch,_,updated=CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base));first=self.job()['result']
        old=self.store/'titles'/first['titleID']/'generations'/first['generationID']
        before={str(p.relative_to(old)):(p.stat().st_ino,p.read_bytes()) for p in old.rglob('*') if p.is_file()}
        update=self.directory/'reuse-update.nsp';update.write_bytes(self.fixture.partition(patch))
        result=self.job(update=update,reuse=(first['titleID'],first['generationID']))['result']
        self.assertEqual(result['titleVersion'],12);self.assertTrue(result['updateApplied'])
        self.assertEqual((self.store/'titles'/result['titleID']/'generations'/result['generationID']/'romfs.bin').read_bytes(),updated)
        metrics=result['ioMetrics'];self.assertEqual(metrics['streamedBytes'],metrics['writtenBytes']+metrics['comparedEqualBytes']+metrics['resumedBytes'])
        self.assertEqual(before,{str(p.relative_to(old)):(p.stat().st_ino,p.read_bytes()) for p in old.rglob('*') if p.is_file()})

    def test_reuse_identifiers_are_strict_atomic_and_optional_as_pair(self):
        for title,generation in ((None,'a'*64),('0100123456780000',None),('0'*16,'a'*64),('../bad','a'*64),('0100123456780000','A'*64)):
            self.assertTrue(self.job('invalid',reuse=(title,generation))['rejected'])
        self.assertFalse(self.store.exists())

    def test_missing_corrupt_and_other_title_reuse_never_replace_current(self):
        first=self.job()['result'];current=self.current();before=current.read_bytes()
        missing=self.job('failure',reuse=(first['titleID'],'a'*64));self.assertIn('ioMetrics',missing['error'])
        self.assertEqual(current.read_bytes(),before)
        other=int(first['titleID'],16)+1
        self.source.write_bytes(self.fixture.partition([('program.nca',self.fixture.nca(title=other))]))
        mismatch=self.job('failure',reuse=(first['titleID'],first['generationID']))
        self.assertEqual(mismatch['error']['code'],1);self.assertEqual(current.read_bytes(),before)
        self.assertFalse(self.current(other).exists())
        target=self.store/'titles'/first['titleID']/'generations'/first['generationID']/'romfs.bin'
        target.chmod(0o600);target.write_bytes(b'corrupt')
        failed=self.job('failure',reuse=(first['titleID'],first['generationID']))
        self.assertEqual(failed['error']['code'],5);self.assertEqual(failed['error']['ioMetrics']['streamedBytes'],0)
        self.assertEqual(current.read_bytes(),before)

    def test_reuse_cancel_reports_actual_zero_or_completed_payload_metrics(self):
        first=self.job()['result'];current=self.current().read_bytes()
        report=self.job('cancel-immediate',reuse=(first['titleID'],first['generationID']))
        self.assertEqual(report['error']['code'],6)
        self.assertEqual(report['error']['ioMetrics']['scope'],'logicalPayloadIO')
        self.assertEqual(self.current().read_bytes(),current)

    def test_two_coordinated_inputs_publish_actual_updated_assets_and_provenance(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base, patch, _, updated = CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory/'invented-update.nsp'
        update.write_bytes(self.fixture.partition(patch))
        report = self.job(update=update)
        self.assertIs(report['result']['updateApplied'], True)
        self.assertEqual((report['result']['baseTitleVersion'], report['result']['titleVersion']), (7, 12))
        self.assertEqual(report['result']['updateSourceSHA256'], hashlib.sha256(update.read_bytes()).hexdigest())
        root = self.generation(report, 0x0100123456780000)
        self.assertEqual((root/'exefs/main').read_bytes(), b'updated native bytes')
        self.assertEqual((root/'romfs.bin').read_bytes(), updated)
        self.assertEqual(json.loads((root/'manifest.json').read_text())['schemaVersion'], 3)

    def test_update_cancellation_waits_for_completion_and_resumes_verified_work(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base, patch, _, updated = CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base))
        update = self.directory/'invented-update.nsp'; update.write_bytes(self.fixture.partition(patch))
        before = self.job()
        current = self.current(0x0100123456780000)
        identifier = 'ef'*16
        cancelled = self.job('cancel', identifier, update)
        self.assertEqual(cancelled['error']['code'], 6)
        self.assertEqual(current.read_text().strip(), before['result']['generationID'])
        retained = self.store/'jobs'/identifier/'exefs/main'
        inode = retained.stat().st_ino
        resumed = self.job(job=identifier, update=update)
        root = self.generation(resumed, 0x0100123456780000)
        self.assertEqual((root/'exefs/main').stat().st_ino, inode)
        self.assertEqual((root/'romfs.bin').read_bytes(), updated)

    def test_cancellation_from_main_progress_preserves_current_and_resumes_job(self):
        first = self.job()
        original_current = self.current().read_bytes()
        original_main = (self.generation(first) / 'exefs/main').read_bytes()
        second_title = 0x0100123456780000
        self.source.write_bytes(self.fixture.partition([('program.nca', self.fixture.nca(title=second_title))]))
        identifier = 'ef' * 16
        cancelled = self.job('cancel', identifier)
        self.assertTrue(cancelled['cancel_sent'])
        self.assertEqual(self.current().read_bytes(), original_current)
        self.assertFalse(self.current(second_title).exists())
        staged = self.store / 'jobs' / identifier / 'exefs/main'
        self.assertTrue(staged.is_file())
        inode = staged.stat().st_ino
        resumed = self.job('success', identifier)
        self.assertEqual((self.generation(resumed, second_title) / 'exefs/main').stat().st_ino, inode)
        self.assertEqual(self.current().read_bytes(), original_current)
        self.assertEqual((self.generation(first) / 'exefs/main').read_bytes(), original_main)

    def test_wrong_malformed_and_missing_keys_do_not_publish_or_leak(self):
        for mode in ('wrong', 'malformed', 'missing', 'empty_provider'):
            with self.subTest(mode=mode):
                self.keys.unlink(missing_ok=True)
                if mode == 'wrong':
                    self.keys.write_text(self.key_text.replace(self.fixture.HEADER.hex(), 'ff' * 32))
                elif mode == 'malformed':
                    self.keys.write_text('header_key = not-hex\n')
                elif mode == 'empty_provider':
                    self.keys.write_text('invented_unused_key = 00\n')
                self.job('failure')
                self.assertFalse(self.current().exists())

    def test_invalid_source_and_key_symlink_do_not_replace_existing_current(self):
        self.job()
        original = self.current().read_bytes()
        self.source.write_bytes(b'not a container')
        self.job('failure')
        self.assertEqual(self.current().read_bytes(), original)
        self.source.write_bytes(self.fixture.game_image('nsp'))
        real = self.keys.with_suffix('.original')
        self.keys.rename(real)
        self.keys.symlink_to(real)
        self.job('failure')
        self.assertEqual(self.current().read_bytes(), original)

    def folder_source(self, kind, image=None):
        from test_canopy_folder import nso, npdm
        from test_canopy_romfs import romfs
        source=self.directory/('folder-'+kind)
        source.mkdir()
        if kind=='nca':
            files={'program.nca':self.fixture.nca(managed=True),'common.tik':self.fixture.ticket()}
        else:
            (source/'exefs').mkdir();(source/'romfs').mkdir()
            files={'exefs/main':nso(),'exefs/main.npdm':npdm(),
                   'romfs/romfs.bin':image if image is not None else romfs([('nested/original',b'private fixture')],['empty'])[0]}
            (source/'extraction-manifest.json').write_text('{"verified":true,"titleID":"forged"}')
        for path,data in files.items():(source/path).write_bytes(data)
        self.source=source
        return files

    def test_both_folder_jobs_publish_actual_v4_assets_without_physical_sha(self):
        for kind in ('nca','assets'):
            with self.subTest(kind=kind):
                files=self.folder_source(kind)
                report=self.job(folder=True,keys=kind=='nca')
                result=report['result'];root=self.generation(report,int(result['titleID'],16))
                self.assertEqual(result['sourceKind'],'nca-folder' if kind=='nca' else 'asset-folder')
                self.assertEqual(result['sourceMemberBytes'],sum(map(len,files.values())))
                self.assertEqual(result['sourceMemberCount'],len(files))
                self.assertIs(result['romfsStructureVerified'],kind=='assets')
                raw=(root/'input-members.json').read_bytes()
                self.assertEqual(result['memberInventorySHA256'],hashlib.sha256(raw).hexdigest())
                self.assertEqual(json.loads(raw)['members'],[
                    {'path':path,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
                    for path,data in sorted(files.items())])
                manifest=json.loads((root/'manifest.json').read_bytes())
                self.assertEqual((manifest['schemaVersion'],manifest['recipeID']),(4,'canopy-assets-v4'))
                if kind=='assets':
                    self.assertEqual((root/'exefs/main').read_bytes(),files['exefs/main'])
                    self.assertEqual((root/'romfs.bin').read_bytes(),files['romfs/romfs.bin'])
                else:
                    self.assertEqual((root/'exefs/main').read_bytes(),b'synthetic main')
                    self.assertEqual((root/'romfs.bin').read_bytes(),self.fixture.romfs())
                again=self.job(folder=True,keys=kind=='nca')
                self.assertEqual(again['result']['generationID'],result['generationID'])

    def test_plain_folder_unicode_normalization_and_alias_collision(self):
        from test_canopy_romfs import romfs
        self.folder_source('unicode',romfs([('é',b'original')])[0])
        result=self.job(folder=True,keys=False)
        current=self.current(0x0100123456780000);before=current.read_bytes()
        (self.source/'romfs/romfs.bin').write_bytes(romfs([('é',b'x'),('e\u0301',b'y')])[0])
        failure=self.job('failure',folder=True,keys=False)
        self.assertEqual(failure['error']['code'],1)
        self.assertEqual(current.read_bytes(),before)
        self.assertIs(result['result']['romfsStructureVerified'],True)

    def test_folder_cancel_preserves_current_and_resumes_completed_asset(self):
        for kind in ('nca','assets'):
            with self.subTest(kind=kind):
                self.folder_source(kind)
                before=self.job(folder=True,keys=kind=='nca')
                title=int(before['result']['titleID'],16);current=self.current(title);snapshot=current.read_bytes()
                if kind=='assets':
                    member=self.source/'exefs/main';data=bytearray(member.read_bytes());data[-1]^=1;member.write_bytes(data)
                else:
                    (self.source/'note.xml').write_bytes(b'original metadata fixture')
                identifier=('ac' if kind=='assets' else 'ad')*16
                cancelled=self.job('cancel',identifier,folder=True,keys=kind=='nca')
                self.assertTrue(cancelled['cancel_sent']);self.assertEqual(cancelled['error']['code'],6)
                self.assertEqual(current.read_bytes(),snapshot)
                retained=self.store/'jobs'/identifier/'exefs/main';inode=retained.stat().st_ino
                resumed=self.job(job=identifier,folder=True,keys=kind=='nca')
                root=self.generation(resumed,title)
                self.assertEqual((root/'exefs/main').stat().st_ino,inode)

    def test_folder_wrong_keys_missing_keys_and_file_type_mismatch_refused(self):
        self.folder_source('nca')
        self.assertEqual(self.job('failure',folder=True,keys=False)['error']['code'],4)
        self.keys.write_text(self.key_text.replace(self.fixture.HEADER.hex(),'ff'*32))
        self.assertEqual(self.job('failure',folder=True)['error']['code'],4)
        self.assertFalse(self.current().exists())
        self.keys.write_text(self.key_text)
        self.source=self.directory/'invented.nsp'
        self.job('failure',folder=True,keys=False)
        self.folder_source('assets')
        self.job('failure')  # A directory never passes the original file API.
        member=self.source/'exefs/main';member.unlink();member.symlink_to(self.source/'exefs/main.npdm')
        self.job('failure',folder=True,keys=False)
        self.assertFalse(self.current(0x0100123456780000).exists())

    def test_pair_coordination_missing_input_mismatch_and_immediate_cancel_finish(self):
        from test_canopy_pipeline import CanopyPipelineTests
        base,patch,_,_=CanopyPipelineTests.update_fixture(self)
        self.source.write_bytes(self.fixture.partition(base))
        before=self.job();current=self.current(0x0100123456780000);snapshot=current.read_bytes()
        missing=self.directory/'missing-update.nsp'
        failed=self.job('failure',update=missing)
        self.assertEqual(failed['error']['code'],2)
        self.assertEqual(current.read_bytes(),snapshot)
        foreign=self.directory/'foreign-update.nsp';foreign.write_bytes(self.fixture.game_image('nsp'))
        self.job('failure',update=foreign)
        self.assertEqual(current.read_bytes(),snapshot)
        update=self.directory/'valid-update.nsp';update.write_bytes(self.fixture.partition(patch))
        cancelled=self.job('cancel-immediate',update=update)
        self.assertTrue(cancelled['cancel_sent']);self.assertEqual(cancelled['error']['code'],6)
        self.assertEqual(current.read_bytes(),snapshot)
        self.assertEqual(before['result']['generationID'],current.read_text().strip())

    def test_second_start_is_refused_while_worker_is_busy(self):
        self.job('busy')
        self.assertTrue(self.current().exists())


    def addon_inputs(self,**options):
        import test_canopy_content as cf
        from test_canopy_prepare import CanopyPrepareTests
        from test_canopy_addon_prepare import CanopyAddonPrepareTests
        from extract_exefs import decrypt
        from cryptography.hazmat.primitives.ciphers import modes
        helper=CanopyPrepareTests();helper.fixture=self.fixture;helper.content_fixture=cf;helper.decrypt=staticmethod(decrypt);helper.modes=modes
        self.source.write_bytes(self.fixture.partition(helper.identified_package()))
        base=self.job()['result'];base_current=self.current(cf.APP).read_bytes()
        addon=CanopyAddonPrepareTests();addon.f=self.fixture;addon.cf=cf;addon.helper=helper
        files,cnmt=addon.package(**options);self.source.write_bytes(self.fixture.partition(files))
        return base,base_current,cnmt

    def addon_job(self,base,mode='success',job=None,env=None,application=None,generation=None,title=None):
        source_before=self.source.read_bytes();keys_before=self.keys.read_bytes()
        run=subprocess.run([str(self.probe),'addon-'+mode,str(self.source),str(self.keys),str(self.store),job or '-',
            application or '0100123456780000',generation or base['generationID'],title or '0100123456781001'],
            capture_output=True,text=True,timeout=30,env={**os.environ,**(env or {})})
        self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'')
        self.assertEqual(self.source.read_bytes(),source_before);self.assertEqual(self.keys.read_bytes(),keys_before)
        for secret in (self.fixture.HEADER,self.fixture.AREA,self.fixture.CONTENT,self.fixture.TITLEKEK):self.assertNotIn(secret.hex(),run.stdout)
        report=json.loads(run.stdout);self.assertEqual(report['status'],'pass');self.assertNotIn(str(self.directory),json.dumps(report))
        return report

    def test_actual_addon_job_installs_v5_with_typed_provenance(self):
        base,before,cnmt=self.addon_inputs()
        report=self.addon_job(base);result=report['result'];root=self.generation(report,0x0100123456781001)
        self.assertEqual(self.current(0x0100123456780000).read_bytes(),before)
        self.assertEqual((root/'romfs.bin').read_bytes(),self.fixture.romfs())
        self.assertEqual((result['preparedKind'],result['recipeID'],result['applicationID'],result['titleVersion']),('addOn','canopy-assets-v5','0100123456780000',3))
        self.assertEqual(result['cnmtSHA256'],hashlib.sha256(cnmt).hexdigest())
        self.assertEqual(result['sourceSHA256'],hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(result['indexSHA256'],hashlib.sha256((root/'runtime-index.bin').read_bytes()).hexdigest())
        self.assertEqual((result['requiredApplicationVersion'],result['verifiedBaseVersion'],result['assetCount']),(7,7,2))
        self.assertIs(result['exefsVerified'],False);self.assertIs(result['romfsVerified'],True);self.assertIs(result['romfsStructureVerified'],True)
        self.assertIs(result['signatureVerified'],False);self.assertIs(result['executionVerified'],False)

    def test_actual_addon_job_cancel_waits_and_resumes_same_inode(self):
        base,before,_=self.addon_inputs();identifier='d'*32
        cancelled=self.addon_job(base,'cancel',identifier);self.assertEqual(cancelled['error']['code'],6)
        self.assertEqual(cancelled['error']['jobID'],identifier);self.assertFalse(cancelled['error']['publicationUncertain'])
        staged=self.store/'jobs'/identifier/'romfs.bin';inode=staged.stat().st_ino
        resumed=self.addon_job(base,job=identifier);root=self.generation(resumed,0x0100123456781001)
        self.assertEqual((root/'romfs.bin').stat().st_ino,inode);self.assertEqual(self.current(0x0100123456780000).read_bytes(),before)

    def test_actual_addon_job_postrename_io_preserves_uncertainty_and_current_facts(self):
        base,before,_=self.addon_inputs()
        report=self.addon_job(base,'failure',env={'CANOPY_PREPARATION_FAIL_CURRENT_SYNC':'1'});error=report['error']
        self.assertEqual(error['code'],2)
        for key in ('commitAttempted','publicationUncertain','reloadRequired','currentReadable'):self.assertIs(error[key],True)
        self.assertEqual(self.current(0x0100123456781001).read_text().strip(),error['currentGenerationID'])
        current=self.current(0x0100123456781001).parent/'generations'/error['currentGenerationID']
        self.assertEqual((current/'romfs.bin').read_bytes(),self.fixture.romfs());self.assertEqual(self.current(0x0100123456780000).read_bytes(),before)

    def test_actual_addon_job_late_cancel_does_not_relabel_native_commit_success(self):
        base,before,_=self.addon_inputs()
        report=self.addon_job(base,env={'CANOPY_PREPARATION_CANCEL_AFTER_CURRENT':'1'})
        self.assertTrue(report['late_cancel']);self.assertIn('result',report);self.generation(report,0x0100123456781001)
        self.assertEqual(self.current(0x0100123456780000).read_bytes(),before)

    def test_actual_addon_job_identifier_base_authority_and_required_version(self):
        base,_,_=self.addon_inputs(required=8)
        self.assertEqual(self.addon_job(base,'failure')['error']['code'],3)
        self.assertNotIn('result',self.addon_job(base,'failure',generation='a'*64))
        for options in ({'application':'0'*16},{'title':'../invalid'},{'generation':'A'*64},{'title':'0100123456780000'}):
            self.assertTrue(self.addon_job(base,'invalid',**options)['rejected'])

    def test_actual_addon_job_empty_volume_and_unicode_index_validation(self):
        from test_canopy_romfs import romfs
        for image in (romfs()[0],romfs([('é',b'original')])[0]):
            base,_,_=self.addon_inputs(image=image);report=self.addon_job(base);root=self.generation(report,0x0100123456781001)
            self.assertEqual((root/'romfs.bin').read_bytes(),image)
            self.assertEqual(report['result']['indexFileCount'],0 if image==romfs()[0] else 1)


if __name__ == '__main__':
    unittest.main()
