#!/usr/bin/env python3
"""双机敲击对时：盲测机 A 和真值伴随机 B 叠在一起敲三下（开始、结束各一组），用两机 imu.csv 的 |a| 峰求 B 相对 A 的
时钟偏移和漂移（docs/office-test.md 第 3 步）。

  python -I -X utf8 tools/lab/bump_sync.py a/imu.csv b/imu.csv [--json out.json]

做法
1. 找峰：|a| 超过 min_peak_g·g 的局部最大值，两峰至少隔 min_sep_ms；峰时刻用三点抛物线插值到亚采样。
2. 成组：相邻峰间隔在 [gap_min_ms, gap_max_ms] 的连成一串，取恰好 taps 个（默认 3）的串；开始组 = 录制开头 edge_s 秒内的第一组，
   结束组 = 末尾 edge_s 秒内的最后一组。
3. 每组：先用峰时刻差的平均当粗偏移，再在 ±xcorr_ms 内对两机这一段 |a| − g（线性插值到 xcorr_step_ms 网格）做互相关取最大，
   最后用峰时刻差相对这个偏移的 RMS 当残差；残差 > max_residual_ms（默认 20 ms）的组不用。
4. 两组都可用：偏移 + 漂移（ppm）；只有一组：只给偏移，漂移为 None；一组都没有：ok = false。

约定：offset_ms = t_B − t_A（同一物理时刻 B 的时钟读数减 A 的），B 的时间戳换到 A 的时钟用 `to_a_clock`。
注意（评审意见）：iPhone 50 Hz deviceMotion 经过系统低通，> 3 g、约 10 ms 的敲击脉冲常被削平；峰门限 min_peak_g 可调，
采集端最好对时段用 100 Hz 原始加速度。两机贴紧一起转动 2–3 s 用陀螺互相关会更稳，留作以后的补充。
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

G = 9.80665


@dataclass
class SyncParams:
    """全部可从命令行改（--min-peak-g 等）。峰门限、间隔范围是占位值：待自采 iPhone 双机数据标定"""
    min_peak_g: float = 3.0
    min_sep_ms: float = 150.0
    gap_min_ms: float = 200.0
    gap_max_ms: float = 1200.0
    taps: int = 3
    edge_s: float = 90.0
    xcorr_ms: float = 150.0
    xcorr_step_ms: float = 1.0
    max_residual_ms: float = 20.0


def load_acc(path) -> tuple[list[float], list[float]]:
    """imu.csv → (t_ms, |a| m/s²)"""
    ts, mag = [], []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                t, ax, ay, az = float(r["t_ms"]), float(r["ax"]), float(r["ay"]), float(r["az"])
            except (KeyError, TypeError, ValueError):
                continue
            ts.append(t)
            mag.append(math.sqrt(ax * ax + ay * ay + az * az))
    order = sorted(range(len(ts)), key=ts.__getitem__)
    return [ts[i] for i in order], [mag[i] for i in order]


def find_peaks(t, a, p: SyncParams) -> list[float]:
    """|a| 超门限的局部最大值的时刻（ms，抛物线插值）"""
    thr = p.min_peak_g * G
    cand = []
    for i in range(1, len(a) - 1):
        if a[i] >= thr and a[i] >= a[i - 1] and a[i] > a[i + 1]:
            y0, y1, y2 = a[i - 1], a[i], a[i + 1]
            den = y0 - 2 * y1 + y2
            frac = 0.5 * (y0 - y2) / den if den != 0 else 0.0
            frac = max(-0.5, min(0.5, frac))
            dt = (t[i + 1] - t[i - 1]) / 2
            cand.append((t[i] + frac * dt, a[i]))
    peaks: list[tuple[float, float]] = []
    for tc, v in cand:                                     # 太近的峰只留大的
        if peaks and tc - peaks[-1][0] < p.min_sep_ms:
            if v > peaks[-1][1]:
                peaks[-1] = (tc, v)
            continue
        peaks.append((tc, v))
    return [tc for tc, _ in peaks]


def tap_groups(peaks: list[float], p: SyncParams) -> list[list[float]]:
    """相邻间隔在 [gap_min, gap_max] 的峰连成串，只要恰好 taps 个的串"""
    groups, cur = [], []
    for tp in peaks:
        if cur and p.gap_min_ms <= tp - cur[-1] <= p.gap_max_ms:
            cur.append(tp)
        else:
            if len(cur) == p.taps:
                groups.append(cur)
            cur = [tp]
    if len(cur) == p.taps:
        groups.append(cur)
    return groups


def edge_groups(t, peaks, p: SyncParams):
    """(开始组, 结束组)；没有就是 None。录制太短、两组重合时结束组为 None"""
    if not t:
        return None, None
    gs = tap_groups(peaks, p)
    start = next((g for g in gs if g[0] <= t[0] + p.edge_s * 1000), None)
    end = next((g for g in reversed(gs) if g[-1] >= t[-1] - p.edge_s * 1000), None)
    if end is start:
        end = None
    return start, end


def _interp(t, a, x):
    """线性插值（t 升序）；超出范围返回 None"""
    import bisect
    if x < t[0] or x > t[-1]:
        return None
    i = bisect.bisect_right(t, x) - 1
    if i >= len(t) - 1:
        return a[-1]
    f = (x - t[i]) / (t[i + 1] - t[i]) if t[i + 1] > t[i] else 0.0
    return a[i] + (a[i + 1] - a[i]) * f


def group_offset(ta, aa, ga, tb, ab, gb, p: SyncParams) -> dict:
    """一组敲击：偏移（t_B − t_A，ms）和残差（ms）"""
    coarse = sum(b - a for a, b in zip(ga, gb)) / len(ga)
    lo, hi = ga[0] - 300, ga[-1] + 300
    n = int((hi - lo) / p.xcorr_step_ms) + 1
    xs = [lo + k * p.xcorr_step_ms for k in range(n)]
    def dyn(t, a, x):
        v = _interp(t, a, x)
        return 0.0 if v is None else v - G
    sa = [dyn(ta, aa, x) for x in xs]
    steps = int(p.xcorr_ms / p.xcorr_step_ms)
    # B 先按同一步长插值一次：滞后 k 步就是数组错开 k 位
    sb = [dyn(tb, ab, lo + coarse + (j - steps) * p.xcorr_step_ms) for j in range(n + 2 * steps)]
    best, best_lag = -math.inf, coarse
    for k in range(-steps, steps + 1):
        off = k + steps
        acc = sum(va * sb[i + off] for i, va in enumerate(sa))
        if acc > best:
            best, best_lag = acc, coarse + k * p.xcorr_step_ms
    res = math.sqrt(sum((b - a - best_lag) ** 2 for a, b in zip(ga, gb)) / len(ga))
    return {"t_a_ms": sum(ga) / len(ga), "offset_ms": best_lag, "coarse_ms": coarse, "residual_ms": res,
            "ok": res <= p.max_residual_ms}


def sync(ta, aa, tb, ab, p: SyncParams = SyncParams()) -> dict:
    """两机加速度 → 对时结果（见模块说明）"""
    sa, ea = edge_groups(ta, find_peaks(ta, aa, p), p)
    sb, eb = edge_groups(tb, find_peaks(tb, ab, p), p)
    out = {"ok": False, "offset_ms": None, "drift_ppm": None, "start": None, "end": None, "reason": None,
           "params": asdict(p)}
    if sa and sb:
        out["start"] = group_offset(ta, aa, sa, tb, ab, sb, p)
    if ea and eb:
        out["end"] = group_offset(ta, aa, ea, tb, ab, eb, p)
    good = [g for g in (out["start"], out["end"]) if g and g["ok"]]
    if not good:
        out["reason"] = ("没有找到成组的敲击" if not (out["start"] or out["end"])
                         else f"残差超过 {p.max_residual_ms:g} ms，不用")
        return out
    out["ok"] = True
    out["offset_ms"] = good[0]["offset_ms"]
    out["t_ref_ms"] = good[0]["t_a_ms"]
    if len(good) == 2 and good[1]["t_a_ms"] > good[0]["t_a_ms"]:
        out["drift_ppm"] = (good[1]["offset_ms"] - good[0]["offset_ms"]) / (good[1]["t_a_ms"] - good[0]["t_a_ms"]) * 1e6
    elif len(good) == 1:
        out["reason"] = "只有一组敲击可用：没有漂移"
    return out


def offset_at(res: dict, t_a: float) -> float:
    """A 时钟 t_a 时刻的偏移（t_B − t_A，ms）"""
    k = (res.get("drift_ppm") or 0.0) * 1e-6
    return res["offset_ms"] + k * (t_a - res["t_ref_ms"])


def to_a_clock(res: dict, t_b: float) -> float:
    """B 的时间戳换到 A 的时钟（漂移是 ppm 级，用一步近似就够）"""
    t_a = t_b - res["offset_ms"]
    return t_b - offset_at(res, t_a)


def sync_files(a_imu, b_imu, p: SyncParams = SyncParams()) -> dict:
    ta, aa = load_acc(a_imu)
    tb, ab = load_acc(b_imu)
    r = sync(ta, aa, tb, ab, p)
    # 评分窗口（A 的时钟）：开始组最后一下之后、结束组第一下之前
    sa, ea = edge_groups(ta, find_peaks(ta, aa, p), p)
    r["window_a_ms"] = [sa[-1] if sa else (ta[0] if ta else None), ea[0] if ea else (ta[-1] if ta else None)]
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a_imu", type=Path, help="盲测机 A 的 imu.csv")
    ap.add_argument("b_imu", type=Path, help="真值伴随机 B 的 imu.csv")
    ap.add_argument("--json", type=Path)
    for k, v in SyncParams().__dict__.items():
        ap.add_argument("--" + k.replace("_", "-"), type=type(v), default=v)
    a = ap.parse_args(argv)
    p = SyncParams(**{k: getattr(a, k) for k in SyncParams().__dict__})
    r = sync_files(a.a_imu, a.b_imu, p)
    txt = json.dumps(r, ensure_ascii=False, indent=1)
    if a.json:
        a.json.write_text(txt + "\n", encoding="utf-8")
    else:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(txt)
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
