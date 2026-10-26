"""Real runtime-data reader and private staging, with original metadata only.

No fixture contains game images, executable instructions, fonts or private pins.
"""
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from test_canopy_private_build import BUILDER, sha

ROOT = Path(__file__).resolve().parents[1]
FILES = BUILDER.GAME_DATA_FILES


def original_tables(version='v121'):
    arrays = bytearray(); strings = bytearray(); modules = bytearray()
    for name in ('main', 'subsdk0', 'sdk'):
        symbol = len(arrays) + 688
        arrays += struct.pack('<QQIBBBB', 4, 4, len(strings), 1, 1, 2, 0)
        strings += ('original-' + name).encode() + b'\0'
        reloc = len(arrays) + 688
        arrays += struct.pack('<QIIq', 0x2010, 1027, 0, 4)
        gate = len(arrays) + 688
        arrays += struct.pack('<QQII', 0x8000, 4, 0, 0)
        arrays += struct.pack('<QQII', 0x8004, 8, 1, 1)
        modules += struct.pack('<16s72s13Q4I', name.encode(), sha(name.encode()).encode(),
            0xc000, 0x1000, 0x1000, 0x2000, 0x8000, 0x4000,
            0, 0x2000, 0x2008, 8, symbol, reloc, gate, 1, 1, 2, 0)
    header = struct.pack('<8s8sII5Q', b'TOTKTAB1', version.encode(), 3, 1, 4, 0x2010,
                         688 + len(arrays), len(strings), 688 + len(arrays) + len(strings))
    return header + modules + arrays + strings


def original_data(root, version='v121'):
    """Make generator-shaped synthetic metadata for the real staging verifier."""
    source = root / f'build/game-data/{version}'; source.mkdir(parents=True)
    index = b'original synthetic runtime index'
    path = root / f'extracted/{version}/romfs/runtime-index.bin'
    path.parent.mkdir(parents=True); path.write_bytes(index)
    recorded = sha(b'original synthetic rewriter')
    path = root / f'rewritten/{version}/build_src.sha256'
    path.parent.mkdir(parents=True); path.write_text(recorded + '\n')
    profile = {'romfs': {'size': 17, 'sha256': sha(b'original RomFS')}, 'shared_fonts_sha256': {}}
    fonts = []
    for i in range(6):
        name = f'original-{i}'; digest = sha(name.encode())
        profile['shared_fonts_sha256'][name] = digest
        fonts += [f'FONT{i}_FILE {i}-{name}.bfttf', f'FONT{i}_FILE_BYTES 9',
                  f'FONT{i}_FONT_BYTES 1', f'FONT{i}_SHA256 {digest}']
    payloads = (original_tables(version),
        (f'ROMFS_IMAGE_SIZE 17\nROMFS_IMAGE_SHA256 {profile["romfs"]["sha256"]}\n'
         f'ROMFS_INDEX_SHA256 {sha(index)}\n').encode(),
        ('\n'.join(fonts) + '\n').encode(), f'REWRITER_SHA256 {recorded}\n'.encode())
    for name, data in zip(FILES, payloads): (source / name).write_bytes(data)
    return source, profile


def manifest(directory):
    data = ('CANOPY-GAME-DATA-1\n' + ''.join(
        f'{name} {(directory / name).stat().st_size} {sha((directory / name).read_bytes())}\n'
        for name in FILES)).encode()
    (directory / 'manifest.txt').write_bytes(data)
    return sha(data)


