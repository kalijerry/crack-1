#!/usr/bin/env python3
"""
建磁场图：把「建图采集」录下的会话（ARKit 位姿 + 路口锚点 + 全部传感器）变成地磁场地图。

用法：
    python magmap.py --map map.json --sessions 会话1 会话2 ... --out magmap.json
                     [--points 已有点位的地图.json] [--cell 50] [--report 报告.json]

输出的 magmap.json 可以直接导入 App「地磁定位」页：含 width、height、markPoints、magField。
App 里的「门店数据」页仍然导入原来的 map.json（货架和通道）。

做了什么：
  1. 用锚点（App 里长按地图记下的已知位置）把 ARKit 轨迹分段对齐到地图坐标：
     相邻两个锚点之间做「旋转 + 平移」，再把终点残差按时间线性摊回去（吸收漂移）。
  2. 丢掉 ARKit 跟踪受限的片段、站着不动的片段、iOS 磁力计重新校准前后 2 秒。
  3. 取与朝向无关的三个特征 |B|、Bz、Bh，按 cell 厘米的方格累积均值和标准差，缺的格子用周围插值。
  4. 出质检报告：每个会话的锚点和对齐质量、每条通道的覆盖、最容易认错的平行通道对。

只依赖 Python 3.8+ 标准库。数据格式见 docs/data-format.md。
"""
import argparse
import bisect
import csv
import json
import math
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from calibrate import read_csv, resolve_session_dir  # noqa: E402
from mag_feasibility import calibration_jumps, compute_features, load_imu  # noqa: E402

MIN_SAMPLES = 5            # 一个格子至少要有这么多样本才算「有数据」
FILL_RADIUS_CM = 150.0     # 补格子时只看这个半径内的有效格
MIN_SPEED_CM_S = 30.0      # 走得比这慢的样本不要（站着会在一个格子里堆很多重复样本）
MIN_ANCHOR_GAP_CM = 500.0  # 两个锚点相距小于这个值，不用它们拟合旋转
SCALE_RANGE = (0.9, 1.1)   # 锚点间距 / ARKit 位移 超出这个范围，说明锚点点错了或跟踪出了问题
TAIL_MAX_CM = 3000.0       # 最后一个锚点之后最多沿用多远（超过的丢掉）
JUMP_GUARD_S = 2           # 校准跳变前后丢掉多少秒
TRUTH_KINDS = ("start", "reanchor")   # heading / end 记的是当时的估计位置，不是真值


# ---------------------------------------------------------------- 地图

def unwrap(obj):
    """与 App 一致：去掉 {code, message, success, data} 信封，data 可能是 JSON 字符串。"""
    if isinstance(obj, str):
        obj = json.loads(obj)
    if isinstance(obj, dict) and "data" in obj and any(k in obj for k in ("success", "code", "message")):
        obj = obj["data"]
        if isinstance(obj, str):
            obj = json.loads(obj)
    return obj


def load_map(path):
    root = unwrap(json.loads(Path(path).read_text(encoding="utf-8")))
    crosses = []
    for e in root.get("mapElementList", []):
        if e.get("shapeType") == "MapCross" and len(e.get("points", [])) >= 4:
            x1, y1, x2, y2 = (float(v) for v in e["points"][:4])
            crosses.append({"a": (x1, y1), "b": (x2, y2), "w": float(e.get("lineWidth") or 140), "code": e.get("code", "")})
    return float(root["width"]), float(root["height"]), crosses


# ---------------------------------------------------------------- 会话读取与对齐

