"""Actual pinned in-process SPIRV-Cross and NativeAOT gates, original shaders only.

No fixture ever borrows a game's shader. Missing dependency source/compiler is
an explicit skip; managed and iOS proofs are separate from native Cross tests.
"""
import base64
import concurrent.futures
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'games/totk/tools/totk_xlate'
PIN='aa217aeb6c9f0ace7a0ab233b28807edf45eb165'


def original_compute_spirv():
    # Khronos SPIR-V word encoding: Shader, Logical/GLSL450, GLCompute main,
    # LocalSize1, void function returning immediately. IDs1..4, no resources.
    words=[0x07230203,0x10000,0,5,0,0x20011,1,0x3000e,0,1,
           0x5000f,5,3,0x6e69616d,0,0x60010,3,17,1,1,1,
           0x20013,1,0x30021,2,1,0x50036,1,3,0,2,0x200f8,4,0x100fd,0x10038]
    return struct.pack('<'+'I'*len(words),*words)


def original_compute_maxwell():
    # Grounded in vendored InstTable.cs Exit/Nop, InstExit Pred7/Ccc.T=15;
    # Decoder.cs skips the scheduling word at each32-byte boundary.
    # This is authored opcode data, not extracted game code. Successful
    # translation must be demonstrated by the NativeAOT+CLI parity gate.
    return struct.pack('<4Q',0,0xe30000000007000f,0x50b0000000070f00,0x50b0000000070f00)


def original_request():
    key=hashlib.sha256(original_compute_maxwell()).hexdigest()
    return {'variant':key+'-'+hashlib.sha256(b'original answers').hexdigest()[:12],
            'stage':'cs','chain':'original-native-probe-v1','local':[1,1,1],
            'tex':{},'img':{},'attr':{},'fout':{},'c1':'','debug':False,'depth_minus_w':False}


class FixtureContractTests(unittest.TestCase):
    @staticmethod
    def builder():
        spec=importlib.util.spec_from_file_location('shader_library_builder',TOOLS/'publish_library.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

    def test_dependency_rejects_untracked_and_ignored_headers(self):
        if not shutil.which('git'):self.skipTest('git required for local provenance fixture')
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp)
            def git(*args):return subprocess.check_output(['git','-C',str(folder),*args],text=True).strip()
            git('init','-q');(folder/'tracked.h').write_text('original')
            (folder/'.gitignore').write_text('ignored.h\n');git('add','.')
            git('-c','user.name=Original Fixture','-c','user.email=fixture@example.invalid','commit','-qm','Original public fixture')
            pin=git('rev-parse','HEAD');builder=self.builder();builder.validate_cross_source(folder,pin)
            for name in ('injected.h','ignored.h'):
                (folder/name).write_text('injected')
                with self.assertRaises(ValueError):builder.validate_cross_source(folder,pin)
                (folder/name).unlink()
            (folder/'tracked.h').write_text('changed')
            with self.assertRaises(ValueError):builder.validate_cross_source(folder,pin)

    def test_tree_identity_binds_vendor_and_product_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);file=folder/'compiler.cs';file.write_bytes(b'original')
            builder=self.builder();before=builder.tree_digest(folder);records=builder.file_records(folder)
            self.assertEqual(records['compiler.cs']['sha256'],hashlib.sha256(b'original').hexdigest())
            file.write_bytes(b'changed');self.assertNotEqual(before,builder.tree_digest(folder))
            file.rename(folder/'renamed.cs');self.assertNotEqual(before,builder.tree_digest(folder))

    def test_original_instruction_vector_source_contract(self):
        code=original_compute_maxwell();self.assertEqual(len(code),32)
        word=struct.unpack_from('<Q',code,8)[0]
        self.assertEqual(word>>52,0xe30);self.assertEqual((word>>16)&7,7);self.assertEqual(word&31,15)
        self.assertEqual(struct.unpack_from('<I',original_compute_spirv())[0],0x07230203)


class InProcessCrossTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source=Path(os.environ.get('CANOPY_SPIRV_CROSS_SOURCE',ROOT/'games/totk/build/native-shader/SPIRV-Cross'))
        if not shutil.which('c++') or not (source/'spirv_msl.cpp').exists():
            raise unittest.SkipTest('Requires installed C++ compiler and existing exact-pinned public Cross source; no downloads by tests')
        pin=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
        if pin!=PIN:raise AssertionError('Wrong public SPIRV-Cross commit')
        clean=subprocess.check_output(['git','-C',str(source),'status','--porcelain','--untracked-files=all','--ignored'],text=True)
        if clean.strip():raise AssertionError('Cross source contains modified, untracked or ignored files')
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup)
        folder=Path(cls.temp.name);cls.library=folder/('libcross.dylib' if sys.platform=='darwin' else 'libcross.so')
        sources=['spirv_cross.cpp','spirv_parser.cpp','spirv_cross_parsed_ir.cpp','spirv_cfg.cpp','spirv_glsl.cpp','spirv_msl.cpp']
        command=['c++','-std=c++11','-O1','-fPIC','-dynamiclib' if sys.platform=='darwin' else '-shared',
                 '-I',str(source),str(TOOLS/'inprocess_cross.cpp'),*[str(source/s) for s in sources],'-o',str(cls.library)]
        run=subprocess.run(command,capture_output=True,text=True,timeout=180)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
        cls.lib=ctypes.CDLL(str(cls.library));cls.cross=cls.lib.canopy_spirv_cross
        cls.cross.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t)]
        cls.cross.restype=ctypes.c_int

    def call(self,data,capacity=65536):
        src=ctypes.create_string_buffer(data);out=ctypes.create_string_buffer(b'Z'*capacity,capacity);n=ctypes.c_size_t(999)
        status=self.cross(src,len(data),out,capacity,ctypes.byref(n))
        return status,out.raw,n.value

    def test_original_compute_actual_msl(self):
        status,data,n=self.call(original_compute_spirv());self.assertEqual(status,0)
        self.assertIn(b'kernel void main0',data[:n]);self.assertIn(b'metal_stdlib',data[:n])
        self.assertEqual(data[n:],b'Z'*(len(data)-n))

    def test_null_length_and_pointer_capacity_validation(self):
        data=ctypes.create_string_buffer(original_compute_spirv());n=ctypes.c_size_t(99)
        self.assertEqual(self.cross(data,len(original_compute_spirv()),None,0,None),1)
        self.assertEqual(self.cross(data,len(original_compute_spirv()),None,10,ctypes.byref(n)),1)
        self.assertEqual(n.value,0)

    def test_output_capacity_does_not_write_partial(self):
        status,data,n=self.call(original_compute_spirv(),1);self.assertEqual(status,2)
        self.assertGreater(n,1);self.assertEqual(data,b'Z')

    def test_invalid_header_alignment_id_bound_and_exception(self):
        for data in (b'',b'x'*21,b'\0'*20,struct.pack('<5I',0x07230203,0x10000,0,262145,0),
                     struct.pack('<6I',0x07230203,0x10000,0,1,0,0xffffffff)):
            status,output,n=self.call(data);self.assertNotEqual(status,0);self.assertEqual(n,0)
            self.assertEqual(output,b'Z'*len(output))

    def test_concurrent_independent_compilers(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda _:self.call(original_compute_spirv()),range(20)))
        self.assertTrue(all(status==0 for status,_,_ in results))
        self.assertTrue(all(result==results[0] for result in results))

    @unittest.skipUnless(os.environ.get('CANOPY_SPIRV_CROSS_CLI'),'Requires actual pinned CLI binary for independent Cross parity')
    def test_existing_cli_flags_byte_parity(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);(path/'original.spv').write_bytes(original_compute_spirv())
            subprocess.run([os.environ['CANOPY_SPIRV_CROSS_CLI'],'--msl','--msl-version','20300',
                '--msl-argument-buffers','--msl-texture-buffer-native','--msl-pad-fragment-output',
                str(path/'original.spv'),'--output',str(path/'output.metal')],check=True,timeout=30)
            status,data,n=self.call(original_compute_spirv());self.assertEqual(status,0)
            self.assertEqual(data[:n],(path/'output.metal').read_bytes())


@unittest.skipUnless(os.environ.get('CANOPY_SHADER_NATIVE_PROBE') and os.environ.get('CANOPY_SHADER_CLI') and
                     os.environ.get('CANOPY_SPIRV_CROSS_CLI'),
                     'Requires actually linked static NativeAOT probe and existing CLI/Cross binaries')
class NativeAOTParityTests(unittest.TestCase):
    def test_actual_static_abi_error_capacity_and_concurrency(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);code=folder/'original.bin';code.write_bytes(original_compute_maxwell())
            request=folder/'request.json';request.write_text(json.dumps(original_request()))
            run=subprocess.run([os.environ['CANOPY_SHADER_NATIVE_PROBE'],'--self-test',str(code),str(request)],
                               capture_output=True,text=True,timeout=60)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertEqual(json.loads(run.stdout)['status'],0)

    def test_original_maxwell_full_cli_parity(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);code=folder/'original.bin';code.write_bytes(original_compute_maxwell())
            request=original_request();rq=folder/'request.json';rq.write_text(json.dumps(request));output=folder/'native.json'
            run=subprocess.run([os.environ['CANOPY_SHADER_NATIVE_PROBE'],str(code),str(rq),str(output)],
                               capture_output=True,text=True,timeout=60)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr);native=json.loads(output.read_bytes())
            cli_request=dict(request,code=str(code));cli=folder/'cli';cli.mkdir()
            run=subprocess.run([os.environ['CANOPY_SHADER_CLI'],'--service','--spirv-cross',os.environ['CANOPY_SPIRV_CROSS_CLI'],
                '--out',str(cli),'--chain',request['chain'],'--debug-mode','0'],input=json.dumps(cli_request)+'\n',
                text=True,capture_output=True,timeout=60)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            variant=request['variant'];self.assertEqual(base64.b64decode(native['spirv_base64']),(cli/(variant+'.spv')).read_bytes())
            self.assertEqual(native['metal'],(cli/(variant+'_b.metal')).read_text())
            self.assertEqual(native['reflection'],json.loads((cli/(variant+'_b.json')).read_bytes()))
