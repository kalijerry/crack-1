"""定位实验室 lab.py 的单元测试：指标、档位、基线对比、走一遍协议的配对、报告，以及用假的 hpass-eval 跑通整条流程。"""
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "lab"))

import lab  # noqa: E402

SUITE = lab.load_suite()


def rep(errs, ref=None, first_fix=10.0):
    return {"errorsCm": errs, "refPoints": ref if ref is not None else len(errs), "firstFixM": first_fix}


class MetricsTests(unittest.TestCase):
    def test_percentiles_and_shares(self):
        m = lab.metrics([rep([100] * 8 + [600, 700], ref=20), rep([], ref=0, first_fix=None)])
        self.assertEqual(m["replays"], 2)
        self.assertEqual(m["median_cm"], 100)
        self.assertEqual(m["p90_cm"], 600)        # 最近秩：索引 int(9×0.9+0.5) = 8
        self.assertAlmostEqual(m["wrong_fix"], 0.2)
        self.assertAlmostEqual(m["coverage"], 0.5)
        self.assertAlmostEqual(m["fixed_share"], 0.5)
        self.assertEqual(m["first_fix_m"], 10.0)

    def test_empty(self):
        m = lab.metrics([rep([], ref=5, first_fix=None)])
        self.assertIsNone(m["median_cm"])
        self.assertEqual(m["coverage"], 0)
        self.assertEqual(m["fixed_share"], 0)

    def test_ladder(self):
        ladder = SUITE["ladder"]
        self.assertEqual(lab.ladder_level({"median_cm": 120, "p90_cm": 250, "wrong_fix": 0.02, "coverage": 0.9}, ladder),
                         "对标 Oriient")
        self.assertEqual(lab.ladder_level({"median_cm": 250, "p90_cm": 500, "wrong_fix": 0.1, "coverage": 0.9}, ladder), "可用")
        # 覆盖太低不算，防止「只在少数点上报位置」刷指标
        self.assertIsNone(lab.ladder_level({"median_cm": 100, "p90_cm": 200, "wrong_fix": 0, "coverage": 0.1}, ladder))


class CompareTests(unittest.TestCase):
    tol = SUITE["tolerance"]

    def test_regression_and_improvement(self):
        base = {"median_cm": 300, "p90_cm": 800, "wrong_fix": 0.2, "coverage": 0.8, "fixed_share": 1.0}
        worse = dict(base, median_cm=400, wrong_fix=0.3)
        c = lab.compare(worse, base, self.tol)
        self.assertEqual({k for k, _, _ in c["regressions"]}, {"median_cm", "wrong_fix"})
        better = dict(base, p90_cm=500, coverage=0.95)
        c = lab.compare(better, base, self.tol)
        self.assertFalse(c["regressions"])
        self.assertEqual({k for k, _, _ in c["improvements"]}, {"p90_cm", "coverage"})

    def test_noise_within_tolerance_is_flat(self):
        base = {"median_cm": 300, "p90_cm": 800, "wrong_fix": 0.2, "coverage": 0.8, "fixed_share": 1.0}
        c = lab.compare(dict(base, median_cm=340, wrong_fix=0.23), base, self.tol)
        self.assertFalse(c["regressions"])
        self.assertFalse(c["improvements"])

    def test_losing_a_metric_is_a_regression(self):
        c = lab.compare({"median_cm": None}, {"median_cm": 300}, {"median_cm": self.tol["median_cm"]})
        self.assertEqual(len(c["regressions"]), 1)


class ProtocolTests(unittest.TestCase):
    def test_walk_once_uses_other_days(self):
        build = ["ios_survey_20261006_114810", "ios_survey_20261007_091813"]
        test = ["ios_survey_20261006_120000", "ios_survey_20261008_100000"]
        pairs = dict(lab.walk_once_pairs(build, test))
        self.assertEqual(pairs["ios_survey_20261006_114810"], ["ios_survey_20261008_100000"])
        self.assertEqual(pairs["ios_survey_20261007_091813"], test)

    def test_walk_once_falls_back_when_same_day(self):
        pairs = lab.walk_once_pairs(["s_20261006_a"], ["s_20261006_b"])
        self.assertEqual(pairs, [("s_20261006_a", ["s_20261006_b"])])

    def test_site_label_hides_id(self):
        lbl = lab.site_label("site-alpha-secret")
        self.assertTrue(lbl.startswith("site-"))
        self.assertNotIn("alpha", lbl)
        self.assertEqual(lbl, lab.site_label("site-alpha-secret"))


