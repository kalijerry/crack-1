#!/usr/bin/env python3
"""
LiDAR 实景核对：用建图采集时扫的网格（mesh.ply），量出走过的通道两边**货架的真实高度**，
以及**地图上的货架位置和实物差多少**。

用法：
    python meshcheck.py --map map.json --sessions 会话1 会话2 ... [--report meshcheck.json]

会话要在 App「建图采集」里打开「LiDAR 实景扫描」录，里面有 mesh.ply、arkit_pose.csv、anchors.csv。

做法：
  1. 网格顶点在 ARKit 世界坐标里。用和 magmap.py 一样的锚点分段对齐，把顶点换到地图坐标；
     每个顶点归到离它最近的轨迹点，用那一刻所在的对齐段（离轨迹超过 3 m 的顶点不用，太远的漂移大）。
  2. 地面高度 = 轨迹附近顶点高度的低分位数。
  3. 对每个离轨迹不远的**标准货架**（Shelf-001…100）：
     - 高度：货架占地范围内顶点高度的 95% 分位；
     - 横向偏移：货架两个长边（面向通道的那两面）附近、离地 0.4～1.6 m 的顶点，
       它们的位置中位数与地图上的长边相比，差多少。两面都看得到时取平均。
  4. 汇总：货架高度中位数、偏移量分布、整体平移（所有货架偏移的加权平均，换成地图 x / y）。

只依赖 Python 3.8+ 标准库。
"""
import argparse
import array
import bisect
import json
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from calibrate import resolve_session_dir  # noqa: E402
from magmap import Pose, build_segments, load_anchors, read_csv, to_map, unwrap  # noqa: E402

MAX_FROM_TRACK_CM = 300.0     # 离轨迹超过这个距离的顶点不用
SHELF_NEAR_TRACK_CM = 600.0   # 离轨迹这么近的货架才分析
MAX_VERTICES = 600_000        # 顶点太多时均匀抽样
MIN_POINTS = 30


# ---------------------------------------------------------------- 读取

def read_ply_vertices(path):
    """二进制小端 PLY，只读顶点（float x, y, z）。返回三个 array('f')。"""
    data = Path(path).read_bytes()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:end].decode("ascii")
    if "binary_little_endian" not in header:
        raise ValueError("只支持 binary_little_endian 的 PLY")
    m = re.search(r"element vertex (\d+)", header)
    n = int(m.group(1)) if m else 0
    a = array.array("f")
    a.frombytes(data[end:end + n * 12])
    if sys.byteorder != "little":
        a.byteswap()
    return a[0::3], a[1::3], a[2::3]


def standard_shelves(map_path):
    """标准货架（与 App 的 ShelfClassifier 一致），换算成中心 + 旋转。"""
    root = unwrap(json.loads(Path(map_path).read_text(encoding="utf-8")))
    out = []
    for e in root.get("mapElementList", []):
        if e.get("shapeType") != "MapShelf":
            continue
        code = e.get("code", "")
        parts = code.split("-")
        if code.lower().startswith("virtual") or len(parts) < 2 or parts[0] != "Shelf" or not parts[1].isdigit():
            continue
        n = int(parts[1])
        if not (1 <= n <= 100) or (n < 10 and len(parts[1]) < 3):
            continue
        w, h, r = float(e["width"]), float(e["height"]), math.radians(float(e.get("rotation") or 0))
        c, s = math.cos(r), math.sin(r)
        cx = float(e["x"]) + c * w / 2 - s * h / 2          # (x, y) 是左上角，旋转绕左上角
        cy = float(e["y"]) + s * w / 2 + c * h / 2
        out.append({"code": code, "cx": cx, "cy": cy, "w": w, "h": h, "c": c, "s": s})
    return out


# ---------------------------------------------------------------- 顶点 → 地图