class Pose:
    """ARKit 位姿序列（平面位置 cm + 跟踪状态），支持按时间插值。"""

    def __init__(self, rows):
        self.t = [int(r["t_ms"]) for r in rows]
        self.x = [float(r["x_m"]) * 100 for r in rows]
        self.z = [float(r["z_m"]) * 100 for r in rows]
        self.state = [int(r["tracking"]) for r in rows]

    def at(self, t):
        """返回 (x, z, 状态是否正常)；时间超出范围或相邻位姿间隔太大返回 None。"""
        i = bisect.bisect_left(self.t, t)
        if i <= 0 or i >= len(self.t):
            return None
        t0, t1 = self.t[i - 1], self.t[i]
        if t1 - t0 > 200:
            return None
        f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
        ok = self.state[i - 1] == 2 and self.state[i] == 2
        return self.x[i - 1] + f * (self.x[i] - self.x[i - 1]), self.z[i - 1] + f * (self.z[i] - self.z[i - 1]), ok


def rot(v, phi):
    c, s = math.cos(phi), math.sin(phi)
    return v[0] * c - v[1] * s, v[0] * s + v[1] * c


def initial_phi(anchors, pose):
    """首段旋转：用 heading 锚点的设定朝向 + 之后走出 1.5 m 的位移方向（与 App 里的对齐方式相同）。"""
    for a in anchors:
        if a["kind"] != "heading" or a["heading"] is None:
            continue
        p0 = pose.at(a["t"])
        if not p0:
            continue
        i = bisect.bisect_left(pose.t, a["t"])
        for k in range(i, len(pose.t)):
            d = (pose.x[k] - p0[0], pose.z[k] - p0[1])
            if math.hypot(*d) >= 150:
                hm = (math.sin(a["heading"]), math.cos(a["heading"]))
                return math.atan2(hm[1], hm[0]) - math.atan2(d[1], d[0])
    return None


def load_anchors(path):
    out = []
    for r in read_csv(path):
        out.append({
            "t": int(r["t_ms"]), "kind": r["kind"],
            "p": (float(r["map_x_cm"]), float(r["map_y_cm"])),
            "a": (float(r["ar_x_cm"]), float(r["ar_z_cm"])),
            "heading": float(r["heading_rad"]) if r.get("heading_rad") else None,
            "note": r.get("note", ""),
        })
    out.sort(key=lambda a: a["t"])
    return out


def build_segments(anchors, pose, report):
    """
    返回对齐段列表。每段：t0, t1, 起点锚（map p、ar a）、旋转 phi、终点残差修正 (dx, dy)、是否尾段。
    """
    truth = [a for a in anchors if a["kind"] in TRUTH_KINDS]
    segs = []
    if not truth:
        report["warnings"].append("没有 start / reanchor 锚点，无法对齐")
        return segs
    phi_prev = initial_phi(anchors, pose)
    for i, a in enumerate(truth):
        nxt = truth[i + 1] if i + 1 < len(truth) else None
        seg = {"t0": a["t"], "p": a["p"], "a": a["a"], "tail": nxt is None}
        if nxt:
            dm = (nxt["p"][0] - a["p"][0], nxt["p"][1] - a["p"][1])
            da = (nxt["a"][0] - a["a"][0], nxt["a"][1] - a["a"][1])
            gap, ar_len = math.hypot(*dm), math.hypot(*da)
            seg["t1"] = nxt["t"]
            phi = phi_prev
            scale = None
            if gap >= MIN_ANCHOR_GAP_CM and ar_len > 1:
                scale = gap / ar_len
                if SCALE_RANGE[0] <= scale <= SCALE_RANGE[1]:
                    phi = math.atan2(dm[1], dm[0]) - math.atan2(da[1], da[0])
                else:
                    seg["bad"] = f"锚点间距 {gap:.0f} cm 与 ARKit 位移 {ar_len:.0f} cm 之比 {scale:.2f} 超出范围"
            if phi is None:
                seg["bad"] = "没有可用的旋转（锚点太近，也没有 heading 锚点）"
                phi = 0.0
            seg["phi"] = phi
            # 终点残差：按此旋转推到终点，与真值之差，之后按时间线性摊回去
            end = rot((da[0], da[1]), phi)
            seg["resid"] = (dm[0] - end[0], dm[1] - end[1])
            seg["scale"] = scale
            seg["len_cm"] = gap
            if "bad" not in seg:
                phi_prev = phi
        else:
            seg["t1"] = pose.t[-1] if pose.t else a["t"]
            seg["phi"] = phi_prev if phi_prev is not None else None
            seg["resid"] = (0.0, 0.0)
            if seg["phi"] is None:
                seg["bad"] = "最后一段没有可用的旋转"
        segs.append(seg)
    return segs