class RuntimeDataRecipeTests(unittest.TestCase):
    def test_staged_folder_manifest_and_independent_index_match_exact_bytes(self):
        for version in ('v121', 'v143'):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); source, profile = original_data(root, version)
                before = {name: (source / name).read_bytes() for name in FILES}
                destination = root / 'runtime-data'
                result = BUILDER.stage_game_data(root, destination, version, profile)
                self.assertEqual(set(p.name for p in destination.iterdir()), {*FILES, 'manifest.txt'})
                self.assertEqual(result['manifestSHA256'], manifest(destination))
                self.assertEqual(result['runtimeIndexSHA256'], sha((root / f'extracted/{version}/romfs/runtime-index.bin').read_bytes()))
                self.assertEqual({name: (destination / name).read_bytes() for name in FILES}, before)
                self.assertEqual({name: (source / name).read_bytes() for name in FILES}, before)

    def test_staging_refuses_unexpected_output_and_config_identity_changes(self):
        for fault in ('extra', 'romfs', 'index', 'font', 'font-basename', 'rewriter', 'duplicate', 'symlink'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); source, profile = original_data(root)
                if fault == 'extra': (source / 'unexpected').write_bytes(b'original')
                elif fault == 'index': (root / 'extracted/v121/romfs/runtime-index.bin').write_bytes(b'changed')
                elif fault == 'font-basename':
                    target = source / FILES[2]
                    target.write_bytes(target.read_bytes().replace(b'0-original-0.bfttf', b'original-0'))
                elif fault == 'symlink':
                    target = source / FILES[0]; data = target.read_bytes(); target.unlink()
                    outside = root / 'outside'; outside.write_bytes(data); target.symlink_to(outside)
                else:
                    name = {'romfs': FILES[1], 'font': FILES[2], 'rewriter': FILES[3], 'duplicate': FILES[1]}[fault]
                    target = source / name; data = target.read_bytes()
                    target.write_bytes(data + data if fault == 'duplicate' else data.replace(b'SHA256 ', b'SHA256 0', 1))
                with self.assertRaises((ValueError, OSError)):
                    BUILDER.stage_game_data(root, root / 'runtime-data', 'v121', profile)
                self.assertFalse((root / 'runtime-data').exists())


