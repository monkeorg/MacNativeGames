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


def original_collection_spirv(count=64):
    # Original structured compute module: an unused uint struct/function type,
    # a switch whose labels merge immediately, then a one-incoming Phi. This
    # exercises actual parser collection and CFG case/predecessor processing.
    words=[0x07230203,0x10000,0,12,0,0x20011,1,0x3000e,0,1,
           0x5000f,5,3,0x6e69616d,0,0x60010,3,17,1,1,1,
           0x20013,1,0x30021,2,1,0x40015,5,32,0,0x4002b,5,6,0]
    words += [((2+count)<<16)|30,8]+[5]*count
    words += [((3+count)<<16)|33,9,1]+[5]*count
    words += [0x50036,1,3,0,2,0x200f8,4,0x300f7,7,0,((3+2*count)<<16)|251,6,7]
    for literal in range(count):words += [literal,7]
    words += [0x200f8,7,0x500f5,5,11,6,4,0x100fd,0x10038]
    return struct.pack('<'+'I'*len(words),*words)


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

    def test_native_dependency_plan_preserves_real_arguments_and_refuses_empty_or_nul(self):
        with tempfile.TemporaryDirectory() as temp:
            plan=Path(temp)/'link.args';builder=self.builder()
            plan.write_text('\ufeff"/a directory/libRuntime.a"\n-framework Foundation\n-isysroot "/an SDK"\n')
            self.assertEqual(builder.read_link_plan(plan),['/a directory/libRuntime.a','-framework','Foundation','-isysroot','/an SDK'])
            for invalid in ('','\0','"unterminated'):
                plan.write_text(invalid)
                with self.assertRaises(ValueError):builder.read_link_plan(plan)

    def test_checked_vendor_patches_refuse_mutation_and_reapplication_without_touching_original(self):
        builder=self.builder();original=ROOT/'vendor/ryujinx/src/Ryujinx.Graphics.Shader/Translation/Optimizations/Optimizer.cs'
        original_hash=hashlib.sha256(original.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            private=Path(temp)/'vendor';shutil.copytree(ROOT/'vendor/ryujinx',private,ignore=shutil.ignore_patterns('.git','bin','obj'))
            target=private/original.relative_to(ROOT/'vendor/ryujinx');target.write_bytes(target.read_bytes()+b'\n// mutation\n')
            with self.assertRaises(ValueError):builder.checked_patches(private,TOOLS/'patches')
            # Restart from the exact original copy after an explicit refusal.
            shutil.rmtree(private);shutil.copytree(ROOT/'vendor/ryujinx',private,ignore=shutil.ignore_patterns('.git','bin','obj'))
            builder.checked_patches(private,TOOLS/'patches')
            self.assertTrue((private/'src/Ryujinx.Common/Utilities/CanopyTranslationGuard.cs').is_file())
            with self.assertRaises(ValueError):builder.checked_patches(private,TOOLS/'patches')
        self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(),original_hash)

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
        private=folder/'cross-source';shutil.copytree(source,private,ignore=shutil.ignore_patterns('.git'))
        FixtureContractTests.builder().checked_patches(private,TOOLS/'cross_patches')
        sources=['spirv_cross.cpp','spirv_parser.cpp','spirv_cross_parsed_ir.cpp','spirv_cfg.cpp','spirv_glsl.cpp','spirv_msl.cpp']
        command=['c++','-std=c++11','-O1','-fPIC','-dynamiclib' if sys.platform=='darwin' else '-shared',
                 '-I',str(private),'-I',str(TOOLS),str(TOOLS/'inprocess_cross.cpp'),str(TOOLS/'canopy_cross_budget.cpp'),*[str(private/s) for s in sources],'-o',str(cls.library)]
        run=subprocess.run(command,capture_output=True,text=True,timeout=180)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
        cls.lib=ctypes.CDLL(str(cls.library));cls.cross=cls.lib.canopy_spirv_cross
        cls.cross.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t)]
        cls.cross.restype=ctypes.c_int
        cls.checkpoint=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_void_p,ctypes.c_uint64,ctypes.c_uint64,ctypes.c_uint64)
        cls.controlled=cls.lib.canopy_spirv_cross_controlled
        cls.controlled.argtypes=cls.cross.argtypes+[cls.checkpoint,ctypes.c_void_p];cls.controlled.restype=ctypes.c_int
        cls.walk_probe=folder/'walk-probe'
        run=subprocess.run(['c++','-std=c++11','-Wall','-Wextra','-Werror','-fsanitize=address','-fno-omit-frame-pointer',
            '-I',str(private),'-I',str(TOOLS),str(ROOT/'tests/canopy_shader_walk_probe.cpp'),str(cls.library),
            '-Wl,-rpath,'+str(folder),'-o',str(cls.walk_probe)],capture_output=True,text=True,timeout=120)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)
        cls.flush_probe=folder/'flush-probe'
        run=subprocess.run(['c++','-std=c++11','-Wall','-Wextra','-Werror','-fsanitize=address','-fno-omit-frame-pointer',
            '-I',str(private),'-I',str(TOOLS),str(ROOT/'tests/canopy_shader_flush_probe.cpp'),str(cls.library),
            '-Wl,-rpath,'+str(folder),'-o',str(cls.flush_probe)],capture_output=True,text=True,timeout=120)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)

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

    def test_actual_internal_checkpoint_cancel_and_quota_leave_output_unchanged(self):
        data=ctypes.create_string_buffer(original_compute_spirv());output=ctypes.create_string_buffer(b'Z'*65536,65536)
        for refusal in (5,6):
            calls=[]
            def poll(context,work,nodes,tracked):
                calls.append((work,nodes,tracked));return refusal if len(calls)>5 else 0
            callback=self.checkpoint(poll);n=ctypes.c_size_t(99)
            status=self.controlled(data,len(original_compute_spirv()),output,len(output),ctypes.byref(n),callback,None)
            self.assertEqual(status,refusal);self.assertEqual(n.value,0);self.assertEqual(output.raw,b'Z'*65536)
            self.assertGreater(len(calls),5)
        calls=[]
        def success(context,work,nodes,tracked):calls.append((work,nodes,tracked));return 0
        callback=self.checkpoint(success);n=ctypes.c_size_t(0)
        self.assertEqual(self.controlled(data,len(original_compute_spirv()),output,len(output),ctypes.byref(n),callback,None),0)
        self.assertTrue(any(nodes for _,nodes,_ in calls));self.assertTrue(any(tracked for _,_,tracked in calls))

    def test_actual_cyclic_type_and_expression_walks_cancel_quota_and_repair(self):
        for kind in (0,1):
            for status in (5,6):
                with self.subTest(kind=kind,status=status):
                    run=subprocess.run([str(self.walk_probe),str(kind),str(status)],capture_output=True,text=True,timeout=15,
                        env=dict(os.environ,ASAN_OPTIONS='abort_on_error=1:detect_leaks=1'))
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                    self.assertEqual(run.stdout.strip(),'{"status":0}')

    def test_all_ten_actual_ir_invalidation_loops_quota_cancel_unwind_and_fresh_success(self):
        for kind in range(10):
            for status in (5,6):
                with self.subTest(kind=kind,status=status):
                    run=subprocess.run([str(self.flush_probe),str(kind),str(status)],capture_output=True,text=True,timeout=15,
                        env=dict(os.environ,ASAN_OPTIONS='abort_on_error=1:detect_leaks=1'))
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                    self.assertEqual(run.stdout.strip(),'{"status":0}')

    def test_input_sized_parser_and_cfg_collections_refuse_work_quota_and_cancel(self):
        code=original_collection_spirv();status,normal,n=self.call(code);self.assertEqual(status,0)
        self.assertIn(b'kernel void main0',normal[:n])
        source=ctypes.create_string_buffer(code)
        for refusal in (5,6):
            total=[]
            def poll(context,work,nodes,tracked):
                total.append(work);return refusal if sum(total)>=200 else 0
            callback=self.checkpoint(poll);length=ctypes.c_size_t(99);output=ctypes.create_string_buffer(b'Z'*65536,65536)
            self.assertEqual(self.controlled(source,len(code),output,len(output),ctypes.byref(length),callback,None),refusal)
            self.assertGreaterEqual(sum(total),200);self.assertEqual(length.value,0);self.assertEqual(output.raw,b'Z'*65536)
        self.assertEqual(self.call(code),(status,normal,n))

    @unittest.skipUnless(os.environ.get('CANOPY_SPIRV_CROSS_CLI'),'Requires actual pinned CLI binary for independent Cross parity')
    def test_existing_cli_flags_byte_parity(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)
            for code in (original_compute_spirv(),original_collection_spirv()):
                (path/'original.spv').write_bytes(code)
                subprocess.run([os.environ['CANOPY_SPIRV_CROSS_CLI'],'--msl','--msl-version','20300',
                    '--msl-argument-buffers','--msl-texture-buffer-native','--msl-pad-fragment-output',
                    str(path/'original.spv'),'--output',str(path/'output.metal')],check=True,timeout=30)
                status,data,n=self.call(code);self.assertEqual(status,0)
                self.assertEqual(data[:n],(path/'output.metal').read_bytes())


class CrossStreamOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source=Path(os.environ.get('CANOPY_SPIRV_CROSS_SOURCE',ROOT/'games/totk/build/native-shader/SPIRV-Cross'))
        if not shutil.which('c++') or not (source/'spirv_cross_containers.hpp').exists():
            raise unittest.SkipTest('Requires installed C++/ASan and existing exact-pinned Cross; no downloads')
        builder=FixtureContractTests.builder();builder.validate_cross_source(source)
        cls.temp=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.temp.cleanup);folder=Path(cls.temp.name)
        private=folder/'cross';shutil.copytree(source,private,ignore=shutil.ignore_patterns('.git'))
        builder.checked_patches(private,TOOLS/'cross_patches');cls.probe=folder/'stream-probe'
        run=subprocess.run(['c++','-std=c++11','-Wall','-Wextra','-Werror','-fsanitize=address','-fno-omit-frame-pointer',
            '-I',str(private),'-I',str(TOOLS),str(ROOT/'tests/canopy_shader_stream_probe.cpp'),
            str(TOOLS/'canopy_cross_budget.cpp'),'-o',str(cls.probe)],capture_output=True,text=True,timeout=120)
        if run.returncode:raise AssertionError(run.stdout+run.stderr)

    def test_heap_growth_cancel_quota_and_success_unwind_without_duplicate_free(self):
        for status in (0,5,6):
            with self.subTest(status=status):
                result=subprocess.run([str(self.probe),str(status)],capture_output=True,text=True,timeout=20,
                    env=dict(os.environ,ASAN_OPTIONS='abort_on_error=1:detect_leaks=1'))
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(result.stdout.strip(),'{"status":0}')


