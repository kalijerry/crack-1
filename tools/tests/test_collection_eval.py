"""collection_eval.py 的单元测试：偏置、回访一致性、刚体对齐误差、整个会话目录评估。"""
import json
import math
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import collection_eval as ce  # noqa: E402


def field(x, y):
    """位置 → 设备系磁场（µT）：随位置变的 30 µT 左右"""
    return (20 + 8 * math.sin(x / 150), -10 + 6 * math.cos(y / 120), -15 + 4 * math.sin((x + y) / 200))


def write_survey(d, ios_drift):
    """绕 4 m × 3 m 的矩形走三圈；iOS 校准偏置按 ios_drift（µT）随时间漂，原始 = 场 + 固定偏置"""
    os.makedirs(d)
    bias = (40.0, 110.0, -630.0)
    t0 = 1_700_000_000_000
    per = 2 * (400 + 300)
    pts = []
    for k in range(0, 3 * per, 2):           # 1 m/s，每 2 cm 一个点 = 50 Hz
        s = k % per
        if s < 400:
            x, y = s, 0
        elif s < 700:
            x, y = 400, s - 400
        elif s < 1100:
            x, y = 400 - (s - 700), 300
        else:
            x, y = 0, 300 - (s - 1100)
        pts.append((t0 + k * 10, x, y))
    with open(os.path.join(d, "arkit_pose.csv"), "w") as f:
        f.write("t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n")
        for t, x, y in pts:
            f.write(f"{t},{x / 100:.4f},0,{y / 100:.4f},0,0,0,1,2,0\n")
    with open(os.path.join(d, "mag_raw.csv"), "w") as fr, open(os.path.join(d, "imu.csv"), "w") as fi:
        fr.write("t_ms,mx,my,mz\n")
        fi.write("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz\n")
        for i, (t, x, y) in enumerate(pts):
            b = field(x, y)
            raw = tuple(b[k] + bias[k] for k in range(3))
            drift = ios_drift * math.sin(i / 400)
            cal = (b[0] + drift, b[1] - drift, b[2])
            fr.write(f"{t},{raw[0]:.3f},{raw[1]:.3f},{raw[2]:.3f}\n")
            fi.write(f"{t},0,0,9.8,0,0,0,{cal[0]:.3f},{cal[1]:.3f},{cal[2]:.3f},2,1,0,0,0,0,0,0,9.8\n")
    json.dump({"survey": True, "map_id": "m1", "start_ms": pts[0][0], "end_ms": pts[-1][0]},
              open(os.path.join(d, "meta.json"), "w"))
    return pts


class HelpersTest(unittest.TestCase):
    def test_rigid_fit_recovers_rotation(self):
        a = [(i * 10.0, (i % 7) * 13.0) for i in range(50)]
        th = 0.7
        b = [(math.cos(th) * x - math.sin(th) * y + 500, math.sin(th) * x + math.cos(th) * y - 200) for x, y in a]
        res = ce.rigid_fit_residuals(a, b)
        self.assertLess(max(res), 1e-6)

    def test_rigid_fit_mirror(self):
        a = [(i * 10.0, (i % 5) * 20.0) for i in range(40)]
        b = [(x, -y) for x, y in a]
        self.assertLess(max(ce.rigid_fit_residuals(a, b)), 1e-6)

    def test_rigid_fit_reports_noise(self):
        random.seed(1)
        a = [(i * 10.0, (i % 9) * 30.0) for i in range(200)]
        b = [(x + random.gauss(0, 100), y + random.gauss(0, 100)) for x, y in a]
        rms = math.sqrt(sum(r * r for r in ce.rigid_fit_residuals(a, b)) / 200)
        self.assertGreater(rms, 80)
        self.assertLess(rms, 160)

    def test_revisit_needs_gap_and_radius(self):
        s = [(0, 0, 0, 30.0), (5_000, 5, 0, 50.0), (20_000, 10, 10, 33.0), (40_000, 500, 0, 99.0)]
        d = ce.revisit_diffs(s)
        # (0,2) 和 (1,2) 隔够 15 s 且在 30 cm 内；(0,1) 隔太近；第 4 个太远
        self.assertEqual(sorted(d), [3.0, 17.0])

    def test_fixed_bias_is_median(self):
        raw = [(t, (100.0 + t % 3, 0.0, 0.0)) for t in range(0, 1000, 10)]
        imu = [(t, (30.0, 0.0, 0.0), (0, 0, 9.8)) for t in range(0, 1000, 10)]
        b = ce.fixed_bias(ce.pair_raw_calibrated(raw, imu))
        self.assertAlmostEqual(b[0], 71.0, delta=1.0)


