"""imdf_export.py / georef.py 的单元测试。

合成一栋两层小楼（RoomPlan 扫描输出的 map.json 格式），两层分别扫描，地图原点和朝向都不同（geoRef 旋转角不同），
导出 IMDF 后用 imdf_convert 读回来：可走面积、门、连接体（含跨楼层分组）、名称应一致。

楼层平面（米，+x 向东、+y 向南，原点在楼的西北角）：
    会议室 (0,0)-(8,4)   卫生间 (8,0)-(12,4)   电梯 (14,0)-(16,2)   库房（非公共）(16,0)-(20,4)
    走廊   (0,4)-(20,7)  楼梯 (0,7)-(3,10)
    门：走廊 ↔ 会议室 x 3..4 m（y = 4），开口：走廊 ↔ 卫生间 x 9..10 m
可走 = 32 + 16 + 4 + 60 + 9 = 121 m²（库房不可走）。
"""
import json
import math
import sys
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "venue"))

import georef  # noqa: E402
import imdf_convert  # noqa: E402
import imdf_export  # noqa: E402

LON_W, LAT_N = 121.4737, 31.2304          # 楼西北角
M_LAT = georef.M_PER_DEG_LAT
M_LON = M_LAT * math.cos(math.radians(LAT_N))

UNITS = [
    ("office", "room", (0, 0, 8, 4)),
    ("wc", "restroom", (8, 0, 12, 4)),
    ("lift", "elevator", (14, 0, 16, 2)),
    ("store", "nonpublic", (16, 0, 20, 4)),
    ("hall", "walkway", (0, 4, 20, 7)),
    ("stair", "stairs", (0, 7, 3, 10)),
]
WALKABLE_M2 = 121


def world_ll(x_m, y_m):
    return LON_W + x_m / M_LON, LAT_N - y_m / M_LAT


def scan_doc(ordinal, name, rotation_deg, origin_shift_m, names):
    """模拟一次扫描：地图坐标系相对真北转了 rotation_deg，原点在楼外某处。"""
    g = georef.make(*world_ll(-origin_shift_m, -origin_shift_m), margin_cm=100, rotation_deg=rotation_deg,
                    lat_ref=LAT_N)

    def m(x, y):
        return georef.to_map(g, *world_ll(x, y))

    def flat(pts):
        return [round(v, 1) for p in pts for v in p]

    units, walk, obst, els = [], [], [], []
    for uid_, cat, (x0, y0, x1, y1) in UNITS:
        poly = flat([m(x0, y0), m(x1, y0), m(x1, y1), m(x0, y1)])
        units.append({"id": uid_, "category": cat, "name": names.get(uid_), "polygon": poly})
        (obst if cat in imdf_convert.NON_WALKABLE else walk).append(poly)
    for typ, (xa, xb) in (("MapDoor", (3, 4)), ("MapOpening", (9, 10))):
        a, b = m(xa, 4), m(xb, 4)
        els.append({"shapeType": typ, "x": (a[0] + b[0]) / 2, "y": (a[1] + b[1]) / 2,
                    "width": math.dist(a, b), "height": 14,
                    "rotation": math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))})
    tl = m(2, 1)
    els.append({"shapeType": "MapShelf", "code": "Room-table-1", "x": tl[0], "y": tl[1], "width": 200,
                "height": 100, "rotation": -rotation_deg})
    return {"width": 3000, "height": 3000, "floorName": name, "ordinal": ordinal, "source": "roomplan",
            "venueName": "合成办公楼", "units": units, "floorPolygons": walk, "obstaclePolygons": obst,
            "mapElementList": els, "geoRef": g}


def two_levels():
    return [
        scan_doc(0, "1F", 25.0, 3, {"office": "会议室 A", "wc": "卫生间", "lift": "1 号电梯"}),
        scan_doc(1, "2F", -40.0, 7, {"office": "研发部", "wc": "卫生间"}),
    ]


