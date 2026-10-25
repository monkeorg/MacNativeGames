"""Original synthetic BKTR images; independent AES/IVFC/relocation oracle.

No game data, key downloads, external executables or CPU emulation. The table
layout is the pinned public hactool BKTR contract documented in mng_bktr.c.
"""
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

ROOT=Path(__file__).resolve().parents[1]
PAGE=0x4000
KEY=bytes(range(16))
PREFIX=bytes.fromhex('0123456789abcdef')
SECTION=0xc00


def ctr(data,offset,prefix):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    counter=prefix+(offset//16).to_bytes(8,'big')
    cipher=Cipher(algorithms.AES(KEY),modes.CTR(counter)).encryptor()
    skip=offset%16
    return cipher.update(bytes(skip)+data)[skip:]+cipher.finalize()


def ivfc(payload):
    levels=[b'']*6
    levels[5]=payload
    for i in range(4,-1,-1):
        levels[i]=b''.join(hashlib.sha256(levels[i+1][at:at+4096].ljust(4096,b'\0')).digest()
                           for at in range(0,len(levels[i+1]),4096))
    image=bytearray((5*4096+len(payload)+511)//512*512)
    fs=bytearray(512)
    fs[2:5]=bytes((0,3,4));fs[8:12]=b'IVFC'
    struct.pack_into('<III',fs,12,0x20000,32,7)
    for i,data in enumerate(levels):
        image[i*4096:i*4096+len(data)]=data
        struct.pack_into('<QQII',fs,0x18+24*i,i*4096,len(data),12,0)
    fs[0xc8:0xe8]=hashlib.sha256(levels[0].ljust(4096,b'\0')).digest()
    fs[0x140:0x148]=PREFIX[::-1]
    return image,fs


def table(entries,total,relocations):
    width=20 if relocations else 16
    capacity=(PAGE-16)//width
    groups=[entries[i:i+capacity] for i in range(0,len(entries),capacity)]
    raw=bytearray(PAGE*(len(groups)+1))
    struct.pack_into('<IIQ',raw,0,0,len(groups),total)
    for i,group in enumerate(groups):
        struct.pack_into('<Q',raw,16+8*i,group[0][0])
        boundary=groups[i+1][0][0] if i+1<len(groups) else total
        at=(i+1)*PAGE
        struct.pack_into('<IIQ',raw,at,i,len(group),boundary)
        for j,entry in enumerate(group):
            struct.pack_into('<QQI' if relocations else '<QII',raw,at+16+j*width,*entry)
    return raw


def fixture(payload=None,relocations=None,subsections=None,legacy_total=False,trailing=0,mutate=None):
    if payload is None:
        payload=bytes(range(251))*80
    virtual,fs=ivfc(payload)
    if relocations is None:
        relocations=[(0,0,0),(0x5007,0x23,1),(0x5133,0x5133,0),
                     (0x6001,0x800,1),(len(virtual)-17,len(virtual)-17,0)]
    if subsections is None:
        subsections=[(0,0,0x1020304),(0x100,0,0xaabbccdd),(0x1000,0,0x02030405)]
    physical_end=max([PAGE,subsections[-1][0]+1]+[
        physical+(relocations[i+1][0] if i+1<len(relocations) else len(virtual))-start
        for i,(start,physical,patch) in enumerate(relocations) if patch])
    physical_end=(physical_end+PAGE-1)//PAGE*PAGE
    base=bytearray(virtual)
    physical=bytearray(physical_end)
    for i,(start,at,patch) in enumerate(relocations):
        end=relocations[i+1][0] if i+1<len(relocations) else len(virtual)
        if patch:
            physical[at:at+end-start]=virtual[start:end]
            base[start:end]=bytes(b^0xa5 for b in base[start:end])
    rel=table(relocations,len(virtual),True)
    sub=table(subsections,physical_end+len(rel) if legacy_total else physical_end,False)
    section=physical+rel+sub+bytes(trailing)
    struct.pack_into('<QQ4sIII',fs,0x100,physical_end,len(rel),b'BKTR',1,len(relocations),0)
    struct.pack_into('<QQ4sIII',fs,0x120,physical_end+len(rel),len(sub),b'BKTR',1,len(subsections),0)
    layout={'reloc':physical_end,'sub':physical_end+len(rel),'end':physical_end,
            'reloc_size':len(rel),'sub_size':len(sub),'virtual':len(virtual)}
    if mutate:
        mutate(base,section,fs,layout)
    encrypted=bytearray(len(section))
    for i,(start,_,counter) in enumerate(subsections):
        end=subsections[i+1][0] if i+1<len(subsections) else physical_end
        encrypted[start:end]=ctr(bytes(section[start:end]),SECTION+start,PREFIX[:4]+counter.to_bytes(4,'big'))
    encrypted[physical_end:]=ctr(bytes(section[physical_end:]),SECTION+physical_end,PREFIX)
    return bytes(base),bytes(SECTION)+encrypted,bytes(fs),bytes(virtual),layout


@unittest.skipUnless(shutil.which('cc') and importlib.util.find_spec('cryptography'),
                     'native compiler and independent cryptography oracle required')
class CanopyBktrTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        cls.probe=Path(cls.build.name)/'bktr-probe'
        command=['cc','-std=c11','-Wall','-Wextra','-Wpedantic','-Werror',
                 '-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(ROOT/'launcher/include'),
                 str(ROOT/'launcher/src/mng_bktr.c'),str(ROOT/'launcher/src/mng_crypto.c'),
                 str(ROOT/'launcher/tests/bktr_probe.c')]
        if sys.platform!='darwin':command+=['-lcrypto']
        result=subprocess.run(command+['-o',str(cls.probe)],capture_output=True,text=True)
        if result.returncode:raise AssertionError(result.stdout+result.stderr)

    def setUp(self):
        self.workspace=tempfile.TemporaryDirectory();self.addCleanup(self.workspace.cleanup)
        self.root=Path(self.workspace.name);self.serial=0

    def run_fixture(self,parts,mode='normal',status='ok'):
        self.serial+=1
        work=self.root/str(self.serial);work.mkdir()
        base,patch,fs,expected,_=parts
        for name,data in (('base',base),('patch',patch),('fs',fs)):(work/name).write_bytes(data)
        result=subprocess.run([str(self.probe),str(work/'base'),str(work/'patch'),
            str(work/'fs'),str(work/'result'),mode],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(result.stderr,'')
        report=json.loads(result.stdout)
        self.assertEqual(report['status'],status,report)
        self.assertTrue(report['preserved'])
        if status=='ok':
            self.assertEqual((work/'result').read_bytes(),expected)
            self.assertEqual(report['virtualSize'],len(expected))
            self.assertEqual(report['preverify'],7) # range unavailable before IVFC
            self.assertGreater(report['progress'],6)
        return work,report

    def test_exact_native_virtual_merge_crosses_relocations_and_ctr_subsections(self):
        parts=fixture(payload=bytes(range(251))*1200)
        _,report=self.run_fixture(parts)
        self.assertEqual(report['romfsOffset'],5*4096)
        self.assertEqual(report['romfsSize'],251*1200)
        self.assertGreater(report['reads'],20)

    def test_legacy_subsection_total_and_sector_aligned_trailing_padding(self):
        self.run_fixture(fixture(legacy_total=True,trailing=1024))

    def test_multiple_relocation_and_subsection_buckets(self):
        relocations=[(i,i,0) for i in range(820)]
        subsections=[(i*32,0,i) for i in range(1025)]
        self.run_fixture(fixture(relocations=relocations,subsections=subsections))

    def test_short_source_adapter_reads_and_plain_base_only_segments(self):
        self.run_fixture(fixture(),mode='short')
        self.run_fixture(fixture(relocations=[(0,0,0)]))

    def test_io_cancellation_mutation_and_request_bounds_fail_closed(self):
        for mode,status in (('io','io'),('cancel-initial','cancelled'),('cancel-tables','cancelled'),
                            ('cancel-verify','cancelled'),('mutate','integrity'),('bounds','invalid')):
            with self.subTest(mode=mode):self.run_fixture(fixture(),mode,status)

    def test_wrong_key_and_corrupted_patch_payload_cannot_verify(self):
        self.run_fixture(fixture(),mode='wrong-key',status='invalid')
        def change(base,section,fs,layout):section[0x23]^=1
        self.run_fixture(fixture(mutate=change),status='integrity')

    def test_every_ivfc_level_and_master_hash_is_verified(self):
        for level in range(6):
            def change(base,section,fs,layout,level=level):base[level*4096]^=1
            with self.subTest(level=level):self.run_fixture(fixture(mutate=change),status='integrity')
        def master(base,section,fs,layout):fs[0xc8]^=1
        self.run_fixture(fixture(mutate=master),status='integrity')

    def test_relocation_bucket_counts_anchors_flags_and_physical_ranges(self):
        mutations=[lambda b,s,f,l:struct.pack_into('<I',s,l['reloc']+4,0),
            lambda b,s,f,l:struct.pack_into('<Q',s,l['reloc']+16,1),
            lambda b,s,f,l:struct.pack_into('<I',s,l['reloc']+PAGE+4,819),
            lambda b,s,f,l:struct.pack_into('<I',s,l['reloc']+PAGE+16+16,2),
            lambda b,s,f,l:struct.pack_into('<Q',s,l['reloc']+PAGE+16+8,1<<40),
            lambda b,s,f,l:struct.pack_into('<Q',s,l['reloc']+PAGE+16+20,0)]
        for i,change in enumerate(mutations):
            with self.subTest(case=i):self.run_fixture(fixture(mutate=change),status='invalid')

    def test_subsection_counts_order_coverage_and_padding(self):
        mutations=[lambda b,s,f,l:struct.pack_into('<Q',s,l['sub']+8,l['end']+1),
            lambda b,s,f,l:struct.pack_into('<Q',s,l['sub']+PAGE+16,1),
            lambda b,s,f,l:struct.pack_into('<Q',s,l['sub']+PAGE+16+16,0),
            lambda b,s,f,l:struct.pack_into('<I',s,l['sub']+PAGE+4,1024)]
        for i,change in enumerate(mutations):
            with self.subTest(case=i):self.run_fixture(fixture(mutate=change),status='invalid')
        def reserved(base,section,fs,layout):struct.pack_into('<I',section,layout['sub']+PAGE+16+8,1)
        self.run_fixture(fixture(mutate=reserved),status='unsupported')

    def test_header_versions_entry_and_table_quotas_and_layout_bounds(self):
        for at,value,status in ((0x114,2,'unsupported'),(0x11c,1,'unsupported'),
                                (0x118,262145,'limit'),(0x108,32*1024*1024+PAGE,'limit'),
                                (0x120,1<<40,'invalid'),(0x128,1,'invalid')):
            def change(base,section,fs,layout,at=at,value=value):
                struct.pack_into('<Q' if at in (0x108,0x120,0x128) else '<I',fs,at,value)
            with self.subTest(at=at):self.run_fixture(fixture(mutate=change),status=status)

    def test_ivfc_level_bounds_overlap_parent_capacity_and_powers(self):
        mutations=[(0x18,1<<40,'<Q','invalid'),(0x18+24,0,'<Q','invalid'),
                   (0x18+16,11,'<I','unsupported'),(0x18+20,1,'<I','unsupported'),
                   (0x18+8,8192,'<Q','invalid')]
        for at,value,fmt,status in mutations:
            def change(base,section,fs,layout,at=at,value=value,fmt=fmt):struct.pack_into(fmt,fs,at,value)
            with self.subTest(at=at):self.run_fixture(fixture(mutate=change),status=status)


if __name__=='__main__':unittest.main()
