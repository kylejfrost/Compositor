"""Tests for scripts/profiles: the committed profile fixtures match the generator, and the codec vectors hold.

Run from the repository root:
    uv run --with numpy --with pillow python -m unittest discover -s scripts/tests -p 'test_profile_fixtures.py'
"""

import subprocess
import sys
import unittest
from pathlib import Path

PROFILES = Path(__file__).resolve().parents[1] / "profiles"
sys.path.insert(0, str(PROFILES / "reference"))

import lrprofile  # noqa: E402


class ProfileFixtureTests(unittest.TestCase):
    def test_committed_fixtures_match_the_generator(self):
        result = subprocess.run(
            [sys.executable, str(PROFILES / "make_fixtures.py"), "--check"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_codec_vectors(self):
        self.assertEqual(lrprofile.a85_encode(bytes.fromhex("0b30557a9f")), "bT#qD|1")
        self.assertEqual(lrprofile.a85_decode("#####"), bytes.fromhex("c40e7808"))


if __name__ == "__main__":
    unittest.main()