def to_map(seg, pose_xy, t):
    d = (pose_xy[0] - seg["a"][0], pose_xy[1] - seg["a"][1])
    r = rot(d, seg["phi"])
    f = 0.0
    if not seg["tail"] and seg["t1"] > seg["t0"]:
        f = min(max((t - seg["t0"]) / (seg["t1"] - seg["t0"]), 0.0), 1.0)
    return (seg["p"][0] + r[0] + f * seg["resid"][0], seg["p"][1] + r[1] + f * seg["resid"][1])


def session_samples(dir_, report_sessions):
    """一个会话 → [(x_cm, y_cm, |B|, Bz, Bh)]。"""
    rep = {"name": dir_.name, "segments": [], "warnings": [], "samples": 0, "dropped": {}}
    report_sessions.append(rep)
    for f in ("arkit_pose.csv", "anchors.csv", "imu.csv"):
        if not (dir_ / f).exists():
            rep["warnings"].append(f"缺少 {f}，跳过这个会话")
            return []
    pose = Pose(read_csv(dir_ / "arkit_pose.csv"))
    anchors = load_anchors(dir_ / "anchors.csv")
    segs = build_segments(anchors, pose, rep)
    t, acc, mag, _ = load_imu(dir_)
    feats = compute_features(t, acc, mag)
    jumps = calibration_jumps(dir_)
    bad_secs = set()
    if jumps:
        for j in jumps["jumps"]:
            bad_secs.update(range(j["t_s"] - JUMP_GUARD_S, j["t_s"] + JUMP_GUARD_S + 1))
    rep["calibration_jumps"] = len(jumps["jumps"]) if jumps else None

    for s in segs:
        rep["segments"].append({
            "from_ms": s["t0"], "to_ms": s["t1"], "tail": s["tail"],
            "length_m": round(s.get("len_cm", 0) / 100, 1),
            "scale": round(s["scale"], 3) if s.get("scale") else None,
            "rotation_deg": round(math.degrees(s["phi"]), 1) if s.get("phi") is not None else None,
            "residual_cm": round(math.hypot(*s["resid"])),
            "bad": s.get("bad"),
        })

    out = []
    drop = rep["dropped"]
    seg_i = 0
    prev = None
    for ti, f in zip(t, feats):
        while seg_i < len(segs) - 1 and ti >= segs[seg_i + 1]["t0"]:
            seg_i += 1
        if not segs or ti < segs[0]["t0"]:
            continue
        seg = segs[seg_i]
        if ti > seg["t1"] or "bad" in seg:
            drop["段无效或在最后一个锚点之后"] = drop.get("段无效或在最后一个锚点之后", 0) + 1
            continue
        if ti // 1000 in bad_secs:
            drop["校准跳变附近"] = drop.get("校准跳变附近", 0) + 1
            continue
        p = pose.at(ti)
        if not p:
            drop["没有 ARKit 位姿"] = drop.get("没有 ARKit 位姿", 0) + 1
            continue
        if not p[2]:
            drop["ARKit 跟踪受限"] = drop.get("ARKit 跟踪受限", 0) + 1
            continue
        xy = to_map(seg, (p[0], p[1]), ti)
        if seg["tail"]:
            a0 = seg["a"]
            if math.hypot(p[0] - a0[0], p[1] - a0[1]) > TAIL_MAX_CM:
                drop["超出最后锚点太远"] = drop.get("超出最后锚点太远", 0) + 1
                continue
        # 速度：与 0.5 s 前的位置比
        q = pose.at(ti - 500)
        if q and math.hypot(p[0] - q[0], p[1] - q[1]) / 0.5 < MIN_SPEED_CM_S:
            drop["站着不动"] = drop.get("站着不动", 0) + 1
            continue
        out.append((xy[0], xy[1], f[0], f[1], f[2]))
    rep["samples"] = len(out)
    return out


