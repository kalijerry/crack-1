#!/usr/bin/env python3
"""把 Microsoft Indoor Location Competition 2.0 的一层楼转成我们的会话格式（见 docs/benchmark.md）。

  python3 tools/bench/ilc_convert.py <楼层目录(含 path_data_files/ floor_info.json)> <输出目录>
        [--test-n 15] [--test-min-s 45] [--seed 1] [--drift arkit|pdr|none]
        [--walkable geojson|paths] [--dilate 2]

输出：
  <out>/map.json            宽高 + floorPolygons：默认来自楼层平面图 geojson_map.json（外轮廓减去店铺等单元，
                            --walkable geojson）；--walkable paths 时只由「建图 trace 的真值路径」膨胀得到（不看测试 trace）
  <out>/build/<id>/         建图会话：imu/mag_raw/ble/wifi/arkit_pose(=真值)/anchors(真值)
  <out>/test/<id>/          测试会话：imu/mag_raw/ble/wifi + 合成漂移位姿(arkit_pose) + truth.csv(真值)
  <out>/manifest.json

近似说明：
- 真值 = 稀疏 waypoint 按时间线性插值（人在点之间匀速直走）。
- 测试会话没有 ARKit：位姿 = 真值位移加旋转(随机初始朝向)、尺度误差、朝向随机游走，是合成的，不是真实 PDR。
- Wi-Fi（wifi.csv，格式见 docs/data-format.md）：原始记录里每条带「扫描结果上报时刻」和「这个 AP 最后一次被看到的时刻」，
  系统会把几十秒前缓存的旧结果混进新一轮扫描里；最后看到的时刻比上报时刻早 WIFI_MAX_AGE_MS 以上的丢掉。
  Wi-Fi 只在 Android 能扫（iOS 第三方 App 拿不到），只给 --wifi 场景用。
- 纯标准库，不依赖 numpy。
"""
import argparse, bisect, glob, json, math, os, random, sys

# Wi-Fi 结果「最后看到」比上报时刻早这么多（ms）就算缓存的旧结果，不要
WIFI_MAX_AGE_MS = 5000


def parse(path):
    d = {k: [] for k in ("acc", "gyr", "mag", "raw", "ble", "wifi", "wp")}
    with open(path, errors="ignore") as f:
        for l in f:
            if l[0] == "#":
                continue
            p = l.rstrip("\n").split("\t")
            if len(p) < 3:
                continue
            try:
                t = int(p[0])
                k = p[1]
                if k == "TYPE_ACCELEROMETER":
                    d["acc"].append((t, float(p[2]), float(p[3]), float(p[4])))
                elif k == "TYPE_GYROSCOPE":
                    d["gyr"].append((t, float(p[2]), float(p[3]), float(p[4])))
                elif k == "TYPE_MAGNETIC_FIELD":
                    d["mag"].append((t, float(p[2]), float(p[3]), float(p[4])))
                elif k == "TYPE_MAGNETIC_FIELD_UNCALIBRATED":
                    d["raw"].append((t, float(p[2]), float(p[3]), float(p[4])))
                elif k == "TYPE_BEACON":
                    d["ble"].append((t, p[8].strip(), float(p[6])))   # MAC, RSSI
                elif k == "TYPE_WIFI":
                    # t  TYPE_WIFI  ssid  bssid  rssi  freq_mhz  last_seen_ms
                    last = int(p[6]) if len(p) > 6 and p[6].strip() else t
                    if t - last <= WIFI_MAX_AGE_MS:
                        d["wifi"].append((t, p[3].strip().lower(), float(p[4]), int(p[5])))
                elif k == "TYPE_WAYPOINT":
                    d["wp"].append((t, float(p[2]) * 100, float(p[3]) * 100))   # m -> cm
            except (ValueError, IndexError):
                continue
    for v in d.values():
        v.sort()
    return d


