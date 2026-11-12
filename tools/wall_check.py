#!/usr/bin/env python3
"""定位记录里激光雷达量到的「身体两侧到墙的距离」和地图对照：通道宽度对不对、定位横向偏了多少。

    python tools/wall_check.py --map map.json 定位记录目录 [更多目录 ...] [--csv 输出.csv]

定位记录目录（mag_*_files）里要有 track.csv（定位结果）和 depth_lateral.csv（App 0.1.25 起带
wall_left_cm / wall_right_cm：从相机水平往左右打射线到 ARKit 认出的竖直平面）。没有墙列时退回
left_cm / right_cm（相机前方视野里最近的东西，常是桌椅，只能参考）。

对每一行：用定位位置和前后 1.5 s 的行进方向，在地图上往左右打射线（地板多边形边、障碍物、墙），
得到「地图上这个位置两侧到墙」的距离，再和实测比：
- 宽度：实测 左+右 和 地图 左+右 比，差很多说明地图上这段通道画宽 / 画窄了（和定位准不准无关）；
- 横向偏差：(左−右)/2 实测和地图比，说明定位点在通道里横向偏到哪边、偏多少。
左右约定按两种都算，取和实测相关性高的那种（地图 y 轴方向不同会让左右对调）。
"""
import argparse
import csv
import json
import math
import os
import sys


def load_map(path):
    m = json.load(open(path))
    r = m.get("data", m)
    segs = []

    def poly(pts):
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            segs.append((a[0], a[1], b[0], b[1]))

    for p in r.get("floorPolygons", []):
        poly([(p[i], p[i + 1]) for i in range(0, len(p) - 1, 2)])
    for p in r.get("obstaclePolygons", []):
        if len(p) >= 6:
            poly([(p[i], p[i + 1]) for i in range(0, len(p) - 1, 2)])
    for e in r.get("mapElementList", []):
        if e.get("shapeType") == "MapWall":
            x, y, w, h = e["x"], e["y"], e["width"], e["height"]
            poly([(x - w / 2, y - h / 2), (x + w / 2, y - h / 2), (x + w / 2, y + h / 2), (x - w / 2, y + h / 2)])
    return segs


def ray(segs, p, d, max_cm=800.0):
    best = None
    for ax, ay, bx, by in segs:
        ex, ey = bx - ax, by - ay
        den = d[0] * ey - d[1] * ex
        if abs(den) < 1e-9:
            continue
        t = ((ax - p[0]) * ey - (ay - p[1]) * ex) / den
        u = ((ax - p[0]) * d[1] - (ay - p[1]) * d[0]) / den
        if t > 1 and 0 <= u <= 1 and (best is None or t < best):
            best = t
    return best if best is not None and best <= max_cm else None


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def median(v):
    s = sorted(v)
    return s[len(s) // 2] if s else float("nan")


def pct(v, q):
    s = sorted(v)
    return s[min(len(s) - 1, int(q / 100 * len(s)))] if s else float("nan")


def corr(a, b):
    n = len(a)
    if n < 3:
        return 0.0
    ma, mb = sum(a) / n, sum(b) / n
    sab = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return sab / (sa * sb) if sa > 0 and sb > 0 else 0.0


def analyse(segs, d):
    track = list(csv.DictReader(open(os.path.join(d, "track.csv"))))
    depth = list(csv.DictReader(open(os.path.join(d, "depth_lateral.csv"))))
    tt = [float(r["t_ms"]) for r in track]
    pos = [(float(r["x_cm"]), float(r["y_cm"])) for r in track]
    has_wall = "wall_left_cm" in (depth[0].keys() if depth else [])
    src = "墙（竖直平面射线）" if has_wall else "前方视野最近物体（旧版，只能参考）"
    rows = []
    import bisect
    for z in depth:
        ml = num(z.get("wall_left_cm")) if has_wall else num(z.get("left_cm"))
        mr = num(z.get("wall_right_cm")) if has_wall else num(z.get("right_cm"))
        if ml is None or mr is None:
            continue
        t = float(z["t_ms"])
        i = bisect.bisect_left(tt, t)
        j = bisect.bisect_left(tt, t - 1500)
        if i < 1 or i >= len(tt):
            continue
        p, q = pos[i], pos[j]
        dx, dy = p[0] - q[0], p[1] - q[1]
        n = math.hypot(dx, dy)
        if n < 60:
            continue                       # 站着不动：方向不可靠
        ux, uy = dx / n, dy / n
        a = ray(segs, p, (uy, -ux))
        b = ray(segs, p, (-uy, ux))
        if a is None or b is None:
            continue
        rows.append((t, ml, mr, a, b, p[0], p[1]))
    name = os.path.basename(os.path.normpath(d))
    if not rows:
        print(f"{name}：没有两侧都量到、又在走动的样本（{src}）")
        return []
    om = [(r[1] - r[2]) / 2 for r in rows]
    c1 = corr(om, [(r[3] - r[4]) / 2 for r in rows])
    c2 = corr(om, [(r[4] - r[3]) / 2 for r in rows])
    sgn = 1 if c1 >= c2 else -1
    out = []
    for r, o in zip(rows, om):
        ml_map, mr_map = (r[3], r[4]) if sgn == 1 else (r[4], r[3])
        out.append(dict(t_ms=int(r[0]), x_cm=round(r[5], 1), y_cm=round(r[6], 1),
                        left_meas=r[1], right_meas=r[2], left_map=round(ml_map, 1), right_map=round(mr_map, 1),
                        width_diff=round(ml_map + mr_map - r[1] - r[2], 1),
                        lateral_err=round((ml_map - mr_map) / 2 - o, 1)))
    wd = [x["width_diff"] for x in out]
    le = [x["lateral_err"] for x in out]
    print(f"{name}：{len(out)} 个样本，实测来源 {src}")
    print(f"  通道宽度 实测 {median([x['left_meas'] + x['right_meas'] for x in out]):.0f} cm，"
          f"地图（定位点处）{median([x['left_map'] + x['right_map'] for x in out]):.0f} cm，"
          f"地图−实测 中位 {median(wd):+.0f}（P10 {pct(wd, 10):+.0f}，P90 {pct(wd, 90):+.0f}）cm")
    print(f"  定位横向偏差（往左为正）中位 {median(le):+.0f} cm，|偏差| 中位 {median([abs(x) for x in le]):.0f}、"
          f"P90 {pct([abs(x) for x in le], 90):.0f} cm（左右约定相关性 {max(c1, c2):.2f}）")
    return [dict(session=name, **x) for x in out]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", required=True)
    ap.add_argument("--csv")
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    segs = load_map(a.map)
    allrows = []
    for d in a.dirs:
        if not os.path.exists(os.path.join(d, "depth_lateral.csv")):
            print(f"{d}：没有 depth_lateral.csv（定位时要打开深度）", file=sys.stderr)
            continue
        allrows += analyse(segs, d)
    if a.csv and allrows:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(allrows[0].keys()), lineterminator="\n")
            w.writeheader()
            w.writerows(allrows)


if __name__ == "__main__":
    main()
