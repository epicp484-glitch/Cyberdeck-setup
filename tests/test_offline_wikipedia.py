#!/usr/bin/env python3
"""Unit tests for the offline Wikipedia tool (no Kiwix needed).

Run: python3 tests/test_offline_wikipedia.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import offline_wikipedia as w  # noqa: E402

PAGE = """<html><head><title>Capacitor</title><script>var x = 1;</script><style>p{}</style></head>
<body><h1>Capacitor</h1>
<div role="note" class="hatnote">For other uses, see Capacitor (disambiguation).</div>
<table class="infobox"><caption>Capacitor</caption>
<tr><th>Type</th><td>Passive</td></tr><tr><th>Invented</th><td>1745</td></tr></table>
<p>A <b>capacitor</b> stores electrical energy.<sup class="reference">[1]</sup> It was called a condenser.[2]</p>
<h2>History<span class="mw-editsection">[edit]</span></h2>
<p>The Leyden jar was the first capacitor.</p>
<table class="wikitable"><tr><td>junk cell</td></tr></table>
<h2>Applications</h2><p>Capacitors smooth the output of power supplies.</p>
<h2>References</h2><ol class="references"><li>A book</li></ol>
<table class="navbox"><tr><td>nav junk</td></tr></table>
</body></html>"""


class CleanHtml(unittest.TestCase):
    def setUp(self):
        self.title, self.paras = w.clean_article_html(PAGE)
        self.text = "\n".join(self.paras)

    def test_title(self):
        self.assertEqual(self.title, "Capacitor")

    def test_keeps_article_text_and_infobox(self):
        self.assertIn("A capacitor stores electrical energy. It was called a condenser.", self.text)
        self.assertIn("Type: Passive", self.text)
        self.assertIn("## History", self.text)

    def test_removes_junk(self):
        for junk in ("var x", "[1]", "[2]", "[edit]", "junk cell", "nav junk", "A book", "For other uses"):
            self.assertNotIn(junk, self.text)

    def test_stops_at_references(self):
        self.assertNotIn("## References", self.text)


class Keywords(unittest.TestCase):
    def test_strips_question_words(self):
        self.assertEqual(w.keywords("What is a capacitor?"), ["capacitor"])
        self.assertEqual(w.keywords("who was the first person on the moon"), ["first", "person", "moon"])


class SelectText(unittest.TestCase):
    def test_intro_first_and_budget(self):
        paras = ["Intro sentence one. Intro sentence two.", "## Section", "Unrelated stuff here about other things.",
                 "Batteries and capacitors both store energy in circuits."]
        text = w.select_text(paras, "how do capacitors store energy", 200)
        self.assertTrue(text.startswith("Intro sentence one."))
        self.assertIn("capacitors both store energy", text)
        self.assertLessEqual(len(text), 220)

    def test_trims_long_intro_at_sentence(self):
        text = w.select_text(["First sentence here. " * 50], "x", 100)
        self.assertTrue(text.endswith("."))
        self.assertLessEqual(len(text), 100)


class Ranking(unittest.TestCase):
    def test_exact_title_wins_and_disambiguation_loses(self):
        sugg = [w.Candidate("Capacitor plague", "Capacitor_plague"), w.Candidate("Capacitor", "Capacitor"),
                w.Candidate("Capacitor (disambiguation)", "Capacitor_(disambiguation)")]
        full = [w.Candidate("Electrolytic capacitor", "Electrolytic_capacitor"), w.Candidate("Capacitor", "Capacitor")]
        ranked = w.rank_candidates("what is a capacitor", sugg, full)
        self.assertEqual(ranked[0].title, "Capacitor")
        self.assertEqual(ranked[-1].title, "Capacitor (disambiguation)")


class OpenWebUITool(unittest.TestCase):
    def test_tool_reports_unreachable_kiwix_politely(self):
        import asyncio

        tool = w.Tools()
        tool.valves.KIWIX_URL = "http://127.0.0.1:9"  # nothing listens here
        out = asyncio.run(tool.search_wikipedia("capacitor"))
        self.assertIn("could not be searched", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
