"""Tests for scripts/psd-corpus-expectations.py's own rules. Needs psd-tools (the script imports it).

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_psd_corpus_expectations.py'
"""

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "psd-corpus-expectations.py"


def load_expectations():
    spec = importlib.util.spec_from_file_location("psd_corpus_expectations", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TextBoxLimitTests(unittest.TestCase):
    """A paragraph text box stays editable up to one surface's cap (`DocumentLimits.maxSurfacePixels`, 200 MP), as
    Compositor's `TypeTool.boxIsValid` allows, not the 100 MP a document once had in all."""

    @classmethod
    def setUpClass(cls):
        cls.script = load_expectations()

    def test_the_caps_match_compositors_document_limits(self):
        self.assertEqual(self.script.MAX_SIDE, 30_000)
        self.assertEqual(self.script.MAX_SURFACE_PIXELS, 200_000_000)

    def test_a_box_past_100_megapixels_but_within_200_stays_editable(self):
        # 12,000 x 12,000 at scale 1 is 12,024 px a side with the padding: about 145 MP.
        self.assertTrue(self.script.text_box_fits(12_000, 12_000, 1, 1))
        # The box is measured as drawn: twice the size at half scale is the same 12,024 px a side.
        self.assertTrue(self.script.text_box_fits(24_000, 24_000, 0.5, 0.5))

    def test_a_box_past_one_surface_or_the_side_limit_or_empty_is_not(self):
        self.assertFalse(self.script.text_box_fits(15_000, 15_000, 1, 1))  # about 226 MP
        self.assertFalse(self.script.text_box_fits(29_990, 100, 1, 1))  # 30,014 px wide
        self.assertTrue(self.script.text_box_fits(29_970, 100, 1, 1))  # 29,994 px wide
        self.assertFalse(self.script.text_box_fits(0, 40, 1, 1))


if __name__ == "__main__":
    unittest.main()