class PreparePublicCacheTests(unittest.TestCase):
    """转换结果按「转换脚本内容 + 参数」缓存：没变就跳过，变了就重转。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.conv = self.tmp / "conv.py"
        self.conv.write_text("# v1\n")
        self.work = self.tmp / "work"
        self.suite = {"datasets": {"d": {"kind": "ilc", "drift": "pdr"}, "x": {"kind": "private"}}}
        self.calls = []

    def fake_run(self, cmd, check):
        self.calls.append(cmd)
        dst = Path(cmd[3])
        dst.mkdir(parents=True, exist_ok=True)
        (dst / "manifest.json").write_text("{}")

    def prep(self):
        lab.prepare_public(self.suite, self.tmp / "ilc", self.work, conv=self.conv, run=self.fake_run)

    def test_skips_when_unchanged_and_reconverts_on_change(self):
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][4:], ["--drift", "pdr"])
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.conv.write_text("# v2\n")
        self.prep()
        self.assertEqual(len(self.calls), 2)
        self.suite["datasets"]["d"]["build_max"] = 5
        self.prep()
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.calls[2][4:], ["--drift", "pdr", "--build-max", "5"])
        self.prep()
        self.assertEqual(len(self.calls), 3)

    def test_old_cache_without_key_is_rebuilt(self):
        dst = self.work / "public" / "d"
        dst.mkdir(parents=True)
        (dst / "manifest.json").write_text("{}")
        (dst / "stale.txt").write_text("old")
        self.prep()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse((dst / "stale.txt").exists())
        self.assertTrue((dst / lab.CONVERT_KEY_FILE).exists())

    def test_key_depends_on_script_and_args(self):
        k1 = lab.convert_key(self.conv, ["--drift", "pdr"])
        self.assertEqual(k1, lab.convert_key(self.conv, ["--drift", "pdr"]))
        self.assertNotEqual(k1, lab.convert_key(self.conv, ["--drift", "arkit"]))
        self.conv.write_text("# changed\n")
        self.assertNotEqual(k1, lab.convert_key(self.conv, ["--drift", "pdr"]))


FAKE_EVAL = textwrap.dedent("""
    import json, sys
    a = sys.argv
    out = a[a.index("--json") + 1]
    runs = int(a[a.index("--runs") + 1])
    cold = "--oracle-start" not in a
    errs = [150.0] * 9 + ([900.0] if cold else [250.0])
    json.dump([{"session": "t", "errorsCm": errs, "refPoints": 12, "firstFixM": 20.0 if cold else 0.0}] * runs, open(out, "w"))
""")


class EndToEndTests(unittest.TestCase):
    def test_run_report_baseline(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            fake = td / "fake_eval.py"
            fake.write_text(FAKE_EVAL, encoding="utf-8")
            for ds in SUITE["datasets"]:
                d = td / "work" / "public" / ds
                (d / "build").mkdir(parents=True)
                (d / "test").mkdir()
                (d / "map.json").write_text("{}")
            res = lab.run_suite(SUITE, "pr", td / "work", [sys.executable, str(fake)])
            ids = [r["id"] for r in res["results"]]
            self.assertEqual(ids, [s["id"] for s in SUITE["scenarios"] if "pr" in s["tiers"]])
            self.assertTrue(all("metrics" in r for r in res["results"]))
            cold = next(r for r in res["results"] if r["id"] == "public/pdr/cold-mag")["metrics"]
            self.assertAlmostEqual(cold["wrong_fix"], 0.1)
            self.assertEqual(cold["replays"], SUITE["runs"]["pr"])

            md, regressed = lab.build_report(res, None, SUITE)
            self.assertIn(lab.MARKER, md)
            self.assertIn("还没有基线", md)
            self.assertFalse(regressed)

            # 写基线 → 同样结果持平；中位变差 → 退步
            rp = td / "results.json"
            rp.write_text(json.dumps(res), encoding="utf-8")
            bp = td / "baseline.json"
            self.assertEqual(lab.main(["baseline", "--results", str(rp), "--out", str(bp)]), 0)
            base = json.loads(bp.read_text(encoding="utf-8"))
            _, regressed = lab.build_report(res, base, SUITE)
            self.assertFalse(regressed)
            worse = json.loads(json.dumps(res))
            worse["results"][0]["metrics"]["median_cm"] = 900
            md, regressed = lab.build_report(worse, base, SUITE)
            self.assertTrue(regressed)
            self.assertIn("退步", md)
            wp = td / "worse.json"
            wp.write_text(json.dumps(worse), encoding="utf-8")
            self.assertEqual(lab.main(["report", "--results", str(wp), "--baseline", str(bp), "--fail-on-regression"]), 1)

    def test_parallel_jobs_keep_order(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            fake = td / "fake_eval.py"
            fake.write_text(FAKE_EVAL, encoding="utf-8")
            for ds in SUITE["datasets"]:
                d = td / "work" / "public" / ds
                (d / "build").mkdir(parents=True)
                (d / "test").mkdir()
                (d / "map.json").write_text("{}")
            serial = lab.run_suite(SUITE, "nightly", td / "work", [sys.executable, str(fake)])
            par = lab.run_suite(SUITE, "nightly", td / "work", [sys.executable, str(fake)], jobs=4)
            self.assertEqual([r["id"] for r in par["results"]], [r["id"] for r in serial["results"]])
            self.assertEqual([r["metrics"] for r in par["results"]], [r["metrics"] for r in serial["results"]])

    def test_eval_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            bad = td / "bad.py"
            bad.write_text("import sys; print('boom'); sys.exit(3)", encoding="utf-8")
            d = td / "work" / "public" / "ilc-pdr"
            d.mkdir(parents=True)
            res = lab.run_suite(SUITE, "pr", td / "work", [sys.executable, str(bad)], only="public/pdr/track-mag")
            self.assertEqual(len(res["results"]), 1)
            self.assertIn("boom", res["results"][0]["error"])
            base = {"results": [{"id": "public/pdr/track-mag", "metrics": {"median_cm": 100}}]}
            md, regressed = lab.build_report(res, base, SUITE)
            self.assertTrue(regressed)
            self.assertIn("运行失败", md)


if __name__ == "__main__":
    unittest.main()