class TrackIndex:
    """轨迹点（ARKit 平面坐标 cm）的格子索引，用来给顶点找最近的轨迹时刻。"""

    def __init__(self, pose, cell=100.0):
        self.cell = cell
        self.grid = {}
        for i in range(0, len(pose.t), 3):
            if pose.state[i] != 2:
                continue
            k = (int(pose.x[i] // cell), int(pose.z[i] // cell))
            self.grid.setdefault(k, []).append(i)
        self.pose = pose

    def nearest(self, x, z, maxd):
        r = int(math.ceil(maxd / self.cell))
        kx, kz = int(x // self.cell), int(z // self.cell)
        best, bd = None, maxd * maxd
        for dx in range(-r, r + 1):
            for dz in range(-r, r + 1):
                for i in self.grid.get((kx + dx, kz + dz), ()):
                    d = (self.pose.x[i] - x) ** 2 + (self.pose.z[i] - z) ** 2
                    if d < bd:
                        best, bd = i, d
        return best


def session_points(dir_, rep):
    """一个会话 → [(地图 x cm, 地图 y cm, 离地高度 m)]，以及地图坐标下的轨迹点。"""
    if not (dir_ / "mesh.ply").exists():
        rep["warnings"].append("没有 mesh.ply（建图时没打开 LiDAR 实景扫描）")
        return [], []
    pose = Pose(read_csv(dir_ / "arkit_pose.csv"))
    anchors = load_anchors(dir_ / "anchors.csv")
    segs = [s for s in build_segments(anchors, pose, rep) if "bad" not in s]
    if not segs:
        rep["warnings"].append("没有可用的对齐段（至少要有起点锚点和朝向）")
        return [], []
    starts = [s["t0"] for s in segs]

    def seg_at(t):
        i = max(bisect.bisect_right(starts, t) - 1, 0)
        s = segs[i]
        return s if t <= s["t1"] or s["tail"] else None

    xs, ys, zs = read_ply_vertices(dir_ / "mesh.ply")
    n = len(xs)
    step = max(1, n // MAX_VERTICES)
    idx = TrackIndex(pose)
    raw = []
    for i in range(0, n, step):
        ax, az = xs[i] * 100, zs[i] * 100
        j = idx.nearest(ax, az, MAX_FROM_TRACK_CM)
        if j is None:
            continue
        t = pose.t[j]
        s = seg_at(t)
        if not s:
            continue
        mx, my = to_map(s, (ax, az), t)
        raw.append((mx, my, ys[i]))
    if not raw:
        return [], []
    hs = sorted(p[2] for p in raw)
    floor = hs[len(hs) // 50]                                  # 2% 分位当地面
    rep["vertices_total"] = n
    rep["vertices_used"] = len(raw)
    rep["floor_ar_y_m"] = round(floor, 3)
    track = []
    for j in range(0, len(pose.t), 15):
        s = seg_at(pose.t[j])
        if s and pose.state[j] == 2:
            track.append(to_map(s, (pose.x[j], pose.z[j]), pose.t[j]))
    return [(x, y, z - floor) for x, y, z in raw], track


# ---------------------------------------------------------------- 货架分析

def analyze(shelves, points, track):
    # 顶点按 1 m 格子分桶
    buckets = {}
    for x, y, h in points:
        buckets.setdefault((int(x // 100), int(y // 100)), []).append((x, y, h))

    def near_track(cx, cy):
        return any((tx - cx) ** 2 + (ty - cy) ** 2 <= SHELF_NEAR_TRACK_CM ** 2 for tx, ty in track[::2])

    out = []
    for sh in shelves:
        if not near_track(sh["cx"], sh["cy"]):
            continue
        ext = max(sh["w"], sh["h"]) / 2 + 80
        pts = []
        for bx in range(int((sh["cx"] - ext) // 100), int((sh["cx"] + ext) // 100) + 1):
            for by in range(int((sh["cy"] - ext) // 100), int((sh["cy"] + ext) // 100) + 1):
                pts.extend(buckets.get((bx, by), ()))
        if len(pts) < MIN_POINTS:
            continue
        c, s = sh["c"], sh["s"]
        hw, hh = sh["w"] / 2, sh["h"] / 2
        local = []
        for x, y, h in pts:
            dx, dy = x - sh["cx"], y - sh["cy"]
            local.append((dx * c + dy * s, -dx * s + dy * c, h))   # u 沿 width，v 沿 height
        inside = [h for u, v, h in local if abs(u) <= hw and abs(v) <= hh and 0.2 <= h <= 3.5]
        top = sorted(inside)[int(len(inside) * 0.95)] if len(inside) >= MIN_POINTS else None
        # 长边：短轴方向上的两个面
        long_is_u = sh["w"] >= sh["h"]
        half_long, half_short = (hw, hh) if long_is_u else (hh, hw)
        sides = {}
        for sign in (1, -1):
            vals = []
            for u, v, h in local:
                along, across = (u, v) if long_is_u else (v, u)
                if abs(along) > half_long - 10 or not (0.4 <= h <= 1.6):
                    continue
                d = sign * across - half_short              # 面外为正
                if -40 <= d <= 80:
                    vals.append(d)
            if len(vals) >= MIN_POINTS:
                sides[sign] = statistics.median(vals)
        shift = None
        if sides:
            # 正面看到的偏移 d+ 表示货架往 +短轴 方向挪了 d+；负面看到的 d- 表示往 −短轴 方向挪了 d-
            est = [(sides[1] if 1 in sides else None), (-sides[-1] if -1 in sides else None)]
            est = [e for e in est if e is not None]
            shift = sum(est) / len(est)
        if top is None and shift is None:
            continue
        # 短轴单位向量（地图坐标）
        ax_x, ax_y = ((-s, c) if long_is_u else (c, s))
        out.append({
            "code": sh["code"], "points": len(local),
            "top_height_m": round(top, 2) if top is not None else None,
            "shift_cm": round(shift, 1) if shift is not None else None,
            "shift_xy_cm": [round(shift * ax_x, 1), round(shift * ax_y, 1)] if shift is not None else None,
            "faces_seen": len(sides),
        })
    return out


def summarize(results):
    heights = [r["top_height_m"] for r in results if r["top_height_m"] is not None]
    shifts = [r for r in results if r["shift_cm"] is not None]
    summ = {"shelves_analyzed": len(results)}
    if heights:
        summ["height_median_m"] = round(statistics.median(heights), 2)
        summ["height_p10_p90_m"] = [round(sorted(heights)[len(heights) // 10], 2),
                                    round(sorted(heights)[len(heights) * 9 // 10], 2)]
    if shifts:
        mags = sorted(abs(r["shift_cm"]) for r in shifts)
        summ["shift_abs_median_cm"] = round(statistics.median(mags), 1)
        summ["shift_abs_p90_cm"] = round(mags[int(len(mags) * 0.9)], 1)
        summ["mean_shift_xy_cm"] = [round(statistics.fmean(r["shift_xy_cm"][0] for r in shifts), 1),
                                    round(statistics.fmean(r["shift_xy_cm"][1] for r in shifts), 1)]
        summ["largest"] = sorted(shifts, key=lambda r: -abs(r["shift_cm"]))[:10]
    return summ


def run(map_path, session_paths, report_path=None):
    shelves = standard_shelves(map_path)
    report = {"sessions": [], "shelves": []}
    allpts, alltrack = [], []
    for sp in session_paths:
        d = resolve_session_dir(Path(sp))
        rep = {"name": d.name, "warnings": []}
        pts, tr = session_points(d, rep)
        report["sessions"].append(rep)
        allpts += pts
        alltrack += tr
    res = analyze(shelves, allpts, alltrack) if allpts else []
    report["shelves"] = res
    report["summary"] = summarize(res)
    if report_path:
        Path(report_path).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def print_report(rep):
    for s in rep["sessions"]:
        print(f"会话 {s['name']}：网格顶点 {s.get('vertices_total', 0)}，用到 {s.get('vertices_used', 0)}，"
              f"地面 ARKit y = {s.get('floor_ar_y_m')} m")
        for w in s["warnings"]:
            print(f"  ! {w}")
    sm = rep["summary"]
    print(f"\n分析了 {sm['shelves_analyzed']} 个标准货架")
    if "height_median_m" in sm:
        print(f"货架高度：中位 {sm['height_median_m']} m（10%～90%：{sm['height_p10_p90_m'][0]}～{sm['height_p10_p90_m'][1]} m）"
              "  → 可以填进 App 的「3D 货架高度」")
    if "shift_abs_median_cm" in sm:
        print(f"地图货架位置与实物的横向偏差：中位 {sm['shift_abs_median_cm']} cm，P90 {sm['shift_abs_p90_cm']} cm")
        print(f"整体平均偏移（地图 x, y）：{sm['mean_shift_xy_cm']} cm  ← 如果明显不为 0，说明地图整体偏了")
        print("偏差最大的货架：")
        for r in sm["largest"]:
            print(f"  {r['code']:16s} 偏 {r['shift_cm']:6.1f} cm  (x {r['shift_xy_cm'][0]}, y {r['shift_xy_cm'][1]})  "
                  f"看到 {r['faces_seen']} 面  高 {r['top_height_m']} m")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", required=True)
    ap.add_argument("--sessions", nargs="+", required=True)
    ap.add_argument("--report", type=Path)
    a = ap.parse_args()
    print_report(run(a.map, a.sessions, a.report))


if __name__ == "__main__":
    main()
