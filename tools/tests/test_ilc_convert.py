"""ilc_convert.py 的单元测试：可走区域（楼层平面图 geojson 栅格化、膨胀、合并成矩形，以及路径膨胀的老办法）；
Wi-Fi 记录转成 wifi.csv（丢掉缓存的旧结果），其他文件照旧。"""
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
import ilc_convert as conv  # noqa: E402


def square(x0, y0, x1, y1):
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]


# 外轮廓：经纬度式的坐标（外包框 [100, 110] × [50, 55]），映射到 20 m × 10 m；一个偏在左下角的单元（店铺），
# 这样 x 或 y 翻转了都会把它挪到别处（单元放在正中间时翻不翻转结果一样，测不出方向）
GEO = {
    "type": "FeatureCollection",
    "features": [
        {"type": "Feature", "properties": {"type": "floor", "name": "F1"},
         "geometry": {"type": "MultiPolygon", "coordinates": [[square(100, 50, 110, 55)]]}},
        # 单元：外包框里 x 1～3、y 1～2 → 地图 x 2～6 m、y 2～4 m（y 翻转会落到 y 6～8 m，x 翻转会落到 x 14～18 m）
        {"type": "Feature", "properties": {"name": "shop"},
         "geometry": {"type": "Polygon", "coordinates": [square(101, 51, 103, 52)]}},
    ],
}
W, H = 2000, 1000


