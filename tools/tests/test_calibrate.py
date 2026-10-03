"""calibrate.py 的单元测试：合成两台设备的数据，检查能否还原已知偏移。"""
import csv
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import calibrate  # noqa: E402


def make_session(root: Path, name: str, platform: str, label: str, delta: float, rate: float, seed: int = 1):
    """生成一个会话目录。delta 是相对基准的 RSSI 偏移，rate 是每秒读数密度。"""
    rnd = random.Random(seed)
    d = root / name
    d.mkdir(parents=True)
    t0 = 1_700_000_000_000
    (d / "meta.json").write_text(json.dumps({
        "platform": platform, "device_label": label, "model": label, "start_ms": t0,
    }), encoding="utf-8")

    tags = [f"{i:02X}-00-00-{(i * 3) % 256:02X}" for i in range(30)]
    marks, ble = [], []
    for p in range(6):
        start = t0 + p * 70_000
        end = start + 60_000
        marks.append((str(p + 1), "", "", start, end, ""))
        for tag in [t for t in tags if hash((t, p)) % 3 == 0]:
            base = -50 - (hash((tag, p, "d")) % 40)
            for _ in range(int(rate * 60)):
                ble.append((rnd.randint(start, end), str(p + 1), tag,
                            int(round(base + delta + rnd.gauss(0, 3)))))
    ble.sort()

    with (d / "marks.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["point_id", "x_cm", "y_cm", "t_start_ms", "t_end_ms", "note"])
        w.writerows(marks)
    with (d / "ble.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_ms", "point_id", "esl_id", "rssi", "src", "mfg_hex"])
        for t, pid, tag, rssi in ble:
            w.writerow([t, pid, tag, rssi, "src", "0D00AABBCCDD"])
    with (d / "imu.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_ms", "ax", "ay", "az", "gx", "gy", "gz",
                    "mx", "my", "mz", "mag_acc", "qw", "qx", "qy", "qz", "heading_deg"])
        for i in range(400):
            w.writerow([t0 + i * 20, 0.1, 0.2, 9.8, 0, 0, 0, 20, 0, -40, 3, 1, 0, 0, 0, 10])
    return d


class TestHelpers(unittest.TestCase):
    def test_rssi_bin(self):
        self.assertEqual(calibrate.rssi_bin(-50), calibrate.rssi_bin(-49))
        self.assertNotEqual(calibrate.rssi_bin(-50), calibrate.rssi_bin(-56))

    def test_linear_fit_recovers_line(self):
        xs = [float(i) for i in range(-90, -40)]
        ys = [2.0 * x + 5.0 for x in xs]
        a, b = calibrate.linear_fit(xs, ys)
        self.assertAlmostEqual(a, 2.0, places=6)
        self.assertAlmostEqual(b, 5.0, places=4)

    def test_linear_fit_degenerate(self):
        a, b = calibrate.linear_fit([3.0, 3.0], [1.0, 5.0])
        self.assertEqual(a, 1.0)
        self.assertTrue(b == b)  # 不是 NaN

    def test_csv_escaping(self):
        self.assertEqual(calibrate.read_csv(Path("/nonexistent/x.csv")), [])


class TestCalibration(unittest.TestCase):
    def test_recovers_known_offset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ref = make_session(root, "android_ref", "android", "ref", 0.0, 4, seed=1)
            tgt = make_session(root, "ios_tgt", "ios", "tgt", -7.0, 2.5, seed=1)
            out = root / "out"
            r = subprocess.run(
                [sys.executable, str(TOOLS / "calibrate.py"), str(ref), str(tgt), "--out", str(out)],
                capture_output=True, text=True, encoding="utf-8",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"})
            self.assertEqual(r.returncode, 0, r.stderr)
            result = json.loads((out / "calibration.json").read_text(encoding="utf-8"))
            # 目标机读数低 7 dB，所以推荐偏移应接近 +7
            self.assertAlmostEqual(result["offset_model"]["b"], 7.0, delta=1.0)
            self.assertEqual(result["recommended"]["model"], "offset")
            # 校正后分档一致率应明显优于不校正
            self.assertGreater(result["bin_agreement"]["offset"], result["bin_agreement"]["raw"] + 0.2)
            self.assertTrue((out / "pairs.csv").exists())

    def test_single_session_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            s = make_session(root, "only", "ios", "only", 0.0, 3)
            r = subprocess.run([sys.executable, str(TOOLS / "calibrate.py"), str(s)],
                               capture_output=True, text=True, encoding="utf-8",
                               env={**os.environ, "PYTHONIOENCODING": "utf-8"})
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("IMU", r.stdout)

    def test_no_common_points_errors_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a = make_session(root, "a", "android", "a", 0.0, 3)
            b = make_session(root, "b", "ios", "b", 0.0, 3)
            # 把 b 的点位编号改掉，使两边没有共同编号
            marks = (b / "marks.csv").read_text(encoding="utf-8").splitlines()
            rewritten = [marks[0]] + ["X" + line for line in marks[1:]]
            (b / "marks.csv").write_text("\n".join(rewritten) + "\n", encoding="utf-8")
            r = subprocess.run([sys.executable, str(TOOLS / "calibrate.py"), str(a), str(b)],
                               capture_output=True, text=True, encoding="utf-8",
                               env={**os.environ, "PYTHONIOENCODING": "utf-8"})
            self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