# ---------------------------------------------------------------- 栅格化

class Grid:
    def __init__(self, width, height, cell):
        self.w, self.h, self.cell = width, height, cell
        self.cols, self.rows = math.ceil(width / cell), math.ceil(height / cell)
        n = self.cols * self.rows
        self.n = [0] * n
        self.mean = [[0.0, 0.0, 0.0] for _ in range(n)]
        self.m2 = [[0.0, 0.0, 0.0] for _ in range(n)]

    def add(self, x, y, f):
        if not (0 <= x <= self.w and 0 <= y <= self.h):
            return False
        i, j = min(int(x / self.cell), self.cols - 1), min(int(y / self.cell), self.rows - 1)
        k = j * self.cols + i
        self.n[k] += 1
        for c in range(3):
            d = f[c] - self.mean[k][c]
            self.mean[k][c] += d / self.n[k]
            self.m2[k][c] += d * (f[c] - self.mean[k][c])
        return True

    def build(self, min_samples=MIN_SAMPLES, fill_radius=FILL_RADIUS_CM, sigma_floor=0.5):
        """返回 (cells, sigmas)：每格 [|B|, Bz, Bh] 或 None。样本不足的格子用周围有效格反距离加权补齐。"""
        cells = [None] * len(self.n)
        sigmas = [None] * len(self.n)
        for k, n in enumerate(self.n):
            if n >= min_samples:
                cells[k] = list(self.mean[k])
                sigmas[k] = [max(math.sqrt(self.m2[k][c] / (n - 1)) if n > 1 else 0.0, sigma_floor) for c in range(3)]
        reach = math.ceil(fill_radius / self.cell)
        orig, orig_s = list(cells), list(sigmas)
        for j in range(self.rows):
            for i in range(self.cols):
                if orig[j * self.cols + i] is not None:
                    continue
                wsum, m, s = 0.0, [0.0] * 3, [0.0] * 3
                for dj in range(-reach, reach + 1):
                    for di in range(-reach, reach + 1):
                        ii, jj = i + di, j + dj
                        if not (0 <= ii < self.cols and 0 <= jj < self.rows):
                            continue
                        v = orig[jj * self.cols + ii]
                        if v is None:
                            continue
                        d = math.hypot(di, dj) * self.cell
                        if d <= 0 or d > fill_radius:
                            continue
                        w = 1 / (d * d)
                        for c in range(3):
                            m[c] += v[c] * w
                            s[c] += orig_s[jj * self.cols + ii][c] * w
                        wsum += w
                if wsum > 0:
                    cells[j * self.cols + i] = [x / wsum for x in m]
                    sigmas[j * self.cols + i] = [1.5 * x / wsum for x in s]
        return cells, sigmas


# ---------------------------------------------------------------- 质检

def corridor_coverage(grid, crosses):
    """每条通道：沿中心线每 50 cm 取一点，看所在格子是否有「真实样本」（不含补齐）。"""
    out = []
    for c in crosses:
        (x1, y1), (x2, y2) = c["a"], c["b"]
        L = math.hypot(x2 - x1, y2 - y1)
        n = max(int(L / 50), 1)
        hit = 0
        ux, uy = ((y1 - y2) / L, (x2 - x1) / L) if L > 0 else (0.0, 0.0)   # 通道横向单位向量
        for s in range(n + 1):
            x, y = x1 + (x2 - x1) * s / n, y1 + (y2 - y1) * s / n
            # 走线可能正好压在格子边界上，把样本分到相邻两格，所以横向 ±1 格都看
            for off in (0.0, -grid.cell, grid.cell):
                qx, qy = x + ux * off, y + uy * off
                if 0 <= qx < grid.w and 0 <= qy < grid.h:
                    k = int(qy / grid.cell) * grid.cols + int(qx / grid.cell)
                    if grid.n[k] >= MIN_SAMPLES:
                        hit += 1
                        break
        out.append({"code": c["code"], "length_m": round(L / 100, 1), "coverage": round(hit / (n + 1), 3)})
    return out


