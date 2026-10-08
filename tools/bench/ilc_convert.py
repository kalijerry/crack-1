#!/usr/bin/env python3
"""把 Microsoft Indoor Location Competition 2.0 的一层楼转成我们的会话格式（见 docs/benchmark.md）。

  python3 tools/bench/ilc_convert.py <楼层目录(含 path_data_files/ floor_info.json)> <输出目录>
        [--test-n 15] [--test-min-s 45] [--seed 1] [--drift arkit|pdr|none] [--dilate 2]

输出：
  <out>/map.json            宽高 + floorPolygons（只由「建图 trace 的真值路径」膨胀得到，不看测试 trace）
  <out>/build/<id>/         建图会话：imu/mag_raw/ble/arkit_pose(=真值)/anchors(真值)
  <out>/test/<id>/          测试会话：imu/mag_raw/ble + 合成漂移位姿(arkit_pose) + truth.csv(真值)
  <out>/manifest.json

近似说明：
- 真值 = 稀疏 waypoint 按时间线性插值（人在点之间匀速直走）。
- 测试会话没有 ARKit：位姿 = 真值位移加旋转(随机初始朝向)、尺度误差、朝向随机游走，是合成的，不是真实 PDR。
- 纯标准库，不依赖 numpy。
"""
import argparse, bisect, glob, json, math, os, random, sys


def parse(path):
    d = {k: [] for k in ("acc", "gyr", "mag", "raw", "ble", "wp")}
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
    with open(os.path.join(dst, "imu.csv"), "w") as f:
        f.write("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg\n")
        for t, ax, ay, az in d["acc"]:
            if t < t0 or t > t1 or not d["gyr"] or not d["mag"]:
                continue
            _, gx, gy, gz = hold(d["gyr"], t, gt)
            _, mx, my, mz = hold(d["mag"], t, mt)
            f.write(f"{t},{ax:.4f},{ay:.4f},{az:.4f},{gx:.5f},{gy:.5f},{gz:.5f},{mx:.3f},{my:.3f},{mz:.3f},3,0,0,0,0,-1\n")
    with open(os.path.join(dst, "mag_raw.csv"), "w") as f:
        f.write("t_ms,mx,my,mz\n")
        for t, x, y, z in d["raw"]:
            if t0 <= t <= t1:
                f.write(f"{t},{x:.3f},{y:.3f},{z:.3f}\n")
    with open(os.path.join(dst, "ble.csv"), "w") as f:
        f.write("t_ms,point_id,esl_id,rssi,src,mfg_hex\n")
        for t, mac, rssi in d["ble"]:
            if t0 <= t <= t1:
                f.write(f"{t},,{mac},{rssi:.0f},{mac},\n")
    json.dump({"format_version": 3, "survey": True, "source": "ILC2.0"}, open(os.path.join(dst, "meta.json"), "w"))


def write_poses(dst, poses):
    with open(os.path.join(dst, "arkit_pose.csv"), "w") as f:
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
    return [[a * cell, b * cell, c * cell, b * cell, c * cell, d * cell, a * cell, d * cell] for a, b, c, d in rects]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("floor_dir")
    ap.add_argument("out")
    ap.add_argument("--test-n", type=int, default=15)
    ap.add_argument("--test-min-s", type=float, default=45)
    ap.add_argument("--build-min-s", type=float, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--drift", choices=["arkit", "pdr", "none"], default="arkit")
    ap.add_argument("--dilate", type=int, default=2, help="可走区域在真值路径外膨胀多少米")
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
        with open(os.path.join(dst, "anchors.csv"), "w") as f:
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
        open(os.path.join(dst, "anchors.csv"), "w").write("t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note\n")
        with open(os.path.join(dst, "truth.csv"), "w") as f:
            f.write("t_ms,x_cm,y_cm\n")
            for t, x, y in tr:
                f.write(f"{t},{x:.1f},{y:.1f}\n")

    polys = floor_polygons(pts, w_cm, h_cm, a.dilate)
    json.dump({"width": w_cm, "height": h_cm, "mapElementList": [], "floorPolygons": polys, "floorName": "ILC"},
              open(os.path.join(a.out, "map.json"), "w"))
    json.dump({"build": build_ids, "test": test_ids, "drift": a.drift, "durations_s": {k: round(dur[k], 1) for k in test_ids}},
              open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    print(f"建图 {len(build_ids)} 条，测试 {len(test_ids)} 条，可走矩形 {len(polys)} 个 -> {a.out}")


if __name__ == "__main__":
    sys.exit(main())
