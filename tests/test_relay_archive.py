"""Installer must reject corrupt relay helpers before replacing a working tree."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RelayArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-archive-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.archive = self.work / "archive"
        shutil.copytree(ROOT, self.archive, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.version = json.loads((ROOT / "config.json").read_text())["version"]

    def validate(self):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'install.sh'))}\n"
             + 'validate_xray_script_archive "$TEST_ARCHIVE" "$TEST_VERSION"'],
            cwd=ROOT, env=os.environ | {"TEST_ARCHIVE": str(self.archive), "TEST_VERSION": self.version},
            capture_output=True, text=True, timeout=20,
        )

    def test_production_python_syntax_failure_blocks_update(self):
        self.assertEqual(self.validate().returncode, 0)
        for filename in ["relay-links.py", "relay-probe.py"]:
            with self.subTest(filename=filename):
                path = self.archive / "lib" / filename
                original = path.read_bytes()
                path.write_text("def broken(:\n")
                self.assertNotEqual(self.validate().returncode, 0)
                path.write_bytes(original)

    def test_validation_does_not_execute_helper_code_or_create_bytecode(self):
        marker = self.work / "must-not-exist"
        (self.archive / "lib/relay-links.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('executed')\n")
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(list(self.archive.rglob("*.pyc")))
