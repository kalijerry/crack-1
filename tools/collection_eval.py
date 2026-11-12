#!/usr/bin/env python3
"""采集 / 定位效果评估（只读后台数据，不改任何东西）。

回答「采集效果到底好不好」：从后台拉所有会话，按地图出几项能直接比较的数字。

建图采集会话（survey）
- 路程、ARKit 正常跟踪比例、走得快慢；
- 磁场回访一致性：同一会话里隔了 ≥ 15 s 又回到 30 cm 以内的地方，两次 |B| 差多少（中位，µT）。
  分别用「原始磁力计 − 整段固定偏置」（云端建图的口径，SurveyMapBuilder.features）和「iOS 校准后磁场」算；
  前者小、后者大说明 iOS 校准在漂，不是现场问题。
- iOS 偏置漂移：每 10 s 的「原始 − 校准」中位数，整段的最大跨度（µT）；
- 磁场越界比例：|B| 不在 10～120 µT 的样本比例（iOS 校准值 / 原始 − 会话累计偏置，后者是 App 现在的质量打分口径）；
- quality.json（App 采集质量打分）有就带上分数和是否保留。

实时定位记录（live，带 ARKit 位姿的）
- 定位误差：track.csv 的位置和 ARKit 轨迹做二维刚体对齐（去掉前 1/3 收敛期），残差 RMS / P90（m）。
  ARKit 只当相对真值：对齐吃掉了整体平移旋转，结果偏乐观，但版本之间可比；
- 跳变：相邻两次输出跳 > 3 m 的次数；App 自报不确定度（unc_cm）中位，和实际误差比。

视觉复核会话（meta purpose = review，App「设置 → 诊断 → 视觉复核」，带 review.csv）
- 真值是 ARKit 认出房间后的相机位置经「ARKit → 地图」变换换到地图上的绝对位置，视觉不参与定位；
  误差是地图上的绝对误差（不做刚体对齐），比上面的 err_rms_m 严格。
- review_err_median_m / review_err_p90_m、1 m 内 / 2 m 内比例、有把握（converged）时的中位、
  有真值时定位有估计的比例、误差第一次连续 3 s 都在 2 m 内用了几秒、自报不确定度 / 实际误差。

另外附上每张地图最近一次云端建图报告里的覆盖率、进图会话数。

环境变量：HPASS_URL、HPASS_TOKEN（同 cloud_build.py）；MAP_ID（可选，只看这一张）；SINCE（可选，YYYYMMDD，只看这天以后的会话）；
DRY_RUN=1（只打印，不把报告传到后台 /api/reports/eval_<时间>.json）。GITHUB_STEP_SUMMARY 有就写一份 Markdown。
会话数据只放在临时目录。纯标准库，不需要 numpy。
"""
from __future__ import annotations

import csv
import io
import json
import math
import os
import statistics
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REVISIT_RADIUS_CM = 30.0
REVISIT_MIN_GAP_MS = 15_000
SAMPLE_MS = 200
MAG_RANGE_UT = (10.0, 120.0)
JUMP_CM = 300.0


# ---------------------------------------------------------------- 读会话

