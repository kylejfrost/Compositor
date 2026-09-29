"""Tests for scripts/psd-diff.py. Needs only Pillow.

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_psd_diff.py'
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

SCRIPT = Path(__file__).resolve().parents[1] / "psd-diff.py"


def run_diff(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True,
        text=True,
        timeout=60,
    )


class PSDDiffTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        # 100 x 100 = 10,000 pixels, so the default 0.002 allows 20 differing pixels.
        self.base = Image.new("RGBA", (100, 100), (40, 80, 120, 255))

    def tearDown(self):
        self._tmp.cleanup()

    def save(self, image, name):
        path = self.tmp / name
        image.save(path)
        return path

    def with_pixels(self, count, color, image=None):
        image = (image or self.base).copy()
        for index in range(count):
            image.putpixel((index % 100, index // 100), color)
        return image

    def test_identical_images_pass(self):
        result = run_diff(self.save(self.base, "a.png"), self.save(self.base, "b.png"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("differing pixels: 0 of 10000", result.stdout)
        self.assertIn("PASS", result.stdout)

    def test_differences_within_tolerance_are_not_counted(self):
        shifted = Image.new("RGBA", (100, 100), (48, 72, 128, 255))  # every channel off by exactly 8
        result = run_diff(self.save(self.base, "a.png"), self.save(shifted, "b.png"))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("differing pixels: 0 of 10000", result.stdout)
        self.assertIn("max channel difference: 8", result.stdout)

    def test_a_difference_just_over_tolerance_counts(self):
        changed = self.with_pixels(1, (49, 80, 120, 255))
        result = run_diff(self.save(self.base, "a.png"), self.save(changed, "b.png"))
        self.assertIn("differing pixels: 1 of 10000", result.stdout)

    def test_passes_at_the_max_fraction_and_fails_above_it(self):
        at_limit = self.with_pixels(20, (255, 0, 0, 255))
        over_limit = self.with_pixels(21, (255, 0, 0, 255))
        a = self.save(self.base, "a.png")

        self.assertEqual(run_diff(a, self.save(at_limit, "b.png")).returncode, 0)
        result = run_diff(a, self.save(over_limit, "c.png"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL", result.stdout)

    def test_tolerance_and_max_fraction_options(self):
        changed = self.with_pixels(5, (60, 80, 120, 255))  # red off by 20
        a = self.save(self.base, "a.png")
        b = self.save(changed, "b.png")

        self.assertEqual(run_diff(a, b, "--max-fraction", "0.0004").returncode, 1)
        self.assertEqual(run_diff(a, b, "--max-fraction", "0.0005").returncode, 0)
        self.assertEqual(run_diff(a, b, "--tolerance", "20", "--max-fraction", "0").returncode, 0)

    def test_alpha_differences_count(self):
        changed = self.with_pixels(30, (40, 80, 120, 128))
        result = run_diff(self.save(self.base, "a.png"), self.save(changed, "b.png"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("differing pixels: 30 of 10000", result.stdout)

    def test_color_under_full_transparency_is_ignored(self):
        clear_red = Image.new("RGBA", (100, 100), (255, 0, 0, 0))
        clear_white = Image.new("RGBA", (100, 100), (255, 255, 255, 0))
        result = run_diff(self.save(clear_red, "a.png"), self.save(clear_white, "b.png"))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_opaque_rgb_compares_equal_to_the_same_rgba(self):
        result = run_diff(self.save(self.base.convert("RGB"), "a.png"), self.save(self.base, "b.png"))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_size_mismatch_is_an_error(self):
        smaller = Image.new("RGBA", (100, 99), (40, 80, 120, 255))
        result = run_diff(self.save(self.base, "a.png"), self.save(smaller, "b.png"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("100 x 100", result.stderr)
        self.assertIn("100 x 99", result.stderr)


if __name__ == "__main__":
    unittest.main()
