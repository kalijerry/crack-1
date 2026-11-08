"""公开数据集转换脚本 ilc_convert.py 的单元测试：Wi-Fi 记录转成 wifi.csv（丢掉缓存的旧结果），其他文件照旧。"""
import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bench"))

import ilc_convert  # noqa: E402

T0 = 1_000_000


def fake_trace(path: Path, wifi: list[str]):
    """一条 20 s 的假 trace：IMU 50 Hz、两个 waypoint、一条蓝牙，再加上给定的 Wi-Fi 行"""
    rows = ["#\tstartTime:%d" % T0]
    for k in range(0, 20_000, 20):
        t = T0 + k
        rows.append(f"{t}\tTYPE_ACCELEROMETER\t0.1\t0.2\t9.8\t3")
        rows.append(f"{t}\tTYPE_GYROSCOPE\t0.0\t0.0\t0.01\t3")
        rows.append(f"{t}\tTYPE_MAGNETIC_FIELD\t10\t20\t-40\t3")
        rows.append(f"{t}\tTYPE_MAGNETIC_FIELD_UNCALIBRATED\t11\t21\t-41\t1\t1\t1\t3")
    rows.append(f"{T0}\tTYPE_WAYPOINT\t1.0\t2.0")
    rows.append(f"{T0 + 20_000}\tTYPE_WAYPOINT\t11.0\t2.0")
    rows.append(f"{T0 + 500}\tTYPE_BEACON\tuuid\t0\t0\t-56\t-70\t2.0\tAA:BB:CC:DD:EE:FF\t{T0 + 500}")
    rows += wifi
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


class WiFiParseTests(unittest.TestCase):
    def test_parse_wifi_drops_stale_and_lowercases(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.txt"
            fake_trace(p, [
                f"{T0 + 3000}\tTYPE_WIFI\tssid-a\tA8:0C:CA:03:9D:D7\t-49\t2422\t{T0 + 2900}",
                f"{T0 + 3000}\tTYPE_WIFI\tssid b\t74:ee:2a:cd:eb:43\t-71\t5785\t{T0 + 3000 - 30_000}",  # 30 s 前的缓存
                f"{T0 + 3000}\tTYPE_WIFI\t\t04:33:89:79:fc:7c\t-80\t2412\t{T0 + 3000 - ilc_convert.WIFI_MAX_AGE_MS}",
            ])
            d = ilc_convert.parse(str(p))
            self.assertEqual(d["wifi"], [(T0 + 3000, "04:33:89:79:fc:7c", -80.0, 2412),
                                         (T0 + 3000, "a8:0c:ca:03:9d:d7", -49.0, 2422)])


class ConvertTests(unittest.TestCase):
    def test_wifi_csv_written_for_build_and_test(self):
        with tempfile.TemporaryDirectory() as td:
            floor = Path(td) / "floor"
            (floor / "path_data_files").mkdir(parents=True)
            (floor / "floor_info.json").write_text(json.dumps({"map_info": {"width": 30, "height": 20}}))
            for i in range(3):
                fake_trace(floor / "path_data_files" / f"tr{i}.txt", [
                    f"{T0 + 4000}\tTYPE_WIFI\tn\t00:11:22:33:44:5{i}\t-60\t2437\t{T0 + 3990}",
                    f"{T0 + 4000}\tTYPE_WIFI\tn\t00:11:22:33:44:99\t-75\t5180\t{T0 + 3000}",
                    f"{T0 + 30_000}\tTYPE_WIFI\tn\t00:11:22:33:44:99\t-75\t5180\t{T0 + 30_000}",  # 轨迹结束之后
                ])
            out = Path(td) / "out"
            subprocess.run([sys.executable, "-I", "-X", "utf8", str(ROOT / "tools" / "bench" / "ilc_convert.py"),
                            str(floor), str(out), "--test-n", "1", "--test-min-s", "5", "--drift", "pdr"],
                           check=True, capture_output=True)
            man = json.loads((out / "manifest.json").read_text())
            self.assertEqual(len(man["test"]), 1)
            self.assertEqual(len(man["build"]), 2)
            for kind, ids in (("build", man["build"]), ("test", man["test"])):
                for k in ids:
                    with open(out / kind / k / "wifi.csv", newline="") as f:
                        rows = list(csv.reader(f))
                    self.assertEqual(rows[0], ["t_ms", "bssid", "rssi", "freq"])
                    self.assertEqual(rows[1:], [[str(T0 + 4000), "00:11:22:33:44:5" + k[-1], "-60", "2437"],
                                                [str(T0 + 4000), "00:11:22:33:44:99", "-75", "5180"]])
                    # 其他文件照旧
                    self.assertTrue((out / kind / k / "ble.csv").exists())
            self.assertTrue((out / "test" / man["test"][0] / "truth.csv").exists())


if __name__ == "__main__":
    unittest.main()
