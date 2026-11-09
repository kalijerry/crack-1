"""office_metrics.py 的单元测试：合成的两房间（+ 一个远处房间）地图，人从 A 房间走进 B 房间，估计分别是完美、滞后、
跑到相邻 / 远处房间、开头不报位置，检查房间判对率、过门延迟、≤1 m、TTFF、分桶。"""
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "lab"))

import office_metrics as om  # noqa: E402


def rect(x0, y0, x1, y1):
    return [x0, y0, x1, y0, x1, y1, x0, y1]


# A、B 中间 20 cm 墙（相邻）；C 在 10 m 外（远处）
MAP = {"width": 1500, "height": 2500, "units": [
    {"id": "A", "category": "room", "polygon": rect(0, 0, 500, 500)},
    {"id": "B", "category": "room", "polygon": rect(520, 0, 1020, 500)},
    {"id": "C", "category": "room", "polygon": rect(0, 1500, 500, 2000)},
]}
P = om.Params()


def walk(est_fn, speed=50.0, x0=250.0, x1=950.0, hz=3.0):
    """沿 y = 250 从 x0 走到 x1（cm/s），每 1/hz 秒一行；est_fn(t, 真值) → (估计 | None, 报没报)"""
    rows, t = [], 0.0
    T = (x1 - x0) / speed
    while t <= T + 1e-9:
        ref = (x0 + speed * t, 250.0)
        est, conv = est_fn(t, ref)
        rows.append({"t": t, "ref": ref, "est": est, "conv": conv})
        t += 1 / hz
    return rows


def run(rows, mp=MAP):
    units = om.load_units(mp)
    return om.replay_metrics(rows, units, om.adjacency(units, P.adjacent_gap_cm), P)


class GeometryTests(unittest.TestCase):
    def test_units_and_adjacency(self):
        units = om.load_units({"data": MAP})               # 包了一层 data 也认
        self.assertEqual([u.id for u in units], ["A", "B", "C"])
        adj = om.adjacency(units, 60)
        self.assertIn(("A", "B"), adj)
        self.assertIn(("B", "A"), adj)
        self.assertNotIn(("A", "C"), adj)

    def test_room_at_excludes_points_near_walls(self):
        units = om.load_units(MAP)
        self.assertEqual(om.room_at(units, 250, 250, 50), ("A", True))
        self.assertEqual(om.room_at(units, 480, 250, 50), ("A", False))      # 离墙 20 cm
        self.assertEqual(om.room_at(units, 510, 250, 50)[1], False)          # 墙缝里
        self.assertEqual(om.room_at(units, 1300, 1000)[0], None)             # 不在任何房间

    def test_age_buckets(self):
        self.assertEqual([om.age_bucket(d) for d in (0, 1, 7, 8, 30, 31, 400, None)],
                         ["0", "1-7", "1-7", "8-30", "8-30", ">30", ">30", None])


