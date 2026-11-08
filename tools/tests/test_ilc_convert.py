"""ilc_convert.py 的可走区域：楼层平面图（geojson）栅格化、膨胀、合并成矩形，以及路径膨胀的老办法。"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "bench"))

import ilc_convert as conv  # noqa: E402


def square(x0, y0, x1, y1):
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]


# 外轮廓：经纬度式的坐标（外包框 [100, 110] × [50, 55]），映射到 20 m × 10 m；中间一个单元（店铺）
GEO = {
    "type": "FeatureCollection",
    "features": [
        {"type": "Feature", "properties": {"type": "floor", "name": "F1"},
         "geometry": {"type": "MultiPolygon", "coordinates": [[square(100, 50, 110, 55)]]}},
        # 单元：外包框里 x 4～6、y 1～4 → 地图 x 8～12 m、y 2～8 m
        {"type": "Feature", "properties": {"name": "shop"},
         "geometry": {"type": "Polygon", "coordinates": [square(104, 51, 106, 54)]}},
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
        self.assertTrue(walk(occ, 50, 300, 500))                  # 店铺左边的走廊
        self.assertTrue(walk(occ, 50, 1000, 100))                 # 店铺下方（y 小）的走廊：y 不翻转
        self.assertFalse(walk(occ, 50, 1000, 500))                # 店铺里
        self.assertFalse(walk(occ, 50, 825, 225))
        area = sum(map(sum, occ)) * 0.25
        self.assertAlmostEqual(area, 200 - 4 * 6, delta=1)        # 20×10 m 减去 4×6 m 的店铺

    def test_dilation_reaches_into_units_by_the_given_distance(self):
        occ, _ = conv.geojson_walkable(GEO, W, H, cell=50, dilate_cm=75)
        self.assertTrue(walk(occ, 50, 825, 500))                  # 店铺边往里 0.25 m：放宽后能走
        self.assertFalse(walk(occ, 50, 1000, 500))                # 店铺中央仍然不能走

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
        self.assertAlmostEqual(conv.inside_share(occ, 50, [(300, 500), (1000, 500), (-10, 5), (5000, 5)]), 0.25)

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


if __name__ == "__main__":
    unittest.main()
