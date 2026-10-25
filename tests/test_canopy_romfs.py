"""Production RomFS indexing/materialization with invented filesystem images."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NONE = 0xffffffff


def romfs(files=(), directories=()):
    """Build packed RomFS metadata independently of the native implementation."""
    root = {'name': b'', 'parent': None, 'dirs': [], 'files': []}
    def directory(parts):
        current = root
        for part in parts:
            found = next((node for node in current['dirs'] if node['name'] == part), None)
            if found is None:
                found = {'name': part, 'parent': current, 'dirs': [], 'files': []}
                current['dirs'].append(found)
            current = found
        return current
    for name in directories:
        raw = name.encode() if isinstance(name, str) else name
        directory(raw.split(b'/'))
    for path, data in files:
        raw = path.encode() if isinstance(path, str) else path
        parts = raw.split(b'/')
        parent = directory(parts[:-1])
        parent['files'].append({'name': parts[-1], 'parent': parent, 'data': data})
    dirs, entries = [], []
    def collect(node):
        dirs.append(node)
        entries.extend(node['files'])
        for child in node['dirs']:
            collect(child)
    collect(root)
    for nodes, fixed in ((dirs, 24), (entries, 32)):
        offset = 0
        for node in nodes:
            node['offset'] = offset
            offset += (fixed+len(node['name'])+3)&~3
    directory_bytes = bytearray()
    for node in dirs:
        parent = node['parent']
        siblings = parent['dirs'] if parent is not None else [node]
        index = siblings.index(node)
        sibling = siblings[index+1]['offset'] if index+1 < len(siblings) else NONE
        directory_bytes += struct.pack('<6I', parent['offset'] if parent else 0, sibling,
            node['dirs'][0]['offset'] if node['dirs'] else NONE,
            node['files'][0]['offset'] if node['files'] else NONE, NONE, len(node['name']))
        directory_bytes += node['name']
        directory_bytes += bytes(-len(directory_bytes) % 4)
    file_bytes, payload = bytearray(), bytearray()
    for node in entries:
        siblings = node['parent']['files']
        index = siblings.index(node)
        sibling = siblings[index+1]['offset'] if index+1 < len(siblings) else NONE
        file_bytes += struct.pack('<IIQQII', node['parent']['offset'], sibling,
                                  len(payload), len(node['data']), NONE, len(node['name']))
        file_bytes += node['name']
        file_bytes += bytes(-len(file_bytes) % 4)
        payload += node['data']
    file_start = 80+len(directory_bytes)
    data_start = file_start+len(file_bytes)
    header = struct.pack('<10Q', 80, 80, 0, 80, len(directory_bytes),
                         file_start, 0, file_start, len(file_bytes), data_start)
    layout = {'dir_start': 80, 'file_start': file_start, 'data_start': data_start,
              'dirs': [node['offset'] for node in dirs], 'files': [node['offset'] for node in entries]}
    return header+directory_bytes+file_bytes+payload, layout


@unittest.skipUnless(shutil.which('cc'), 'native RomFS tests require a C compiler')
class CanopyRomfsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build_temp.cleanup)
        build = Path(cls.build_temp.name)
        wrapper = build/'instrumented.c'
        wrapper.write_text('#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n'
            '#ifdef __APPLE__\n#define _DARWIN_C_SOURCE\n#endif\n'
            '#include <sys/stat.h>\n#include <unistd.h>\n'
            'ssize_t romfs_probe_pread(int,void *,size_t,off_t);\n'
            'int romfs_probe_fstat(int,struct stat *);\n'
            '#define pread romfs_probe_pread\n#define fstat romfs_probe_fstat\n'
            '#include "'+str(ROOT/'launcher/src/mng_romfs.c')+'"\n')
        cls.probe = build/'romfs-probe'
        result = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
            '-I', str(ROOT/'launcher/include'), str(wrapper), str(ROOT/'launcher/tests/romfs_probe.c'),
            '-o', str(cls.probe)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout+result.stderr)

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name).resolve()
        self.serial = 0

    def run_image(self, image, operation='extract', mode='normal', status='ok', setup=None):
        self.serial += 1
        source = self.root/f'image-{self.serial}'
        source.write_bytes(image)
        output = self.root/f'output-{self.serial}'
        output.mkdir()
        if setup:
            setup(source, output)
        run = subprocess.run([str(self.probe), str(source), str(output), operation, mode],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], status, run.stdout+run.stderr)
        self.assertTrue(report['descriptor_preserved'])
        if mode != 'mutate':
            self.assertEqual(source.read_bytes(), image)
        if status != 'ok':
            self.assertEqual((report['files'], report['directories'], report['bytes']), (0,0,0))
        return output, report

    def test_nested_index_and_byte_exact_materialization(self):
        files = [('root.txt', b'root'), ('nested/a.bin', bytes(range(251))*900),
                 ('nested/deeper/empty', b''), ('other/quote".txt', b'quoted')]
        image, _ = romfs(files, ['empty-directory'])
        indexed, index = self.run_image(image, 'index')
        self.assertEqual(list(indexed.iterdir()), [])
        self.assertEqual(index['files'], len(files))
        self.assertEqual(index['directories'], 4)
        self.assertEqual(index['bytes'], sum(len(data) for _, data in files))
        self.assertEqual({entry['path'] for entry in index['entries']}, {path for path, _ in files})
        for entry in index['entries']:
            self.assertEqual(image[entry['offset']:entry['offset']+entry['size']], dict(files)[entry['path']])
        output, report = self.run_image(image)
        for path, content in files:
            self.assertEqual((output/path).read_bytes(), content)
            self.assertEqual((output/path).stat().st_nlink, 1)
        self.assertTrue((output/'empty-directory').is_dir())
        self.assertGreater(report['progress_calls'], 1)

    def test_empty_image_and_existing_python_fixture(self):
        image, _ = romfs()
        _, report = self.run_image(image)
        self.assertEqual(report['files'], 0)
        # Same unpadded last-file metadata arrangement used by the repository's
        # independent Python extractor fixtures (without crypto dependency).
        name, data = b'file.dat', b'invented'
        dirs = struct.pack('<6I', 0, NONE, NONE, 0, NONE, 0)
        files = struct.pack('<IIQQII', 0, NONE, 0, len(data), NONE, len(name))+name
        start = 80+len(dirs)+len(files)
        image = struct.pack('<10Q', 80,80,0,80,len(dirs),104,0,104,len(files),start)+dirs+files+data
        output, _ = self.run_image(image)
        self.assertEqual((output/'file.dat').read_bytes(), data)

    def test_cycles_middle_pointers_wrong_parent_and_orphans(self):
        original, layout = romfs([('a', b'1'), ('b', b'2'), ('dir/child/file', b'3')])
        variants = []
        for where, value in ((80+8, 0), (80+8, 1), (layout['file_start']+4, 0),
                             (layout['file_start'], 99), (80+12, NONE),
                             (80+layout['dirs'][2], 0), (80+16, 0),
                             (layout['file_start']+24, 1)):
            image = bytearray(original)
            struct.pack_into('<I', image, where, value)
            variants.append(image)
        for index, image in enumerate(variants):
            with self.subTest(index=index):
                self.run_image(image, status='invalid')

    def test_hash_bucket_pointers_are_metadata_boundaries(self):
        original, layout = romfs([('file', b'x')])
        h = list(struct.unpack('<10Q', original[:80]))
        h[1], h[2], h[3] = 80, 4, 84
        h[5] += 4
        h[7] += 4
        h[9] += 4
        image = struct.pack('<10Q', *h)+struct.pack('<I', 0)+original[80:]
        self.run_image(image)
        invalid = bytearray(image)
        struct.pack_into('<I', invalid, 80, 1)
        self.run_image(invalid, status='invalid')

    def test_traversal_malformed_utf8_case_and_file_directory_aliases(self):
        for path in ('../escape', './bad', 'bad\\name', 'bad:name', 'bad\nname', b'bad\xc0\xaf'):
            with self.subTest(path=path):
                image, _ = romfs([(path, b'x')])
                self.run_image(image, status='invalid')
        for files in ([('A', b'1'), ('a', b'2')],
                      [('same', b'1'), ('same/file', b'2')],
                      [('A/one', b'1'), ('a/two', b'2')]):
            image, _ = romfs(files)
            output, _ = self.run_image(image, status='invalid')
            self.assertEqual(list(output.iterdir()), [])

    def test_unicode_requires_host_normalization_and_rejects_aliases(self):
        image, _ = romfs([('\u00e9.txt', b'invented')])
        self.run_image(image, status='unsupported')
        output, _ = self.run_image(image, mode='unicode')
        self.assertEqual((output/'\u00e9.txt').read_bytes(), b'invented')
        for alternate in ('e\u0301.txt', '\u00c9.txt'):
            image, _ = romfs([('\u00e9.txt', b'a'), (alternate, b'b')])
            output, _ = self.run_image(image, mode='unicode', status='invalid')
            self.assertEqual(list(output.iterdir()), [])

    def test_payload_overlap_out_of_bounds_and_metadata_overlap(self):
        original, layout = romfs([('one', b'123'), ('two', b'456')])
        images = []
        for offset, value in ((layout['file_start']+layout['files'][1]+8, 1),
                              (layout['file_start']+8, 1<<40), (7*8, 80)):
            image = bytearray(original)
            struct.pack_into('<Q', image, offset, value)
            images.append(image)
        images.append(original[:-1])
        for image in images:
            self.run_image(image, status='invalid')

    def test_budgets_depth_name_path_metadata_and_file_count(self):
        cases = [(romfs([('/'.join(['d']*65)+'/f', b'x')])[0], 'limit'),
                 (romfs([('x'*1025, b'x')])[0], 'limit'),
                 (romfs([('/'.join(['x'*1000]*5)+'/f', b'x')])[0], 'limit')]
        image = bytearray(romfs()[0])
        struct.pack_into('<Q', image, 4*8, 32*1024*1024+1)
        cases.append((image, 'limit'))
        # Packed empty file records exceed the count budget without allocating
        # payload data or requiring a huge filesystem fixture on disk.
        count = 65537
        table = b''.join(struct.pack('<IIQQII', 0, (i+1)*36 if i+1<count else NONE,
                                    0,0,NONE,1)+b'x\0\0\0' for i in range(count))
        dirs = struct.pack('<6I', 0,NONE,NONE,0,NONE,0)
        start = 104+len(table)
        cases.append((struct.pack('<10Q',80,80,0,80,24,104,0,104,len(table),start)+dirs+table,'limit'))
        for index, (image, status) in enumerate(cases):
            with self.subTest(index=index):
                self.run_image(image, status=status)

    def test_cancel_callback_and_read_errors_leave_zero_result(self):
        image, _ = romfs([('large', bytes(range(251))*900), ('second', b'x')])
        for operation, mode, status in (('extract','cancelinitial','cancelled'),
                                       ('extract','cancel','cancelled'), ('index','cancel','cancelled'),
                                       ('extract','io','io'), ('extract','callbackfail','io')):
            with self.subTest(operation=operation, mode=mode):
                self.run_image(image, operation, mode, status)
        for mode in ('short','eintr'):
            output, _ = self.run_image(image, mode=mode)
            self.assertEqual((output/'large').read_bytes(), bytes(range(251))*900)

    def test_index_reads_no_payload_and_mutation_is_detected(self):
        image, _ = romfs([('large', b'invented payload')])
        self.run_image(image, 'index', 'metadataonly')
        self.run_image(image, 'extract', 'metadataonly', 'io')
        for mode in ('mutate','statio','statinode','statsize','statdevice','statmtime','statctime'):
            with self.subTest(mode=mode):
                self.run_image(image, mode=mode, status='io')

    def test_nonempty_output_symlinks_special_and_hardlinked_source_refused(self):
        image, _ = romfs([('file', b'x')])
        outside = self.root/'outside'
        outside.write_bytes(b'preserve')
        for setup in (lambda source, out: (out/'existing').write_bytes(b'preserve'),
                      lambda source, out: (out/'link').symlink_to(outside),
                      lambda source, out: os.link(outside, out/'hardlink'),
                      lambda source, out: os.link(source, self.root/'source-alias')):
            self.run_image(image, setup=setup, status='invalid')
        if hasattr(os, 'mkfifo'):
            self.run_image(image, setup=lambda source,out: os.mkfifo(out/'fifo'), status='invalid')
        self.assertEqual(outside.read_bytes(), b'preserve')

    def test_sparse_payload_total_quota_precedes_materialization(self):
        image, layout = romfs([('large', b'')])
        metadata = bytearray(image)
        length = 64*1024*1024*1024+1
        struct.pack_into('<Q', metadata, layout['file_start']+16, length)
        source, output = self.root/'sparse', self.root/'staging'
        with source.open('wb') as stream:
            stream.write(metadata)
            stream.truncate(layout['data_start']+length)
        output.mkdir()
        run = subprocess.run([str(self.probe), str(source), str(output), 'extract', 'normal'],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(run.stdout)
        self.assertEqual(report['status'], 'limit')
        self.assertEqual((report['files'], report['directories'], report['bytes']), (0,0,0))
        self.assertEqual(list(output.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