class ReplayTests(unittest.TestCase):
    def test_perfect_estimate(self):
        m = run(walk(lambda t, r: (r, True)))
        agg = om.aggregate([m])
        self.assertEqual(agg["room_correct"], 1.0)
        self.assertEqual(agg["room_correct_all"], 1.0)
        self.assertEqual(agg["wrong_room_far"], 0.0)
        self.assertEqual(agg["door_transitions"], 1)
        self.assertEqual(agg["door_latency_p50_s"], 0.0)
        self.assertEqual(agg["door_miss"], 0.0)
        self.assertEqual(agg["within1m_points"], 1.0)
        self.assertEqual(agg["within1m_time"], 1.0)
        self.assertEqual(agg["coverage"], 1.0)
        self.assertEqual(agg["ttff_s_p50"], 0.0)
        self.assertEqual(agg["ttff_rate"], 1.0)
        self.assertEqual(agg["p50_cm"], 0.0)

    def test_lagging_estimate_has_door_latency(self):
        # 估计落后 3 m（= 6 s）：真值 6.4 s 进 B 房间（离墙 50 cm 以上），估计要到真值走到 x ≥ 820 才进 B（11.4 s）
        m = run(walk(lambda t, r: ((max(250.0, r[0] - 300), 250.0), True), x1=1000))
        agg = om.aggregate([m])
        self.assertEqual(agg["door_transitions"], 1)
        self.assertGreater(agg["door_latency_p50_s"], 4)
        self.assertLess(agg["door_latency_p50_s"], 6.5)
        self.assertLess(agg["room_correct"], 1.0)
        self.assertGreater(agg["wrong_room_adjacent"], 0)        # 落后时在相邻的 A 房间
        self.assertEqual(agg["wrong_room_far"], 0.0)
        self.assertLess(agg["within1m_points"], 0.2)              # 一直差 3 m（开头 2 s 估计停在起点，除外）
        self.assertEqual(agg["ttff_rate"], 0.0)                   # 一直差 3 m：没定到，TTFF 按窗口长度截尾
        self.assertAlmostEqual(agg["ttff_s_p50"], 15.0, delta=0.5)

    def test_far_room_and_missing_door(self):
        # 进 B 之后估计一直在远处的 C 房间：过门算漏，错房间算远处
        m = run(walk(lambda t, r: ((250.0, 1750.0), True) if r[0] > 520 else (r, True)))
        agg = om.aggregate([m])
        self.assertGreater(agg["wrong_room_far"], 0.3)
        self.assertEqual(agg["wrong_room_adjacent"], 0.0)
        self.assertEqual(agg["door_miss"], 1.0)
        self.assertIsNone(agg["door_latency_p50_s"])
        self.assertGreaterEqual(m["wrong_before_first"], 0)

    def test_no_fix_at_start_counts_against_all_time_and_ttff(self):
        m = run(walk(lambda t, r: (r, True) if t >= 4 else (None, False)))
        agg = om.aggregate([m])
        self.assertEqual(agg["room_correct"], 1.0)
        self.assertLess(agg["room_correct_all"], 1.0)
        self.assertLess(agg["coverage"], 1.0)
        self.assertAlmostEqual(agg["ttff_s_p50"], 4.0, delta=1.0)
        self.assertAlmostEqual(agg["ttff_m_p50"], 2.0, delta=0.5)
        self.assertLess(agg["within1m_time"], 1.0)

    def test_wrong_fix_before_first_correct(self):
        # 前 5 s 定在远处，然后对了：首个正确定位前错定 1 次（一段连续的算 1 次）
        m = run(walk(lambda t, r: ((250.0, 1750.0), True) if t < 5 else (r, True), speed=40, x1=1000))
        self.assertEqual(m["wrong_before_first"], 1)
        self.assertAlmostEqual(m["ttff_s"], 5.0, delta=1.0)

    def test_without_units_room_metrics_are_none(self):
        m = run(walk(lambda t, r: (r, True)), mp={"width": 1500, "height": 2500})
        agg = om.aggregate([m], have_rooms=False)
        self.assertIsNone(agg["room_correct"])
        self.assertIsNone(agg["door_latency_p50_s"])
        self.assertEqual(agg["within1m_time"], 1.0)
        self.assertEqual(agg["ttff_s_p50"], 0.0)


class EndToEndTests(unittest.TestCase):
    def test_csv_compute_and_grouping(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "track.csv"
            with open(p, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["session", "run", "t_ms", "est_x", "est_y", "converged", "unc_cm", "ref_x", "ref_y"])
                for sess, lag in (("s1", 0), ("s2", 300)):
                    for r in walk(lambda t, ref: ((max(250.0, ref[0] - lag), 250.0), True)):
                        w.writerow([sess, 1, int(r["t"] * 1000), *r["est"], 1, 50, *r["ref"]])
                    w.writerow([sess, 2, 0, "", "", 0, "", 250, 250])      # 第二次回放只有一行：没估计
            g = om.load_track(p)
            self.assertEqual(sorted(g), [("s1", 1), ("s1", 2), ("s2", 1), ("s2", 2)])
            res = om.compute(g, MAP, {"s1": {"map_age_days": 0, "carry_mode": "texting"},
                                      "s2": {"map_age_days": 9, "carry_mode": "pocket"}})
            self.assertEqual(res["rooms"], 3)
            self.assertEqual(sorted(res["by_map_age"]), ["0", "8-30"])
            self.assertEqual(res["by_carry_mode"]["texting"]["room_correct"], 1.0)
            self.assertLess(res["by_carry_mode"]["pocket"]["room_correct"], 1.0)
            self.assertEqual(res["all"]["replays"], 4)
            # 只有聚合值：不出坐标和房间名
            self.assertNotIn("A", str(res))
            mp, out = Path(td) / "map.json", Path(td) / "out.json"
            mp.write_text(json.dumps(MAP), encoding="utf-8")
            self.assertEqual(om.main(["--track", str(p), "--map", str(mp), "--json", str(out), "--boundary-cm", "30"]), 0)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["all"]["replays"], 4)


if __name__ == "__main__":
    unittest.main()