@unittest.skipUnless(os.environ.get('CANOPY_SHADER_NATIVE_PROBE') and os.environ.get('CANOPY_SHADER_CLI') and
                     os.environ.get('CANOPY_SPIRV_CROSS_CLI'),
                     'Requires actually linked static NativeAOT probe and existing CLI/Cross binaries')
class NativeAOTParityTests(unittest.TestCase):
    def test_first_request_interrupted_then_full_translation_succeeds(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);code=folder/'original.bin';code.write_bytes(original_compute_maxwell())
            request=folder/'request.json';request.write_text(json.dumps(original_request()))
            for limit in (4,8,12,32,128):
                with self.subTest(checkpoint=limit):
                    run=subprocess.run([os.environ['CANOPY_SHADER_NATIVE_PROBE'],'--first-cancel='+str(limit),str(code),str(request)],capture_output=True,text=True,timeout=60)
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                    self.assertEqual(json.loads(run.stdout)['status'],0)

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


@unittest.skipUnless(shutil.which('dotnet'),'Requires an existing .NET10 SDK; no SDK/package install')
class ManagedBudgetTests(unittest.TestCase):
    def test_actual_managed_budget_lifetime_quotas_cancel_deadline_and_depth(self):
        version=subprocess.check_output(['dotnet','--version'],text=True).strip()
        if int(version.split('.')[0])<10:self.skipTest('Existing SDK must support net10/C#14 vendor source')
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);private=folder/'vendor';shutil.copytree(ROOT/'vendor/ryujinx',private,ignore=shutil.ignore_patterns('.git','bin','obj'))
            FixtureContractTests.builder().checked_patches(private,TOOLS/'patches')
            from xml.sax.saxutils import escape
            sources=[TOOLS/'TranslationBudget.cs',TOOLS/'BudgetRegex.cs',ROOT/'tests/canopy_shader_budget_probe.cs',
                     private/'src/Ryujinx.Common/Utilities/CanopyTranslationGuard.cs']
            project=folder/'BudgetProbe.csproj'
            project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><AllowUnsafeBlocks>true</AllowUnsafeBlocks><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup>'+''.join('<Compile Include="'+escape(str(s),{'"':'&quot;'})+'" />' for s in sources)+'</ItemGroup></Project>')
            offline=folder/'empty-source';offline.mkdir()
            env=dict(os.environ,DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true')
            restore=subprocess.run(['dotnet','restore',str(project),'--source',str(offline)],capture_output=True,text=True,timeout=120,env=env)
            self.assertEqual(restore.returncode,0,restore.stdout+restore.stderr)
            result=subprocess.run(['dotnet','run','--no-restore','--project',str(project)],capture_output=True,text=True,timeout=120,env=env)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('{"status":0}',result.stdout)