class GeoRefTests(unittest.TestCase):
    def test_round_trip_and_rotation_convention(self):
        g = georef.make(120.0, 30.0, margin_cm=100, rotation_deg=0)
        lon, lat = georef.to_lonlat(g, 100 + 1000, 100)       # 地图 +x 10 m → 正东 10 m
        self.assertAlmostEqual((lon - 120) * g["mPerDegLon"], 10, places=6)
        self.assertAlmostEqual(lat, 30.0, places=9)
        g["rotationDeg"] = 90                                   # 地图 +x 指向正南
        lon, lat = georef.to_lonlat(g, 1100, 100)
        self.assertAlmostEqual((30 - lat) * g["mPerDegLat"], 10, places=6)
        self.assertAlmostEqual(lon, 120.0, places=9)
        g["rotationDeg"] = 33
        x, y = georef.to_map(g, *georef.to_lonlat(g, 523.4, -77.0))
        self.assertAlmostEqual(x, 523.4, places=4)
        self.assertAlmostEqual(y, -77.0, places=4)

    def test_from_anchor(self):
        truth = georef.make(*world_ll(-3, -3), margin_cm=100, rotation_deg=25, lat_ref=LAT_N)
        p = georef.to_map(truth, *world_ll(5, 5))
        # 手机朝向在地图里是 −y（屏幕向上）：真实方位角 = 90 + (−90) + 25 = 25°
        g = georef.from_anchor(p[0], p[1], *world_ll(5, 5), true_heading_deg=25, map_dir_deg=-90, margin_cm=100)
        self.assertAlmostEqual(g["rotationDeg"], 25, places=9)
        for q in [(0, 0), (2000, 500), (-300, 1200)]:
            a, b = georef.to_lonlat(g, *q), georef.to_lonlat(truth, *q)
            self.assertLess(abs(a[0] - b[0]) * M_LON + abs(a[1] - b[1]) * M_LAT, 0.01)

    def test_from_two_points(self):
        truth = georef.make(*world_ll(-7, -7), margin_cm=100, rotation_deg=-40, lat_ref=LAT_N)
        p1, p2 = georef.to_map(truth, *world_ll(0, 0)), georef.to_map(truth, *world_ll(20, 10))
        g, scale = georef.from_two_points(p1, world_ll(0, 0), p2, world_ll(20, 10), margin_cm=100)
        self.assertAlmostEqual(scale, 1, places=4)
        self.assertAlmostEqual(g["rotationDeg"], -40, places=3)
        a, b = georef.to_lonlat(g, 1234, 567), georef.to_lonlat(truth, 1234, 567)
        self.assertLess(math.hypot((a[0] - b[0]) * M_LON, (a[1] - b[1]) * M_LAT), 0.01)


class ImdfExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.zip = self.dir / "venue.zip"
        self.docs = two_levels()

    def tearDown(self):
        self.tmp.cleanup()

    def _fc(self, name):
        with zipfile.ZipFile(self.zip) as z:
            return json.loads(z.read(f"{name}.geojson").decode("utf-8"))

    def test_archive_contents(self):
        counts = imdf_export.export(self.docs, self.zip)
        with zipfile.ZipFile(self.zip) as z:
            names = set(z.namelist())
            man = json.loads(z.read("manifest.json"))
        for k in ["manifest.json"] + [f"{k}.geojson" for k in
                                      ("venue", "building", "footprint", "level", "unit", "opening",
                                       "fixture", "anchor", "occupant", "address")]:
            self.assertIn(k, names)
        self.assertEqual(man["version"], "1.0.0")
        self.assertEqual(counts["level"], 2)
        self.assertEqual(counts["unit"], 12)
        self.assertEqual(counts["opening"], 4)
        self.assertEqual(counts["fixture"], 2)
        self.assertEqual(counts["anchor"], 12)
        self.assertEqual(counts["occupant"], 2)          # 只有 room 类别的有名单元
        levels = self._fc("level")["features"]
        self.assertEqual(sorted(f["properties"]["ordinal"] for f in levels), [0, 1])
        for name in ("unit", "level", "venue", "footprint", "fixture"):
            for f in self._fc(name)["features"]:
                uuid.UUID(f["id"])
                self.assertEqual(f["feature_type"], name)
                ring = f["geometry"]["coordinates"][0]
                self.assertEqual(ring[0], ring[-1])
                self.assertGreater(imdf_export._signed_area([tuple(p) for p in ring[:-1]]), 0, "外环要逆时针")
        unit_ids = {f["id"] for f in self._fc("unit")["features"]}
        for a in self._fc("anchor")["features"]:
            self.assertIn(a["properties"]["unit_id"], unit_ids)
        venue = self._fc("venue")["features"][0]
        self.assertEqual(venue["properties"]["name"], {"zh-Hans": "合成办公楼"})

    def test_ids_are_stable(self):
        imdf_export.export(self.docs, self.zip)
        a = [f["id"] for f in self._fc("unit")["features"]]
        imdf_export.export(self.docs, self.zip)
        self.assertEqual(a, [f["id"] for f in self._fc("unit")["features"]])

    def test_round_trip_through_imdf_convert(self):
        imdf_export.export(self.docs, self.zip)
        venue = imdf_convert.convert(self.zip, self.dir / "back", margin_cm=100)
        self.assertEqual([lv["ordinal"] for lv in venue["levels"]], [0, 1])
        self.assertEqual([lv["name"] for lv in venue["levels"]], ["1F", "2F"])
        for lv, src in zip(venue["levels"], self.docs):
            # 可走面积：导回来的 = 扫描时的 floorPolygons = 121 m²
            src_m2 = sum(imdf_convert._area(list(zip(p[0::2], p[1::2]))) for p in src["floorPolygons"]) / 1e4
            self.assertAlmostEqual(src_m2, WALKABLE_M2, delta=0.1)
            self.assertAlmostEqual(lv["walkableM2"], src_m2, delta=0.1)
            doc = json.loads((self.dir / "back" / lv["file"]).read_text(encoding="utf-8"))
            self.assertEqual(len(doc["obstaclePolygons"]), 1)
            # 门：数量、宽度、位置（换回经纬度比较）
            src_doors = [e for e in src["mapElementList"] if e["shapeType"] in ("MapDoor", "MapOpening")]
            back_doors = [e for e in doc["mapElementList"] if e["shapeType"] == "MapOpening"]
            self.assertEqual(len(back_doors), len(src_doors))
            for s in src_doors:
                s_ll = georef.to_lonlat(src["geoRef"], s["x"], s["y"])
                best = min(back_doors, key=lambda b: math.dist(
                    georef.to_lonlat(doc["geoRef"], b["x"], b["y"]), s_ll))
                b_ll = georef.to_lonlat(doc["geoRef"], best["x"], best["y"])
                self.assertLess(math.hypot((b_ll[0] - s_ll[0]) * M_LON, (b_ll[1] - s_ll[1]) * M_LAT), 0.02)
                self.assertAlmostEqual(best["width"], s["width"], delta=1)
            # 连接体：类别一致
            self.assertEqual(sorted(c["category"] for c in doc["connectors"]), ["elevator", "stairs"])
            # 名称：扫描时填的单元名 = 读回来的地标
            want = sorted(u["name"] for u in src["units"]
                          if u["name"] and u["category"] not in imdf_convert.NON_WALKABLE)
            got = sorted(e["text"] for e in doc["mapElementList"] if e["shapeType"] == "MapLabel")
            self.assertEqual(got, want)
        # 两层分别扫描、地图朝向不同，经纬度对上之后电梯、楼梯各归成一组
        groups = sorted(g["category"] for g in venue["connectorGroups"])
        self.assertEqual(groups, ["elevator", "stairs"])
        for g in venue["connectorGroups"]:
            self.assertEqual([m["ordinal"] for m in g["members"]], [0, 1])

    def test_same_ordinal_scans_merge_into_one_level(self):
        a, b = two_levels()
        b["ordinal"] = 0
        counts = imdf_export.export([a, b], self.zip)
        self.assertEqual(counts["level"], 1)
        self.assertEqual(counts["unit"], 12)

    def test_legacy_single_room_without_units(self):
        doc = {"floorName": "房间", "floorPolygons": [[100, 100, 500, 100, 500, 400, 100, 400]],
               "mapElementList": [{"shapeType": "MapDoor", "x": 300, "y": 100, "width": 90, "rotation": 0}]}
        with self.assertRaises(ValueError):
            imdf_export.export([doc], self.zip)
        imdf_export.export([doc], self.zip, origin=(120.0, 30.0))
        venue = imdf_convert.convert(self.zip, self.dir / "back")
        self.assertAlmostEqual(venue["levels"][0]["walkableM2"], 12, delta=0.05)
        self.assertEqual(venue["levels"][0]["openings"], 1)

    def test_cli(self):
        src = self.dir / "scans"
        src.mkdir()
        for i, d in enumerate(self.docs):
            (src / f"L{i}.map.json").write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        (src / "venue.json").write_text("{}", encoding="utf-8")
        imdf_export.main([str(src), "-o", str(self.zip), "--name", "命令行场馆"])
        venue = self._fc("venue")["features"][0]
        self.assertEqual(venue["properties"]["name"]["zh-Hans"], "命令行场馆")
        self.assertEqual(len(self._fc("level")["features"]), 2)


if __name__ == "__main__":
    unittest.main()
