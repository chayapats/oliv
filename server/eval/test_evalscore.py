"""Tests for eval/evalscore.py (pure scoring, no LaBSE, no network).

    python3 -m unittest eval/test_evalscore.py
"""
import unittest

import evalscore as es


def row(cid, split="main", scored=None, final="f", raw="r", kw=None, **k):
    r = {"id": cid, "split": split, "set": "my-set",
         "scored": scored, "reference": "ref", "keywords": kw, "raw": raw, "final": final,
         "t_stt": 1.0, "t_cleanup": 0.5, "sim_final": 0.9, "sim_raw": 0.5}
    r.update(k)
    return r


class Buckets(unittest.TestCase):
    def test_bucket_is_id_prefix_like_oliv(self):
        self.assertEqual(es.bucket_of("mx01"), "mx")
        self.assertEqual(es.bucket_of("hx201"), "hx")
        self.assertEqual(es.bucket_of("en91"), "en")
        self.assertEqual(es.bucket_of("clip001"), "clip")

    def test_group_of_split(self):
        self.assertEqual(es.group_of(row("mx01")), "main")
        self.assertEqual(es.group_of(row("mx91", split="holdout")), "holdout")
        self.assertEqual(es.group_of(row("mx201", split="extra")), "extra")
        self.assertEqual(es.group_of(row("va1", split="validation")), "validation")

    def test_fm_excluded(self):
        self.assertTrue(es.excluded(row("fm01")))
        self.assertTrue(es.excluded(row("fm91", split="holdout")))
        self.assertFalse(es.excluded(row("fl01")))


class ScoredText(unittest.TestCase):
    def test_stt_clips_score_raw(self):
        r = row("nm01", scored="stt")
        self.assertEqual(es.scored_text(r), "r")
        self.assertEqual(es.scored_sim(r), 0.5)

    def test_other_clips_score_final(self):
        for r in (row("fl01", scored="pipeline"), row("mx01"), row("mx91", split="holdout")):
            self.assertEqual(es.scored_text(r), "f")
            self.assertEqual(es.scored_sim(r), 0.9)

    def test_oliv_method_always_final(self):
        self.assertEqual(es.oliv_sim(row("nm01", scored="stt")), 0.9)


class Percentile(unittest.TestCase):
    def test_linear_like_numpy(self):
        xs = [1, 2, 3, 4]
        self.assertAlmostEqual(es.percentile(xs, 50), 2.5)
        self.assertAlmostEqual(es.percentile(xs, 95), 3.85)
        self.assertEqual(es.percentile([7], 95), 7)
        self.assertIsNone(es.percentile([], 50))


class Summary(unittest.TestCase):
    def test_match_sim_kw_latency(self):
        rows = [row("mx01", sim_final=0.95, kw=["a"], kw_hit=1.0),
                row("mx02", sim_final=0.70, kw=["a", "b"], kw_hit=0.5, t_stt=3.0, t_cleanup=1.0),
                row("th01", sim_final=0.80)]  # exactly the threshold counts
        s = es.summarize(rows)
        self.assertEqual(s["n"], 3)
        self.assertAlmostEqual(s["match"], 200 / 3)
        self.assertAlmostEqual(s["sim"], (0.95 + 0.70 + 0.80) / 3)
        self.assertAlmostEqual(s["kw"], 75.0)          # mean over clips that declare keywords
        self.assertEqual(s["kw_n"], 2)
        self.assertAlmostEqual(s["total_p50"], 1.5)
        self.assertAlmostEqual(s["total_p95"], 1.5 + 0.9 * 2.5)
        self.assertEqual(s["llm_errors"], 0)

    def test_counts_llm_errors(self):
        s = es.summarize([row("mx01", cleanup_error="timeout"), row("mx02", cleanup_error=None)])
        self.assertEqual(s["llm_errors"], 1)

    def test_empty(self):
        s = es.summarize([])
        self.assertEqual(s["n"], 0)
        self.assertIsNone(s["match"])

    def test_breakdown_excludes_fm_and_splits_groups(self):
        rows = [row("mx01"), row("fm01"), row("mx91", split="holdout"), row("fm91", split="holdout"),
                row("hx201", split="extra"), row("va1", split="validation")]
        b = es.breakdown(rows)
        self.assertEqual(b["groups"]["overall"]["n"], 3)   # all minus fm, no validation
        self.assertEqual(b["groups"]["main"]["n"], 1)
        self.assertEqual(b["groups"]["holdout"]["n"], 1)
        self.assertEqual(b["groups"]["extra"]["n"], 1)
        self.assertEqual(b["groups"]["validation"]["n"], 1)
        self.assertEqual(set(b["buckets"]), {"mx", "hx"})
        self.assertEqual(b["buckets"]["mx"]["n"], 2)
        self.assertEqual(b["excluded"], 2)

    def test_oliv_holdout_uses_final(self):
        rows = [row("nu91", split="holdout", scored="stt", sim_final=0.9, sim_raw=0.1)]
        self.assertEqual(es.breakdown(rows)["oliv_holdout"]["match"], 100.0)


class Selection(unittest.TestCase):
    def b(self, overall, th, en, sim=0.9):
        return {"groups": {"overall": {"match": overall, "sim": sim}},
                "buckets": {"th": {"match": th}, "en": {"match": en}}}

    def test_highest_overall_wins(self):
        w, why = es.choose({"v2": self.b(90, 100, 100), "v3": self.b(92, 100, 100), "v4": self.b(91, 100, 100)})
        self.assertEqual(w, "v3")
        self.assertEqual(why["v3"], "ok")

    def test_regression_on_thai_or_english_disqualifies(self):
        w, why = es.choose({"v2": self.b(90, 100, 100), "v3": self.b(95, 91.7, 100), "v4": self.b(93, 100, 91.7)})
        self.assertEqual(w, "v2")
        self.assertIn("th", why["v3"])
        self.assertIn("en", why["v4"])

    def test_tie_goes_to_mean_sim_then_v2(self):
        w, _ = es.choose({"v2": self.b(90, 100, 100, 0.90), "v3": self.b(90, 100, 100, 0.91)})
        self.assertEqual(w, "v3")
        w, _ = es.choose({"v2": self.b(90, 100, 100, 0.90), "v3": self.b(90, 100, 100, 0.90)})
        self.assertEqual(w, "v2")


if __name__ == "__main__":
    unittest.main()
