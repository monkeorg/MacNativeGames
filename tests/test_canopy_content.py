"""Native CNMT parser/planner, invented metadata only; no games or user keys.

Independent byte fixtures follow the public packaged-CNMT field contract:
https://switchbrew.org/wiki/CNMT (alternate layout reference pinned in native C).
No third-party implementation or real metadata payload is included.
"""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP, PATCH, DLC = 0x0100123456780000, 0x0100123456780800, 0x0100123456781001
PREFIX = {0x80: 'Application', 0x81: 'Patch', 0x82: 'AddOnContent', 0x83: 'Delta'}


def record(label, role=1, offset=0, size=None):
    payload = ('invented NCA bytes '+label).encode()
    digest = hashlib.sha256(payload).digest()
    return {'id': digest[:16], 'sha': digest, 'size': len(payload) if size is None else size,
            'role': role, 'offset': offset}


def cnmt(title=APP, version=0, kind=0x80, application=APP, patch=PATCH,
         required=0, contents=None, dependencies=(), modern=False, extended=b''):
    if contents is None:
        contents = [record(f'{title}-{version}', 2 if kind==0x82 else 1)]
    if kind==0x80:
        extra = struct.pack('<QII', patch, 0, required)
    elif kind==0x81:
        extra = struct.pack('<QII8x', application, 0, len(extended))
    elif kind==0x82:
        extra = struct.pack('<QI4x', application, required)
        if modern:
            extra += bytes(8)
    else:
        extra = struct.pack('<QII', application, len(extended), 0)
    header = struct.pack('<QIBBHHHBBBBI4x', title, version, kind, 0, len(extra),
                         len(contents), len(dependencies), 0, 0, 0, 0, 0)
    packed = b''.join(r['sha']+r['id']+r['size'].to_bytes(6,'little')+
                      bytes((r['role'],r['offset'])) for r in contents)
    deps = b''.join(struct.pack('<QIBB2x', *dependency) for dependency in dependencies)
    data = header+extra+packed+deps+extended
    return data+hashlib.sha256(data).digest(), f'{PREFIX[kind]}_{title:016X}.cnmt', contents


def changed(blob, at, value, fmt='<B'):
    data = bytearray(blob)
    struct.pack_into(fmt, data, at, value)
    data[-32:] = hashlib.sha256(data[:-32]).digest()
    return bytes(data)


def candidates(records):
    role = {0: 1, 1: 0, 2: 4, 3: 2, 4: 3, 5: 3}
    seen = {}
    for r in records:
        seen[r['id']] = r['id']+r['sha']+struct.pack('<QB', r['size'], role[r['role']])
    return b''.join(seen.values())


