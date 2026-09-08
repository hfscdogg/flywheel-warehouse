"""Tests for pipelines.lib.pdftext.rows — reading a PDF table by coordinates.

`lines()` returns runs in the order the file draws them, which is all
Parasol's invoice needs. Security Central's recurring report draws whole
header blocks backwards and puts a wrapped cell to the left of its own label,
so draw order is not reading order and rows have to come from coordinates.

The fixtures here are built to be out of order on purpose: a test that feeds
in an already-ordered document proves nothing about the thing that broke.
"""

import unittest

from pipelines.lib import pdftext


def pdf(runs):
    """A minimal PDF drawing `runs` — (x, y, text) in whatever order given.

    One BT/ET per run with an absolute Td, which is how the reports in
    question are generated.
    """
    body = "\n".join(
        f"BT /F1 7.0 Tf 9.3 TL {x} {y} Td ({text}) Tj T* ET" for x, y, text in runs)
    return (b"%PDF-1.4\n1 0 obj\n<< /Length "
            + str(len(body)).encode()
            + b" >>\nstream\n" + body.encode("latin-1")
            + b"\nendstream\nendobj\ntrailer\n<< >>\n%%EOF\n")


class Rows(unittest.TestCase):
    def test_draw_order_does_not_decide_reading_order(self):
        # Drawn bottom-up and right-to-left; read top-down, left-to-right.
        data = pdf([(200, 600, "Probe"), (100, 600, "left"),
                    (100, 620, "above"), (300, 620, "right")])
        self.assertEqual(pdftext.rows(data, "Probe"),
                         [["above", "right"], ["left", "Probe"]])

    def test_baselines_within_tolerance_are_one_row(self):
        # Cells on one printed line wobble by a fraction of a unit.
        data = pdf([(100, 600.0, "Probe"), (200, 601.4, "same"),
                    (300, 599.2, "line")])
        self.assertEqual(pdftext.rows(data, "Probe"), [["Probe", "same", "line"]])

    def test_a_row_below_the_tolerance_is_a_new_row(self):
        data = pdf([(100, 600, "Probe"), (100, 590, "next")])
        self.assertEqual(pdftext.rows(data, "Probe"), [["Probe"], ["next"]])

    def test_t_star_advances_by_the_leading(self):
        body = ("BT /F1 7.0 Tf 9.3 TL 100 600 Td (Probe) Tj T* "
                "(second) Tj T* (third) Tj ET")
        data = (b"stream\n" + body.encode() + b"\nendstream")
        self.assertEqual(pdftext.rows(data, "Probe"),
                         [["Probe"], ["second"], ["third"]])

    def test_empty_runs_are_dropped(self):
        data = pdf([(100, 600, "Probe"), (200, 600, "   ")])
        self.assertEqual(pdftext.rows(data, "Probe"), [["Probe"]])

    def test_missing_probe_fails_loudly(self):
        # The silent failure mode of a roster parser is an empty roster, so a
        # document that is not the expected one must raise rather than return.
        with self.assertRaises(ValueError):
            pdftext.rows(pdf([(100, 600, "something else")]), "Probe")


if __name__ == "__main__":
    unittest.main()
