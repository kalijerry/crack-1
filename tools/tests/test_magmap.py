"""magmap.py 的单元测试：合成一个带 ARKit 漂移的建图会话，检查建出来的磁场图是否贴近真值。"""
import json
import math
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import magmap  # noqa: E402

T0 = 1_700_000_000_000
SPEED = 120.0                      # cm/s
AISLES = [500.0, 860.0, 1220.0]
TOP, BOTTOM = 300.0, 2300.0
PHI = math.radians(37)             # ARKit 坐标系相对地图转了多少


def field(x, y):
    """真值：返回 (|B|, Bz, Bh)。"""
    xm, ym = x / 100, y / 100
    bz = -43 + 6 * math.sin(1.3 * xm + 0.5 * ym + 0.3) + 5 * math.sin(0.4 * xm - 1.1 * ym + 1.2)
    bh = 25 + 7 * math.sin(0.9 * xm - 0.8 * ym + 2.0) + 4 * math.sin(1.7 * xm + 0.6 * ym)
    return math.hypot(bz, bh), bz, bh


def rot(v, phi):
    c, s = math.cos(phi), math.sin(phi)
    return v[0] * c - v[1] * s, v[0] * s + v[1] * c


def write_map(path, envelope=True):
    elements = []
    for i, x in enumerate(AISLES):
        elements.append({"shapeType": "MapCross", "code": f"V{i}", "lineWidth": 140, "points": [x, TOP, x, BOTTOM]})
    elements.append({"shapeType": "MapCross", "code": "Ht", "lineWidth": 140, "points": [AISLES[0], TOP, AISLES[-1], TOP]})
    elements.append({"shapeType": "MapCross", "code": "Hb", "lineWidth": 140, "points": [AISLES[0], BOTTOM, AISLES[-1], BOTTOM]})
    inner = {"width": 1600, "height": 2600, "mapElementList": elements}
    body = {"code": "200", "message": "success", "success": True, "data": inner} if envelope else inner
    Path(path).write_text(json.dumps(body))


ROUTE = [(AISLES[0], TOP), (AISLES[0], BOTTOM), (AISLES[1], BOTTOM), (AISLES[1], TOP), (AISLES[2], TOP), (AISLES[2], BOTTOM)]


def make_session(root, name, anchor_noise=0.0, wrong_scale=False, seed=1):
    rnd = random.Random(seed)
    d = Path(root) / name
    d.mkdir(parents=True)
    (d / "meta.json").write_text(json.dumps({"platform": "ios", "device_label": "survey", "start_ms": T0}))
    # 真实路径按 20 ms 步长离散
    pts, t, dist = [], 0.0, 0.0
    for (x1, y1), (x2, y2) in zip(ROUTE, ROUTE[1:]):
        L = math.hypot(x2 - x1, y2 - y1)
        n = int(L / SPEED / 0.02)
        for k in range(n):
            f = k / n
            pts.append((T0 + t * 1000, x1 + (x2 - x1) * f, y1 + (y2 - y1) * f, dist))
            t += 0.02
            dist += L / n
    a0 = (123.0, -456.0)
    p0 = ROUTE[0]

    def ar_of(p, dist_):
        v = rot((p[0] - p0[0], p[1] - p0[1]), -PHI)
        return (a0[0] + v[0] * 1.004 + 0.004 * dist_ + rnd.gauss(0, 1.5), a0[1] + v[1] * 1.004 + rnd.gauss(0, 1.5))

    imu = ["t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg"]
    pose = ["t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason"]
    ar_at = {}
    for i, (tm, x, y, dist_) in enumerate(pts):
        b, bz, bh = field(x, y)
        n = rnd.gauss(0, 0.3)
        imu.append(f"{int(tm)},0,0,9.81,0,0,0,{bh + n:.3f},0,{bz + rnd.gauss(0, 0.3):.3f},2,1,0,0,0,-1")
        if i % 2 == 0:                                       # 约 25 Hz 位姿
            a = ar_of((x, y), dist_)
            ar_at[i] = a
            tracking = 1 if 4000 <= (tm - T0) < 6000 else 2    # 中间有 2 秒跟踪受限
            pose.append(f"{int(tm)},{a[0] / 100:.4f},0,{a[1] / 100:.4f},0,0,0,1,{tracking},0")
    (d / "imu.csv").write_text("\n".join(imu) + "\n")
    (d / "arkit_pose.csv").write_text("\n".join(pose) + "\n")

    # 锚点：起点、heading、每个拐角 reanchor、终点估计
    corner_idx = []
    acc = 0.0
    for (x1, y1), (x2, y2) in zip(ROUTE, ROUTE[1:]):
        acc += math.hypot(x2 - x1, y2 - y1)
        corner_idx.append(acc)
    rows = ["t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note"]
    first_dir = (ROUTE[1][0] - ROUTE[0][0], ROUTE[1][1] - ROUTE[0][1])
    heading = math.atan2(first_dir[0], first_dir[1])
    a_start = ar_at[0]
    rows.append(f"{int(pts[0][0])},start,{p0[0]},{p0[1]},{a_start[0]:.1f},{a_start[1]:.1f},,")
    rows.append(f"{int(pts[0][0]) + 5},heading,{p0[0]},{p0[1]},{a_start[0]:.1f},{a_start[1]:.1f},{heading:.4f},")
    for target in corner_idx[:-1]:
        idx = min(range(len(pts)), key=lambda i: abs(pts[i][3] - target))
        idx -= idx % 2
        a = ar_at[idx]
        px, py = pts[idx][1], pts[idx][2]
        mx = px + rnd.gauss(0, anchor_noise)
        my = py + rnd.gauss(0, anchor_noise)
        if wrong_scale:
            mx, my = px * 1.5, py * 1.5
        rows.append(f"{int(pts[idx][0])},reanchor,{mx:.1f},{my:.1f},{a[0]:.1f},{a[1]:.1f},,")
    last = len(pts) - 1 - ((len(pts) - 1) % 2)
    rows.append(f"{int(pts[last][0])},end,{pts[last][1]:.1f},{pts[last][2]:.1f},{ar_at[last][0]:.1f},{ar_at[last][1]:.1f},,")
    (d / "anchors.csv").write_text("\n".join(rows) + "\n")
    return d


class MagmapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="magmap_"))
        write_map(self.tmp / "map.json")

    def test_field_matches_truth_despite_arkit_drift(self):
        s = make_session(self.tmp, "s1", anchor_noise=3.0)
        rep, out = magmap.run(self.tmp / "map.json", [s], self.tmp / "magmap.json", do_disc=False)
        self.assertTrue((self.tmp / "magmap.json").exists())
        mf = out["magField"]
        self.assertEqual(len(mf["cells"]), mf["cols"] * mf["rows"])
        errs = []
        for k, n in enumerate(mf["counts"]):
            if n < magmap.MIN_SAMPLES:
                continue
            i, j = k % mf["cols"], k // mf["cols"]
            cx, cy = (i + 0.5) * mf["cellCm"], (j + 0.5) * mf["cellCm"]
            truth = field(cx, cy)
            errs.append(abs(mf["cells"][k][1] - truth[1]))            # Bz
        self.assertGreater(len(errs), 40)
        rms = math.sqrt(sum(e * e for e in errs) / len(errs))
        self.assertLess(rms, 1.8)
        self.assertEqual(rep["sessions"][0]["warnings"], [])
        self.assertFalse(any(g["bad"] for g in rep["sessions"][0]["segments"]))
        cov = {c["code"]: c["coverage"] for c in rep["corridors"]["worst"]}
        self.assertGreaterEqual(cov["V1"], 0.9)
        self.assertGreaterEqual(cov["V2"], 0.9)
        self.assertGreater(cov["Ht"], 0.4)          # 只走了横向通道的一半
        self.assertLess(cov["V0"], cov["V1"])     # 中间有 2 秒跟踪受限，被丢掉了

    def test_tracking_limited_samples_are_dropped(self):
        s = make_session(self.tmp, "s2")
        rep, _ = magmap.run(self.tmp / "map.json", [s], None, do_disc=False)
        self.assertIn("ARKit 跟踪受限", rep["sessions"][0]["dropped"])

    def test_wrong_anchors_are_rejected(self):
        s = make_session(self.tmp, "s3", wrong_scale=True)
        rep, _ = magmap.run(self.tmp / "map.json", [s], None, do_disc=False)
        self.assertTrue(any(g["bad"] for g in rep["sessions"][0]["segments"]))

    def test_envelope_and_plain_map_both_load(self):
        write_map(self.tmp / "plain.json", envelope=False)
        w1, h1, c1 = magmap.load_map(self.tmp / "map.json")
        w2, h2, c2 = magmap.load_map(self.tmp / "plain.json")
        self.assertEqual((w1, h1, len(c1)), (w2, h2, len(c2)))
        self.assertEqual(len(c1), 5)

    def test_truth_export(self):
        s = make_session(self.tmp, "s5")
        magmap.run(self.tmp / "map.json", [s], None, do_disc=False, truth_dir=self.tmp / "truth")
        lines = (self.tmp / "truth" / "s5.csv").read_text().splitlines()
        self.assertEqual(lines[0], "t_ms,x_cm,y_cm")
        self.assertGreater(len(lines), 100)
        t, x, y = (float(v) for v in lines[50].split(","))
        self.assertGreaterEqual(x, 400)
        self.assertLessEqual(x, 1300)

    def test_similar_pairs_are_ranked(self):
        s = make_session(self.tmp, "s4")
        rep, _ = magmap.run(self.tmp / "map.json", [s], None, do_disc=True)
        pairs = rep.get("similar_pairs", [])
        self.assertTrue(all(pairs[i]["score"] <= pairs[i + 1]["score"] for i in range(len(pairs) - 1)))


if __name__ == "__main__":
    unittest.main()