@unittest.skipUnless(shutil.which('cc'), 'native C compiler required')
class CanopyContentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        cls.probe = Path(cls.build.name)/'content-probe'
        common = ['cc','-std=c11','-Wall','-Wextra','-Wpedantic','-Werror',
            '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include')]
        content_object = Path(cls.build.name)/'content.o'
        result = subprocess.run([*common,'-Dmemcmp=content_probe_memcmp','-c',
            str(ROOT/'launcher/src/mng_content.c'),'-o',str(content_object)],capture_output=True,text=True)
        if result.returncode:
            raise AssertionError(result.stdout+result.stderr)
        command = [*common,str(content_object),str(ROOT/'launcher/src/mng_crypto.c'),
            str(ROOT/'launcher/tests/content_probe.c')]
        if sys.platform!='darwin':
            command += ['-lcrypto']
        result = subprocess.run(command+['-o',str(cls.probe)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout+result.stderr)

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.serial = 0

    def file(self, data):
        self.serial += 1
        path = self.root/str(self.serial)
        path.write_bytes(data)
        return str(path)

    def run_probe(self, *arguments, status='ok'):
        result = subprocess.run([str(self.probe), *map(str,arguments)],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        output = json.loads(result.stdout)
        self.assertEqual(output['status'], status, output)
        if status!='ok' and arguments[0]=='plan':
            self.assertTrue(output['outputUnchanged'])
        return output

    def parse(self, item, status='ok', name=None):
        return self.run_probe('parse', self.file(item[0]), name or item[1], status=status)

    def plan(self, items, observed=None, application=APP, cap=0xffffffff, status='ok'):
        if observed is None:
            observed = candidates([r for item in items for r in item[2]])
        args = ['plan',f'{application:016x}',str(cap),self.file(observed)]
        for item in items:
            args += [self.file(item[0]), item[1]]
        return self.run_probe(*args,status=status)

    def test_public_contract_application_patch_and_both_addon_headers(self):
        for item, expected_app, expected_patch in (
            (cnmt(contents=[record('program'),record('control',3)]),APP,PATCH),
            (cnmt(PATCH,7,0x81,extended=b'bounded opaque patch metadata'),APP,0),
            (cnmt(DLC,2,0x82,required=7),APP,0),
            (cnmt(DLC,3,0x82,modern=True),APP,0)):
            result = self.parse(item)
            self.assertEqual(result['application'],f'{expected_app:016x}')
            self.assertEqual(result['patch'],f'{expected_patch:016x}')
            self.assertEqual(result['contents'],[
                {'id':r['id'].hex(),'sha256':r['sha'].hex(),'size':r['size'],
                 'role':r['role'],'idOffset':r['offset']} for r in item[2]])

    def test_exact_lengths_self_digest_and_member_names(self):
        item = cnmt()
        for data in (b'', item[0][:-1], item[0]+b'\0', item[0][:-33]):
            self.parse((data,item[1],item[2]),'invalid')
        bad = bytearray(item[0]);bad[-1] ^= 1
        self.parse((bad,item[1],item[2]),'integrity')
        for name in ('../'+item[1], 'Patch_'+item[1].split('_')[1],
                     'Application_0100123456780001.cnmt', 'Application_gggggggggggggggg.cnmt',
                     item[1]+'.extra'):
            self.parse(item,'invalid',name=name)

    def test_unsupported_metadata_and_raw_content_roles(self):
        self.parse(cnmt(PATCH,1,0x83),'unsupported')
        item = cnmt()
        for at,value in ((13,1),(20,128),(21,255),(22,1),(23,1),(48+53,1),(48+54,6),(48+54,7)):
            self.parse((changed(item[0],at,value),item[1],item[2]),'unsupported')
        modern = cnmt(DLC,1,0x82,modern=True)
        self.parse((changed(modern[0],48,9,'<Q'),modern[1],modern[2]),'unsupported')

    def test_bounded_counts_sizes_reserved_fields_and_duplicates(self):
        item = cnmt()
        for at,value,fmt,status in ((16,4097,'<H','limit'),(18,257,'<H','limit'),
                                     (28,1,'<I','invalid'),(14,17,'<H','unsupported'),
                                     (48+48,0,'<I','invalid')):
            self.parse((changed(item[0],at,value,fmt),item[1],item[2]),status)
        self.parse(cnmt(contents=[record('too-large',size=(128<<30)+1)]),'limit')
        first = record('first')
        self.parse(cnmt(contents=[first,first]),'invalid')
        self.parse(cnmt(contents=[first,record('other-same-role')]),'invalid')
        wrong = dict(first,id=bytes(16))
        self.parse(cnmt(contents=[wrong]),'invalid')
        self.parse((bytes(1024*1024+1),item[1],[]),'limit')

    def test_highest_versions_selected_independent_of_input_order(self):
        items = [cnmt(PATCH,3,0x81),cnmt(),cnmt(DLC,1,0x82),
                 cnmt(PATCH,9,0x81),cnmt(version=1),cnmt(DLC,4,0x82,required=9)]
        result = self.plan(items)
        self.assertEqual((result['base'],result['patch'],result['version'],result['dlc']), (4,3,9,[5]))
        reversed_items = list(reversed(items))
        result = self.plan(reversed_items)
        self.assertEqual((result['base'],result['patch'],result['version'],result['dlc']), (1,2,9,[0]))
        # A literal0 cap selects base version0; this is not an unlimited sentinel.
        result = self.plan([cnmt(),cnmt(PATCH,3,0x81)],cap=0)
        self.assertEqual((result['base'],result['patch'],result['version']), (0,None,0))

    def test_missing_and_wrong_content_hash_size_id_and_nca_type_refused(self):
        base,new = cnmt(),cnmt(PATCH,7,0x81)
        self.plan([base,new],candidates(base[2]),status='missing')
        observed = bytearray(candidates(base[2]+new[2]))
        for at,value in ((57+16+31,123),(57+48,255),(57+56,2)):
            bad = bytearray(observed);bad[at] ^= value
            self.plan([base,new],bad,status='mismatch')
        bad = bytearray(observed);bad[57] ^= 1
        self.plan([base,new],bad,status='invalid')
        self.plan([base],observed[:57]*2,status='invalid')

    def test_mismatched_application_patch_linkage_and_duplicate_metadata_refused(self):
        self.plan([cnmt(),cnmt(PATCH,4,0x81,application=APP+1)],status='mismatch')
        self.plan([cnmt(),cnmt(PATCH+1,4,0x81)],status='mismatch')
        self.plan([cnmt(),cnmt(DLC,1,0x82,application=APP+1)],status='mismatch')
        self.plan([cnmt(),cnmt()],status='invalid')
        self.plan([cnmt(PATCH,4,0x81)],status='missing')

    def test_required_application_versions_and_exact_meta_dependencies(self):
        base,patch = cnmt(),cnmt(PATCH,7,0x81)
        self.plan([base,cnmt(DLC,1,0x82,required=7)],status='dependency')
        dlc = cnmt(DLC,1,0x82,required=7,dependencies=[(PATCH,7,0x81,0)])
        self.assertEqual(self.plan([base,patch,dlc])['dlc'],[2])
        self.plan([base,patch,cnmt(DLC,1,0x82,dependencies=[(PATCH,8,0x81,0)])],status='dependency')
        self.plan([base,patch,cnmt(DLC,1,0x82,dependencies=[(PATCH,7,0x81,1)])],status='dependency')
        a = cnmt(dependencies=[(PATCH,7,0x81,0)])
        b = cnmt(PATCH,7,0x81,dependencies=[(APP,0,0x80,0)])
        self.plan([a,b],status='dependency')

    def test_content_binding_is_public_for_unselected_bundled_metadata(self):
        item = cnmt(PATCH,9,0x81,contents=[record('manual',4),record('legal',5),record('publicdata',2)])
        observed = bytearray(candidates(item[2]));observed[-1]=5
        self.run_probe('bind',self.file(item[0]),item[1],self.file(observed))
        self.run_probe('bind',self.file(item[0]),item[1],self.file(observed[:57]),status='missing')

    def test_dlc_count_and_candidate_limits(self):
        items = [cnmt()]+[cnmt(DLC+i,1,0x82) for i in range(65)]
        self.plan(items,status='limit')
        item = cnmt()
        self.plan([item],candidates(item[2])*16385,status='limit')

    def test_full_candidate_ids_with_shared_prefixes_are_not_aliases(self):
        records = []
        for i in range(256):
            digest = b'\xaa'*15+bytes((i,))+hashlib.sha256(str(i).encode()).digest()[:16]
            records.append({'sha':digest,'id':digest[:16],'size':10+i,'role':1,'offset':i})
        item = cnmt(contents=list(reversed(records)))
        observed = candidates(records)
        self.assertEqual(self.plan([item],observed)['base'],0)
        self.plan([item],observed[:-57],status='missing')
        # Duplicate full IDs remain ambiguous even when their other fields differ.
        self.plan([item],observed+observed[-57:],status='invalid')

    def test_maximum_candidate_index_reused_across_all_selected_metadata(self):
        records = []
        for i in range(16384):
            digest = b'\xa5'*14+i.to_bytes(2,'big')+hashlib.sha256(str(i).encode()).digest()[:16]
            records.append({'sha':digest,'id':digest[:16],'size':1024+i,'role':(i//256)%6,'offset':i%256})
        #1536 records span every supported role/id_offset pair exactly once.
        #66 selected catalogs previously forced over1.4b linear comparisons.
        selected = records[-1536:]
        items = [cnmt(contents=selected),cnmt(PATCH,7,0x81,contents=selected)]
        items += [cnmt(DLC+i,1,0x82,contents=selected) for i in range(64)]
        result = self.plan(items,candidates(list(reversed(records))))
        self.assertEqual((result['version'],len(result['dlc'])),(7,64))
        self.assertGreater(result['comparisons'],0)
        self.assertLess(result['comparisons'],4_000_000)


if __name__=='__main__':
    unittest.main()
