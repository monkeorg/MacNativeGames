"""Real Canopy CLI and descriptor adapter checks; synthetic files only."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_launcher_container import partition, xci

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_file.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *mode;
static unsigned reads, stats;
ssize_t probe_pread(int fd,void *bytes,size_t size,off_t offset) {
    reads++;
    if (!strcmp(mode,"eintr") && reads==1) { errno=EINTR; return -1; }
    if (!strcmp(mode,"zero")) return 0;
    if (!strcmp(mode,"error")) { errno=EIO; return -1; }
    if (!strcmp(mode,"metadata_only") && (offset<0 || (uint64_t)offset+size>52)) {
        errno=EIO; return -1;
    }
    if (!strcmp(mode,"mutate") && reads==1) {
        struct stat st; if (fstat(fd,&st) || ftruncate(fd,st.st_size+1)) return -1;
    }
    return pread(fd,bytes,size>1 ? 1:size,offset);
}
int probe_fstat(int fd,struct stat *st) {
    if (fstat(fd,st)) return -1;
    if (++stats!=2) return 0;
    if (!strcmp(mode,"stat_error")) { errno=EIO; return -1; }
    if (!strcmp(mode,"size")) st->st_size++;
    if (!strcmp(mode,"device")) st->st_dev++;
    if (!strcmp(mode,"inode")) st->st_ino++;
    if (!strcmp(mode,"type")) st->st_mode=0;
#ifdef __APPLE__
#define MT st_mtimespec
#define CT st_ctimespec
#else
#define MT st_mtim
#define CT st_ctim
#endif
    if (!strcmp(mode,"mtime")) st->MT.tv_sec++;
    if (!strcmp(mode,"mtime_ns")) st->MT.tv_nsec++;
    if (!strcmp(mode,"ctime")) st->CT.tv_sec++;
    if (!strcmp(mode,"ctime_ns")) st->CT.tv_nsec++;
    return 0;
}
int main(int argc,char **argv) {
    if (argc!=3) return 2;
    mode=argv[2];
    int fd=open(argv[1],O_RDWR);
    if (fd<0) return 3;
    if (lseek(fd,1,SEEK_SET)!=1) return 4;
    struct mng_inventory result={0};
    enum mng_status status=mng_inspect_fd(!strcmp(mode,"invalid_fd") ? -1:fd,
                                         !strcmp(mode,"null_output") ? NULL:&result);
    if (fcntl(fd,F_GETFD)<0 || lseek(fd,0,SEEK_CUR)!=1) return 5;
    printf("%u %zu %u\n",(unsigned)status,result.count,
        (unsigned)(result.entries!=NULL || result.names!=NULL));
    mng_inventory_free(&result);
    close(fd);
    return 0;
}
'''


class CanopyCLI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('gcc') or shutil.which('clang') or shutil.which('cc')
        cmake = shutil.which('cmake')
        if not cmake:
            candidate = Path(sys.executable).parent / 'cmake'
            cmake = str(candidate) if candidate.exists() else None
        if not compiler or not cmake:
            raise unittest.SkipTest('C compiler and CMake required')
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        build = cls.root / 'build'
        subprocess.run([cmake, '-S', str(ROOT / 'launcher'), '-B', str(build),
                        '-DCMAKE_C_COMPILER=' + compiler], check=True, capture_output=True, text=True)
        subprocess.run([cmake, '--build', str(build)], check=True, capture_output=True, text=True)
        cls.cli = build / 'canopy'
        probe = cls.root / 'probe.c'
        probe.write_text(PROBE)
        adapter_source = cls.root / 'adapter.c'
        # Load libc declarations before substitution: glibc's 64-bit symbol
        # redirects otherwise bypass command-line function-name macros.
        adapter_source.write_text(
            '#define _POSIX_C_SOURCE 200809L\n#define _FILE_OFFSET_BITS 64\n'
            '#include <sys/stat.h>\n#include <unistd.h>\n'
            'ssize_t probe_pread(int, void *, size_t, off_t);\n'
            'int probe_fstat(int, struct stat *);\n'
            '#define pread probe_pread\n#define fstat probe_fstat\n'
            '#include "' + str(ROOT / 'launcher/src/mng_file.c') + '"\n')
        adapter = cls.root / 'adapter.o'
        flags = ['-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-I', str(ROOT / 'launcher/include')]
        if sys.platform == 'darwin':
            # Both generated translation units include system headers before
            # the adapter source; expose Darwin stat fields from the outset.
            flags.append('-D_DARWIN_C_SOURCE')
        # Instrument adapter, parser, and harness when the compiler supports it.
        sanitizer = cls.root / 'sanitizer'
        supported = subprocess.run([compiler, '-x', 'c', '-', '-fsanitize=undefined',
                                    '-o', str(sanitizer)], input='int main(void){return 0;}\n',
                                   capture_output=True, text=True).returncode == 0
        if supported:
            flags += ['-fsanitize=undefined', '-fno-sanitize-recover=all']
        subprocess.run([compiler, *flags, '-c', str(adapter_source), '-o', str(adapter)],
                       check=True, capture_output=True, text=True)
        cls.probe = cls.root / 'fd-probe'
        subprocess.run([compiler, *flags, str(probe), str(adapter),
                        str(ROOT / 'launcher/src/mng_container.c'), '-o', str(cls.probe)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'temp'):
            cls.temp.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.case.cleanup)
        self.directory = Path(self.case.name)
        self.source = self.directory / 'private-source.nsp'
        self.data = partition([('program.nca', b'opaque synthetic payload')])
        self.source.write_bytes(self.data)

    def cli_result(self, source=None, args=None):
        result = subprocess.run([str(self.cli), *(args if args is not None else
                                ['inspect', str(source or self.source)])],
                                capture_output=True, text=True, timeout=5)
        report = json.loads(result.stdout if result.returncode == 0 else result.stderr)
        self.assertFalse(report['execution_verified'])
        return result, report

    def test_real_nsp_inspection_preserves_source(self):
        result, report = self.cli_result()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')
        self.assertEqual(report['format'], 'nsp')
        self.assertEqual(report['count'], 1)
        self.assertEqual(report['source_size'], len(self.data))
        entry = report['entries'][0]
        self.assertEqual(entry['name'], 'program.nca')
        self.assertEqual(self.data[entry['offset']:entry['offset'] + entry['size']],
                         b'opaque synthetic payload')
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_xci_secure_inventory(self):
        self.source.write_bytes(xci(partition([('a.nca', b'abc')], hfs=True)))
        result, report = self.cli_result()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['format'], 'xci')
        self.assertEqual(report['entries'][0]['name'], 'a.nca')

    def test_json_escapes_quotes_control_characters_and_utf8(self):
        name = 'quote"\t\n\r\b\f\x01-é.nca'
        self.source.write_bytes(partition([(name, b'')]))
        result, report = self.cli_result()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['entries'][0]['name'], name)
        self.assertIn('\\u0001', result.stdout)
        self.assertNotIn('\x01', result.stdout)

    def test_empty_container_is_inventory_not_execution(self):
        self.source.write_bytes(partition([]))
        result, report = self.cli_result()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['entries'], [])

    def test_invalid_input_and_limit_have_safe_errors(self):
        for data, expected in ((b'private secret bytes', 'invalid_container'),
                               (b'PFS0' + (4097).to_bytes(4, 'little') + bytes(8), 'resource_limit')):
            self.source.write_bytes(data)
            result, report = self.cli_result()
            self.assertEqual(result.returncode, 4)
            self.assertEqual(report['error'], expected)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('private', result.stderr)

    def test_symlink_fifo_directory_and_missing_file_refused(self):
        link = self.directory / 'link'
        link.symlink_to(self.source)
        fifo = self.directory / 'fifo'
        os.mkfifo(fifo)
        for path in (link, fifo, self.directory, self.directory / 'missing'):
            with self.subTest(path=path.name):
                result, report = self.cli_result(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(report['error'], ('open_failed', 'invalid_container'))
                self.assertNotIn(str(path), result.stderr)

    def test_usage_is_structured(self):
        for args in ([], ['inspect'], ['play', str(self.source)], ['inspect', str(self.source), 'extra']):
            result, report = self.cli_result(args=args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(report['error'], 'usage')

    def descriptor(self, mode):
        result = subprocess.run([str(self.probe), str(self.source), mode],
                                capture_output=True, text=True, timeout=5,
                                env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return tuple(map(int, result.stdout.split()))

    def test_descriptor_partial_reads_and_eintr_preserve_fd_offset(self):
        for mode in ('normal', 'eintr', 'metadata_only'):
            with self.subTest(mode=mode):
                self.assertEqual(self.descriptor(mode), (0, 1, 1))

    def test_descriptor_short_eof_and_io_error_leave_empty_output(self):
        for mode in ('zero', 'error', 'stat_error', 'invalid_fd'):
            with self.subTest(mode=mode):
                self.assertEqual(self.descriptor(mode), (2, 0, 0))

    def test_null_output_is_rejected_without_closing_descriptor(self):
        self.assertEqual(self.descriptor('null_output'), (1, 0, 0))

    def test_every_stability_field_is_checked(self):
        for mode in ('size', 'device', 'inode', 'type', 'mtime', 'mtime_ns', 'ctime', 'ctime_ns'):
            with self.subTest(mode=mode):
                self.assertEqual(self.descriptor(mode), (2, 0, 0))

    def test_actual_source_mutation_discards_inventory(self):
        self.assertEqual(self.descriptor('mutate'), (2, 0, 0))
        self.assertEqual(self.source.stat().st_size, len(self.data) + 1)


if __name__ == '__main__':
    unittest.main()