def walk(occ, cell, x, y):
    return bool(occ[int(y // cell)][int(x // cell)])


class GeojsonWalkableTests(unittest.TestCase):
    def test_outline_minus_units_mapped_from_bbox_without_flip(self):
        occ, outline = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=0)
        self.assertEqual((len(occ), len(occ[0])), (20, 40))
        self.assertTrue(all(all(r) for r in outline))           # 外轮廓 = 整个外包框
        self.assertFalse(walk(occ, 50, 400, 300))                 # 店铺里（地图 x 2～6 m、y 2～4 m）
        self.assertFalse(walk(occ, 50, 225, 225))
        self.assertTrue(walk(occ, 50, 1000, 500))                 # 中间的走廊
        # 方向：y 翻转时店铺在 y 6～8 m、x 翻转时在 x 14～18 m，这两处都必须能走
        self.assertTrue(walk(occ, 50, 400, 700))
        self.assertTrue(walk(occ, 50, 1600, 300))
        area = sum(map(sum, occ)) * 0.25
        self.assertAlmostEqual(area, 200 - 4 * 2, delta=1)        # 20×10 m 减去 4×2 m 的店铺

    def test_flipped_mapping_would_be_caught(self):
        """对照：把单元的 y（或 x）在外包框里镜像后再栅格化，上面「必须能走」的点就落进店铺了"""
        def mirrored(fx, fy):
            g = json.loads(json.dumps(GEO))
            ring = g["features"][1]["geometry"]["coordinates"][0]
            g["features"][1]["geometry"]["coordinates"][0] = [[210 - x if fx else x, 105 - y if fy else y] for x, y in ring]
            return conv.geojson_walkable(g, W, H, cell=50, dilate_cm=0)[0]
        self.assertFalse(walk(mirrored(False, True), 50, 400, 700))
        self.assertFalse(walk(mirrored(True, False), 50, 1600, 300))

    def test_dilation_reaches_into_units_by_the_given_distance(self):
        before, _ = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=0)
        occ, _ = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=75)
        self.assertFalse(walk(before, 50, 225, 300))
        self.assertTrue(walk(occ, 50, 225, 300))                  # 店铺边往里 0.25 m：放宽后能走
        self.assertFalse(walk(occ, 50, 400, 300))                 # 店铺中央仍然不能走

    def test_merged_rectangles_cover_exactly_the_walkable_cells(self):
        occ, _ = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=75)
        rects = conv.merge_rects(occ, 50)
        cover = [[0] * len(occ[0]) for _ in occ]
        for r in rects:
            x0, y0, x1, y1 = r[0], r[1], r[4], r[5]
            for j in range(int(y0 // 50), int(y1 // 50)):
                for i in range(int(x0 // 50), int(x1 // 50)):
                    cover[j][i] += 1
        for j, row in enumerate(occ):
            for i, v in enumerate(row):
                self.assertEqual(cover[j][i], 1 if v else 0, (i, j))

    def test_inside_share(self):
        occ, _ = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=0)
        self.assertAlmostEqual(conv.inside_share(occ, 50, [(300, 500), (400, 300), (-10, 5), (5000, 5)]), 0.25)

    def test_missing_floor_outline_is_an_error(self):
        with self.assertRaises(ValueError):
            conv.geojson_walkable({"features": GEO["features"][1:]}, W, H)

    def test_path_walkable_unchanged(self):
        polys = conv.floor_polygons([(150, 150)], 1000, 1000, dilate=1)
        cells = sum((p[4] - p[0]) * (p[5] - p[1]) for p in polys) / 1e4
        self.assertEqual(cells, 9)                                 # 1 m 格、半径 1 格：3×3（含对角）


class ConvertCliTests(unittest.TestCase):
    """整条转换：默认用 geojson（有平面图时），--walkable paths 退回路径膨胀；manifest 里写核对比例。"""

    def _floor(self, d: Path):
        (d / "path_data_files").mkdir(parents=True)
        (d / "floor_info.json").write_text(json.dumps({"map_info": {"width": 20, "height": 10}}))
        (d / "geojson_map.json").write_text(json.dumps(GEO))
        # 两条 trace：沿 y = 1 m 的走廊从 x = 1 走到 19 m（都在可走区域）
        for n, t0 in (("a", 0), ("b", 100000)):
            lines = []
            for k in range(200):
                t = t0 + k * 100
                lines.append(f"{t}\tTYPE_ACCELEROMETER\t0\t0\t9.8")
                lines.append(f"{t}\tTYPE_GYROSCOPE\t0\t0\t0")
                lines.append(f"{t}\tTYPE_MAGNETIC_FIELD\t10\t20\t30")
                lines.append(f"{t}\tTYPE_MAGNETIC_FIELD_UNCALIBRATED\t10\t20\t30\t0\t0\t0")
            for k in range(10):
                lines.append(f"{t0 + k * 2000}\tTYPE_WAYPOINT\t{1 + k * 2}\t1")
            (d / "path_data_files" / f"{n}.txt").write_text("\n".join(lines) + "\n")

    def _run(self, *extra):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            self._floor(td / "F1")
            subprocess.run([sys.executable, "-I", str(ROOT / "tools" / "bench" / "ilc_convert.py"), str(td / "F1"),
                            str(td / "out"), "--test-n", "1", "--test-min-s", "10", *extra],
                           check=True, capture_output=True)
            return (json.loads((td / "out" / "map.json").read_text()),
                    json.loads((td / "out" / "manifest.json").read_text()))

    def test_default_uses_floor_plan(self):
        m, man = self._run()
        self.assertEqual(man["walkable"]["source"], "geojson")
        self.assertEqual(man["walkable"]["waypoints_in_walkable"], 1.0)
        self.assertEqual(man["walkable"]["test_truth_in_walkable"], 1.0)
        area = sum((p[4] - p[0]) * (p[5] - p[1]) for p in m["floorPolygons"]) / 1e4
        self.assertGreater(area, 170)                               # 走廊 176 m² + 放宽，远多于路径膨胀

    def test_paths_option(self):
        m, man = self._run("--walkable", "paths")
        self.assertEqual(man["walkable"], {"source": "paths"})
        area = sum((p[4] - p[0]) * (p[5] - p[1]) for p in m["floorPolygons"]) / 1e4
        self.assertLess(area, 120)


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
