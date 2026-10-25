#!/usr/bin/env python3
"""Build an original ARM64 NSO through the unmodified production rewrite/embed tools.

This produces artifacts, not an executable runtime or a gameplay result. All
instruction words below were authored for this fixture; no game input is read.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
REWRITER = ROOT / 'games/totk/third_party/d2r/patch_nso.py'
EMBEDDER = ROOT / 'games/totk/ios/tools/gen_embed.py'
TEXT_END, RO, DATA = 0x220, 0x4000, 0x8000
MOD0, EH, DYNAMIC, HASH, SYMBOLS, STRINGS, RELA = (
    0x4000, 0x4100, 0x4200, 0x4300, 0x4400, 0x4500, 0x4600)
ENTRY, CALL, HELPER, TLS, SERVICE = 0x100, 0x114, 0x140, 0x180, 0x1c0

# Canonical original source: address, AArch64 instruction word, assembly.
# ENTRY expects a pointer to a native target in x18. A future harness must set
# the K18 slot after rewriting, and initialize all other required TLS slots.
PROGRAM = (
    (0x100, 0xA9BC7BFD, 'stp x29, x30, [sp, #-0x40]!'),
    (0x104, 0x910003FD, 'mov x29, sp'),
    (0x108, 0xAA0203F1, 'mov x17, x2'),
    (0x10c, 0xAA0303EF, 'mov x15, x3'),
    (0x110, 0xA901BFF1, 'stp x17, x15, [sp, #0x18]'),
    (0x114, 0xD63F0240, 'blr x18'),
    (0x118, 0xA8C47BFD, 'ldp x29, x30, [sp], #0x40'),
    (0x11c, 0xD65F03C0, 'ret'),
    (0x140, 0x91001C00, 'add x0, x0, #7'),
    (0x144, 0xD65F03C0, 'ret'),
    (0x180, 0xD53BD040, 'mrs x0, tpidr_el0'),
    (0x184, 0xD65F03C0, 'ret'),
    (0x1c0, 0xD4000021, 'svc #1'),
    (0x1c4, 0xD65F03C0, 'ret'),
    (0x200, 0xD65F03C0, 'ret'),
)


def original_nso():
    """Minimal uncompressed NSO with real MOD0/unwind/dynamic metadata."""
    memory = bytearray(DATA + 0x4000)
    for address in range(0, TEXT_END, 4):
        struct.pack_into('<I', memory, address, 0xD503201F)
    struct.pack_into('<II', memory, 0, 0x14000040, MOD0)
    for address, word, _ in PROGRAM:
        struct.pack_into('<I', memory, address, word)
    struct.pack_into('<4siiiii', memory, MOD0, b'MOD0', DYNAMIC-MOD0,
                     0, 0, EH-MOD0, 0)
    starts = (ENTRY, HELPER, TLS, SERVICE, 0x200)
    # DW_EH_PE_udata4 fields and absolute function addresses; only function
    # starts are consumed by the production rewriter, not fabricated game FDEs.
    struct.pack_into('<4BII', memory, EH, 1, 3, 3, 3, 0, len(starts))
    for i, address in enumerate(starts):
        struct.pack_into('<II', memory, EH + 12 + 8*i, address, 0)
    tags = ((4, HASH), (6, SYMBOLS), (5, STRINGS), (7, RELA),
            (8, 24), (9, 24), (0, 0))
    for i, pair in enumerate(tags):
        struct.pack_into('<qQ', memory, DYNAMIC + 16*i, *pair)
    # SysV hash: one bucket, three chains (null plus two defined symbols).
    struct.pack_into('<6I', memory, HASH, 1, 3, 1, 0, 2, 0)
    names = b'\0fixture_entry\0fixture_helper\0'
    memory[STRINGS:STRINGS+len(names)] = names
    for i, name, address in ((1, 1, ENTRY), (2, 15, HELPER)):
        struct.pack_into('<IBBHQQ', memory, SYMBOLS+24*i, name, 0x12,
                         0, 1, address, 0x20)
    struct.pack_into('<QQq', memory, RELA, DATA, 1027, HELPER)
    struct.pack_into('<QQ', memory, DATA, HELPER, 0x123456789abcdef0)
    header = bytearray(0x100)
    header[:4] = b'NSO0'
    header[0x40:0x60] = hashlib.sha256(b'original-launcher-fixture-v1').digest()
    payload = bytearray()
    for i, (address, size) in enumerate(((0, TEXT_END), (RO, 0x4000), (DATA, 0x4000))):
        segment = memory[address:address+size]
        struct.pack_into('<III', header, 0x10+0x10*i, len(header)+len(payload), address, size)
        struct.pack_into('<I', header, 0x60+4*i, size)
        header[0xa0+32*i:0xc0+32*i] = hashlib.sha256(segment).digest()
        payload.extend(segment)
    return bytes(header + payload)


def run_rewriter(source, destination):
    env = dict(os.environ, DM_RULESET='native', DM_PRIVATE_GATES='0')
    return subprocess.run([sys.executable, str(REWRITER), str(source),
                           str(destination), 'fixture'], env=env,
                          capture_output=True, text=True, check=True)


def build(destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    source = destination / 'fixture.nso'
    source.write_bytes(original_nso())
    (destination / 'fixture-source.json').write_text(json.dumps(PROGRAM, indent=2)+'\n')
    rewritten = destination / 'rewritten'
    result = run_rewriter(source, rewritten)
    (destination / 'rewrite.log').write_text(result.stdout)
    image = (rewritten/'fixture.patched.bin').read_bytes()
    text = destination/'text'
    text.mkdir()
    (text/'fixture.x0.bin').write_bytes(image[:0x4000])
    # This fixture needs no title-specific runtime patches; its verified rewritten
    # text is the exact text input consumed by the production embed generator.
    generated = destination/'generated'
    generated.mkdir()
    result = subprocess.run([sys.executable, str(EMBEDDER), str(rewritten),
                             str(generated/'embed.S'), '--text-dir', str(text),
                             'fixture'], capture_output=True, text=True, check=True)
    (generated/'linker-flags.txt').write_text(result.stdout)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    manifest = {
        'schema': 1, 'scope': 'original-source rewrite and embed artifacts only',
        'native_execution': 'not_run', 'apple_signing': 'not_run',
        'tools': {'python': sys.version, 'capstone': importlib.metadata.version('capstone'),
                  'lz4': importlib.metadata.version('lz4')},
        'inputs': {str(p.relative_to(ROOT)): digest(p) for p in (
            Path(__file__), REWRITER, EMBEDDER,
            REWRITER.with_name('call_window.py'), REWRITER.with_name('relr.py'))},
        'options': {'DM_RULESET': 'native', 'DM_PRIVATE_GATES': '0'},
        'files': {str(p.relative_to(destination)): digest(p)
                  for p in sorted(destination.rglob('*')) if p.is_file()},
    }
    (destination/'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new directory; never overwrite an existing build')
    args = parser.parse_args()
    build(args.output)
    print('Built original-source rewrite/embed artifacts; native execution and Apple signing NOT RUN.')
