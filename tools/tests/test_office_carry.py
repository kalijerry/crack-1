"""office-carry 协议（lab.py prepare-private + office_carry.py）、站点代号、公开 public/imu 场景的单元测试：
盲测机 + 真值伴随机的配对、敲击对时把真值换到盲测机的时钟、杆臂、评分窗口、地图年龄，以及用假的 hpass-eval 跑通
「冷启动 + 已知起点」两个场景和办公室指标表。"""
import json
import math
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "lab"))
sys.path.insert(0, str(ROOT / "tools" / "tests"))

import lab  # noqa: E402
import office_carry as oc  # noqa: E402
from test_bump_sync import device, START_TAPS, END_TAPS  # noqa: E402

SUITE = lab.load_suite()
DAY = 86_400_000
T_BUILD = 1_760_000_000_000          # 建图那天
T_TEST = T_BUILD + 3 * DAY           # 三天后测试
OFF_B = 250.0                        # 伴随机时钟比盲测机快 250 ms


def write_imu(d: Path, t0: float, off: float, phase: float, seed: int, dur_ms=60000.0, taps=True):
    d.mkdir(parents=True, exist_ok=True)
    taps_ = ([5000.0, 5500.0, 6000.0, 55000.0, 55500.0, 56000.0] if taps else [])
    ts, a = device(off, 0, taps_, phase_ms=phase, seed=seed, dur_ms=dur_ms)
    with open(d / "imu.csv", "w", encoding="utf-8") as f:
        f.write("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz\n")
        for t, v in zip(ts, a):
            f.write(f"{t0 + t:.0f},0,0,{v:.4f},0,0,0,20,0,-40\n")


def make_raw(root: Path, taps=True, carry="pocket", pair="p1", comp_map_id=False):
    """一个建图会话、一个盲测会话（A）、一个伴随真值会话（B，已经导出了 truth.csv）"""
    b = root / "survey_build"
    write_imu(b, T_BUILD, 0, 0, 5, dur_ms=5000, taps=False)
    (b / "anchors.csv").write_text("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n")
    (b / "meta.json").write_text(json.dumps({"survey": True, "map_id": "office-map-secret"}))
    a = root / "blind_1"
    write_imu(a, T_TEST, 0, 0, 1, taps=taps)
    (a / "meta.json").write_text(json.dumps({"purpose": "blind_test", "camera": False, "pair_id": pair,
                                             "carry_mode": carry, "map_id": "office-map-secret"}))
    c = root / "truth_1"
    write_imu(c, T_TEST, OFF_B, 7, 2, taps=taps)
    # 真值（伴随机时钟）：沿 +x 匀速 1 m/s，10 Hz
    with open(c / "truth.csv", "w", encoding="utf-8") as f:
        f.write("t_ms,x_cm,y_cm\n")
        for k in range(0, 600):
            t = k * 100
            f.write(f"{T_TEST + t + OFF_B:.0f},{100 + t / 10:.1f},300\n")
    cm = {"purpose": "ground_truth", "pair_id": pair, "lever_arm_cm": 25}
    if comp_map_id:
        cm["map_id"] = "office-map-secret"
    (c / "meta.json").write_text(json.dumps(cm))
    return [b, a, c]


class SiteLabelTests(unittest.TestCase):
    def test_hmac_with_salt_and_fallback(self):
        old = lab.site_label("m-1", salt="")
        self.assertEqual(old, "site-" + __import__("hashlib").sha1(b"m-1").hexdigest()[:6])
        salted = lab.site_label("m-1", salt="pepper")
        self.assertNotEqual(salted, old)
        self.assertEqual(salted, lab.site_label("m-1", salt="pepper"))
        self.assertNotEqual(salted, lab.site_label("m-1", salt="other"))
        self.assertRegex(salted, r"^site-[0-9a-f]{6}$")
        os.environ["HPASS_LAB_SALT"] = "pepper"
        try:
            self.assertEqual(lab.site_label("m-1"), salted)
        finally:
            del os.environ["HPASS_LAB_SALT"]


