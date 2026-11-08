#!/usr/bin/env python3
"""IMDF（Apple Indoor Mapping Data Format）场馆 → 每层一个 map.json（我们的地图格式）。

IMDF 是一组 GeoJSON：venue / level / unit / opening / fixture / amenity / occupant / anchor …，
坐标是 WGS84 经纬度。本工具把它投影到以场馆左上角为原点的平面（cm，+x 向东，+y 向南，
与 App 的屏幕坐标一致），每个 level 输出：

  <out>/<level_id>.map.json
    width, height            该层外包框（cm，含留白）
    floorName, ordinal       楼层名、IMDF 的 ordinal（0 = 地面层，负数 = 地下）
    floorPolygons            可走单元的多边形 [[x0,y0,x1,y1,…], …]（StoreDataLoader 直接能读）
    obstaclePolygons         不可走单元（结构、柱子、非公共区等）
    mapElementList           开口 → MapOpening（中心 + 宽度 + 方向），连接体 → MapConnector，
                             有名字的单元 → MapLabel（地标，OCR / 搜索用）
    connectors               电梯 / 扶梯 / 楼梯 / 坡道：{id, category, x, y, polygon}
    geoRef                   {lon0, lat0, mPerDegLon, mPerDegLat}：平面 ↔ 经纬度
  <out>/venue.json           楼层列表（按 ordinal）+ 跨楼层连接体（同类别、平面位置相近的连接体归为一组）

用法：
  python3 tools/venue/imdf_convert.py <imdf 目录或 .zip> <输出目录> [--margin-cm 200]

限制（有意保持简单）：
- 投影用场馆中心处的等距圆柱近似，几百米的场馆误差 < 1 cm 级，不适合跨城市尺度。
- MultiPolygon 拆成多个多边形；多边形的内环（洞）忽略，洞里的不可走区域应在 IMDF 里另有 unit。
- unit 类别按 IMDF 规范的 category 分类，见 WALKABLE / CONNECTOR；不认识的类别当可走（宁可放宽，
  粒子滤波的墙体约束还会再看障碍）。
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import zipfile
from pathlib import Path

# IMDF unit.category → 是否可走。规范里不可走的主要是结构 / 设备间 / 非公共区。
NON_WALKABLE = {
    "structure", "column", "shaft", "nonpublic", "opentobelow", "elevator.shaft",
    "mechanical", "electrical", "unenclosedarea.nonpublic", "steps.nonpublic",
}
CONNECTOR = {"elevator", "escalator", "stairs", "steps", "ramp", "movingwalkway"}

EARTH_R = 6378137.0


def _load_features(src: Path) -> dict[str, list[dict]]:
    """读 IMDF 目录或 zip，返回 {文件名去扩展名: features}。"""
    out: dict[str, list[dict]] = {}
    if src.is_file() and src.suffix.lower() == ".zip":
        with zipfile.ZipFile(src) as z:
            for name in z.namelist():
                if name.lower().endswith(".geojson"):
                    data = json.loads(z.read(name).decode("utf-8"))
                    out[Path(name).stem.lower()] = data.get("features", [])
    else:
        for p in sorted(src.glob("*.geojson")):
            out[p.stem.lower()] = json.loads(p.read_text(encoding="utf-8")).get("features", [])
    if "level" not in out:
        raise SystemExit(f"{src}: 没有 level.geojson，不是 IMDF")
    return out


def _rings(geom: dict | None) -> list[list[list[float]]]:
    """几何 → 外环列表（经纬度）。Polygon / MultiPolygon 只取外环。"""
    if not geom:
        return []
    t, c = geom.get("type"), geom.get("coordinates")
    if t == "Polygon" and c:
        return [c[0]]
    if t == "MultiPolygon" and c:
        return [poly[0] for poly in c if poly]
    return []


def _all_lonlat(features: dict[str, list[dict]]):
    for key in ("level", "unit", "venue", "footprint", "building"):
        for f in features.get(key, []):
            for ring in _rings(f.get("geometry")):
                yield from ring


class Projector:
    """等距圆柱投影：经纬度 → cm，原点 (lon0, lat0) 为场馆西北角。"""

    def __init__(self, lon0: float, lat0: float, lat_ref: float):
        self.lon0, self.lat0 = lon0, lat0
        self.m_per_deg_lat = math.pi * EARTH_R / 180
        self.m_per_deg_lon = self.m_per_deg_lat * math.cos(math.radians(lat_ref))

    def __call__(self, lon: float, lat: float, margin_cm: float = 0) -> tuple[float, float]:
        x = (lon - self.lon0) * self.m_per_deg_lon * 100 + margin_cm
        y = (self.lat0 - lat) * self.m_per_deg_lat * 100 + margin_cm      # +y 向南
        return x, y


def _area(poly: list[tuple[float, float]]) -> float:
    s = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        s += x0 * y1 - x1 * y0
    return abs(s) / 2


def _centroid(poly: list[tuple[float, float]]) -> tuple[float, float]:
    a = 0.0
    cx = cy = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        cr = x0 * y1 - x1 * y0
        a += cr
        cx += (x0 + x1) * cr
        cy += (y0 + y1) * cr
    if abs(a) < 1e-9:
        n = len(poly)
        return sum(p[0] for p in poly) / n, sum(p[1] for p in poly) / n
    return cx / (3 * a), cy / (3 * a)


def _name(props: dict) -> str | None:
    """IMDF 的 name 是多语言对象 {"en": "...", "zh-Hans": "..."}，取中文优先。"""
    n = props.get("name") or props.get("alt_name")
    if isinstance(n, dict):
        for k in ("zh-Hans", "zh", "zh-CN", "en"):
            if n.get(k):
                return n[k]
        return next(iter(n.values()), None)
    return n if isinstance(n, str) else None


def _r1(v: float) -> float:
    return round(v, 1)


def convert(src: Path, out: Path, margin_cm: float = 200) -> dict:
    feats = _load_features(src)
    pts = list(_all_lonlat(feats))
    if not pts:
        raise SystemExit("IMDF 里没有任何多边形")
    lon_min = min(p[0] for p in pts)
    lat_max = max(p[1] for p in pts)
    lat_ref = (min(p[1] for p in pts) + lat_max) / 2
    proj = Projector(lon_min, lat_max, lat_ref)

    levels = sorted(feats["level"], key=lambda f: (f.get("properties", {}).get("ordinal", 0), f.get("id", "")))
    occupant_by_anchor: dict[str, str] = {}
    anchors = {a.get("id"): a for a in feats.get("anchor", [])}
    for occ in feats.get("occupant", []):
        anc = anchors.get(occ.get("properties", {}).get("anchor_id"))
        nm = _name(occ.get("properties", {}))
        if anc and nm:
            unit_id = anc.get("properties", {}).get("unit_id")
            if unit_id:
                occupant_by_anchor[unit_id] = nm

    out.mkdir(parents=True, exist_ok=True)
    venue_levels = []
    all_connectors = []
    for lv in levels:
        lid = lv.get("id")
        lp = lv.get("properties", {})
        ordinal = lp.get("ordinal", 0)
        units = [u for u in feats.get("unit", []) if u.get("properties", {}).get("level_id") == lid]
        openings = [o for o in feats.get("opening", []) if o.get("properties", {}).get("level_id") == lid]

        walk, obst, elements, connectors = [], [], [], []
        xs, ys = [], []
        for ring in _rings(lv.get("geometry")):
            for lon, lat in ring:
                x, y = proj(lon, lat, margin_cm)
                xs.append(x)
                ys.append(y)
        for u in units:
            up = u.get("properties", {})
            cat = (up.get("category") or "").lower()
            for ring in _rings(u.get("geometry")):
                poly = [proj(lon, lat, margin_cm) for lon, lat in ring]
                if len(poly) > 1 and poly[0] == poly[-1]:
                    poly = poly[:-1]
                if len(poly) < 3:
                    continue
                xs += [p[0] for p in poly]
                ys += [p[1] for p in poly]
                flat = [_r1(v) for p in poly for v in p]
                cx, cy = _centroid(poly)
                if cat in NON_WALKABLE:
                    obst.append(flat)
                    continue
                walk.append(flat)
                if cat in CONNECTOR:
                    c = {"id": u.get("id"), "category": cat, "level": lid, "ordinal": ordinal,
                         "x": _r1(cx), "y": _r1(cy), "polygon": flat}
                    connectors.append(c)
                    elements.append({"shapeType": "MapConnector", "code": u.get("id"), "category": cat,
                                     "x": _r1(cx), "y": _r1(cy), "width": 0, "height": 0, "rotation": 0})
                nm = occupant_by_anchor.get(u.get("id")) or _name(up)
                if nm:
                    elements.append({"shapeType": "MapLabel", "code": u.get("id"), "text": nm, "category": cat,
                                     "x": _r1(cx), "y": _r1(cy), "width": 0, "height": 0, "rotation": 0})
        for o in openings:
            g = o.get("geometry") or {}
            if g.get("type") != "LineString" or len(g.get("coordinates", [])) < 2:
                continue
            a = proj(*g["coordinates"][0], margin_cm)
            b = proj(*g["coordinates"][-1], margin_cm)
            w = math.hypot(b[0] - a[0], b[1] - a[1])
            rot = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))
            elements.append({"shapeType": "MapOpening", "code": o.get("id"),
                             "category": (o.get("properties", {}).get("category") or ""),
                             "x": _r1((a[0] + b[0]) / 2), "y": _r1((a[1] + b[1]) / 2),
                             "width": _r1(w), "height": 14, "rotation": _r1(rot)})
        if not xs:
            continue
        width = max(xs) + margin_cm
        height = max(ys) + margin_cm
        name = _name(lp) or lp.get("short_name") or str(lid)
        if isinstance(lp.get("short_name"), dict):
            name = _name({"name": lp["short_name"]}) or name
        doc = {
            "width": _r1(width), "height": _r1(height), "floorName": name, "ordinal": ordinal,
            "source": "imdf", "levelId": lid,
            "floorPolygons": walk, "obstaclePolygons": obst,
            "mapElementList": elements, "connectors": connectors,
            "geoRef": {"lon0": lon_min, "lat0": lat_max, "marginCm": margin_cm,
                       "mPerDegLon": proj.m_per_deg_lon, "mPerDegLat": proj.m_per_deg_lat},
        }
        fname = f"{_safe(lid)}.map.json"
        (out / fname).write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
        walk_m2 = sum(_area(list(zip(p[0::2], p[1::2]))) for p in walk) / 1e4 if walk else 0
        venue_levels.append({"levelId": lid, "ordinal": ordinal, "name": name, "file": fname,
                             "walkableM2": round(walk_m2, 1), "units": len(units), "openings": len(openings),
                             "connectors": len(connectors)})
        all_connectors += connectors

    venue = {"source": "imdf", "levels": venue_levels, "connectorGroups": group_connectors(all_connectors)}
    (out / "venue.json").write_text(json.dumps(venue, ensure_ascii=False, indent=1), encoding="utf-8")
    return venue


def group_connectors(conns: list[dict], radius_cm: float = 800) -> list[dict]:
    """跨楼层把同类别、平面位置相近（< radius）的连接体归为一组：同一部电梯 / 同一部楼梯。

    扶梯在相邻两层的投影常错开一段，所以半径默认放宽到 8 m。贪心：按 ordinal 从低到高，
    每个连接体接到「同类别、上一层、最近且未被占用」的组上。
    """
    groups: list[dict] = []
    for c in sorted(conns, key=lambda c: (c["ordinal"], c["id"] or "")):
        best, best_d = None, radius_cm
        for g in groups:
            last = g["members"][-1]
            if g["category"] != c["category"] or last["ordinal"] >= c["ordinal"]:
                continue
            d = math.hypot(last["x"] - c["x"], last["y"] - c["y"])
            if d < best_d:
                best, best_d = g, d
        if best is None:
            groups.append({"category": c["category"], "members": [c]})
        else:
            best["members"].append(c)
    return [{"category": g["category"],
             "members": [{"id": m["id"], "level": m["level"], "ordinal": m["ordinal"], "x": m["x"], "y": m["y"]}
                         for m in g["members"]]}
            for g in groups if len(g["members"]) >= 2]


def _safe(s) -> str:
    return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in str(s))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=Path, help="IMDF 目录（含 level.geojson 等）或 .zip")
    ap.add_argument("out", type=Path, help="输出目录")
    ap.add_argument("--margin-cm", type=float, default=200, help="四周留白（cm）")
    a = ap.parse_args(argv)
    venue = convert(a.src, a.out, a.margin_cm)
    for lv in venue["levels"]:
        print(f"楼层 {lv['name']}（ordinal {lv['ordinal']}）：可走 {lv['walkableM2']} m²，"
              f"单元 {lv['units']}，开口 {lv['openings']}，连接体 {lv['connectors']} → {lv['file']}")
    print(f"跨楼层连接体组：{len(venue['connectorGroups'])}")


if __name__ == "__main__":
    sys.exit(main())
