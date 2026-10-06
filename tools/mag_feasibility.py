#!/usr/bin/env python3
"""
地磁可行性分析（阶段 0）：回答三个问题
  1. 磁场沿路线的空间变化，是否明显大于「同一位置重复走」的差异？（SNR）
  2. 用一遍当地图、另一遍当查询，用一段 L 米的特征序列能否找回正确位置？（可区分度）
  3. iOS 校准后的磁场里有没有系统重新校准造成的跳变？（原始磁力计 vs 校准磁场）

用法：
    python mag_feasibility.py --map 会话A 会话B ... --query 会话C 会话D ... [--ds 0.5] [--out 输出目录]

会话是 iOS 采集器导出的目录或 zip（格式见 docs/data-format.md）。
**路线会话**的要求：沿地面标记行走，每到一个标记就「打点」（时长随意，1 秒也行），
并填写该标记的坐标 x、y（厘米）。相邻两次打点之间按匀速插值出位置。

特征（都与手机朝向、航向无关）：
    |B|  总强度       Bz  沿重力方向（向上）的分量       Bh  水平分量大小

只依赖 Python 3.8+ 标准库。
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

FEATURES = ("|B|", "Bz", "Bh")
WINDOWS_M = (3, 5, 10, 15)
HIT_RADIUS_M = 1.5          # 估计位置离真值不超过这个距离算「找对」
SNR_PASS = 3.0              # 空间标准差 / 重复噪声 的通过线
TOP1_PASS = 0.9             # L=10 m 的找回率通过线
JUMP_UT = 2.0               # 校准偏置 1 秒内变化超过这个值算一次跳变
GRAVITY_SMOOTH_S = 0.5      # 用加速度低通估计「向上」方向


# ---------------------------------------------------------------- 读取与特征

class Track:
    """沿路线按弧长等间隔重采样后的特征序列。"""

    def __init__(self, name):
        self.name = name
        self.xy = []     # (x_m, y_m)
        self.feat = []   # (|B|, Bz, Bh)


def load_imu(dir_):
    rows = read_csv(dir_ / "imu.csv")
    t = [int(r["t_ms"]) for r in rows]
    acc = [(float(r["ax"]), float(r["ay"]), float(r["az"])) for r in rows]
    mag = [(float(r["mx"]), float(r["my"]), float(r["mz"])) for r in rows]
    acc_flag = [int(r["mag_acc"]) for r in rows]
    return t, acc, mag, acc_flag


def moving_average(vecs, n):
    """对三维序列做长度 n 的居中滑动平均（均匀采样假设）。"""
    n = max(1, n | 1)
    half = n // 2
    cum = [(0.0, 0.0, 0.0)]
    for v in vecs:
        c = cum[-1]
        cum.append((c[0] + v[0], c[1] + v[1], c[2] + v[2]))
    out = []
    for i in range(len(vecs)):
        a, b = max(0, i - half), min(len(vecs), i + half + 1)
        k = b - a
        out.append(tuple((cum[b][j] - cum[a][j]) / k for j in range(3)))
    return out


def compute_features(t, acc, mag):
    """返回每个样本的 (|B|, Bz, Bh)。向上方向取加速度（含重力）的低通方向。"""
    if len(t) < 3:
        return []
    dt = statistics.median(b - a for a, b in zip(t, t[1:])) / 1000.0
    n = int(round(GRAVITY_SMOOTH_S / dt)) if dt > 0 else 1
    up = moving_average(acc, n)   # Android 约定：静止时加速度指向「上」
    out = []
    for u, m in zip(up, mag):
        un = math.sqrt(sum(c * c for c in u))
        b = math.sqrt(sum(c * c for c in m))
        if un < 1e-6:
            out.append((b, 0.0, b))
            continue
        bz = sum(m[i] * u[i] for i in range(3)) / un
        out.append((b, bz, math.sqrt(max(b * b - bz * bz, 0.0))))
    return out


def waypoints(marks):
    """按时间排序的路标：(t_mid_ms, x_m, y_m)。缺坐标的打点忽略。"""
    wp = []
    for m in marks:
        if m.get("x_cm", "") == "" or m.get("y_cm", "") == "":
            continue
        t_mid = (int(m["t_start_ms"]) + int(m["t_end_ms"])) / 2
        wp.append((t_mid, float(m["x_cm"]) / 100.0, float(m["y_cm"]) / 100.0))
    wp.sort()
    return wp


def build_track(dir_, ds, name=None):
    """会话 → 等弧长间隔的 Track。第一个与最后一个路标之间的样本才会用到。"""
    t, acc, mag, _ = load_imu(dir_)
    feats = compute_features(t, acc, mag)
    wp = waypoints(read_csv(dir_ / "marks.csv"))
    tr = Track(name or dir_.name)
    if len(wp) < 2 or not feats:
        return tr
    seg_len = [math.hypot(b[1] - a[1], b[2] - a[2]) for a, b in zip(wp, wp[1:])]
    cum = [0.0]
    for L in seg_len:
        cum.append(cum[-1] + L)
    wt = [w[0] for w in wp]
    bins = {}
    for ti, f in zip(t, feats):
        if ti < wt[0] or ti > wt[-1]:
            continue
        i = min(bisect.bisect_right(wt, ti) - 1, len(wp) - 2)
        span = wt[i + 1] - wt[i]
        frac = (ti - wt[i]) / span if span > 0 else 0.0
        s = cum[i] + frac * seg_len[i]
        x = wp[i][1] + frac * (wp[i + 1][1] - wp[i][1])
        y = wp[i][2] + frac * (wp[i + 1][2] - wp[i][2])
        acc_ = bins.setdefault(int(s / ds), [0, 0.0, 0.0, 0.0, 0.0, 0.0])
        acc_[0] += 1
        acc_[1] += x
        acc_[2] += y
        for j in range(3):
            acc_[3 + j] += f[j]
    for k in sorted(bins):
        n, sx, sy, f0, f1, f2 = bins[k]
        tr.xy.append((sx / n, sy / n))
        tr.feat.append((f0 / n, f1 / n, f2 / n))
    return tr


# ---------------------------------------------------------------- 分析 1：重复性与空间变化

def repeatability(map_tracks, query_tracks, max_dist=0.5):
    """
    对每个查询点，在地图轨迹里找最近点（≤ max_dist），取特征差。
    噪声 σ = 差的 RMS / √2（两次测量各带噪声）。SNR = 地图轨迹的空间标准差 / σ。
    """
    diffs = [[] for _ in FEATURES]
    for q in query_tracks:
        for (qx, qy), qf in zip(q.xy, q.feat):
            best, bd = None, max_dist
            for m in map_tracks:
                for (mx, my), mf in zip(m.xy, m.feat):
                    d = math.hypot(qx - mx, qy - my)
                    if d <= bd:
                        best, bd = mf, d
            if best is not None:
                for j in range(3):
                    diffs[j].append(qf[j] - best[j])
    res = {}
    for j, name in enumerate(FEATURES):
        spatial = [f[j] for m in map_tracks for f in m.feat]
        sd = statistics.pstdev(spatial) if len(spatial) > 1 else float("nan")
        d = diffs[j]
        if len(d) < 5:
            res[name] = {"n": len(d), "spatial_std": sd}
            continue
        rms = math.sqrt(sum(x * x for x in d) / len(d))
        noise = rms / math.sqrt(2)
        res[name] = {
            "n": len(d), "spatial_std": sd, "mean_offset": statistics.fmean(d),
            "repeat_rms": rms, "noise_sigma": noise,
            "snr": sd / noise if noise > 0 else float("inf"),
        }
    return res


# ---------------------------------------------------------------- 分析 2：可区分度

def _windows(track, L, scale, rev):
    """生成 (向量, 终点坐标)。rev=True 表示沿相反方向行走时的窗口。"""
    n = len(track.feat)
    out = []
    for i in range(n - L + 1):
        idx = range(i + L - 1, i - 1, -1) if rev else range(i, i + L)
        vec = []
        for k in idx:
            f = track.feat[k]
            vec.extend(f[j] / scale[j] for j in range(3))
        end = track.xy[i] if rev else track.xy[i + L - 1]
        out.append((vec, end))
    return out


def identifiability(map_tracks, query_tracks, window_m, ds, demean=False):
    L = max(2, int(round(window_m / ds)))
    all_f = [f for m in map_tracks for f in m.feat]
    if not all_f:
        return None
    scale = [statistics.pstdev([f[j] for f in all_f]) or 1.0 for j in range(3)]
    cands = []
    for m in map_tracks:
        cands += _windows(m, L, scale, False) + _windows(m, L, scale, True)
    if demean:
        cands = [(_demean(v), e) for v, e in cands]
    step = max(1, int(round(2.0 / ds)))     # 查询窗口每 2 m 取一个
    errors, ratios = [], []
    for q in query_tracks:
        for vec, truth in _windows(q, L, scale, False)[::step]:
            if demean:
                vec = _demean(vec)
            scored = sorted(((sum((a - b) ** 2 for a, b in zip(vec, c[0])) / len(vec), c[1]) for c in cands),
                            key=lambda x: x[0])
            d1, p1 = scored[0]
            errors.append(math.hypot(p1[0] - truth[0], p1[1] - truth[1]))
            d2 = next((d for d, p in scored if math.hypot(p[0] - p1[0], p[1] - p1[1]) > 3.0), None)
            if d2 is not None and d1 > 0:
                ratios.append(d2 / d1)
    if not errors:
        return None
    errors.sort()
    return {
        "window_m": window_m, "n_queries": len(errors),
        "top1_rate": sum(e <= HIT_RADIUS_M for e in errors) / len(errors),
        "median_err_m": statistics.median(errors),
        "p90_err_m": errors[min(len(errors) - 1, int(0.9 * len(errors)))],
        "median_ambiguity_ratio": statistics.median(ratios) if ratios else None,
    }


def _demean(vec):
    mean = [sum(vec[j::3]) / (len(vec) // 3) for j in range(3)]
    return [v - mean[i % 3] for i, v in enumerate(vec)]


# ---------------------------------------------------------------- 分析 3：校准跳变

def calibration_jumps(dir_):
    """原始磁力计 − 校准磁场 = 系统当前估计的偏置；它在 1 秒内的突变就是一次重新校准。"""
    raw_path = dir_ / "mag_raw.csv"
    if not raw_path.exists():
        return None
    raw = read_csv(raw_path)
    t, _, mag, acc_flag = load_imu(dir_)
    if not raw or not t:
        return None
    rt = [int(r["t_ms"]) for r in raw]
    rv = [(float(r["mx"]), float(r["my"]), float(r["mz"])) for r in raw]
    bias_by_sec = {}
    for ti, m in zip(t, mag):
        i = bisect.bisect_left(rt, ti)
        if i <= 0 or i >= len(rt) or rt[i] - ti > 50:
            continue
        b = tuple(rv[i][j] - m[j] for j in range(3))
        bias_by_sec.setdefault(ti // 1000, []).append(b)
    secs = sorted(bias_by_sec)
    means = {s: tuple(statistics.fmean(v[j] for v in bias_by_sec[s]) for j in range(3)) for s in secs}
    jumps = []
    for a, b in zip(secs, secs[1:]):
        if b - a != 1:
            continue
        d = math.sqrt(sum((means[b][j] - means[a][j]) ** 2 for j in range(3)))
        if d > JUMP_UT:
            jumps.append({"t_s": b, "delta_uT": round(d, 2)})
    low_acc = sum(1 for a in acc_flag if a < 2) / len(acc_flag) if acc_flag else None
    return {"seconds_checked": len(secs), "jumps": jumps, "low_accuracy_fraction": low_acc}


# ---------------------------------------------------------------- 报告

def run(map_dirs, query_dirs, ds, out_dir=None, demean=False):
    maps = [build_track(d, ds) for d in map_dirs]
    queries = [build_track(d, ds) for d in query_dirs]
    maps_ok = [m for m in maps if m.feat]
    queries_ok = [q for q in queries if q.feat]
    report = {"ds_m": ds, "map": [m.name for m in maps], "query": [q.name for q in queries],
              "map_points": [len(m.feat) for m in maps], "query_points": [len(q.feat) for q in queries]}
    if not maps_ok or not queries_ok:
        report["error"] = "没有可用的路线数据：需要每个会话至少 2 次带坐标的打点，且有 imu.csv"
        return report
    report["repeatability"] = repeatability(maps_ok, queries_ok)
    report["identifiability"] = [r for r in
                                 (identifiability(maps_ok, queries_ok, w, ds, demean) for w in WINDOWS_M) if r]
    report["calibration_jumps"] = {d.name: calibration_jumps(d) for d in map_dirs + query_dirs}
    report["verdict"] = verdict(report)
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "mag_feasibility.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def verdict(report):
    rep = report["repeatability"]
    snr = {k: rep[k].get("snr") for k in ("|B|", "Bz")}
    ident = {r["window_m"]: r for r in report["identifiability"]}
    reasons, ok = [], True
    for k, v in snr.items():
        if v is None:
            reasons.append(f"{k}：重复点太少，无法评估 SNR（需要地图与查询走同一路线）")
            ok = False
        elif v < SNR_PASS:
            reasons.append(f"{k} SNR {v:.1f} < {SNR_PASS}：空间变化不够大，或重复性差")
            ok = False
    r10 = ident.get(10)
    if r10 is None:
        reasons.append("路线太短，无法评估 10 m 窗口")
        ok = False
    elif r10["top1_rate"] < TOP1_PASS:
        reasons.append(f"10 m 窗口找回率 {r10['top1_rate']:.0%} < {TOP1_PASS:.0%}")
        ok = False
    return {"go": ok, "reasons": reasons or ["各项指标均达到通过线"]}


def print_report(rep):
    if "error" in rep:
        print("错误：" + rep["error"])
        return
    print(f"地图轨迹 {rep['map']}（点数 {rep['map_points']}）\n查询轨迹 {rep['query']}（点数 {rep['query_points']}）\n")
    print("== 1. 空间变化 vs 重复性（SNR ≥ %.0f 为佳）==" % SNR_PASS)
    print(f"{'特征':<6}{'空间std':>9}{'噪声σ':>9}{'SNR':>8}{'两遍均值差':>12}{'配对点':>8}   单位 µT")
    for k, r in rep["repeatability"].items():
        if "snr" not in r:
            print(f"{k:<6}{r['spatial_std']:>9.2f}{'-':>9}{'-':>8}{'-':>12}{r['n']:>8}")
        else:
            print(f"{k:<6}{r['spatial_std']:>9.2f}{r['noise_sigma']:>9.2f}{r['snr']:>8.1f}{r['mean_offset']:>12.2f}{r['n']:>8}")
    print("\n== 2. 可区分度：用一段 L 米的特征序列在地图里找位置 ==")
    print(f"{'窗口':>6}{'查询数':>8}{'找回率':>9}{'中位误差':>10}{'P90误差':>9}{'歧义比':>8}")
    for r in rep["identifiability"]:
        amb = f"{r['median_ambiguity_ratio']:.2f}" if r["median_ambiguity_ratio"] else "-"
        print(f"{r['window_m']:>5}m{r['n_queries']:>8}{r['top1_rate']:>9.0%}{r['median_err_m']:>9.2f}m{r['p90_err_m']:>8.2f}m{amb:>8}")
    print("  （歧义比 = 第二好且相距 >3 m 的匹配误差 / 最好匹配误差；越接近 1 越容易走错通道）")
    print("\n== 3. iOS 校准跳变 ==")
    for name, j in rep["calibration_jumps"].items():
        if j is None:
            print(f"  {name}: 没有 mag_raw.csv，跳过")
        else:
            low = j["low_accuracy_fraction"]
            print(f"  {name}: 检查 {j['seconds_checked']} 秒，跳变 {len(j['jumps'])} 次，"
                  f"磁场精度偏低占比 {low:.0%}" if low is not None else f"  {name}: 跳变 {len(j['jumps'])} 次")
    v = rep["verdict"]
    print("\n== 结论：" + ("GO（继续阶段 1～）" if v["go"] else "NO-GO / 需要复查") + " ==")
    for r in v["reasons"]:
        print("  - " + r)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", nargs="+", required=True, help="做地图用的会话（目录或 zip）")
    ap.add_argument("--query", nargs="+", required=True, help="做查询用的会话（建议不同时间、不同方向）")
    ap.add_argument("--ds", type=float, default=0.5, help="沿路线的重采样间隔，米（默认 0.5）")
    ap.add_argument("--demean", action="store_true", help="窗口内去均值后再匹配（模拟对绝对偏移不敏感的做法）")
    ap.add_argument("--out", type=Path, help="输出目录，写 mag_feasibility.json")
    a = ap.parse_args()
    rep = run([resolve_session_dir(Path(p)) for p in a.map],
              [resolve_session_dir(Path(p)) for p in a.query], a.ds, a.out, a.demean)
    print_report(rep)


if __name__ == "__main__":
    main()
