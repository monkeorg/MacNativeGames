"""Actual native DLC preparation from invented NCA/CNMT bytes and keys."""
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
ROOT=Path(__file__).resolve().parents[1]
APP=0x0100123456780000
DLC=0x0100123456781001

@unittest.skipUnless(shutil.which('cc') and importlib.util.find_spec('cryptography'), 'requires native compiler and fixture cryptography')
class CanopyAddonPrepareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_game_containers as f
        import test_canopy_content as cf
        from test_canopy_prepare import CanopyPrepareTests
        from extract_exefs import decrypt
        from cryptography.hazmat.primitives.ciphers import modes
        cls.f=f;cls.cf=cf;cls.helper=CanopyPrepareTests();cls.helper.fixture=f;cls.helper.content_fixture=cf;cls.helper.decrypt=staticmethod(decrypt);cls.helper.modes=modes
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup);folder=Path(cls.build.name)
        wrapper=folder/'prepare.c';wrapper.write_text('#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n#include <sys/stat.h>\n#include <unistd.h>\nssize_t addon_prepare_pread(int,void *,size_t,off_t);\n#define pread addon_prepare_pread\n#include "'+str(ROOT/'launcher/src/mng_prepare.c')+'"\n')
        cls.probe=folder/'probe';command=['cc','-std=c11','-O3','-Wall','-Wextra','-Wpedantic','-Werror','-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),str(wrapper),str(ROOT/'launcher/tests/addon_prepare_probe.c')]
        command += [str(ROOT/'launcher/src'/name) for name in ('mng_container.c','mng_content.c','mng_crypto.c','mng_bktr.c')]
        if sys.platform!='darwin':command+=['-lcrypto']
        run=subprocess.run(command+['-o',str(cls.probe)],capture_output=True,text=True,timeout=60)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
    def package(self,version=3,required=7,managed=False,raw_title=DLC,nca_type=4,transform=None,dependency=False,owner=APP,image=None):
        if image is None:data=self.f.nca(managed,title=raw_title,content=nca_type)
        else:
            with mock.patch.object(self.f,"romfs",return_value=image):data=self.f.nca(managed,title=raw_title,content=nca_type)
        if transform:data=transform(data)
        record=self.helper.observed_record(data,2)
        cnmt,name,_=self.cf.cnmt(title=DLC,version=version,kind=0x82,application=owner,required=required,contents=[record],dependencies=[(APP,7,0x80,0)] if dependency else [])
        meta=self.helper.metadata_nca(kind=0x82,title=DLC,payload=cnmt,member=name)
        files=[(f'data-{version}.nca',data),(f'meta-{version}.nca',meta)]
        if managed:files.append(('common.tik',self.f.ticket()))
        return files,cnmt
    def run_package(self,files,mode='ok',base_version=7,owner=APP,addon=DLC,expected='ok',cnmt=None,expected_image=None):
        data=self.f.partition(files)
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source.nsp';source.write_bytes(data);stage=root/'stage';stage.mkdir()
            run=subprocess.run([str(self.probe),str(source),str(stage),mode,str(base_version),f'{owner:016x}',f'{addon:016x}'],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertEqual(run.stderr,'');report=json.loads(run.stdout)
            self.assertEqual(report['status'],expected,report);self.assertTrue(report['positionPreserved'])
            for secret in (self.f.HEADER,self.f.AREA,self.f.CONTENT,self.f.TITLEKEK):self.assertNotIn(secret.hex(),run.stdout)
            if expected=='ok':
                self.assertFalse(report['empty']);self.assertEqual(report['emitted'],1);self.assertEqual([p.name for p in stage.iterdir()],['romfs.bin'])
                actual=(stage/'romfs.bin').read_bytes();self.assertEqual(actual,self.f.romfs() if expected_image is None else expected_image);self.assertEqual(report['romfsSize'],len(actual));self.assertEqual(report['romfsSHA'],hashlib.sha256(actual).hexdigest())
                self.assertEqual(report['sourceSHA'],hashlib.sha256(data).hexdigest());self.assertEqual(report['size'],len(data));self.assertEqual(report['application'],f'{APP:016x}');self.assertEqual(report['addon'],f'{DLC:016x}');self.assertEqual(report['verified'],1)
                if cnmt:self.assertEqual(report['cnmtSHA'],hashlib.sha256(cnmt).hexdigest())
            elif mode.startswith('dirty'):self.assertFalse(report['empty'])
            else:self.assertTrue(report['empty'])
            if mode!='mutate':self.assertEqual(source.read_bytes(),data)
            return report
    def test_real_data_and_publicdata_keyarea_common_ticket_exact_provenance(self):
        for managed in (False,True):
            for nca_type in (4,5):
                with self.subTest(managed=managed,nca_type=nca_type):
                    files,cnmt=self.package(managed=managed,nca_type=nca_type);r=self.run_package(files,cnmt=cnmt);self.assertEqual((r['version'],r['required']),(3,7))
    def test_highest_declared_revision_no_literal_version_sentinel(self):
        lower,_=self.package(version=0);image=self.f.romfs()[:-1]+b"Z"
        higher,cnmt=self.package(version=0xffffffff,image=image)
        r=self.run_package(lower+higher,cnmt=cnmt,expected_image=image);self.assertEqual(r['version'],0xffffffff)
    def test_highest_bad_ivfc_and_metadata_never_fall_back(self):
        lower,_=self.package(version=1)
        def damage(data):return data[:0xc00]+bytes([data[0xc00]^1])+data[0xc01:]
        high,_=self.package(version=2,transform=damage)
        self.run_package(lower+high,expected='integrity')
        self.run_package(lower+high[1:],expected='integrity')
        high,_=self.package(version=2);bad=bytearray(high[1][1]);bad[0xc00]^=1;high[1]=(high[1][0],bytes(bad))
        self.run_package(lower+high,expected='integrity')
        high,cnmt=self.package(version=2);broken=bytearray(cnmt);broken[-1]^=1
        high[1]=(high[1][0],self.helper.metadata_nca(kind=0x82,title=DLC,payload=bytes(broken),member=f'AddOnContent_{DLC:016x}.cnmt'))
        self.run_package(lower+high[1:],expected='integrity')
    def test_wrong_owner_raw_title_role_missing_base_and_required_version(self):
        files,_=self.package(owner=APP+2);self.run_package(files,expected='integrity')
        files,_=self.package(raw_title=DLC+1);self.run_package(files,expected='integrity')
        files,_=self.package(nca_type=2);self.run_package(files,expected='integrity')
        files,_=self.package();self.run_package(files,mode='unknownbase',expected='invalid');self.run_package(files,base_version=6,expected='unsupported')
        self.run_package(files,addon=DLC+1,expected='unsupported')
    def test_no_cnmt_missing_record_duplicates_and_external_dependencies(self):
        files,_=self.package();self.run_package(files[:1],expected='unsupported');self.run_package(files[1:],expected='integrity')
        duplicates=[*files,('same-meta.nca',files[1][1])];self.run_package(duplicates,expected='invalid')
        files,_=self.package(dependency=True);self.run_package(files,expected='unsupported')
    def test_full_install_bktr_and_extra_section_rejection(self):
        files,_=self.package(transform=lambda n:self.helper.change_header(n,lambda h:h.__setitem__(0x404,4)))
        self.run_package(files,expected='unsupported')
        data=self.helper.change_header(self.helper.custom_nca(title=DLC),lambda h:h.__setitem__(0x205,4))
        record=self.helper.observed_record(data,2)
        meta=self.helper.metadata_nca([record],kind=0x82,title=DLC,application=APP)
        self.run_package([('data.nca',data),('meta.nca',meta)],expected='unsupported')
    def test_keys_source_io_short_reads_and_unpublished_sink_failures(self):
        files,cnmt=self.package()
        for mode,expected in [('missingkey','key'),('wrongkey','key'),('readerror','io'),('sinkerror','io'),('enderror','io'),('short','ok'),('eintr','ok'),('mutate','io')]:
            with self.subTest(mode=mode):self.run_package(files,mode=mode,expected=expected,cnmt=cnmt)
    def test_cancellation_at_initial_ivfc_write_and_sourcehash(self):
        files,_=self.package()
        for mode in ('cancelinitial','cancelivfc','cancelwrite','cancelsource'):
            with self.subTest(mode=mode):self.run_package(files,mode=mode,expected='cancelled')
    def test_dirty_result_is_refused_unchanged(self):
        files,_=self.package()
        for mode in ('dirtyversion','dirtyhash'):self.run_package(files,mode=mode,expected='invalid')

    def test_legacy_producers_reject_new_nonempty_addon_result_fields(self):
        files,_=self.package()
        for mode in ('legacy-dirty-required','legacy-dirty-cnmt'):self.run_package(files,mode=mode,expected='invalid')

    def test_actual_empty_romfs_addon_is_prepared(self):
        from test_canopy_romfs import romfs
        image,_=romfs([]);files,cnmt=self.package(image=image)
        self.run_package(files,cnmt=cnmt,expected_image=image)