def discriminability(grid, cells, sigmas, crosses, window_m=10.0, min_len_m=20.0, max_pairs=400):
    """
    相似度最高的平行通道对：沿中心线取特征序列，比较 window_m 米的窗口，
    返回的 score 是 z 归一化后的最小均方根差，越小越容易认错。
    """
    seqs = []
    for idx, c in enumerate(crosses):
        (x1, y1), (x2, y2) = c["a"], c["b"]
        L = math.hypot(x2 - x1, y2 - y1)
        if L < min_len_m * 100:
            continue
        n = int(L / 50)
        seq = []
        for s in range(n + 1):
            x, y = x1 + (x2 - x1) * s / n, y1 + (y2 - y1) * s / n
            i, j = min(int(x / grid.cell), grid.cols - 1), min(int(y / grid.cell), grid.rows - 1)
            v = cells[j * grid.cols + i]
            if v is None:
                seq = None
                break
            seq.append(v)
        if seq:
            seqs.append((idx, math.atan2(y2 - y1, x2 - x1) % math.pi, L, seq))
    allv = [v for _, _, _, s in seqs for v in s]
    if len(allv) < 10:
        return []
    scale = [statistics.pstdev([v[c] for v in allv]) or 1.0 for c in range(3)]
    W = int(window_m * 100 / 50)
    pairs = []
    for a in range(len(seqs)):
        for b in range(a + 1, len(seqs)):
            ia, ang_a, La, sa = seqs[a]
            ib, ang_b, Lb, sb = seqs[b]
            dang = abs(ang_a - ang_b)
            if min(dang, math.pi - dang) > math.radians(10) or abs(La - Lb) / max(La, Lb) > 0.1:
                continue
            pairs.append((a, b))
    pairs = pairs[:max_pairs]
    out = []
    for a, b in pairs:
        ia, _, _, sa = seqs[a]
        ib, _, _, sb = seqs[b]
        best = None
        for i in range(0, len(sa) - W + 1, 2):
            wa = [sa[i + k][c] / scale[c] for k in range(W) for c in range(3)]
            for seq in (sb, sb[::-1]):
                for j in range(0, len(seq) - W + 1, 2):
                    wb = [seq[j + k][c] / scale[c] for k in range(W) for c in range(3)]
                    d = math.sqrt(sum((x - y) ** 2 for x, y in zip(wa, wb)) / len(wa))
                    if best is None or d < best:
                        best = d
        if best is not None:
            out.append({"a": crosses[ia]["code"] or ia, "b": crosses[ib]["code"] or ib, "score": round(best, 3)})
    out.sort(key=lambda r: r["score"])
    return out


# ---------------------------------------------------------------- 主流程

