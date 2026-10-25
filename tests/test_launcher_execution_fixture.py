"""Exercise production native rewrite/embed tools with wholly original ARM64 input.

These are artifact tests, not native execution, signing or gameplay tests.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'launcher_fixture', ROOT/'tools/launcher/fixture/build_fixture.py')
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
APPLE_SPEC = importlib.util.spec_from_file_location(
    'launcher_apple_probe', ROOT/'tools/launcher/fixture/build_apple_probe.py')
apple_probe = importlib.util.module_from_spec(APPLE_SPEC)
APPLE_SPEC.loader.exec_module(apple_probe)

try:
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    import lz4.block
    HAVE_REWRITE_DEPS = True
except ImportError:
    HAVE_REWRITE_DEPS = False


@unittest.skipUnless(HAVE_REWRITE_DEPS, 'production rewriter requires capstone and lz4')
class ExecutionFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.output = Path(cls.temp.name)/'build'
        cls.manifest = fixture.build(cls.output)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_original_instruction_source_agrees_with_decoder(self):
        decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        for address, word, assembly in fixture.PROGRAM:
            decoded = next(decoder.disasm(struct.pack('<I', word), address))
            actual = f'{decoded.mnemonic} {decoded.op_str}'.strip()
            self.assertEqual(actual, assembly)

    def test_real_rewrite_changes_call_and_emits_system_gates(self):
        image = (self.output/'rewritten/fixture.patched.bin').read_bytes()
        self.assertEqual(struct.unpack_from('<I', image, fixture.CALL)[0], 0xD63F03C0)
        branch = struct.unpack_from('<I', image, fixture.CALL-4)[0]
        self.assertEqual(branch & 0xfc000000, 0x14000000)
        target = fixture.CALL-4 + (((branch & 0x3ffffff) ^ 0x2000000)-0x2000000)*4
        self.assertGreaterEqual(target, 0x10000)
        self.assertLess(target, len(image))
        # The relative-pointer location stays writable data, while the unchanged
        # helper remains intact. This does not apply the runtime relocation.
        self.assertEqual(struct.unpack_from('<Q', image, fixture.DATA)[0], fixture.HELPER)
        self.assertEqual(image[fixture.HELPER:fixture.HELPER+8],
                         struct.pack('<II', 0x91001C00, 0xD65F03C0))
        sites = (self.output/'rewritten/fixture.sites.tsv').read_text()
        self.assertIn('0x110\tC\t0x118', sites)
        self.assertIn('0x180\ttpidr_r', sites)
        self.assertIn('0x1c0\tsvc', sites)
        self.assertIn('\tsvc\t1\t', (self.output/'rewritten/fixture.gates.tsv').read_text())

    @unittest.skipUnless(shutil.which('cc'), 'requires native C compiler for actual Module ABI')
    def test_generated_original_metadata_compiles_against_production_module_abi(self):
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/'metadata.c';binary=Path(temporary)/'metadata'
            source.write_text('''#define _POSIX_C_SOURCE 200809L
#include "runtime.h"
#include "fixture_module.h"
#include <assert.h>
#include <string.h>
int main(void) {
    assert(sizeof(modules)/sizeof(*modules)==1);
    Module *m=modules;
    assert(!strcmp(m->name,"fixture") && strlen(m->digest)==64);
    assert(m->nsym==5 && m->nreloc==1 && m->ngate==1);
    assert(!strcmp(m->symbols[3].name,"fixture_tls") && m->symbols[3].value==0x180);
    assert(!strcmp(m->symbols[4].name,"fixture_service") && m->symbols[4].value==0x1c0);
    assert(m->relocs[0].where==0x8000 && m->relocs[0].kind==1027 && m->relocs[0].addend==0x140);
    assert(m->gates[0].arg==1 && !m->gates[0].timer && m->gates[0].original==0x1c0);
    assert(m->gates[0].ret>=m->patch_off && m->gates[0].ret<m->file_size);
    return 0;
}
''')
            build=subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',
                '-I'+str(ROOT/'games/totk/runtime'),'-I'+str(self.output/'generated'),
                str(source),'-o',str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)

    def test_fixture_metadata_refuses_wrong_layout_relocation_symbols_and_gate(self):
        image=(self.output/'rewritten/fixture.patched.bin').read_bytes()
        for offset,format,value in ((fixture.RELA,'<Q',0), (fixture.HASH+4,'<I',65),
                                    (fixture.SYMBOLS+24,'<I',128)):
            with self.subTest(offset=offset):
                changed=bytearray(image);struct.pack_into(format,changed,offset,value)
                with self.assertRaises(ValueError):fixture.module_metadata(changed,self.output/'rewritten')
        with tempfile.TemporaryDirectory() as temporary:
            rewrite=Path(temporary);shutil.copytree(self.output/'rewritten',rewrite,dirs_exist_ok=True)
            (rewrite/'fixture.gates.tsv').write_text('0x10064\tsvc\t2\t0x1c0\n')
            with self.assertRaises(ValueError):fixture.module_metadata(image,rewrite)
            shutil.copy2(self.output/'rewritten/fixture.gates.tsv',rewrite/'fixture.gates.tsv')
            path=rewrite/'fixture.fixups.tsv';path.write_text(path.read_text().replace('KEY_PAGE_OFF\t0xc000','KEY_PAGE_OFF\t0x8000'))
            with self.assertRaises(ValueError):fixture.module_metadata(image,rewrite)

    def test_embed_sections_hash_exact_rewritten_bytes_and_padding(self):
        image = (self.output/'rewritten/fixture.patched.bin').read_bytes()
        chunks = (image[:0x4000], image[0x4000:0x10000], image[0x10000:])
        chunks = tuple(x + bytes((-len(x)) % 0x4000) for x in chunks)
        header = (self.output/'generated/ios_embed.h').read_text()
        self.assertEqual(re.findall(r'"([0-9a-f]{64})"', header),
                         [hashlib.sha256(x).hexdigest() for x in chunks])
        assembly = (self.output/'generated/embed.S').read_text()
        self.assertIn('.section __TOTKX,__fixturex0', assembly)
        self.assertIn('.section __TOTKfixtureW,__img', assembly)
        self.assertIn('.section __TOTKX,__fixturex1', assembly)
        self.assertEqual(assembly.count('.p2align 14'), 6)
        flags = (self.output/'generated/linker-flags.txt').read_text()
        self.assertIn('-segprot,__TOTKfixtureW,rw,rw', flags)
        self.assertIn('-segprot,__TOTKX,r-x,r-x', flags)

    def test_record_contains_verifiable_outputs_and_no_execution_claim(self):
        record = json.loads((self.output/'manifest.json').read_text())
        self.assertEqual(record['native_execution'], 'not_run')
        self.assertEqual(record['apple_signing'], 'not_run')
        for name, expected in record['files'].items():
            self.assertEqual(hashlib.sha256((self.output/name).read_bytes()).hexdigest(), expected)
        for name, expected in record['inputs'].items():
            self.assertEqual(hashlib.sha256((ROOT/name).read_bytes()).hexdigest(), expected)
        with self.assertRaises(FileExistsError):
            fixture.build(self.output)

    def test_apple_input_verifier_accepts_original_fixture(self):
        self.assertEqual(apple_probe.verify_fixture(self.output), self.manifest)

    def test_apple_input_verifier_rejects_cross_directory_incbin(self):
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary)/'copied'
            shutil.copytree(self.output, copied)
            # Every copied byte still matches its manifest. The assembler would
            # nevertheless read the original directory through absolute paths.
            with self.assertRaisesRegex(ValueError, 'outside the selected fixture.*regenerate'):
                apple_probe.verify_fixture(copied)

    def test_apple_input_verifier_rejects_moved_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            original, moved = Path(temporary)/'original', Path(temporary)/'moved'
            fixture.build(original)
            original.rename(moved)
            with self.assertRaisesRegex(ValueError, 'regenerate the fixture at its current location'):
                apple_probe.verify_fixture(moved)

    def test_apple_input_verifier_rejects_changed_referenced_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary)/'original'
            fixture.build(original)
            text = original/'text/fixture.x0.bin'
            changed = bytearray(text.read_bytes())
            changed[0] ^= 1
            text.write_bytes(changed)
            with self.assertRaisesRegex(ValueError, 'fixture changed after generation: text/fixture.x0.bin'):
                apple_probe.verify_fixture(original)

    def test_apple_input_verifier_requires_referenced_file_in_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary)/'original'
            manifest = fixture.build(original)
            del manifest['files']['text/fixture.x0.bin']
            (original/'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, '.incbin input is missing from manifest'):
                apple_probe.verify_fixture(original)

    def reject_rewrite(self, offset, value, reason):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)/'bad.nso'
            data = bytearray(fixture.original_nso())
            # All tested locations are in the first, uncompressed text segment.
            struct.pack_into('<I', data, 0x100+offset, value)
            source.write_bytes(data)
            with self.assertRaises(subprocess.CalledProcessError) as rejected:
                fixture.run_rewriter(source, Path(temporary)/'rewritten')
            self.assertIn(reason, rejected.exception.stderr)

    def test_direct_branch_cannot_enter_unprepared_call(self):
        target = fixture.CALL
        self.reject_rewrite(0x200, 0x14000000 | (((target-0x200)//4) & 0x3ffffff),
                            'branch into call without preparation')

    def test_call_prefix_must_be_replayable_stack_access(self):
        self.reject_rewrite(fixture.CALL-4, 0xD503201F,
                            'Call prefix must be a non-writeback stack access')

    def test_invalid_mod0_is_rejected(self):
        self.reject_rewrite(4, 0x4004, 'AssertionError')

    def test_embed_rejects_truncated_exported_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work/'fixture.x0.bin').write_bytes(b'\0'*0x3fff)
            result = subprocess.run([sys.executable, str(fixture.EMBEDDER),
                str(self.output/'rewritten'), str(work/'embed.S'), '--text-dir',
                str(work), 'fixture'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('exported x0 must be exactly 0x4000 bytes', result.stderr)
            self.assertFalse((work/'embed.S').exists())


class AppleProbeIdentity(unittest.TestCase):
    def test_dedicated_bundle_ids(self):
        for bundle_id in ('org.macnativegames.executionfixture', 'com.example.executionfixture'):
            apple_probe.validate_bundle_id(bundle_id)
        for bundle_id in ('org.macnativegames.totk', 'org.macnativegames.botw',
                          'executionfixture', 'com.example.executionfixture.extra',
                          'com.example.bad id.executionfixture'):
            with self.subTest(bundle_id=bundle_id):
                with self.assertRaisesRegex(ValueError, 'dedicated bundle ID'):
                    apple_probe.validate_bundle_id(bundle_id)


if __name__ == '__main__':
    unittest.main()