PROBE = r'''
#include "game_data.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
_Noreturn void runtime_fail(const char *message){fprintf(stderr,"%s\n",message);exit(9);}
static unsigned polls, stop;
static int cancelled(void *unused){(void)unused;return ++polls>=stop;}
int main(int argc,char **argv){
    if(argc!=6)return 2;
    int fd=open(argv[1],O_RDONLY|O_DIRECTORY);if(fd<0)return 3;
    struct RuntimeGameData *data=NULL;stop=(unsigned)strtoul(argv[5],NULL,10);
    int rc=runtime_game_data_prepare_fd(fd,argv[2],argv[3],argv[4],stop?cancelled:NULL,NULL,&data);
    close(fd);
    if(rc){if(data)return 4;printf("refused %u\n",polls);return 0;}
    if(runtime_game_data_is_installed()||runtime_game_data_install(data)||!runtime_game_data_is_installed())return 5;
    /* Delete source metadata and poison the old path before consumer access. */
    char path[4096];for(unsigned i=0;i<4;i++){
        const char *names[]={"runtime-tables.bin","romfs-config.txt","shared-fonts.txt","rewriter.txt"};
        snprintf(path,sizeof path,"%s/runtime-data/%s",argv[1],names[i]);if(unlink(path))return 6;
    }
    setenv("TOTK_GAME_DATA","/missing-untrusted-override",1);
    runtime_game_data_release(data); /* An installed owner must survive release. */
    Module modules[3];uint64_t plt=0,slot=0;runtime_game_data_modules(modules,&plt,&slot);
    if(strcmp(modules[0].name,"main")||strcmp(modules[2].name,"sdk")||plt!=4||slot!=0x2010||
       modules[0].nsym!=1||strcmp(modules[0].symbols[0].name,"original-main")||modules[0].nreloc!=1||
       modules[0].ngate!=2||modules[0].gates[0].timer||modules[0].gates[1].timer!=1||
       runtime_game_number("romfs-config.txt","ROMFS_IMAGE_SIZE")!=17||
       strcmp(runtime_game_sha256("romfs-config.txt","ROMFS_IMAGE_SHA256"),argv[3]))return 7;
    puts("accepted owned-snapshot gates-0-1");return 0;
}
'''


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('cc'), 'Apple CommonCrypto and C compiler required')
class RuntimeDataReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name); source = cls.root / 'probe.c'; source.write_text(PROBE)
        cls.probes = {}
        for version in ('v121', 'v143'):
            output = cls.root / version
            run = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                '-Wno-deprecated-declarations', '-fsanitize=undefined', '-fno-sanitize-recover=all',
                '-DCANOPY_GAME_DATA_RESOURCES=1', '-DTOTK_GAME_' + version.upper() + '=1',
                '-I', str(ROOT / 'games/totk/runtime'), str(source),
                str(ROOT / 'games/totk/runtime/game_data.c'), '-o', str(output)],
                capture_output=True, text=True, timeout=60)
            if run.returncode: raise AssertionError(run.stdout + run.stderr)
            cls.probes[version] = output

    def run_reader(self, fault=None, version='v121', stop=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source, profile = original_data(root, version)
            directory = root / 'runtime-data'; shutil.copytree(source, directory)
            if fault: fault(directory)
            pin = manifest(directory)
            result = subprocess.run([str(self.probes[version]), str(root), pin,
                profile['romfs']['sha256'], sha(b'original synthetic runtime index'), str(stop)],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, '')
            return result.stdout

    def test_both_versions_use_owned_snapshots_after_source_removal(self):
        for version in self.probes:
            self.assertEqual(self.run_reader(version=version), 'accepted owned-snapshot gates-0-1\n')

    def test_zero_size_end_marker_is_metadata_but_cannot_extend_beyond_image(self):
        def boundary(value, size, symbol_type=0):
            def fault(directory):
                path = directory / FILES[0]; data = bytearray(path.read_bytes())
                struct.pack_into('<QQ', data, 688, value, size)
                data[688 + 22] = symbol_type
                path.write_bytes(data)
            return fault
        for version in self.probes:
            with self.subTest(version=version):
                self.assertEqual(self.run_reader(boundary(0x4000, 0), version), 'accepted owned-snapshot gates-0-1\n')
                for value, size in ((0x4000, 1), (0x4001, 0), ((1 << 64)-1, 0)):
                    with self.subTest(value=value, size=size):
                        self.assertTrue(self.run_reader(boundary(value, size), version).startswith('refused '))
                self.assertTrue(self.run_reader(boundary(0x4000, 0, 2), version).startswith('refused '))

    def test_cancellation_during_read_hash_and_metadata_parse_refuses(self):
        for stop in (1, 3, 7, 12, 20, 30):
            with self.subTest(stop=stop): self.assertTrue(self.run_reader(stop=stop).startswith('refused '))

    def test_authenticated_malformed_tables_refuse(self):
        # Mutations are re-pinned to prove parser rejection after hash acceptance.
        def mutate(offset, fmt, value):
            def fault(directory):
                path = directory / FILES[0]; data = bytearray(path.read_bytes())
                struct.pack_into(fmt, data, offset, value); path.write_bytes(data)
            return fault
        for label, fault in (
            ('format', mutate(20, '<I', 2)), ('version', mutate(8, '<8s', b'v0')),
            ('array-overflow', mutate(64 + 168, '<Q', (1 << 64)-8)),
            ('reserved', mutate(64 + 204, '<I', 1)),
            ('symbol-range', mutate(688, '<Q', 0x4000)),
            ('relocation-kind', mutate(688 + 24 + 8, '<I', 999)),
            ('unsupported-spin-gate', mutate(688 + 48 + 16, '<I', 2)),
            ('duplicate-gate', mutate(688 + 72, '<Q', 0x8000)),
            ('timer-register', mutate(688 + 72 + 20, '<I', 18))):
            with self.subTest(fault=label): self.assertTrue(self.run_reader(fault).startswith('refused '))

    def test_authenticated_bad_schema_and_independent_pins_refuse(self):
        def change(name, transform):
            def fault(directory):
                path = directory / name; path.write_bytes(transform(path.read_bytes()))
            return fault
        for fault in (
            change(FILES[1], lambda b: b + b'UNKNOWN 1\n'),
            change(FILES[1], lambda b: b + b'ROMFS_IMAGE_SIZE 17\n'),
            change(FILES[1], lambda b: b.replace(b'SIZE 17', b'SIZE 18446744073709551616')),
            change(FILES[1], lambda b: b.replace(b'SHA256 ', b'SHA256 0', 1)),
            change(FILES[2], lambda b: b.replace(b'original-0.bfttf', b'../outside')),
            change(FILES[3], lambda b: b + b'\0'),
            lambda d: (d / 'extra').write_bytes(b'original')):
            with self.subTest(fault=fault): self.assertTrue(self.run_reader(fault).startswith('refused '))


if __name__ == '__main__': unittest.main()
