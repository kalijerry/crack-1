"""imdf_convert.py 的单元测试：合成一个两层、40 m × 20 m 的小场馆（每层一条走廊 + 一家店 + 一部电梯 + 一根柱子），
检查投影尺度、可走面积、开口、地标名称和跨楼层电梯分组。"""
import json
import math
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "venue"))

import imdf_convert  # noqa: E402

LON0, LAT0 = 120.0, 30.0
M_LAT = math.pi * 6378137.0 / 180


def m_lon(lat):
    return M_LAT * math.cos(math.radians(lat))


def ll(x_m, y_m):
    """平面（m，+x 东、+y 南，原点西北角）→ 经纬度。"""
    lat_ref = LAT0 - 10 / M_LAT          # 场馆中线纬度（20 m 高）
    return [LON0 + x_m / m_lon(lat_ref), LAT0 - y_m / M_LAT]


def rect(x0, y0, x1, y1):
    return {"type": "Polygon", "coordinates": [[ll(x0, y0), ll(x1, y0), ll(x1, y1), ll(x0, y1), ll(x0, y0)]]}


def fc(features):
    return {"type": "FeatureCollection", "features": features}


def make_imdf(d: Path):
    levels, units, openings = [], [], []
    for lid, ordinal, name in [("L0", 0, "1F"), ("L1", 1, "2F")]:
        levels.append({"id": lid, "type": "Feature", "feature_type": "level", "geometry": rect(0, 0, 40, 20),
                       "properties": {"ordinal": ordinal, "name": {"en": name}, "category": "unspecified"}})
        units += [
            {"id": f"{lid}-hall", "type": "Feature", "geometry": rect(0, 8, 40, 12),
             "properties": {"level_id": lid, "category": "walkway"}},
            {"id": f"{lid}-shop", "type": "Feature", "geometry": rect(10, 0, 20, 8),
             "properties": {"level_id": lid, "category": "room"}},
            {"id": f"{lid}-elev", "type": "Feature", "geometry": rect(30, 12, 32, 14),
             "properties": {"level_id": lid, "category": "elevator"}},
            {"id": f"{lid}-col", "type": "Feature", "geometry": rect(5, 0, 6, 1),
             "properties": {"level_id": lid, "category": "column"}},
        ]
        openings.append({"id": f"{lid}-door", "type": "Feature",
                         "geometry": {"type": "LineString", "coordinates": [ll(14, 8), ll(16, 8)]},
                         "properties": {"level_id": lid, "category": "pedestrian"}})
    anchors = [{"id": "A1", "type": "Feature", "geometry": {"type": "Point", "coordinates": ll(15, 4)},
                "properties": {"unit_id": "L0-shop"}}]
    occupants = [{"id": "O1", "type": "Feature", "geometry": None,
                  "properties": {"anchor_id": "A1", "name": {"en": "Coffee", "zh-Hans": "咖啡店"}}}]
    for name, feats in [("level", levels), ("unit", units), ("opening", openings),
                        ("anchor", anchors), ("occupant", occupants)]:
        (d / f"{name}.geojson").write_text(json.dumps(fc(feats)), encoding="utf-8")


class ImdfConvertTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.src = Path(self.tmp.name) / "imdf"
        self.src.mkdir()
        make_imdf(self.src)
        self.out = Path(self.tmp.name) / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def test_levels_area_and_scale(self):
        venue = imdf_convert.convert(self.src, self.out, margin_cm=100)
        self.assertEqual([lv["name"] for lv in venue["levels"]], ["1F", "2F"])
        lv = venue["levels"][0]
        # 走廊 40×4 + 店 10×8 + 电梯 2×2 = 244 m²；柱子不可走
        self.assertAlmostEqual(lv["walkableM2"], 244, delta=1)
        doc = json.loads((self.out / lv["file"]).read_text(encoding="utf-8"))
        self.assertAlmostEqual(doc["width"], 4000 + 200, delta=5)
        self.assertAlmostEqual(doc["height"], 2000 + 200, delta=5)
        self.assertEqual(len(doc["obstaclePolygons"]), 1)
        # 走廊左上角 (0, 8 m) → (100, 900) cm
        hall = doc["floorPolygons"][0]
        self.assertAlmostEqual(min(hall[0::2]), 100, delta=2)
        self.assertAlmostEqual(min(hall[1::2]), 900, delta=2)

    def test_opening_label_and_connectors(self):
        venue = imdf_convert.convert(self.src, self.out, margin_cm=0)
        doc = json.loads((self.out / venue["levels"][0]["file"]).read_text(encoding="utf-8"))
        els = doc["mapElementList"]
        door = next(e for e in els if e["shapeType"] == "MapOpening")
        self.assertAlmostEqual(door["width"], 200, delta=2)
        self.assertAlmostEqual(door["x"], 1500, delta=2)
        self.assertAlmostEqual(door["y"], 800, delta=2)
        labels = [e["text"] for e in els if e["shapeType"] == "MapLabel"]
        self.assertIn("咖啡店", labels)
        self.assertEqual(len(doc["connectors"]), 1)
        self.assertEqual(doc["connectors"][0]["category"], "elevator")
        groups = venue["connectorGroups"]
        self.assertEqual(len(groups), 1)
        self.assertEqual([m["level"] for m in groups[0]["members"]], ["L0", "L1"])

    def test_geo_ref_round_trip(self):
        venue = imdf_convert.convert(self.src, self.out, margin_cm=0)
        doc = json.loads((self.out / venue["levels"][0]["file"]).read_text(encoding="utf-8"))
        g = doc["geoRef"]
        lon, lat = ll(25, 10)
        x = (lon - g["lon0"]) * g["mPerDegLon"] * 100
        y = (g["lat0"] - lat) * g["mPerDegLat"] * 100
        self.assertAlmostEqual(x, 2500, delta=2)
        self.assertAlmostEqual(y, 1000, delta=2)

    def test_zip_input(self):
        z = Path(self.tmp.name) / "venue.zip"
        with zipfile.ZipFile(z, "w") as zf:
            for p in self.src.glob("*.geojson"):
                zf.write(p, p.name)
        venue = imdf_convert.convert(z, self.out)
        self.assertEqual(len(venue["levels"]), 2)

    def test_connector_grouping_respects_category_and_distance(self):
        conns = [
            {"id": "e0", "category": "elevator", "ordinal": 0, "level": "a", "x": 0, "y": 0},
            {"id": "e1", "category": "elevator", "ordinal": 1, "level": "b", "x": 50, "y": 0},
            {"id": "s1", "category": "stairs", "ordinal": 1, "level": "b", "x": 10, "y": 0},
            {"id": "e2", "category": "elevator", "ordinal": 2, "level": "c", "x": 5000, "y": 0},
        ]
        groups = imdf_convert.group_connectors(conns)
        self.assertEqual(len(groups), 1)
        self.assertEqual([m["id"] for m in groups[0]["members"]], ["e0", "e1"])


if __name__ == "__main__":
    unittest.main()