def hold(series, t, times):
    """取 t 之前最近的一条（没有就取第一条）"""
    i = bisect.bisect_right(times, t) - 1
    return series[max(i, 0)]


def truth_track(wp, hz=30):
    """waypoint 线性插值成 hz 的真值 [(t, x, y)]"""
    out = []
    step = 1000.0 / hz
    for (t0, x0, y0), (t1, x1, y1) in zip(wp, wp[1:]):
        if t1 <= t0:
            continue
        t = t0
        while t < t1:
            f = (t - t0) / (t1 - t0)
            out.append((int(t), x0 + (x1 - x0) * f, y0 + (y1 - y0) * f))
            t += step
    out.append(wp[-1])
    return out


def write_sensors(dst, d, t0, t1):
    os.makedirs(dst, exist_ok=True)
    gt = [x[0] for x in d["gyr"]]
    mt = [x[0] for x in d["mag"]]
    with open(os.path.join(dst, "imu.csv"), "w", newline="\n") as f:
        f.write("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg\n")
        for t, ax, ay, az in d["acc"]:
            if t < t0 or t > t1 or not d["gyr"] or not d["mag"]:
                continue
            _, gx, gy, gz = hold(d["gyr"], t, gt)
            _, mx, my, mz = hold(d["mag"], t, mt)
            f.write(f"{t},{ax:.4f},{ay:.4f},{az:.4f},{gx:.5f},{gy:.5f},{gz:.5f},{mx:.3f},{my:.3f},{mz:.3f},3,0,0,0,0,-1\n")
    with open(os.path.join(dst, "mag_raw.csv"), "w", newline="\n") as f:
        f.write("t_ms,mx,my,mz\n")
        for t, x, y, z in d["raw"]:
            if t0 <= t <= t1:
                f.write(f"{t},{x:.3f},{y:.3f},{z:.3f}\n")
    with open(os.path.join(dst, "ble.csv"), "w", newline="\n") as f:
        f.write("t_ms,point_id,esl_id,rssi,src,mfg_hex\n")
        for t, mac, rssi in d["ble"]:
            if t0 <= t <= t1:
                f.write(f"{t},,{mac},{rssi:.0f},{mac},\n")
    with open(os.path.join(dst, "wifi.csv"), "w", newline="\n") as f:
        f.write("t_ms,bssid,rssi,freq\n")
        for t, bssid, rssi, freq in d["wifi"]:
            if t0 <= t <= t1:
                f.write(f"{t},{bssid},{rssi:.0f},{freq}\n")
    json.dump({"format_version": 3, "survey": True, "source": "ILC2.0"}, open(os.path.join(dst, "meta.json"), "w", newline="\n"))


def write_poses(dst, poses):
    with open(os.path.join(dst, "arkit_pose.csv"), "w", newline="\n") as f:
        f.write("t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n")
        for t, x, y in poses:
            f.write(f"{t},{x / 100:.4f},0,{y / 100:.4f},0,0,0,1,2,0\n")


def drift_poses(truth, rng, scale_sigma, head_sigma_per_sqrt_s):
    """真值位移 -> 带漂移的「ARKit/PDR 位姿」（任意朝向的局部坐标系）"""
    th = rng.uniform(0, 2 * math.pi)
    scale = 1 + rng.gauss(0, scale_sigma)
    x = y = 0.0
    out = [(truth[0][0], x, y)]
    for (t0, a0, b0), (t1, a1, b1) in zip(truth, truth[1:]):
        dt = max(t1 - t0, 1) / 1000
        th += rng.gauss(0, head_sigma_per_sqrt_s) * math.sqrt(dt)
        dx, dy = (a1 - a0) * scale, (b1 - b0) * scale
        x += dx * math.cos(th) - dy * math.sin(th)
        y += dx * math.sin(th) + dy * math.cos(th)
        out.append((t1, x, y))
    return out