class SessionTest(unittest.TestCase):
    def test_survey_raw_consistent_ios_drifting(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "ios_survey_1")
            write_survey(d, ios_drift=25.0)
            sv, lv = ce.evaluate_dirs([d])
            self.assertEqual(len(sv), 1)
            x = sv[0]
            self.assertEqual(x["name"], "ios_survey_1")
            self.assertGreater(x["revisit_pairs"], 100)
            self.assertLess(x["revisit_raw_ut"], 1.0)        # 原始减固定偏置：同一个地方读数一样
            self.assertGreater(x["revisit_ios_ut"], 5.0)     # iOS 校准在漂
            self.assertGreater(x["ios_bias_wander_ut"], 20)
            self.assertEqual(x["raw_out_of_range"], 0.0)
            md = ce.markdown(ce.summarize(sv, lv, {"m1": {"coverage": 0.5, "walkableM2": 100, "sessions": [{}]}}))
            self.assertIn("覆盖 50%", md)

    def test_live_error_against_arkit(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "mag_live")
            pts = write_survey(d, ios_drift=0.0)
            os.remove(os.path.join(d, "meta.json"))
            json.dump({"live": True, "map_id": "m1", "mag_calibration": "ios"}, open(os.path.join(d, "meta.json"), "w"))
            random.seed(2)
            th = 1.1
            with open(os.path.join(d, "track.csv"), "w") as f:
                f.write("t_ms,x_cm,y_cm,unc_cm\n")
                for t, x, y in pts[::25]:
                    mx = math.cos(th) * x - math.sin(th) * y + 900 + random.gauss(0, 30)
                    my = math.sin(th) * x + math.cos(th) * y + 300 + random.gauss(0, 30)
                    f.write(f"{t},{mx:.1f},{my:.1f},80\n")
            sv, lv = ce.evaluate_dirs([d])
            self.assertEqual(len(lv), 1)
            x = lv[0]
            self.assertAlmostEqual(x["err_rms_m"], 0.42, delta=0.15)
            self.assertEqual(x["jumps_3m"], 0)
            self.assertEqual(x["unc_reported_m"], 0.8)


    def test_review_absolute_error(self):
        """视觉复核：review.csv 里真值和估计直接相减（不对齐）；前 4 s 偏 5 m，之后偏 0.5 m"""
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "mag_review")
            os.makedirs(d)
            json.dump({"live": True, "map_id": "m1", "purpose": "review", "review_start": "auto"},
                      open(os.path.join(d, "meta.json"), "w"))
            t0 = 1_700_000_000_000
            with open(os.path.join(d, "review.csv"), "w") as f, open(os.path.join(d, "track.csv"), "w") as ft:
                f.write("t_ms,truth_x_cm,truth_y_cm,est_x_cm,est_y_cm,err_cm,unc_cm,converged,steps\n")
                ft.write("t_ms,x_cm,y_cm,unc_cm\n")
                f.write(f"{t0 - 200},0,0,,,,,0,0\n")          # 还没有估计
                for i in range(100):                          # 20 s，5 Hz，沿 x 走 1 m/s
                    t = t0 + i * 200
                    x = i * 20.0
                    off = 500.0 if i < 20 else 50.0
                    f.write(f"{t},{x:.1f},0,{x:.1f},{off:.1f},{off:.1f},100,{0 if i < 20 else 1},{i}\n")
                    ft.write(f"{t},{x:.1f},{off:.1f},100\n")
            sv, lv = ce.evaluate_dirs([d])
            x = lv[0]
            self.assertTrue(x["review"])
            self.assertEqual(x["review_samples"], 100)
            self.assertEqual(x["review_truth_samples"], 101)
            self.assertEqual(x["review_err_median_m"], 0.5)
            self.assertEqual(x["review_err_max_m"], 5.0)
            self.assertEqual(x["review_within_1m"], 0.8)
            self.assertEqual(x["review_err_converged_median_m"], 0.5)
            self.assertAlmostEqual(x["review_settle_s"], 4.2, delta=0.01)   # 第一行（无估计）起算
            self.assertEqual(x["review_unc_over_err"], 2.0)
            self.assertAlmostEqual(x["review_walk_m"], 19.8, delta=0.01)
            md = ce.markdown(ce.summarize(sv, lv, {}))
            self.assertIn("视觉复核 1 次", md)
            self.assertIn("| mag_review | auto |", md)


if __name__ == "__main__":
    unittest.main()