def run(map_path, session_paths, out_path=None, cell=50.0, points_path=None, report_path=None, do_disc=True):
    width, height, crosses = load_map(map_path)
    grid = Grid(width, height, cell)
    report = {"map": {"width_cm": width, "height_cm": height, "crosses": len(crosses)}, "sessions": [], "warnings": []}
    for sp in session_paths:
        d = resolve_session_dir(Path(sp))
        for x, y, b, bz, bh in session_samples(d, report["sessions"]):
            grid.add(x, y, (b, bz, bh))
    total = sum(grid.n)
    cells, sigmas = grid.build()
    valid = sum(1 for n in grid.n if n >= MIN_SAMPLES)
    report["field"] = {"samples": total, "valid_cells": valid, "filled_cells": sum(c is not None for c in cells),
                       "total_cells": len(cells), "cell_cm": cell}
    cov = corridor_coverage(grid, crosses)
    report["corridors"] = {
        "count": len(cov),
        "covered_ge_90": sum(c["coverage"] >= 0.9 for c in cov),
        "covered_lt_25": sum(c["coverage"] < 0.25 for c in cov),
        "worst": sorted(cov, key=lambda c: c["coverage"])[:15],
    }
    if do_disc and total > 0:
        report["similar_pairs"] = discriminability(grid, cells, sigmas, crosses)[:15]

    markpoints = []
    if points_path:
        root = unwrap(json.loads(Path(points_path).read_text(encoding="utf-8")))
        markpoints = root.get("markPoints", [])
    r3 = lambda v: [round(x, 2) for x in v] if v else None  # noqa: E731
    out = {
        "mapId": 1, "floorId": 1, "floorName": "地磁地图",
        "width": width, "height": height, "mapElementList": [], "markPoints": markpoints,
        "magField": {"cellCm": cell, "cols": grid.cols, "rows": grid.rows,
                     "cells": [r3(c) for c in cells], "sigma": [r3(s) for s in sigmas], "counts": grid.n},
    }
    if out_path:
        Path(out_path).write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    if report_path:
        Path(report_path).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report, out


def print_report(rep):
    f = rep["field"]
    print(f"地图 {rep['map']['width_cm'] / 100:.0f} × {rep['map']['height_cm'] / 100:.0f} m，{rep['map']['crosses']} 条通道")
    for s in rep["sessions"]:
        print(f"\n会话 {s['name']}：用到 {s['samples']} 个样本，校准跳变 {s.get('calibration_jumps')}")
        for w in s["warnings"]:
            print(f"  ! {w}")
        for g in s["segments"]:
            flag = f"  【无效：{g['bad']}】" if g["bad"] else ""
            print(f"  段 {g['length_m']:>5} m  比例 {g['scale']}  旋转 {g['rotation_deg']}°  终点残差 {g['residual_cm']} cm"
                  f"{'（尾段）' if g['tail'] else ''}{flag}")
        if s["dropped"]:
            print("  丢弃：" + "，".join(f"{k} {v}" for k, v in s["dropped"].items()))
    print(f"\n磁场图：{f['samples']} 个样本，有效格 {f['valid_cells']} / {f['total_cells']}，补齐后 {f['filled_cells']}")
    c = rep["corridors"]
    print(f"通道覆盖：{c['count']} 条，≥90% 的 {c['covered_ge_90']} 条，<25% 的 {c['covered_lt_25']} 条")
    for w in c["worst"][:8]:
        print(f"  覆盖最差 {w['code'] or '-'}  长 {w['length_m']} m  覆盖 {w['coverage']:.0%}")
    if rep.get("similar_pairs"):
        print("\n最容易认错的平行通道对（分数越小越像，10 m 窗口）：")
        for p in rep["similar_pairs"][:8]:
            print(f"  {p['a']} ↔ {p['b']}  {p['score']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", required=True, help="门店地图 JSON（货架和通道，可带信封）")
    ap.add_argument("--sessions", nargs="+", required=True, help="建图采集的会话目录或 zip")
    ap.add_argument("--out", required=True, type=Path, help="输出的 magmap.json")
    ap.add_argument("--points", help="带 markPoints 的地图 JSON，点位会写进输出")
    ap.add_argument("--cell", type=float, default=50.0, help="磁场格子边长 cm（默认 50）")
    ap.add_argument("--report", type=Path, help="质检报告 JSON")
    ap.add_argument("--no-discriminability", action="store_true", help="跳过平行通道相似度分析（大地图较慢）")
    a = ap.parse_args()
    rep, _ = run(a.map, a.sessions, a.out, a.cell, a.points, a.report, not a.no_discriminability)
    print_report(rep)
    print(f"\n已写入 {a.out}")


if __name__ == "__main__":
    main()
