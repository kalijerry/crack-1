"""平面地图（cm）↔ WGS84 经纬度的对应关系 `geoRef`。

和 `imdf_convert.py` 输出的 geoRef 同一格式，另外多一个旋转角：

    geoRef = {lon0, lat0, marginCm, mPerDegLon, mPerDegLat, rotationDeg}

换算（地图坐标 +x 向右、+y 向下，单位 cm）：

    dx, dy = (x - marginCm) / 100, (y - marginCm) / 100          # 米
    e = dx·cos r − dy·sin r                                       # 向东（米）
    s = dx·sin r + dy·cos r                                       # 向南（米）
    lon = lon0 + e / mPerDegLon
    lat = lat0 − s / mPerDegLat

r = rotationDeg：地图 +x 轴的方位角是 90° + r（从正北顺时针量）。r = 0 时地图「上」就是正北，
与 imdf_convert 的输出完全一致（它总是正北朝上，不写 rotationDeg）。(lon0, lat0) 是地图点
(marginCm, marginCm) 的经纬度。投影用等距圆柱近似，几百米的场馆误差在厘米级。

Swift 版在 `HPASSKit/Models/GeoRef.swift`，网页版在 `web/map-editor.html`（两点对准），三处公式一致。
"""
from __future__ import annotations

import math

EARTH_R = 6378137.0
M_PER_DEG_LAT = math.pi * EARTH_R / 180


def make(lon0: float, lat0: float, margin_cm: float = 0, rotation_deg: float = 0, lat_ref: float | None = None) -> dict:
    lr = lat0 if lat_ref is None else lat_ref
    return {"lon0": lon0, "lat0": lat0, "marginCm": margin_cm,
            "mPerDegLon": M_PER_DEG_LAT * math.cos(math.radians(lr)), "mPerDegLat": M_PER_DEG_LAT,
            "rotationDeg": rotation_deg}


def to_lonlat(g: dict, x: float, y: float) -> tuple[float, float]:
    m = g.get("marginCm", 0) or 0
    r = math.radians(g.get("rotationDeg", 0) or 0)
    dx, dy = (x - m) / 100, (y - m) / 100
    e = dx * math.cos(r) - dy * math.sin(r)
    s = dx * math.sin(r) + dy * math.cos(r)
    return g["lon0"] + e / g["mPerDegLon"], g["lat0"] - s / g["mPerDegLat"]


def to_map(g: dict, lon: float, lat: float) -> tuple[float, float]:
    m = g.get("marginCm", 0) or 0
    r = math.radians(g.get("rotationDeg", 0) or 0)
    e = (lon - g["lon0"]) * g["mPerDegLon"]
    s = (g["lat0"] - lat) * g["mPerDegLat"]
    dx = e * math.cos(r) + s * math.sin(r)
    dy = -e * math.sin(r) + s * math.cos(r)
    return dx * 100 + m, dy * 100 + m


def _wrap(d: float) -> float:
    while d <= -180:
        d += 360
    while d > 180:
        d -= 360
    return d


def from_anchor(map_x: float, map_y: float, lon: float, lat: float,
                true_heading_deg: float, map_dir_deg: float, margin_cm: float = 0) -> dict:
    """入口处记一次 GPS + 真北朝向，算出 geoRef。

    - (map_x, map_y)：记录时手机在地图上的位置（cm，ARKit 位置经 arAlign 换过来）；
    - true_heading_deg：CLHeading.trueHeading，手机朝向的方位角（从正北顺时针）；
    - map_dir_deg：同一时刻手机朝向在地图里的方向角，atan2(dy, dx)（度，y 向下）。

    地图方向角 α 对应的方位角 = 90 + α + r，所以 r = heading − 90 − α。
    """
    r = _wrap(true_heading_deg - 90 - map_dir_deg)
    g = make(0, 0, margin_cm, r, lat_ref=lat)
    lon0_dummy = to_lonlat({**g, "lon0": 0.0, "lat0": 0.0}, map_x, map_y)
    g["lon0"] = lon - lon0_dummy[0]
    g["lat0"] = lat - lon0_dummy[1]
    return g


def from_two_points(p1: tuple[float, float], ll1: tuple[float, float],
                    p2: tuple[float, float], ll2: tuple[float, float], margin_cm: float = 0) -> tuple[dict, float]:
    """两点对准：地图上两点 p1、p2（cm）分别对应经纬度 ll1、ll2 = (lon, lat)。

    返回 (geoRef, scale)。只解旋转 + 平移（扫描的尺度是激光雷达量的，比 GPS / 底图准）；
    scale = 经纬度距离 / 地图距离，偏离 1 太多（> 5%）说明点选错了。
    """
    g = make(0, 0, margin_cm, 0, lat_ref=(ll1[1] + ll2[1]) / 2)
    e = (ll2[0] - ll1[0]) * g["mPerDegLon"]
    s = (ll1[1] - ll2[1]) * g["mPerDegLat"]
    mx, my = (p2[0] - p1[0]) / 100, (p2[1] - p1[1]) / 100
    dm = math.hypot(mx, my)
    if dm < 1e-6:
        raise ValueError("两个点在地图上重合")
    g["rotationDeg"] = _wrap(math.degrees(math.atan2(s, e) - math.atan2(my, mx)))
    base = to_lonlat({**g, "lon0": 0.0, "lat0": 0.0}, *p1)
    g["lon0"] = ll1[0] - base[0]
    g["lat0"] = ll1[1] - base[1]
    return g, math.hypot(e, s) / dm
