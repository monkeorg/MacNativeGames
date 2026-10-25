"""Executes original-source shared libraries through the production loader."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CanopySessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="canopy-session-")
        cls.directory = Path(cls.temp.name).resolve()
        cc = shutil.which("cc")
        if not cc:
            raise unittest.SkipTest("C compiler unavailable")
        flags = [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-I", str(ROOT / "launcher/include")]
        fixture = str(ROOT / "launcher/tests/session_fixture.c")
        shared = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
        cls.modules = {}
        for name, extra in (("valid", []), ("abi", ["-DFIXTURE_ABI=99"]), ("missing", ["-DFIXTURE_MISSING_ENTRY"])):
            path = cls.directory / (name + ".dylib")
            subprocess.run(flags + shared + extra + [fixture, "-o", str(path)], check=True, capture_output=True)
            cls.modules[name] = path
        cls.driver = cls.directory / "driver"
        crypto = ROOT / "launcher/src/mng_crypto.c"
        command = flags + ["-DMNG_SESSION_DRIVER", fixture, str(ROOT / "launcher/src/mng_session.c"), str(crypto), "-o", str(cls.driver)]
        command += ["-framework", "Security"] if sys.platform == "darwin" else ["-lcrypto", "-ldl"]
        subprocess.run(command, check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_module(self, module="valid", case="valid", digest=None, relative=None):
        path = self.modules[module]
        content = path.read_bytes()
        output = subprocess.check_output([str(self.driver), str(self.directory), relative or path.name,
                                          str(len(content)), digest or hashlib.sha256(content).hexdigest(), case], text=True)
        return int(output)

    def test_native_lifecycle_settings_two_players_and_save(self):
        self.assertEqual(self.run_module(), 0)
        self.assertEqual((self.directory / "fixture-save").read_text(), "profile-a 1 2 1 30\n")

    def test_abi_and_identity_rejected(self):
        self.assertEqual(self.run_module("abi"), -5)
        self.assertEqual(self.run_module(case="identity"), -5)
        self.assertEqual(self.run_module("missing"), -5)

    def test_hash_and_unapproved_module_rejected(self):
        self.assertEqual(self.run_module(digest="00" * 32), -3)
        self.assertEqual(self.run_module(case="unapproved"), -2)

    def test_path_traversal_and_symlink_rejected(self):
        self.assertEqual(self.run_module(relative="../" + self.directory.name + "/valid.dylib"), -3)
        link = self.directory / "link.dylib"
        link.symlink_to(self.modules["valid"])
        try:
            self.assertEqual(self.run_module(relative=link.name), -3)
        finally:
            link.unlink()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_nonregular_module_rejected_without_blocking(self):
        fifo = self.directory / "fifo.dylib"
        os.mkfifo(fifo)
        try:
            self.assertEqual(self.run_module(relative=fifo.name), -3)
        finally:
            fifo.unlink()

    def test_stale_and_duplicate_player_inputs_rejected(self):
        self.assertEqual(self.run_module(case="stale"), -7)
        self.assertEqual(self.run_module(case="duplicate-device"), -1)


if __name__ == "__main__":
    unittest.main()
