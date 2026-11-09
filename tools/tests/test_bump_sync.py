"""bump_sync.py 的单元测试：两台「手机」各自的时钟（B 比 A 快 137 ms、漂移 +40 ppm、采样相位不同），开头和结尾各敲三下，
中间是走路的起伏（低于峰门限）。求出的偏移、漂移要对；敲击对不上（残差 > 20 ms）的那组不用。"""
import math
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "lab"))

import bump_sync as bs  # noqa: E402

G = bs.G
START_TAPS = [5000.0, 5500.0, 6000.0]
END_TAPS = [595000.0, 595500.0, 596000.0]


def device(off_ms, drift_ppm, taps, phase_ms=0.0, hz=50.0, dur_ms=600000.0, seed=1, amp_g=5.0):
    """真实时间 s 上采样；设备时钟 = s + off + drift·s。返回 (设备时间戳, |a|)"""
    rng = random.Random(seed)
    dt = 1000.0 / hz
    ts, a = [], []
    k = 0
    while True:
        s = phase_ms + k * dt
        if s > dur_ms:
            break
        v = G + 0.9 * G * 0.3 * math.sin(2 * math.pi * 1.8 * s / 1000) + rng.gauss(0, 0.1)
        for tp in taps:
            v += amp_g * G * math.exp(-0.5 * ((s - tp) / 15.0) ** 2)
        ts.append(s + off_ms + drift_ppm * 1e-6 * s)
        a.append(v)
        k += 1
    return ts, a


class SyncTests(unittest.TestCase):
    def test_offset_and_drift(self):
        ta, aa = device(0, 0, START_TAPS + END_TAPS, phase_ms=0, seed=1)
        tb, ab = device(137, 40, START_TAPS + END_TAPS, phase_ms=7, seed=2)
        r = bs.sync(ta, aa, tb, ab)
        self.assertTrue(r["ok"], r)
        # 开始组：偏移 = 137 + 40e-6·5500 ≈ 137.2 ms
        self.assertAlmostEqual(r["offset_ms"], 137 + 40e-6 * 5500, delta=4)
        self.assertAlmostEqual(r["drift_ppm"], 40, delta=10)
        self.assertLess(r["start"]["residual_ms"], 5)
        self.assertLess(r["end"]["residual_ms"], 5)
        # B 的时间戳换回 A 的时钟：结尾那一下对得上
        tb_end = END_TAPS[1] + 137 + 40e-6 * END_TAPS[1]
        self.assertAlmostEqual(bs.to_a_clock(r, tb_end), END_TAPS[1], delta=5)

    def test_inconsistent_taps_are_rejected(self):
        ta, aa = device(0, 0, START_TAPS + END_TAPS, seed=1)
        # B 结尾那组的间隔不一样（0.5 s / 0.65 s）：同一次敲击对不上，残差远超 20 ms，这一组不用，也就没有漂移
        bad_end = [595000.0, 595500.0, 596150.0]
        tb, ab = device(137, 0, START_TAPS + bad_end, phase_ms=7, seed=2)
        r = bs.sync(ta, aa, tb, ab)
        self.assertTrue(r["ok"])
        self.assertFalse(r["end"]["ok"])
        self.assertGreater(r["end"]["residual_ms"], 20)
        self.assertIsNone(r["drift_ppm"])
        self.assertAlmostEqual(r["offset_ms"], 137, delta=4)

    def test_no_taps_is_not_ok(self):
        ta, aa = device(0, 0, [], seed=1)
        tb, ab = device(137, 0, [], seed=2)
        r = bs.sync(ta, aa, tb, ab)
        self.assertFalse(r["ok"])
        self.assertIsNone(r["offset_ms"])

    def test_two_taps_are_not_a_group(self):
        p = bs.SyncParams()
        self.assertEqual(bs.tap_groups([1000, 1500], p), [])
        self.assertEqual(bs.tap_groups([1000, 1500, 2000, 9000], p), [[1000, 1500, 2000]])
        self.assertEqual(bs.tap_groups([1000, 1500, 2000, 2500], p), [])      # 四下不是三下

    def test_files_and_window(self):
        with tempfile.TemporaryDirectory() as td:
            paths = []
            for name, (off, ph, seed) in {"a": (0, 0, 1), "b": (137, 7, 2)}.items():
                ts, a = device(off, 0, START_TAPS + END_TAPS, phase_ms=ph, seed=seed)
                p = Path(td) / f"{name}.csv"
                with open(p, "w", encoding="utf-8") as f:
                    f.write("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz\n")
                    for t, v in zip(ts, a):
                        f.write(f"{t:.0f},0,0,{v:.4f},0,0,0,0,0,0\n")
                paths.append(p)
            r = bs.sync_files(*paths)
            self.assertTrue(r["ok"])
            self.assertAlmostEqual(r["offset_ms"], 137, delta=4)
            w0, w1 = r["window_a_ms"]
            self.assertAlmostEqual(w0, START_TAPS[-1], delta=25)
            self.assertAlmostEqual(w1, END_TAPS[0], delta=25)
            out = Path(td) / "r.json"
            self.assertEqual(bs.main([str(paths[0]), str(paths[1]), "--json", str(out)]), 0)
            self.assertTrue(out.exists())


if __name__ == "__main__":
    unittest.main()