def merge_rects(occ, cell):
    """占格（occ[行][列]）-> 横向连续段，上下相同的段合并成矩形（cm，[x0,y0,x1,y0,x1,y1,x0,y1]）"""
    rows = len(occ)
    cols = len(occ[0]) if rows else 0
    rects, open_ = [], {}
    for j in range(rows + 1):
        runs = set()
        if j < rows:
            i = 0
            while i < cols:
                if occ[j][i]:
                    k = i
                    while k + 1 < cols and occ[j][k + 1]:
                        k += 1
                    runs.add((i, k))
                    i = k + 1
                else:
                    i += 1
        for r in list(open_):          # 上一行的段：这一行有同样的段就继续向下延伸，否则收尾
            if r in runs:
                continue
            j0 = open_.pop(r)
            rects.append((r[0], j0, r[1] + 1, j))
        for r in runs:
            open_.setdefault(r, j)
    return [[a * cell, b * cell, c * cell, b * cell, c * cell, d * cell, a * cell, d * cell] for a, b, c, d in sorted(rects)]


def dilate_grid(occ, radius_cells):
    """按格心距离 <= radius_cells 的圆盘膨胀"""
    rows = len(occ)
    cols = len(occ[0]) if rows else 0
    r = int(math.floor(radius_cells))
    offs = [(di, dj) for dj in range(-r, r + 1) for di in range(-r, r + 1)
            if di * di + dj * dj <= radius_cells * radius_cells + 1e-9]
    out = [row[:] for row in occ]
    for j in range(rows):
        for i in range(cols):
            if not occ[j][i]:
                continue
            for di, dj in offs:
                a, b = i + di, j + dj
                if 0 <= a < cols and 0 <= b < rows:
                    out[b][a] = True
    return out


