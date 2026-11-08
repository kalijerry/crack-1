#!/usr/bin/env python3
"""一个场馆的多层 map.json（RoomPlan 扫描生成，或 imdf_convert 导入后再编辑）→ IMDF 压缩包。

和 `imdf_convert.py` 互为逆过程：导出后再用 imdf_convert 读回来，可走面积、门、连接体、名称一致
（见 tools/tests/test_imdf_export.py）。Swift 版是 `HPASSKit/Models/IMDFExporter.swift`，两边规则相同。

输入的每个 map.json 需要：
  geoRef        平面 cm ↔ 经纬度（见 georef.py；没有时可用 --origin 给一个假原点）
  ordinal       楼层序号（IMDF level.ordinal，0 = 地面层）；同一 ordinal 的多个文件合成一层
  floorName     楼层名
  units         [{id, category, name, polygon:[x0,y0,x1,y1,…]}]：单元（房间 / 走廊 / 电梯…），
                category 用 IMDF unit category。没有 units 时退回 floorPolygons（当 room）
                + obstaclePolygons（当 structure）
  mapElementList  MapDoor / MapOpening → opening；MapShelf（扫描出的家具）→ fixture
可选：venueName、venueCategory（IMDF venue category，默认 businesscampus）。

输出 zip 内容：manifest.json、address / venue / building / footprint / level / unit / opening /
fixture / anchor / occupant 的 .geojson。坐标 WGS84，外环逆时针、首尾闭合。
每个要素的 id 是 UUID（由场馆名 + 楼层 + 局部编号做 uuid5，重复导出 id 不变）。
有名字的单元都有一个 anchor（单元中心）；category = room 的有名单元另外生成 occupant（租户 / 房间名）。

用法：
  python3 tools/venue/imdf_export.py <map.json 或目录 …> -o venue_imdf.zip [--name 场馆名]
         [--category businesscampus] [--origin lon,lat] [--language zh-Hans]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import georef  # noqa: E402
from imdf_convert import CONNECTOR, NON_WALKABLE  # noqa: E402

FEATURE_FILES = ["address", "venue", "building", "footprint", "level", "unit", "opening",
                 "fixture", "anchor", "occupant"]
# 有名字时生成 occupant 的单元类别（租户 / 房间）；其他类别（卫生间、电梯…）名字只写在 unit 上
OCCUPANT_UNIT_CATEGORIES = {"room", "retail", "office", "unspecified"}
NS = uuid.UUID("6f1c2b0e-5d0a-4b8e-9a51-2f3c0d6e7a10")


def doc_units(doc: dict) -> list[dict]:
    """map.json → 单元列表 [{id, category, name, poly:[(x,y),…]}]（cm）。"""
    out = []
    for i, u in enumerate(doc.get("units") or []):
        flat = u.get("polygon") or []
        poly = list(zip(flat[0::2], flat[1::2]))
        if len(poly) >= 3:
            out.append({"id": str(u.get("id") or f"unit{i + 1}"), "category": (u.get("category") or "room").lower(),
                        "name": (u.get("name") or "").strip() or None, "poly": poly})
    if out or doc.get("units"):
        return out
    for key, cat in (("floorPolygons", "room"), ("obstaclePolygons", "structure")):
        for i, flat in enumerate(doc.get(key) or []):
            poly = list(zip(flat[0::2], flat[1::2]))
            if len(poly) >= 3:
                out.append({"id": f"{key}{i + 1}", "category": cat, "name": None, "poly": poly})
    return out


def _signed_area(ring: list[tuple[float, float]]) -> float:
    s = 0.0
    for i in range(len(ring)):
        x0, y0 = ring[i]
        x1, y1 = ring[(i + 1) % len(ring)]
        s += x0 * y1 - x1 * y0
    return s / 2


def _centroid(poly):
    a = cx = cy = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        c = x0 * y1 - x1 * y0
        a += c
        cx += (x0 + x1) * c
        cy += (y0 + y1) * c
    if abs(a) < 1e-12:
        return sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly)
    return cx / (3 * a), cy / (3 * a)


def _r(v: float) -> float:
    return round(v, 9)


def _ring(lonlat: list[tuple[float, float]]) -> list[list[float]]:
    """GeoJSON 外环：去掉重复的末点，逆时针，再闭合。"""
    pts = list(lonlat)
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts = pts[:-1]
    if _signed_area(pts) < 0:
        pts.reverse()
    pts.append(pts[0])
    return [[_r(lon), _r(lat)] for lon, lat in pts]


def _polygon(lonlat) -> dict:
    return {"type": "Polygon", "coordinates": [_ring(lonlat)]}


def _point(lon: float, lat: float) -> dict:
    return {"type": "Point", "coordinates": [_r(lon), _r(lat)]}


def convex_hull(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
    p = sorted(set(pts))
    if len(p) < 3:
        return p

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for q in p:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], q) <= 0:
            lower.pop()
        lower.append(q)
    for q in reversed(p):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], q) <= 0:
            upper.pop()
        upper.append(q)
    return lower[:-1] + upper[:-1]


def _feature(fid: str, ftype: str, geometry, props: dict) -> dict:
    return {"id": fid, "type": "Feature", "feature_type": ftype, "geometry": geometry, "properties": props}


def _labels(text: str | None, lang: str):
    return {lang: text} if text else None


def opening_segment(e: dict) -> tuple[tuple[float, float], tuple[float, float]]:
    """MapDoor / MapOpening（按中心 + 宽度 + 角度）→ 两个端点（cm）。"""
    cx, cy = float(e.get("x", 0)), float(e.get("y", 0))
    w = float(e.get("width", 0))
    r = math.radians(float(e.get("rotation", 0)))
    ux, uy = math.cos(r) * w / 2, math.sin(r) * w / 2
    return (cx - ux, cy - uy), (cx + ux, cy + uy)


def shelf_corners(e: dict) -> list[tuple[float, float]]:
    """MapShelf（Konva：左上角 + 绕左上角转）→ 四个角（cm）。"""
    x, y = float(e.get("x", 0)), float(e.get("y", 0))
    w, h = float(e.get("width", 0)), float(e.get("height", 0))
    r = math.radians(float(e.get("rotation", 0)))
    u = (math.cos(r), math.sin(r))
    v = (-math.sin(r), math.cos(r))
    return [(x, y), (x + u[0] * w, y + u[1] * w), (x + u[0] * w + v[0] * h, y + u[1] * w + v[1] * h),
            (x + v[0] * h, y + v[1] * h)]


def build_features(docs: list[dict], venue_name: str | None = None, venue_category: str | None = None,
                   language: str = "zh-Hans", origin: tuple[float, float] | None = None) -> dict[str, list[dict]]:
    """多层 map.json → {feature_type: [feature]}。"""
    if not docs:
        raise ValueError("没有楼层")
    name = venue_name or next((d.get("venueName") for d in docs if d.get("venueName")), None) or "场馆"
    category = venue_category or next((d.get("venueCategory") for d in docs if d.get("venueCategory")),
                                      None) or "businesscampus"

    def uid(*parts) -> str:
        return str(uuid.uuid5(NS, "/".join([name] + [str(p) for p in parts])))

    feats: dict[str, list[dict]] = {k: [] for k in FEATURE_FILES}
    address_id, venue_id, building_id = uid("address"), uid("venue"), uid("building")

    by_ord: dict[int, list[dict]] = {}
    for d in docs:
        g = d.get("geoRef")
        if not g:
            if origin is None:
                raise ValueError(f"楼层 {d.get('floorName') or '?'} 没有 geoRef（先在网页编辑器里两点对准，或给 --origin）")
            g = georef.make(origin[0], origin[1], d.get("marginCm", 0) or 0)
        by_ord.setdefault(int(d.get("ordinal", 0) or 0), []).append({**d, "geoRef": g})

    all_pts: list[tuple[float, float]] = []
    for ordinal in sorted(by_ord):
        level_docs = by_ord[ordinal]
        level_name = next((d.get("floorName") for d in level_docs if d.get("floorName")), None) or f"{ordinal}F"
        level_id = uid("level", ordinal)
        level_pts: list[tuple[float, float]] = []
        unit_feats = []
        for di, d in enumerate(level_docs):
            g = d["geoRef"]
            ll = lambda p: georef.to_lonlat(g, p[0], p[1])  # noqa: E731
            for u in doc_units(d):
                ring = [ll(p) for p in u["poly"]]
                level_pts += ring
                cx, cy = _centroid(u["poly"])
                c_lon, c_lat = ll((cx, cy))
                unit_id = uid("unit", ordinal, di, u["id"])
                unit_feats.append(_feature(unit_id, "unit", _polygon(ring), {
                    "category": u["category"], "restriction": None, "accessibility": None,
                    "name": _labels(u["name"], language), "alt_name": None,
                    "level_id": level_id, "display_point": _point(c_lon, c_lat)}))
                anchor_id = uid("anchor", ordinal, di, u["id"])
                feats["anchor"].append(_feature(anchor_id, "anchor", _point(c_lon, c_lat),
                                                {"address_id": None, "unit_id": unit_id}))
                if u["name"] and u["category"] in OCCUPANT_UNIT_CATEGORIES:
                    feats["occupant"].append(_feature(uid("occupant", ordinal, di, u["id"]), "occupant", None, {
                        "name": _labels(u["name"], language), "alt_name": None, "category": "unspecified",
                        "anchor_id": anchor_id, "hours": None, "phone": None, "website": None,
                        "validity": None, "correlation_id": None}))
            for ei, e in enumerate(d.get("mapElementList") or []):
                t = e.get("shapeType")
                if t in ("MapDoor", "MapOpening"):
                    a, b = opening_segment(e)
                    if math.dist(a, b) < 1:
                        continue
                    la, lb = ll(a), ll(b)
                    mid = ll(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2))
                    feats["opening"].append(_feature(uid("opening", ordinal, di, ei), "opening", {
                        "type": "LineString", "coordinates": [[_r(la[0]), _r(la[1])], [_r(lb[0]), _r(lb[1])]]}, {
                        "category": "pedestrian", "accessibility": None, "access_control": None, "door": None,
                        "name": None, "alt_name": None, "display_point": _point(*mid), "level_id": level_id}))
                elif t == "MapShelf":
                    ring = [ll(p) for p in shelf_corners(e)]
                    if abs(_signed_area(ring)) < 1e-14:
                        continue
                    c = ll(_centroid(shelf_corners(e)))
                    feats["fixture"].append(_feature(uid("fixture", ordinal, di, ei), "fixture", _polygon(ring), {
                        "category": "furniture", "name": _labels(e.get("code"), language), "alt_name": None,
                        "anchor_id": None, "level_id": level_id, "display_point": _point(*c)}))
        if not level_pts:
            continue
        hull = convex_hull(level_pts)
        all_pts += hull
        hc = _centroid(hull)
        feats["level"].append(_feature(level_id, "level", _polygon(hull), {
            "category": "unspecified", "restriction": None, "ordinal": ordinal, "outdoor": False,
            "name": _labels(level_name, language), "short_name": _labels(level_name, language),
            "display_point": _point(*hc), "address_id": None, "building_ids": [building_id]}))
        feats["unit"] += unit_feats
    if not all_pts:
        raise ValueError("所有楼层都没有单元多边形")

    outline = convex_hull(all_pts)
    oc = _centroid(outline)
    feats["address"].append(_feature(address_id, "address", None, {
        "address": name, "unit": None, "locality": "", "province": None, "country": None,
        "postal_code": None, "postal_code_ext": None, "postal_code_vanity": None}))
    feats["venue"].append(_feature(venue_id, "venue", _polygon(outline), {
        "category": category, "restriction": None, "name": _labels(name, language), "alt_name": None,
        "hours": None, "phone": None, "website": None, "display_point": _point(*oc), "address_id": address_id}))
    feats["building"].append(_feature(building_id, "building", None, {
        "category": "unspecified", "restriction": None, "name": _labels(name, language), "alt_name": None,
        "display_point": _point(*oc), "address_id": address_id}))
    feats["footprint"].append(_feature(uid("footprint"), "footprint", _polygon(outline), {
        "category": "ground", "name": None, "building_ids": [building_id]}))
    return feats


def manifest(language: str = "zh-Hans") -> dict:
    return {"version": "1.0.0", "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generated_by": "indoor_navigatoin imdf_export", "language": language, "extensions": None}


def export(docs: list[dict], out_zip: Path, venue_name: str | None = None, venue_category: str | None = None,
           language: str = "zh-Hans", origin: tuple[float, float] | None = None) -> dict:
    feats = build_features(docs, venue_name, venue_category, language, origin)
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest(language), ensure_ascii=False, indent=1))
        for k in FEATURE_FILES:
            fc = {"type": "FeatureCollection", "name": k, "features": feats[k]}
            z.writestr(f"{k}.geojson", json.dumps(fc, ensure_ascii=False))
    return {k: len(v) for k, v in feats.items()}


def load_docs(paths: list[Path]) -> list[dict]:
    """读 map.json；目录则读里面所有 *.json（跳过 venue.json 等不是地图的文件）。"""
    docs = []
    for p in paths:
        files = sorted(p.rglob("*.json")) if p.is_dir() else [p]
        for f in files:
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(d, dict) and ("units" in d or "floorPolygons" in d):
                docs.append(d)
    return docs


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", type=Path, nargs="+", help="map.json 文件或目录")
    ap.add_argument("-o", "--out", type=Path, required=True, help="输出 .zip")
    ap.add_argument("--name", help="场馆名（默认取 map.json 的 venueName）")
    ap.add_argument("--category", help="IMDF venue category（默认 businesscampus）")
    ap.add_argument("--language", default="zh-Hans")
    ap.add_argument("--origin", help="没有 geoRef 的楼层用的假原点 lon,lat")
    a = ap.parse_args(argv)
    origin = tuple(float(v) for v in a.origin.split(",")) if a.origin else None
    docs = load_docs(a.inputs)
    if not docs:
        raise SystemExit("没找到 map.json")
    counts = export(docs, a.out, a.name, a.category, a.language, origin)
    print(f"{a.out}：" + "，".join(f"{k} {v}" for k, v in counts.items()))


if __name__ == "__main__":
    sys.exit(main())