class PairingTests(unittest.TestCase):
    def test_classify_and_group(self):
        with tempfile.TemporaryDirectory() as td:
            dirs = make_raw(Path(td))
            g = lab.group_sessions(dirs)
            self.assertEqual(list(g), ["office-map-secret"])
            kinds = {k: [d.name for d, _ in v] for k, v in g["office-map-secret"].items()}
            self.assertEqual(kinds, {"build": ["survey_build"], "test": [], "blind": ["blind_1"], "companion": ["truth_1"]})

    def test_blind_with_camera_is_not_used(self):
        self.assertIsNone(oc.classify({"purpose": "blind_test", "camera": True, "pair_id": "x"}, Path(".")))
        self.assertIsNone(oc.classify({"purpose": "blind_test", "camera": False}, Path(".")))

    def test_app_companion_role_is_companion(self):
        # App 的伴随真值机是建图测试会话（purpose = test、survey = true）加 role = gt_companion
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "anchors.csv").write_text("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n", encoding="utf-8")
            meta = {"purpose": "test", "survey": True, "role": "gt_companion", "pair_id": "a1b2c3d4"}
            self.assertEqual(oc.classify(meta, d), "companion")
            self.assertEqual(oc.classify({"purpose": "test", "survey": True}, d), "test")

    def test_sync_file_prefers_acc_raw(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "imu.csv").write_text("t_ms,ax,ay,az\n", encoding="utf-8")
            self.assertEqual(oc.sync_file(d).name, "imu.csv")
            (d / "acc_raw.csv").write_text("t_ms,ax,ay,az\n1,0,0,9.8\n2,0,0,9.8\n", encoding="utf-8")
            self.assertEqual(oc.sync_file(d).name, "acc_raw.csv")

    def test_unpaired(self):
        with tempfile.TemporaryDirectory() as td:
            dirs = make_raw(Path(td))
            g = lab.group_sessions(dirs)["office-map-secret"]
            pairs, unpaired = oc.pair_sessions(g["blind"], [])
            self.assertEqual((pairs, unpaired), ([], ["blind_1"]))