def _rows(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def _f(x, default=None):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def load_session(d):
    """会话目录 → dict（缺的文件给空列表）"""
    meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8"))
    raw = [(_f(r["t_ms"]), (_f(r["mx"]), _f(r["my"]), _f(r["mz"]))) for r in _rows(os.path.join(d, "mag_raw.csv"))]
    imu = []
    for r in _rows(os.path.join(d, "imu.csv")):
        g = (_f(r.get("gvx")), _f(r.get("gvy")), _f(r.get("gvz")))
        if None in g:
            g = (_f(r["ax"]), _f(r["ay"]), _f(r["az"]))
        imu.append((_f(r["t_ms"]), (_f(r["mx"]), _f(r["my"]), _f(r["mz"])), g))
    poses = [(_f(r["t_ms"]), _f(r["x_m"]) * 100, _f(r["z_m"]) * 100, r.get("tracking") == "2")
             for r in _rows(os.path.join(d, "arkit_pose.csv"))]
    track = [(_f(r["t_ms"]), _f(r["x_cm"]), _f(r["y_cm"]), _f(r.get("unc_cm"), 0.0))
             for r in _rows(os.path.join(d, "track.csv"))]
    review = []
    for r in _rows(os.path.join(d, "review.csv")):
        review.append((_f(r["t_ms"]), _f(r["truth_x_cm"]), _f(r["truth_y_cm"]), _f(r.get("est_x_cm")), _f(r.get("est_y_cm")),
                       _f(r.get("unc_cm")), r.get("converged") == "1"))
    q = None
    qp = os.path.join(d, "quality.json")
    if os.path.exists(qp):
        try:
            q = json.load(open(qp, encoding="utf-8"))
        except ValueError:
            q = None
    return {"name": os.path.basename(os.path.normpath(d)), "meta": meta, "raw": raw, "imu": imu, "poses": poses, "track": track, "quality": q, "review": review}


# ---------------------------------------------------------------- 小工具

def norm(v):
    return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(math.floor(k))
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def interp(ts, series):
    """series: [(t, value)] 按 t 升序；ts 升序。返回每个 t 的线性插值（越界 None）。value 可以是数或元组。"""
    out, j = [], 0
    n = len(series)
    for t in ts:
        if n == 0 or t < series[0][0] or t > series[-1][0]:
            out.append(None)
            continue
        while j + 1 < n and series[j + 1][0] < t:
            j += 1
        t0, v0 = series[j]
        if j + 1 >= n:
            out.append(v0)
            continue
        t1, v1 = series[j + 1]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        if isinstance(v0, tuple):
            out.append(tuple(a + (b - a) * f for a, b in zip(v0, v1)))
        else:
            out.append(v0 + (v1 - v0) * f)
    return out


def pair_raw_calibrated(raw, imu, tol_ms=20):
    """每个 iOS 校准样本配最近的原始样本：[(t, raw, cal)]；校准值无效（|B| ≤ 1 或 ≥ 200）的不要"""
    out, j = [], 0
    n = len(raw)
    for t, cal, _ in imu:
        if n == 0:
            break
        while j + 1 < n and raw[j + 1][0] <= t:
            j += 1
        best = j
        if j + 1 < n and abs(raw[j + 1][0] - t) < abs(raw[j][0] - t):
            best = j + 1
        if abs(raw[best][0] - t) > tol_ms:
            continue
        b = norm(cal)
        if not (1.0 < b < 200.0):
            continue
        out.append((t, raw[best][1], cal))
    return out


def fixed_bias(pairs):
    """整段「原始 − 校准」的逐轴中位数（云端建图同一个口径）"""
    if not pairs:
        return None
    return tuple(median([r[k] - c[k] for _, r, c in pairs]) for k in range(3))


def bias_wander(pairs, window_ms=10_000, min_n=50):
    """每 window 的「原始 − 校准」中位数，整段最大跨度（三轴里最大的那个，µT）"""
    if not pairs:
        return None
    t0 = pairs[0][0]
    wins = {}
    for t, r, c in pairs:
        wins.setdefault(int((t - t0) // window_ms), []).append(tuple(r[k] - c[k] for k in range(3)))
    meds = [tuple(median([v[k] for v in vs]) for k in range(3)) for vs in wins.values() if len(vs) >= min_n]
    if len(meds) < 2:
        return None
    return max(max(m[k] for m in meds) - min(m[k] for m in meds) for k in range(3))


def cumulative_bias_totals(raw, pairs):
    """App 质量打分口径：每个原始样本减「会话开始到现在」的累计中位偏置（按秒平均后取中位，≥ 5 秒才出）后的 |B|"""
    per_sec = {}
    for t, r, c in pairs:
        per_sec.setdefault(int(t // 1000), []).append(tuple(r[k] - c[k] for k in range(3)))
    secs = sorted(per_sec)
    means = [tuple(sum(v[k] for v in per_sec[s]) / len(per_sec[s]) for k in range(3)) for s in secs]
    out, i, hist = [], 0, []
    for t, v in raw:
        s = int(t // 1000)
        while i < len(secs) and secs[i] < s:
            hist.append(means[i])
            i += 1
        if len(hist) < 5:
            continue
        b = tuple(median([h[k] for h in hist]) for k in range(3))
        out.append(norm((v[0] - b[0], v[1] - b[1], v[2] - b[2])))
    return out


def revisit_diffs(samples, radius_cm=REVISIT_RADIUS_CM, min_gap_ms=REVISIT_MIN_GAP_MS):
    """samples: [(t, x_cm, y_cm, value)]。隔了 ≥ min_gap 又回到 radius 以内的样本对，value 差的绝对值列表"""
    cell = radius_cm
    grid = {}
    for i, (t, x, y, v) in enumerate(samples):
        grid.setdefault((int(math.floor(x / cell)), int(math.floor(y / cell))), []).append(i)
    diffs = []
    r2 = radius_cm * radius_cm
    for i, (t, x, y, v) in enumerate(samples):
        cx, cy = int(math.floor(x / cell)), int(math.floor(y / cell))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    if j <= i:
                        continue
                    t2, x2, y2, v2 = samples[j]
                    if t2 - t < min_gap_ms:
                        continue
                    if (x2 - x) ** 2 + (y2 - y) ** 2 <= r2:
                        diffs.append(abs(v2 - v))
    return diffs


def rigid_fit_residuals(a, b):
    """二维刚体（含可选镜像）把 a 对到 b，返回残差列表（同单位）。a、b 等长 [(x, y)]"""
    n = len(a)
    if n < 3:
        return None
    best = None
    for refl in (1.0, -1.0):
        aa = [(x, y * refl) for x, y in a]
        ax = sum(p[0] for p in aa) / n
        ay = sum(p[1] for p in aa) / n
        bx = sum(p[0] for p in b) / n
        by = sum(p[1] for p in b) / n
        s_cross = s_dot = 0.0
        for (x1, y1), (x2, y2) in zip(aa, b):
            u1, v1, u2, v2 = x1 - ax, y1 - ay, x2 - bx, y2 - by
            s_dot += u1 * u2 + v1 * v2
            s_cross += u1 * v2 - v1 * u2
        th = math.atan2(s_cross, s_dot)
        c, s = math.cos(th), math.sin(th)
        res = []
        for (x1, y1), (x2, y2) in zip(aa, b):
            u, v = x1 - ax, y1 - ay
            res.append(math.hypot(c * u - s * v + bx - x2, s * u + c * v + by - y2))
        rms = math.sqrt(sum(r * r for r in res) / n)
        if best is None or rms < best[0]:
            best = (rms, res)
    return best[1]


def _r1(x, nd=1):
    return None if x is None else round(x, nd)


# ---------------------------------------------------------------- 评估

def eval_survey(s):
    poses = [p for p in s["poses"] if p[0] is not None]
    meta = s["meta"]
    out = {"name": s["name"], "kind": "survey", "map_id": meta.get("map_id", ""),
           "seconds": _r1(((meta.get("end_ms") or 0) - (meta.get("start_ms") or 0)) / 1000, 0)}
    if poses:
        out["path_m"] = _r1(sum(math.hypot(b[1] - a[1], b[2] - a[2]) for a, b in zip(poses, poses[1:])) / 100)
        out["tracking_ok"] = _r1(sum(1 for p in poses if p[3]) / len(poses), 2)
    if s["quality"]:
        out["quality_score"] = s["quality"].get("score")
        out["quality_kept"] = s["quality"].get("kept", True)
    pairs = pair_raw_calibrated(s["raw"], s["imu"])
    b = fixed_bias(pairs)
    out["ios_bias_wander_ut"] = _r1(bias_wander(pairs), 0)
    cal_tot = [norm(c) for _, c, _ in s["imu"] if c[0] is not None]
    if cal_tot:
        out["ios_out_of_range"] = _r1(sum(1 for x in cal_tot if not MAG_RANGE_UT[0] <= x <= MAG_RANGE_UT[1]) / len(cal_tot), 2)
    cum = cumulative_bias_totals(s["raw"], pairs)
    if cum:
        out["raw_out_of_range"] = _r1(sum(1 for x in cum if not MAG_RANGE_UT[0] <= x <= MAG_RANGE_UT[1]) / len(cum), 2)
    if b is not None and len(poses) > 10:
        t0 = max(poses[0][0], s["raw"][0][0], s["imu"][0][0])
        t1 = min(poses[-1][0], s["raw"][-1][0], s["imu"][-1][0])
        ts = [t0 + k * SAMPLE_MS for k in range(int((t1 - t0) // SAMPLE_MS))]
        pos = interp(ts, [(p[0], (p[1], p[2])) for p in poses])
        ok = interp(ts, [(p[0], 1.0 if p[3] else 0.0) for p in poses])
        rawv = interp(ts, s["raw"])
        calv = interp(ts, [(t, c) for t, c, _ in s["imu"]])
        raw_s, cal_s = [], []
        for t, p, o, r, c in zip(ts, pos, ok, rawv, calv):
            if p is None or o is None or o < 0.99 or r is None or c is None:
                continue
            raw_s.append((t, p[0], p[1], norm((r[0] - b[0], r[1] - b[1], r[2] - b[2]))))
            cb = norm(c)
            if 1.0 < cb < 200.0:
                cal_s.append((t, p[0], p[1], cb))
        dr, dc = revisit_diffs(raw_s), revisit_diffs(cal_s)
        out["revisit_pairs"] = len(dr)
        if len(dr) >= 20:
            out["revisit_raw_ut"] = _r1(median(dr))
            out["revisit_raw_p90_ut"] = _r1(pct(dr, 0.9))
        if len(dc) >= 20:
            out["revisit_ios_ut"] = _r1(median(dc))
        out["field_ut"] = _r1(median([x[3] for x in raw_s]))
    return out


def eval_live(s):
    meta = s["meta"]
    tr = [x for x in s["track"] if x[0] is not None and x[1] is not None]
    out = {"name": s["name"], "kind": "live", "map_id": meta.get("map_id", ""),
           "mag_calibration": meta.get("mag_calibration"), "map_source": meta.get("map_source"),
           "seconds": _r1((tr[-1][0] - tr[0][0]) / 1000, 0) if len(tr) > 1 else 0}
    if meta.get("purpose") == "review" or s.get("review"):
        out["review"] = True
        out["review_start"] = meta.get("review_start")
        out.update(eval_review(s.get("review") or []))
    if len(tr) < 2:
        return out
    out["jumps_3m"] = sum(1 for a, b in zip(tr, tr[1:]) if math.hypot(b[1] - a[1], b[2] - a[2]) > JUMP_CM)
    out["unc_reported_m"] = _r1(median([x[3] for x in tr]) / 100)
    poses = [p for p in s["poses"] if p[0] is not None]
    if len(poses) < 30:
        return out
    walk = sum(math.hypot(b[1] - a[1], b[2] - a[2]) for a, b in zip(poses, poses[1:])) / 100
    out["walk_m"] = _r1(walk)
    ar = interp([x[0] for x in tr], [(p[0], (p[1], p[2])) for p in poses])
    pts = [(a, (x[1], x[2])) for a, x in zip(ar, tr) if a is not None]
    pts = pts[len(pts) // 3:]
    xs = [a[0] for a, _ in pts]
    ys = [a[1] for a, _ in pts]
    if len(pts) < 10 or max(max(xs) - min(xs), max(ys) - min(ys)) < 200:
        return out
    res = rigid_fit_residuals([a for a, _ in pts], [b for _, b in pts])
    out["err_rms_m"] = _r1(math.sqrt(sum(r * r for r in res) / len(res)) / 100)
    out["err_p90_m"] = _r1(pct(res, 0.9) / 100)
    return out


REVIEW_SETTLE_CM = 200.0
REVIEW_SETTLE_MS = 3000


def eval_review(rows):
    """review.csv 行 [(t, 真值 x, y, 估计 x, y, unc, converged)] → review_* 指标（和 HPASSKit PositionReviewStats 同一口径）"""
    rows = [r for r in rows if None not in r[:3]]
    if not rows:
        return {}
    errs, conv_errs, uncs = [], [], []
    settled_at = since = None
    for t, tx, ty, ex, ey, unc, conv in rows:
        if ex is None or ey is None:
            since = None
            continue
        e = math.hypot(ex - tx, ey - ty)
        errs.append(e)
        if conv:
            conv_errs.append(e)
        if unc is not None:
            uncs.append(unc)
        if e <= REVIEW_SETTLE_CM:
            since = t if since is None else since
            if settled_at is None and t - since >= REVIEW_SETTLE_MS:
                settled_at = since
        else:
            since = None
    out = {"review_samples": len(errs), "review_truth_samples": len(rows),
           "review_truth_s": _r1((rows[-1][0] - rows[0][0]) / 1000, 0),
           "review_estimate_share": _r1(len(errs) / len(rows), 2)}
    if errs:
        med = median(errs)
        out.update({
            "review_err_median_m": _r1(med / 100, 2), "review_err_p90_m": _r1(pct(errs, 0.9) / 100, 2),
            "review_err_max_m": _r1(max(errs) / 100, 2),
            "review_within_1m": _r1(sum(1 for e in errs if e <= 100) / len(errs), 2),
            "review_within_2m": _r1(sum(1 for e in errs if e <= 200) / len(errs), 2),
        })
        if conv_errs:
            out["review_err_converged_median_m"] = _r1(median(conv_errs) / 100, 2)
        if uncs and med > 0:
            out["review_unc_over_err"] = _r1(median(uncs) / med, 2)
        tr = [(r[1], r[2]) for r in rows]
        out["review_walk_m"] = _r1(sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(tr, tr[1:])) / 100)
    if settled_at is not None:
        out["review_settle_s"] = _r1((settled_at - rows[0][0]) / 1000)
    return out


def evaluate_dirs(dirs, only_map=""):
    surveys, lives = [], []
    for d in dirs:
        try:
            s = load_session(d)
        except (OSError, ValueError, KeyError) as e:
            print(f"  读不了 {os.path.basename(os.path.normpath(d))}：{e}", file=sys.stderr)
            continue
        m = s["meta"]
        if only_map and m.get("map_id") != only_map:
            continue
        if m.get("survey"):
            surveys.append(eval_survey(s))
        elif m.get("live"):
            lives.append(eval_live(s))
    return surveys, lives


def summarize(surveys, lives, builds):
    """按地图汇总，返回 {map_id: {...}}"""
    maps = {}
    for x in surveys + lives:
        maps.setdefault(x["map_id"] or "?", {"surveys": [], "lives": []})
    for x in surveys:
        maps[x["map_id"] or "?"]["surveys"].append(x)
    for x in lives:
        maps[x["map_id"] or "?"]["lives"].append(x)
    for mid, g in maps.items():
        sv, lv = g["surveys"], [x for x in g["lives"] if "err_rms_m" in x]
        g["summary"] = {
            "surveys": len(sv),
            "survey_path_m": _r1(sum(x.get("path_m") or 0 for x in sv)),
            "revisit_raw_ut": _r1(median([x.get("revisit_raw_ut") for x in sv])),
            "revisit_ios_ut": _r1(median([x.get("revisit_ios_ut") for x in sv])),
            "ios_out_of_range": _r1(median([x.get("ios_out_of_range") for x in sv]), 2),
            "raw_out_of_range": _r1(median([x.get("raw_out_of_range") for x in sv]), 2),
            "live_sessions": len(g["lives"]),
            "live_scored": len(lv),
            "live_err_rms_m": _r1(median([x["err_rms_m"] for x in lv])),
            "live_jumps_per_min": _r1(sum(x.get("jumps_3m", 0) for x in g["lives"]) /
                                      max(1e-9, sum(x.get("seconds") or 0 for x in g["lives"]) / 60)) if g["lives"] else None,
        }
        rv = [x for x in g["lives"] if x.get("review_samples")]
        g["summary"].update({
            "review_sessions": len(rv),
            "review_samples": sum(x["review_samples"] for x in rv),
            "review_err_median_m": _r1(median([x.get("review_err_median_m") for x in rv]), 2),
            "review_err_p90_m": _r1(median([x.get("review_err_p90_m") for x in rv]), 2),
            "review_within_2m": _r1(median([x.get("review_within_2m") for x in rv]), 2),
        })
        b = builds.get(mid)
        if b:
            g["summary"].update({"coverage": _r1(b.get("coverage"), 2), "walkable_m2": _r1(b.get("walkableM2"), 0),
                                 "sessions_in_field": len(b.get("sessions") or []),
                                 "mag_excluded": b.get("magExcluded") or [], "build": b.get("_key")})
    return maps


def _cell(v, suffix=""):
    return "—" if v is None else f"{v}{suffix}"


def markdown(maps):
    L = ["# 采集 / 定位效果评估", ""]
    L.append("回访一致性：同一地点隔 ≥ 15 s 再经过时 |B| 的差（中位，µT），越小越好；原始 = 原始磁力计减整段固定偏置（建图口径），"
             "iOS = iOS 校准后的值。定位误差：实时定位轨迹和 ARKit 轨迹刚体对齐后的残差（m），偏乐观，版本之间比。"
             "视觉复核：视觉认出房间后的地图位置当真值，地磁混合定位的绝对误差（m），不做对齐。")
    for mid, g in sorted(maps.items()):
        s = g["summary"]
        L += ["", f"## {mid}", ""]
        cov = s.get("coverage")
        L.append(f"- 建图采集 {s['surveys']} 次，共 {s['survey_path_m']} m；进磁场图 {_cell(s.get('sessions_in_field'))} 次，"
                 f"覆盖 {_cell(None if cov is None else round(cov * 100), '%')}（可走 {_cell(s.get('walkable_m2'), ' m²')}）")
        L.append(f"- 磁场回访一致性：原始 {_cell(s['revisit_raw_ut'], ' µT')}，iOS {_cell(s['revisit_ios_ut'], ' µT')}；"
                 f"越界比例：iOS {_cell(s['ios_out_of_range'])}，原始 {_cell(s['raw_out_of_range'])}")
        L.append(f"- 实时定位 {s['live_sessions']} 次（能和 ARKit 对比的 {s['live_scored']} 次）：误差中位 {_cell(s['live_err_rms_m'], ' m')}，"
                 f"跳 > 3 m {_cell(s['live_jumps_per_min'], ' 次/分钟')}")
        if s.get("review_sessions"):
            L.append(f"- 视觉复核 {s['review_sessions']} 次（{s['review_samples']} 个样本，地图上的绝对误差）：误差中位 "
                     f"{_cell(s['review_err_median_m'], ' m')}，P90 {_cell(s['review_err_p90_m'], ' m')}，"
                     f"2 m 内 {_cell(None if s['review_within_2m'] is None else round(s['review_within_2m'] * 100), '%')}"
                     "（各会话的中位数）")
        if g["surveys"]:
            L += ["", "| 采集会话 | 秒 | 路程 m | ARKit 正常 | 回访 原始 µT | 回访 iOS µT | iOS 偏置漂移 µT | 越界 iOS / 原始 | 质量分 |",
                  "|---|---|---|---|---|---|---|---|---|"]
            for x in g["surveys"]:
                L.append(f"| {x['name']} | {_cell(x.get('seconds'))} | {_cell(x.get('path_m'))} | {_cell(x.get('tracking_ok'))} | "
                         f"{_cell(x.get('revisit_raw_ut'))} | {_cell(x.get('revisit_ios_ut'))} | {_cell(x.get('ios_bias_wander_ut'))} | "
                         f"{_cell(x.get('ios_out_of_range'))} / {_cell(x.get('raw_out_of_range'))} | "
                         f"{_cell(x.get('quality_score'))}{'' if x.get('quality_kept', True) else '（不合格）'} |")
        scored = [x for x in g["lives"] if x.get("seconds")]
        if scored:
            L += ["", "| 定位记录 | 秒 | 走 m | 误差 RMS m | P90 m | 自报不确定度 m | 跳 > 3 m | 磁场口径 |", "|---|---|---|---|---|---|---|---|"]
            for x in scored:
                L.append(f"| {x['name']} | {_cell(x.get('seconds'))} | {_cell(x.get('walk_m'))} | {_cell(x.get('err_rms_m'))} | "
                         f"{_cell(x.get('err_p90_m'))} | {_cell(x.get('unc_reported_m'))} | {_cell(x.get('jumps_3m'))} | "
                         f"{_cell(x.get('mag_calibration'))} |")
        reviews = [x for x in g["lives"] if x.get("review")]
        if reviews:
            L += ["", "| 视觉复核 | 起点 | 有真值 秒 | 走 m | 误差中位 m | P90 m | 最大 m | 1 m 内 | 2 m 内 | 有把握时中位 m | 有估计 | 稳定用时 s | 自报/实际 |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
            for x in reviews:
                L.append(f"| {x['name']} | {_cell(x.get('review_start'))} | {_cell(x.get('review_truth_s'))} | {_cell(x.get('review_walk_m'))} | "
                         f"{_cell(x.get('review_err_median_m'))} | {_cell(x.get('review_err_p90_m'))} | {_cell(x.get('review_err_max_m'))} | "
                         f"{_cell(x.get('review_within_1m'))} | {_cell(x.get('review_within_2m'))} | "
                         f"{_cell(x.get('review_err_converged_median_m'))} | {_cell(x.get('review_estimate_share'))} | "
                         f"{_cell(x.get('review_settle_s'))} | {_cell(x.get('review_unc_over_err'))} |")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------- 后台

def main():
    url = os.environ["HPASS_URL"].rstrip("/")
    if not url.startswith("http"):
        url = "https://" + url
    token = os.environ["HPASS_TOKEN"]
    only = os.environ.get("MAP_ID", "").strip()
    since = os.environ.get("SINCE", "").strip()
    dry = os.environ.get("DRY_RUN") == "1"

    def req(path, method="GET", data=None, headers=None):
        h = {"Authorization": "Bearer " + token, "User-Agent": "hpass-cloud-build/1.0"}
        h.update(headers or {})
        r = urllib.request.Request(url + path, data=data, method=method, headers=h)
        with urllib.request.urlopen(r, timeout=300) as resp:
            return resp.read()

    work = tempfile.mkdtemp(prefix="hpass-eval-")
    dirs = []
    for o in json.loads(req("/api/sessions")):
        name = o["key"].split("/", 1)[1]
        stamp = "".join(ch for ch in name if ch.isdigit())[:8]
        if since and stamp and stamp < since:
            continue
        z = zipfile.ZipFile(io.BytesIO(req("/api/sessions/" + urllib.parse.quote(name))))
        z.extractall(work)
        for m in z.namelist():
            if m.endswith("meta.json") and m.count("/") == 1:
                dirs.append(os.path.join(work, os.path.dirname(m)))
    print(f"会话 {len(dirs)} 个")
    builds = {}
    for o in sorted(json.loads(req("/api/reports")), key=lambda o: o["key"]):
        k = o["key"]
        if not k.startswith("reports/build_"):
            continue
        try:
            b = json.loads(req("/api/" + k))
        except (urllib.error.HTTPError, ValueError):
            continue
        if b.get("mapId"):
            b["_key"] = k
            builds[b["mapId"]] = b             # 按名字排序，后面的（更新的）覆盖
    surveys, lives = evaluate_dirs(sorted(dirs), only)
    maps = summarize(surveys, lives, builds)
    md = markdown(maps)
    print(md)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(md)
    report = {"kind": "collection_eval", "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "maps": maps}
    if not dry:
        key = f"/api/reports/eval_{time.strftime('%Y%m%d-%H%M', time.gmtime())}.json"
        req(key, "PUT", json.dumps(report, ensure_ascii=False).encode(), {"Content-Type": "application/json"})
        print("报告已上传：" + key)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        # 本地：python3 tools/collection_eval.py 会话目录…（不连后台）
        sv, lv = evaluate_dirs(sys.argv[1:], os.environ.get("MAP_ID", "").strip())
        print(markdown(summarize(sv, lv, {})))
    else:
        main()
