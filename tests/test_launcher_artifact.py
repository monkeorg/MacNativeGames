"""Synthetic public-artifact checks; no proprietary inputs or Apple SDK needed."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location('launcher_artifact',
    Path(__file__).resolve().parents[1] / 'tools/launcher/audit_public_artifact.py')
audit_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = audit_module
SPEC.loader.exec_module(audit_module)


def macho(name=b'__TEXT', cpu=0x0100000c, sections=b''):
    command = struct.pack('<II16sQQQQIIII', 0x19, 72 + len(sections), name,
                          0, 0, 0, 0, 7, 5, len(sections) // 80, 0) + sections
    return struct.pack('<8I', 0xfeedfacf, cpu, 0, 2, 1, len(command), 0, 0) + command


class ArtifactAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Fixture.app'
        self.app.mkdir()
        self.inventory = self.root / 'reviewed.json'

    def fixture(self, files):
        rows = []
        for name, data in files.items():
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            rows.append({'path': name, 'size': len(data),
                         'sha256': hashlib.sha256(data).hexdigest(),
                         'provenance': {'source': 'synthetic-fixture', 'license': 'CC0',
                                        'recipe': 'test-construction-v1'}})
        document = {'schema_version': 1, 'source_revision': 'synthetic-revision',
                    'recipe_id': 'synthetic-build-v1', 'files': rows}
        self.inventory.write_text(json.dumps(document))
        return document

    def check(self, **kwargs):
        return audit_module.audit(self.app, self.inventory, **kwargs)

    def test_inventory_matches_includes_signing_files_and_limitations(self):
        self.fixture({'App': macho(), '_CodeSignature/CodeResources': b'synthetic'})
        first = self.check()
        self.assertEqual(first, self.check())
        self.assertEqual(first['status'], 'inventory matches')
        self.assertEqual(len(first['files']), 2)
        self.assertIn('Does not establish absence of Nintendo-derived content.',
                      first['limitations'])

    def test_changed_missing_and_unlisted_files(self):
        for mutation in ('changed', 'missing', 'extra'):
            with self.subTest(mutation=mutation):
                self.fixture({'payload': b'ab'})
                if mutation == 'changed':
                    (self.app / 'payload').write_bytes(b'cd')
                elif mutation == 'missing':
                    (self.app / 'payload').unlink()
                else:
                    (self.app / 'extra').write_bytes(b'x')
                with self.assertRaises(audit_module.AuditError):
                    self.check()
                (self.app / 'extra').unlink(missing_ok=True)

    def test_guest_segments_fail_in_extensionless_file(self):
        for name in (b'__TOTKX', b'__TOTKmainW', b'__TOTKsdkW'):
            with self.subTest(name=name):
                self.fixture({'payload': macho(name)})
                with self.assertRaisesRegex(audit_module.AuditError, 'guest'):
                    self.check()

    def test_fat_endian_32bit_and_non_arm64_rejected(self):
        for data in (bytes.fromhex(h) + b'\0' * 100 for h in
                     ('cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
                      'feedfacf', 'feedface', 'cefaedfe')):
            self.fixture({'payload': data})
            with self.assertRaisesRegex(audit_module.AuditError, 'unsupported'):
                self.check()
        self.fixture({'payload': macho(cpu=0x01000007)})
        with self.assertRaisesRegex(audit_module.AuditError, 'CPU'):
            self.check()

    def test_malformed_load_commands(self):
        valid = macho()
        fixtures = [valid[:20], valid[:40],
                    valid[:32] + struct.pack('<II', 0x19, 0) + valid[40:],
                    valid[:32] + struct.pack('<II', 0x19, 80) + valid[40:]]
        count = bytearray(valid)
        struct.pack_into('<I', count, 16, 4097)
        fixtures.append(bytes(count))
        section_count = bytearray(valid)
        struct.pack_into('<I', section_count, 32 + 64, 100)
        fixtures.append(bytes(section_count))
        for index, data in enumerate(fixtures):
            with self.subTest(index=index):
                self.fixture({'payload': data})
                with self.assertRaises(audit_module.AuditError):
                    self.check()

    def test_zerofill_does_not_require_file_bytes(self):
        section = struct.pack('<16s16sQQIIIIIIII', b'__bss', b'__DATA', 0,
                              1 << 30, 0, 0, 0, 0, 1, 0, 0, 0)
        self.fixture({'payload': macho(sections=section)})
        self.check()
        section = bytearray(section)
        struct.pack_into('<I', section, 64, 0)  # regular section
        self.fixture({'payload': macho(sections=bytes(section))})
        with self.assertRaisesRegex(audit_module.AuditError, 'section outside'):
            self.check()

    def test_links_and_special_files_rejected(self):
        self.fixture({'payload': b'ok'})
        (self.app / 'alias').symlink_to(self.app / 'payload')
        with self.assertRaisesRegex(audit_module.AuditError, 'links'):
            self.check()
        (self.app / 'alias').unlink()
        (self.app / 'directory-alias').symlink_to(self.app, target_is_directory=True)
        with self.assertRaisesRegex(audit_module.AuditError, 'links'):
            self.check()
        (self.app / 'directory-alias').unlink()
        if hasattr(os, 'mkfifo'):
            os.mkfifo(self.app / 'fifo')
            with self.assertRaisesRegex(audit_module.AuditError, 'special'):
                self.check()

    def test_case_and_unicode_collisions(self):
        for names in (('A', 'a'), ('\u00e9', 'e\u0301')):
            with self.subTest(names=names):
                self.fixture({names[0]: b'x', names[1]: b'y'})
                with self.assertRaisesRegex(audit_module.AuditError, 'collid'):
                    self.check()
                for name in names:
                    # On case/normalization-insensitive filesystems both names
                    # can refer to one file. The policy collision assertion
                    # above still executes before artifact contents are read.
                    (self.app / name).unlink(missing_ok=True)

    def test_disk_directory_collision_even_without_inventory_collision(self):
        self.fixture({'A/file': b'x'})
        try:
            (self.app / 'a').mkdir()
        except FileExistsError:
            if (self.app / 'A').samefile(self.app / 'a'):
                self.skipTest('filesystem cannot represent distinct A and a directories')
            raise
        with self.assertRaisesRegex(audit_module.AuditError, 'collision'):
            self.check()

    def test_unsafe_inventory_paths_and_missing_provenance(self):
        for name in ('../escape', '/absolute', 'a\\b', 'a//b', 'C:drive', 'a/./b'):
            document = self.fixture({'payload': b'x'})
            document['files'][0]['path'] = name
            self.inventory.write_text(json.dumps(document))
            with self.assertRaisesRegex(audit_module.AuditError, 'path'):
                self.check()
        document = self.fixture({'payload': b'x'})
        document['files'][0]['provenance']['source'] = ''
        self.inventory.write_text(json.dumps(document))
        with self.assertRaisesRegex(audit_module.AuditError, 'provenance'):
            self.check()

    def test_duplicate_json_key_and_bool_size_rejected(self):
        document = self.fixture({'payload': b'x'})
        raw = self.inventory.read_text().replace('"schema_version": 1',
            '"schema_version": 1, "schema_version": 1')
        self.inventory.write_text(raw)
        with self.assertRaisesRegex(audit_module.AuditError, 'duplicate'):
            self.check()
        document['files'][0]['size'] = True
        self.inventory.write_text(json.dumps(document))
        with self.assertRaisesRegex(audit_module.AuditError, 'size'):
            self.check()

    def test_resource_bounds(self):
        self.fixture({'payload': b'123'})
        for limits in (audit_module.Limits(file_bytes=2),
                       audit_module.Limits(total_bytes=2),
                       audit_module.Limits(entries=0),
                       audit_module.Limits(inventory_bytes=2)):
            with self.subTest(limits=limits):
                with self.assertRaises(audit_module.AuditError):
                    self.check(limits=limits)
        self.fixture({'payload': b'x'})
        (self.app / 'empty').mkdir()
        with self.assertRaisesRegex(audit_module.AuditError, 'entry limit'):
            self.check(limits=audit_module.Limits(entries=1))

    def test_unlisted_empty_directory_rejected(self):
        self.fixture({'payload': b'x'})
        (self.app / 'unlisted').mkdir()
        with self.assertRaisesRegex(audit_module.AuditError, 'unlisted.*directories'):
            self.check()

    def test_ipa_and_symlink_root_rejected(self):
        self.fixture({'payload': b'x'})
        ipa = self.root / 'fixture.ipa'
        ipa.write_bytes(b'PK\x03\x04')
        with self.assertRaisesRegex(audit_module.AuditError, 'IPA/ZIP'):
            audit_module.audit(ipa, self.inventory)
        alias = self.root / 'Alias.app'
        alias.symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(audit_module.AuditError):
            audit_module.audit(alias, self.inventory)

    def test_policy_hash_binds_recipe_and_provenance(self):
        document = self.fixture({'payload': b'x'})
        first = self.check()
        document['recipe_id'] = 'other-recipe'
        self.inventory.write_text(json.dumps(document))
        self.assertNotEqual(first['inventory_sha256'], self.check()['inventory_sha256'])


if __name__ == '__main__':
    unittest.main()