def floor_polygons(points, w_cm, h_cm, dilate, cell=100):
    """真值点占格 -> 膨胀 -> 横向连续段合并成矩形（cm）"""
    cols, rows = int(w_cm // cell) + 1, int(h_cm // cell) + 1
    occ = [[False] * cols for _ in range(rows)]
    for x, y in points:
        i, j = int(x // cell), int(y // cell)
        for dj in range(-dilate, dilate + 1):
            for di in range(-dilate, dilate + 1):
                if di * di + dj * dj <= dilate * dilate + 1 and 0 <= j + dj < rows and 0 <= i + di < cols:
                    occ[j + dj][i + di] = True
    return merge_rects(occ, cell)


# ───────── 楼层平面图（geojson）-> 可走区域 ─────────
# geojson_map.json：一个 properties.type == "floor" 的楼层外轮廓（MultiPolygon），其余 Polygon 是店铺 / 辅助面 /
# 不开放区域等「单元」。可走 = 外轮廓以内、所有单元以外（走廊）。坐标按楼层外轮廓的外包框线性映射到
# [0, width] x [0, height]（m -> cm，y 不翻转；转换时用 waypoint 落在可走区域内的比例核对，写进 manifest）。

def _fill_rings(grid, rings, val, cell):
    """偶奇规则扫描线：格心落在多边形（若干环，cm）内的格子置 val"""
    rows, cols = len(grid), len(grid[0])
    edges = []
    for ring in rings:
        for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
            if y1 != y2:
                edges.append((x1, y1, x2, y2))
    if not edges:
        return
    ys = [e[1] for e in edges] + [e[3] for e in edges]
    j0, j1 = max(0, int(min(ys) / cell) - 1), min(rows - 1, int(max(ys) / cell) + 1)
    for j in range(j0, j1 + 1):
        cy = (j + 0.5) * cell
        xs = sorted(x1 + (cy - y1) * (x2 - x1) / (y2 - y1) for x1, y1, x2, y2 in edges if (y1 > cy) != (y2 > cy))
        for a, b in zip(xs[0::2], xs[1::2]):
            i0 = max(0, int(math.ceil(a / cell - 0.5)))
            i1 = min(cols - 1, int(math.floor(b / cell - 0.5)))
            for i in range(i0, i1 + 1):
                grid[j][i] = val


def geojson_walkable(geo, w_cm, h_cm, cell=50, dilate_cm=75):
    """geojson 平面图 -> (可走占格 occ[行][列], 外轮廓占格)。
    dilate_cm：可走区域向单元里放宽多少（waypoint 之间按直线插值，会切过店铺的角）。"""
    feats = geo["features"]
    floors = [f for f in feats if (f.get("properties") or {}).get("type") == "floor"]
    if not floors:
        raise ValueError("geojson 里没有 properties.type == 'floor' 的楼层外轮廓")
    units = [f for f in feats if f not in floors and f["geometry"]["type"] in ("Polygon", "MultiPolygon")]

    def polys(f):
        g = f["geometry"]
        return [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]

    pts = [p for f in floors for poly in polys(f) for ring in poly for p in ring]
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)

    def to_cm(p):
        return (p[0] - x0) / (x1 - x0) * w_cm, (p[1] - y0) / (y1 - y0) * h_cm

    cols, rows = int(math.ceil(w_cm / cell)), int(math.ceil(h_cm / cell))
    outline = [[False] * cols for _ in range(rows)]
    for f in floors:
        for poly in polys(f):
            _fill_rings(outline, [[to_cm(p) for p in ring] for ring in poly], True, cell)
    occ = [row[:] for row in outline]
    for f in units:
        for poly in polys(f):
            _fill_rings(occ, [[to_cm(p) for p in ring] for ring in poly], False, cell)
    if dilate_cm > 0:
        occ = dilate_grid(occ, dilate_cm / cell)
    return occ, outline


def inside_share(occ, cell, points):
    """点（cm）落在占格里的比例"""
    if not points:
        return 0.0
    rows, cols = len(occ), len(occ[0])
    n = 0
    for x, y in points:
        i, j = int(x // cell), int(y // cell)
        n += 0 <= i < cols and 0 <= j < rows and occ[j][i]
    return n / len(points)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("floor_dir")
    ap.add_argument("out")
    ap.add_argument("--test-n", type=int, default=15)
    ap.add_argument("--test-min-s", type=float, default=45)
    ap.add_argument("--build-min-s", type=float, default=10)
    ap.add_argument("--build-max", type=int, default=0,
                    help="建图最多用几条 trace（随机抽，0 = 全部）：模拟「只走几趟」的稀疏建图")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--drift", choices=["arkit", "pdr", "none"], default="arkit")
    ap.add_argument("--dilate", type=int, default=2, help="--walkable paths：可走区域在真值路径外膨胀多少米")
    ap.add_argument("--walkable", choices=["geojson", "paths"], default=None,
                    help="可走区域来源：geojson = 楼层平面图（外轮廓减去店铺等单元；有 geojson_map.json 时默认）；"
                         "paths = 建图 trace 的真值路径膨胀")
    ap.add_argument("--geo-cell", type=float, default=50, help="--walkable geojson：栅格边长（cm）")
    ap.add_argument("--geo-dilate", type=float, default=75, help="--walkable geojson：可走区域放宽多少（cm）")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    info = json.load(open(os.path.join(a.floor_dir, "floor_info.json")))["map_info"]
    w_cm, h_cm = info["width"] * 100, info["height"] * 100

    traces = {}
    for p in sorted(glob.glob(os.path.join(a.floor_dir, "path_data_files", "*.txt"))):
        d = parse(p)
        if len(d["wp"]) < 2 or len(d["acc"]) < 100:
            continue
        traces[os.path.basename(p)[:-4]] = d
    dur = {k: (d["wp"][-1][0] - d["wp"][0][0]) / 1000 for k, d in traces.items()}
    cand = sorted(k for k in traces if dur[k] >= a.test_min_s)
    rng.shuffle(cand)
    test_ids = sorted(cand[: a.test_n])
    build_ids = sorted(k for k in traces if k not in test_ids and dur[k] >= a.build_min_s)
    if a.build_max > 0 and len(build_ids) > a.build_max:
        build_ids = sorted(random.Random(a.seed + 1).sample(build_ids, a.build_max))

    # 漂移参数：ARKit 约 1% 尺度、慢朝向漂移；PDR 约 4% 尺度、朝向漂移快
    sc, hd = {"arkit": (0.01, math.radians(0.5)), "pdr": (0.04, math.radians(1.5)), "none": (0, 0)}[a.drift]

    pts = []
    for k in build_ids:
        d = traces[k]
        tr = truth_track(d["wp"])
        pts += [(x, y) for _, x, y in tr]
        dst = os.path.join(a.out, "build", k)
        t0, t1 = d["wp"][0][0], d["wp"][-1][0]
        write_sensors(dst, d, t0, t1)
        write_poses(dst, tr)           # 建图会话：位姿直接是真值（地图坐标），锚点 = 全部 waypoint
        with open(os.path.join(dst, "anchors.csv"), "w", newline="\n") as f:
            f.write("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n")
            f.write(f"{t0},align,0,0,0,0,0,\n")
            for i, (t, x, y) in enumerate(d["wp"]):
                f.write(f"{t},{'start' if i == 0 else 'reanchor'},{x:.1f},{y:.1f},{x:.1f},{y:.1f},,\n")
    for k in test_ids:
        d = traces[k]
        tr = truth_track(d["wp"])
        dst = os.path.join(a.out, "test", k)
        t0, t1 = d["wp"][0][0], d["wp"][-1][0]
        write_sensors(dst, d, t0, t1)
        write_poses(dst, drift_poses(tr, rng, sc, hd))
        open(os.path.join(dst, "anchors.csv"), "w", newline="\n").write("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n")
        with open(os.path.join(dst, "truth.csv"), "w", newline="\n") as f:
            f.write("t_ms,x_cm,y_cm\n")
            for t, x, y in tr:
                f.write(f"{t},{x:.1f},{y:.1f}\n")

    geo_path = os.path.join(a.floor_dir, "geojson_map.json")
    walk_src = a.walkable or ("geojson" if os.path.exists(geo_path) else "paths")
    walk_info = {"source": walk_src}
    if walk_src == "geojson":
        occ, outline = geojson_walkable(json.load(open(geo_path, encoding="utf-8")), w_cm, h_cm, a.geo_cell, a.geo_dilate)
        polys = merge_rects(occ, a.geo_cell)
        # 核对坐标映射：全部 trace 的 waypoint、测试真值落在外轮廓 / 可走区域里的比例
        wps = [(x, y) for d in traces.values() for _, x, y in d["wp"]]
        test_pts = [(x, y) for k in test_ids for _, x, y in truth_track(traces[k]["wp"])]
        walk_info.update({
            "waypoints_in_outline": round(inside_share(outline, a.geo_cell, wps), 4),
            "waypoints_in_walkable": round(inside_share(occ, a.geo_cell, wps), 4),
            "test_truth_in_walkable": round(inside_share(occ, a.geo_cell, test_pts), 4),
            "area_m2": round(sum(map(sum, occ)) * a.geo_cell * a.geo_cell / 1e4),
        })
    else:
        polys = floor_polygons(pts, w_cm, h_cm, a.dilate)
    json.dump({"width": w_cm, "height": h_cm, "mapElementList": [], "floorPolygons": polys, "floorName": "ILC"},
              open(os.path.join(a.out, "map.json"), "w", newline="\n"))
    json.dump({"build": build_ids, "test": test_ids, "drift": a.drift, "durations_s": {k: round(dur[k], 1) for k in test_ids},
               "walkable": walk_info},
              open(os.path.join(a.out, "manifest.json"), "w", newline="\n"), indent=1)
    print(f"建图 {len(build_ids)} 条，测试 {len(test_ids)} 条，可走矩形 {len(polys)} 个（{walk_info}）-> {a.out}")


if __name__ == "__main__":
    sys.exit(main())
