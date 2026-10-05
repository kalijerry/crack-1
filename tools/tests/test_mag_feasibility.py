"""mag_feasibility.py 的单元测试：用合成磁场房间检查 SNR、可区分度、跳变检测与手机倾斜不变性。"""
import json
import math
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import mag_feasibility as mf  # noqa: E402

T0 = 1_700_000_000_000
IMU_HZ = 50
SPEED = 1.2            # m/s
ROOM = 10.0


def make_field(seed, amp=8.0):
    """世界系磁场 B(x, y)：地球背景 + 若干正弦分量，空间变化尺度 2～6 m。"""
    rnd = random.Random(seed)
    comps = [[(rnd.uniform(0.3, 1.0), rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(0, 6.28))
              for _ in range(6)] for _ in range(3)]
    base = (20.0, 5.0, -43.0)

    def field(x, y):
        return tuple(base[c] + amp * sum(a * math.sin(kx * x + ky * y + ph) for a, kx, ky, ph in comps[c])
                     for c in range(3))
    return field


def rotation(rnd):
    """随机朝向（任意航向 + 最多 40° 倾斜）的旋转矩阵。"""
    def rx(a): return [[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]]
    def ry(a): return [[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]]
    def rz(a): return [[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]]
    def mul(a, b): return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    t = math.radians(40)
    return mul(rz(rnd.uniform(0, 6.28)), mul(rx(rnd.uniform(-t, t)), ry(rnd.uniform(-t, t))))


def apply(r, v):
    return tuple(sum(r[i][k] * v[k] for k in range(3)) for i in range(3))


def snake_route(reverse=False, lanes=(1, 3, 5, 7, 9)):
    pts = []
    for n, y in enumerate(lanes):
        xs = list(range(1, 10)) if n % 2 == 0 else list(range(9, 0, -1))
        pts += [(x, y) for x in xs]
    return pts[::-1] if reverse else pts


def make_session(root, name, field, route, seed, noise=0.3, bias_step=None, tilt_seed=None):
    rnd = random.Random(seed)
    r = rotation(random.Random(tilt_seed if tilt_seed is not None else seed))
    d = root / name
    d.mkdir(parents=True)
    (d / "meta.json").write_text(json.dumps({"platform": "ios", "device_label": name, "start_ms": T0}))
    imu = ["t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg"]
    raw = ["t_ms,mx,my,mz"]
    marks = ["point_id,x_cm,y_cm,t_start_ms,t_end_ms,note"]
    up = apply(r, (0, 0, 9.81))
    seg_t = 1.0 / SPEED
    t_wp = [T0 + i * seg_t * 1000 for i in range(len(route))]
    for i, (x, y) in enumerate(route):
        marks.append(f"{i},{x * 100},{y * 100},{int(t_wp[i]) - 100},{int(t_wp[i]) + 100},")
    n_samples = int((t_wp[-1] - t_wp[0]) / 1000 * IMU_HZ)
    for k in range(n_samples + 1):
        t = t_wp[0] + k * 1000 / IMU_HZ
        i = min(int((t - t_wp[0]) / (seg_t * 1000)), len(route) - 2)
        f = (t - t_wp[i]) / (seg_t * 1000)
        x = route[i][0] + f * (route[i + 1][0] - route[i][0])
        y = route[i][1] + f * (route[i + 1][1] - route[i][1])
        b = apply(r, field(x, y))
        bias = (0.0, 0.0, 0.0)
        if bias_step and t - T0 > bias_step[0] * 1000:
            bias = (bias_step[1], 0.0, 0.0)
        cal = tuple(b[j] + rnd.gauss(0, noise) for j in range(3))
        imu.append(f"{int(t)},{up[0]:.4f},{up[1]:.4f},{up[2]:.4f},0,0,0,{cal[0]:.3f},{cal[1]:.3f},{cal[2]:.3f},2,1,0,0,0,-1")
        raw.append(f"{int(t)},{cal[0] + 5 + bias[0]:.3f},{cal[1] - 3 + bias[1]:.3f},{cal[2] + 2 + bias[2]:.3f}")
    (d / "imu.csv").write_text("\n".join(imu) + "\n")
    (d / "mag_raw.csv").write_text("\n".join(raw) + "\n")
    (d / "marks.csv").write_text("\n".join(marks) + "\n")
    return d


class MagFeasibilityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="magtest_"))

    def test_features_ignore_phone_orientation(self):
        field = make_field(1)
        a = make_session(self.tmp, "a", field, snake_route(), 1, noise=0.0, tilt_seed=11)
        b = make_session(self.tmp, "b", field, snake_route(), 2, noise=0.0, tilt_seed=22)
        ta, tb = mf.build_track(a, 0.5), mf.build_track(b, 0.5)
        n = min(len(ta.feat), len(tb.feat))
        self.assertGreater(n, 60)
        for fa, fb in zip(ta.feat[:n], tb.feat[:n]):
            for j in range(3):
                self.assertAlmostEqual(fa[j], fb[j], delta=0.6)   # 低通与插值带来的小误差

    def test_structured_field_passes(self):
        field = make_field(3)
        m = make_session(self.tmp, "map", field, snake_route(), 1, tilt_seed=5)
        q = make_session(self.tmp, "query", field, snake_route(reverse=True), 2, tilt_seed=6)
        rep = mf.run([m], [q], 0.5, self.tmp / "out")
        self.assertTrue((self.tmp / "out" / "mag_feasibility.json").exists())
        for k in ("|B|", "Bz"):
            self.assertGreater(rep["repeatability"][k]["snr"], 3.0, k)
        r10 = next(r for r in rep["identifiability"] if r["window_m"] == 10)
        self.assertGreater(r10["top1_rate"], 0.85)
        self.assertTrue(rep["verdict"]["go"], rep["verdict"])

    def test_flat_field_fails(self):
        """没有空间结构的磁场（只有噪声）必须判 NO-GO，不能被误判为可行。"""
        flat = make_field(4, amp=0.0)
        m = make_session(self.tmp, "map", flat, snake_route(), 1, noise=0.5)
        q = make_session(self.tmp, "query", flat, snake_route(), 2, noise=0.5)
        rep = mf.run([m], [q], 0.5)
        self.assertFalse(rep["verdict"]["go"])

    def test_calibration_jump_detected(self):
        field = make_field(5)
        d = make_session(self.tmp, "j", field, snake_route(), 1, bias_step=(20, 6.0))
        res = mf.calibration_jumps(d)
        self.assertEqual(len(res["jumps"]), 1)
        self.assertAlmostEqual(res["jumps"][0]["delta_uT"], 6.0, delta=0.5)

    def test_no_marks_reports_error(self):
        d = make_session(self.tmp, "x", make_field(6), snake_route(), 1)
        (d / "marks.csv").write_text("point_id,x_cm,y_cm,t_start_ms,t_end_ms,note\n")
        rep = mf.run([d], [d], 0.5)
        self.assertIn("error", rep)


if __name__ == "__main__":
    unittest.main()
