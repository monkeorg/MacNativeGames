"""Portable iPad mouse focus/menu/text-entry admission checks against production policy."""
import shutil
import unittest
from pathlib import Path
from test_mouse import run_probe

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cc'), 'needs a C compiler')
class IOSMouseCaptureTests(unittest.TestCase):
    def test_capture_interruption_sequence(self):
        run_probe(self, ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                         f'-I{ROOT}/games/totk/ios/Sources',
                         str(ROOT / 'tests/ios_mouse_capture_probe.c')])