class BlindSessionTests(unittest.TestCase):
    def test_truth_in_blind_clock_with_lever_and_window(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            b, a, c = make_raw(td / "raw")
            info = oc.make_blind_session(a, c, json.loads((a / "meta.json").read_text()), json.loads((c / "meta.json").read_text()),
                                         td / "out" / "blind_1", T_BUILD)
            self.assertTrue(info["ok"], info)
            self.assertEqual(info["map_age_days"], 3)
            self.assertEqual(info["start_heading"], "unknown")          # 口袋：δ 未知，整圆
            self.assertAlmostEqual(info["sync"]["offset_ms"], OFF_B, delta=5)
            rows = [tuple(map(float, l.split(","))) for l in (td / "out" / "blind_1" / "truth.csv").read_text().splitlines()[1:]]
            # 换到盲测机时钟后：x = 100 + (t − T_TEST)/10，再往后挪 25 cm
            for t, x, y in rows[::50]:
                self.assertAlmostEqual(x, 100 + (t - T_TEST) / 10 - 25, delta=1.0)
                self.assertEqual(y, 300)
            # 评分窗口：开始敲击后 3 s 到结束敲击之前
            self.assertGreaterEqual(rows[0][0], T_TEST + 6000 + 3000 - 30)
            self.assertLessEqual(rows[-1][0], T_TEST + 55000 + 30)
            out = td / "out" / "blind_1"
            self.assertEqual((out / "arkit_pose.csv").read_text().strip().split(",")[0], "t_ms")   # 只有表头
            self.assertTrue((out / "imu.csv").exists())

    def test_texting_gets_truth_heading(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            b, a, c = make_raw(td / "raw", carry="texting")
            info = oc.make_blind_session(a, c, json.loads((a / "meta.json").read_text()), json.loads((c / "meta.json").read_text()),
                                         td / "out" / "x", None)
            self.assertEqual(info["start_heading"], "truth")
            self.assertIsNone(info["map_age_days"])

    def test_no_taps_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            b, a, c = make_raw(td / "raw", taps=False)
            info = oc.make_blind_session(a, c, {}, {}, td / "out" / "x", T_BUILD)
            self.assertFalse(info["ok"])
            self.assertIn("对时失败", info["reason"])
            self.assertFalse((td / "out" / "x").exists())

    def test_lever_arm_follows_walking_direction(self):
        tr = [(t * 100.0, 0.0, t * 10.0) for t in range(30)]          # 沿 +y 走
        out = oc.apply_lever(tr, 25)
        self.assertAlmostEqual(out[10][1], 0.0)
        self.assertAlmostEqual(out[10][2], tr[10][2] - 25)
        self.assertEqual(oc.apply_lever(tr, 0), tr)


FAKE_EVAL = textwrap.dedent("""
    import json, sys
    a = sys.argv
    out = a[a.index("--json") + 1]
    runs = int(a[a.index("--runs") + 1])
    tests = [t.split("/")[-1] for t in a[a.index("--test") + 1].split(",")]
    json.dump([{"session": t, "errorsCm": [100.0] * 10, "refPoints": 12, "firstFixM": 2.0} for t in tests] * runs, open(out, "w"))
    if "--track-out" in a:
        with open(a[a.index("--track-out") + 1], "w") as f:
            f.write("session,run,t_ms,est_x,est_y,converged,unc_cm,ref_x,ref_y\\n")
            for t in tests:
                for r in range(1, runs + 1):
                    for k in range(40):
                        x = 100 + 30 * k
                        f.write(f"{t},{r},{k * 500},{x + 50},300,1,80,{x},300\\n")
""")


class OfficeCarryEndToEndTests(unittest.TestCase):
    def test_prepare_site_and_run(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            dirs = make_raw(td / "raw")
            g = lab.group_sessions(dirs)["office-map-secret"]
            units = {"width": 2000, "height": 1000, "units": [
                {"id": "R1", "category": "room", "polygon": [0, 0, 600, 0, 600, 600, 0, 600]},
                {"id": "R2", "category": "room", "polygon": [620, 0, 1400, 0, 1400, 600, 620, 600]}]}
            entry = lab.prepare_site("office-map-secret", g, td / "work", json.dumps(units).encode())
            self.assertIsNotNone(entry)
            self.assertNotIn("office-map-secret", json.dumps(entry))
            self.assertEqual(entry["test"], [])
            self.assertEqual(entry["office"], [{"name": "blind_1", "carry_mode": "pocket", "map_age_days": 3,
                                                "start_heading": "unknown"}])
            (td / "work" / "private").mkdir(exist_ok=True)
            (td / "work" / "private" / "manifest.json").write_text(json.dumps([entry]), encoding="utf-8")
            fake = td / "fake_eval.py"
            fake.write_text(FAKE_EVAL, encoding="utf-8")
            res = lab.run_suite(SUITE, "pr", td / "work", [sys.executable, str(fake)], only="private/")
            ids = [r["id"] for r in res["results"]]
            label = entry["label"]
            self.assertEqual(ids, [f"private/{label}/office-carry/track", f"private/{label}/office-carry/cold"])
            for r in res["results"]:
                self.assertIn("office", r, r)
                o = r["office"]
                self.assertEqual(o["rooms"], 2)
                self.assertEqual(o["all"]["coverage"], 1.0)
                self.assertEqual(o["all"]["within1m_points"], 1.0)
                self.assertEqual(sorted(o["by_carry_mode"]), ["pocket"])
                self.assertEqual(sorted(o["by_map_age"]), ["1-7"])
                self.assertIsNotNone(o["all"]["room_correct"])
            md, _ = lab.build_report(res, None, SUITE)
            self.assertIn("办公室指标", md)
            self.assertIn("office-carry/track", md)


class PublicImuScenarioTests(unittest.TestCase):
    def test_suite_has_real_imu_scenarios_and_keeps_old_ones(self):
        by_id = {s["id"]: s for s in SUITE["scenarios"]}
        for sid in ("public/pdr/track-mag", "public/pdr/cold-mag-search", "public/pdr/cold-mag-radio", "public/pdr/cold-wifi"):
            self.assertEqual(by_id[sid]["dataset"], "ilc-pdr")
            self.assertNotIn("--motion", by_id[sid]["flags"])
        imu = {k: v for k, v in by_id.items() if k.startswith("public/imu/")}
        self.assertEqual(sorted(imu), ["public/imu/cold-mag-radio", "public/imu/cold-mag-search", "public/imu/cold-wifi",
                                       "public/imu/track-mag", "public/imu/track-mag-carry", "public/imu/track-mag-noheading",
                                       "public/imu/track-mag-noheading-carry"])
        # 携带无关运动模型（App 默认）的场景带 --carry-motion，起步朝向未知的带 --start-heading unknown
        for k, s in imu.items():
            self.assertEqual("--carry-motion" in s["flags"], k.endswith("-carry"), k)
            self.assertEqual("unknown" in s["flags"], "noheading" in k, k)
        for s in imu.values():
            self.assertEqual(s["dataset"], "ilc-imu")
            self.assertEqual(s["flags"][s["flags"].index("--motion") + 1], "pdr-imu")
            self.assertTrue(s["office_metrics"])
        self.assertEqual({k for k, s in imu.items() if "pr" in s["tiers"]},
                         {"public/imu/track-mag", "public/imu/cold-mag-radio", "public/imu/track-mag-carry"})
        # 办公室盲测和 App 默认一致：携带无关运动模型、房间约束、静止冻结
        oc_flags = SUITE["private"]["protocols"]["office-carry"]["flags"]
        for f in ("--carry-motion", "--rooms", "--stationary-freeze"):
            self.assertIn(f, oc_flags)
        self.assertEqual(SUITE["datasets"]["ilc-imu"]["drift"], "imu")
        self.assertTrue(SUITE["datasets"]["ilc-imu"]["flip_y"])

    def test_prepare_public_passes_flip(self):
        calls = []
        with tempfile.TemporaryDirectory() as td:
            conv = Path(td) / "c.py"
            conv.write_text("#")

            def run(cmd, check):
                calls.append(cmd[4:])
                Path(cmd[3]).mkdir(parents=True, exist_ok=True)
            lab.prepare_public({"datasets": {"x": {"kind": "ilc", "drift": "imu", "flip_y": True}}}, Path(td), Path(td) / "w",
                               conv=conv, run=run)
        self.assertEqual(calls, [["--drift", "imu", "--flip-y"]])

    def test_office_level(self):
        lad = SUITE["office_ladder"]
        good = {"room_correct": 0.95, "wrong_room_far": 0.01, "p50_cm": 120, "p90_cm": 280, "ttff_m_p50": 15}
        self.assertEqual(lab.office_level(good, lad), "目标")
        self.assertEqual(lab.office_level(dict(good, p50_cm=200), lad), "可用")
        self.assertIsNone(lab.office_level(dict(good, room_correct=None), lad))     # 没有房间单元就不评档


if __name__ == "__main__":
    unittest.main()
