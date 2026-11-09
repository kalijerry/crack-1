#!/usr/bin/env python3
"""办公室指标：hpass-eval --track-out 的逐点轨迹 + map.json 的房间单元（units）→ 房间判对率、过门延迟、≤1 m、TTFF 等。

  python -I -X utf8 tools/lab/office_metrics.py --track track.csv --map map.json [--meta meta.json] [--json out.json]

输入
  track.csv   hpass-eval --track-out 写的：session,run,t_ms,est_x,est_y,converged,unc_cm,ref_x,ref_y（cm）。
              每个运动节拍一行；est 为空 = 还没有估计；converged = 1 才算「报了位置」（App 会显示）。
  map.json    units：[{id, category, polygon: [x0, y0, x1, y1, …]}]（cm）。没有 units 时房间类指标为 None，其余照算。
  meta.json   可选：{会话名: {"map_age_days": 3, "carry_mode": "pocket"}}，用来按地图年龄 / 携带方式分组。

口径（docs/office-test.md「指标口径」，1 Hz 网格；每个参数都可以改，见 Params）
- 网格：每个 (会话, 第几次回放) 从第一行到最后一行每秒取一个点，取该时刻之前最近的一行（隔了 > max_gap_s 就跳过这一秒）。
- 房间：真值点离任何单元边界 < boundary_cm（默认 0.5 m）的不计房间指标（墙边、门口本来就说不清在哪个房间）；
  真值不在任何单元里的也不计。估计落在墙缝里时归到 boundary_cm 以内最近的单元，再远 = 错房间（远处）。
- room_correct：报了位置的点里房间对的比例；room_correct_all：全部时间（没报位置算错）。
- wrong_room_adjacent / wrong_room_far：报了位置的点里，错到相邻房间 / 不相邻的地方。相邻 = 两个单元多边形最近距离
  ≤ adjacent_gap_cm（默认 0.6 m，墙厚 + 门框）。
- door_latency：真值从房间 A 进 B 之后，估计进入 B 并连续保持 hold_s（3 s）所用的时间；> miss_s（15 s）算漏。
- within1m_points（按每次输出的定位点）/ within1m_time（按全部时间，没报位置算不合格）；p50 / p90（报了位置的网格点，cm）。
- coverage：报了位置的时间占比。
- TTFF：第一次「房间对（真值房间可判时）且误差 ≤ ttff_err_cm（2 m）」并连续保持 ttff_hold_s（10 s）的时刻，
  按时间（s）和真值路程（m）算；没发生就按窗口长度 / 全程截尾，并计入 ttff_rate（定到率）。
- wrong_fix_before_first_correct：TTFF 之前「报了位置但误差 > 5 m 或房间错」的次数（按连续段计）。
- 分桶：map_age_days 0 / 1–7 / 8–30 / >30。
真值本身有 0.3–0.5 m 底噪（伴随机 ARKit + 杆臂），≤1 m 会被系统性低估：版本之间只看差值。
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Params:
    grid_s: float = 1.0
    max_gap_s: float = 2.0
    boundary_cm: float = 50.0
    adjacent_gap_cm: float = 60.0
    hold_s: float = 3.0
    miss_s: float = 15.0
    ttff_err_cm: float = 200.0
    ttff_hold_s: float = 10.0
    wrong_fix_cm: float = 500.0


AGE_BUCKETS = (("0", 0, 0), ("1-7", 1, 7), ("8-30", 8, 30), (">30", 31, math.inf))


def age_bucket(days) -> str | None:
    if days is None:
        return None
    d = max(0, int(math.floor(days)))
    for name, lo, hi in AGE_BUCKETS:
        if lo <= d <= hi:
            return name
    return None


def pct(sorted_vals, q):
    """和 lab.py / hpass-eval 同一种分位数取法（最近秩）"""
    if not sorted_vals:
        return None
    return sorted_vals[min(int((len(sorted_vals) - 1) * q + 0.5), len(sorted_vals) - 1)]


# ───────────────────────── 几何 ─────────────────────────

def _seg_point_dist(ax, ay, bx, by, px, py):
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    f = 0.0 if L2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return math.hypot(ax + f * dx - px, ay + f * dy - py)


def _segs_intersect(a, b, c, d):
    def orient(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    o1, o2, o3, o4 = orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b)
    return (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0)


@dataclass
class Unit:
    id: str
    poly: list

    def edges(self):
        n = len(self.poly)
        return [(self.poly[i], self.poly[(i + 1) % n]) for i in range(n)]

    def contains(self, x, y) -> bool:
        inside = False
        for (x1, y1), (x2, y2) in self.edges():
            if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
                inside = not inside
        return inside

    def boundary_dist(self, x, y) -> float:
        return min(_seg_point_dist(a[0], a[1], b[0], b[1], x, y) for a, b in self.edges())


def load_units(map_obj: dict) -> list[Unit]:
    """map.json（可能包了一层 data）→ 房间单元。只要能走的单元也行，这里不按类别筛：走廊也是一个「房间」"""
    root = map_obj.get("data", map_obj) if isinstance(map_obj, dict) else {}
    out = []
    for u in root.get("units") or []:
        f = [float(v) for v in (u.get("polygon") or [])]
        poly = [(f[i], f[i + 1]) for i in range(0, len(f) - 1, 2)]
        if len(poly) >= 3 and u.get("id") is not None:
            out.append(Unit(str(u["id"]), poly))
    return out


def poly_distance(a: Unit, b: Unit) -> float:
    """两个多边形边界之间的最近距离（相交 / 重叠为 0）"""
    best = math.inf
    for p, q in a.edges():
        for r, s in b.edges():
            if _segs_intersect(p, q, r, s):
                return 0.0
            best = min(best, _seg_point_dist(p[0], p[1], q[0], q[1], *r), _seg_point_dist(r[0], r[1], s[0], s[1], *p))
    if a.contains(*b.poly[0]) or b.contains(*a.poly[0]):
        return 0.0
    return best


def adjacency(units: list[Unit], gap_cm: float) -> set[tuple[str, str]]:
    adj = set()
    for i, a in enumerate(units):
        for b in units[i + 1:]:
            if poly_distance(a, b) <= gap_cm:
                adj.add((a.id, b.id))
                adj.add((b.id, a.id))
    return adj


def room_at(units: list[Unit], x, y, boundary_cm: float = 0.0):
    """(单元 id 或 None, 是否可判)。boundary_cm > 0 时离边界太近的点不可判"""
    for u in units:
        if u.contains(x, y):
            if boundary_cm > 0 and u.boundary_dist(x, y) < boundary_cm:
                return u.id, False
            return u.id, True
    if boundary_cm > 0 and any(u.boundary_dist(x, y) < boundary_cm for u in units):
        return None, False
    return None, bool(units) and boundary_cm <= 0


def est_room(units: list[Unit], x, y, snap_cm: float):
    """估计点所在的单元；落在墙缝里（不在任何单元内）时归到 snap_cm 以内最近的单元，再远就是 None（算远处的错房间）"""
    rid = room_at(units, x, y)[0]
    if rid is not None or not units:
        return rid
    d, u = min((u.boundary_dist(x, y), u.id) for u in units)
    return u if d <= snap_cm else None


# ───────────────────────── 读入 ─────────────────────────

def _f(v):
    try:
        return float(v) if v not in ("", None) else None
    except ValueError:
        return None


def load_track(path) -> dict[tuple[str, int], list[dict]]:
    """track.csv → {(会话, 第几次回放): [行]}，行按时间排好"""
    groups: dict[tuple[str, int], list[dict]] = {}
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t, rx, ry = _f(r.get("t_ms")), _f(r.get("ref_x")), _f(r.get("ref_y"))
            if t is None or rx is None or ry is None:
                continue
            ex, ey = _f(r.get("est_x")), _f(r.get("est_y"))
            row = {"t": t / 1000.0, "ref": (rx, ry), "est": (ex, ey) if ex is not None and ey is not None else None,
                   "conv": str(r.get("converged", "0")).strip() in ("1", "true", "True")}
            groups.setdefault((r.get("session", ""), int(_f(r.get("run")) or 1)), []).append(row)
    for v in groups.values():
        v.sort(key=lambda x: x["t"])
    return groups


# ───────────────────────── 单个回放 ─────────────────────────

def replay_metrics(rows: list[dict], units: list[Unit], adj: set, p: Params = Params()) -> dict:
    """一个 (会话, 回放) 的计数和 TTFF 等。计数留着给 aggregate 合并（按点混合，不是按会话平均）"""
    have_rooms = bool(units)
    c = {"grid": 0, "reported": 0, "room_valid": 0, "room_valid_reported": 0, "room_correct": 0,
         "wrong_adjacent": 0, "wrong_far": 0, "within1m_time": 0, "fix_points": 0, "within1m_points": 0,
         "errs": [], "door_latencies": [], "door_transitions": 0, "door_missed": 0}
    if not rows:
        return {**c, "ttff_s": None, "ttff_m": None, "ttff_fixed": False, "wrong_before_first": 0, "window_s": 0}
    for r in rows:                                    # 按定位点的 ≤1 m
        if r["conv"] and r["est"] is not None:
            c["fix_points"] += 1
            c["within1m_points"] += math.dist(r["est"], r["ref"]) <= 100
    t0, t1 = rows[0]["t"], rows[-1]["t"]
    grid = []                                         # [(t, ref, est|None, 报了没有, 真值房间, 可判, 估计房间)]
    k = 0
    n = int(math.floor((t1 - t0) / p.grid_s + 1e-9)) + 1
    for i in range(n):
        g = t0 + i * p.grid_s
        while k + 1 < len(rows) and rows[k + 1]["t"] <= g + 1e-9:
            k += 1
        r = rows[k]
        if g - r["t"] > p.max_gap_s:
            continue
        rep = r["conv"] and r["est"] is not None
        tr, ok = room_at(units, *r["ref"], boundary_cm=p.boundary_cm) if have_rooms else (None, False)
        er = est_room(units, *r["est"], snap_cm=p.boundary_cm) if (have_rooms and rep) else None
        grid.append((g, r["ref"], r["est"] if rep else None, rep, tr, ok and tr is not None, er))
    path = [0.0]
    for a, b in zip(grid, grid[1:]):
        path.append(path[-1] + math.dist(a[1], b[1]) / 100)
    for g, ref, est, rep, tr, valid, er in grid:
        c["grid"] += 1
        err = math.dist(est, ref) if rep else None
        if rep:
            c["reported"] += 1
            c["errs"].append(err)
            c["within1m_time"] += err <= 100
        if valid:
            c["room_valid"] += 1
            if rep:
                c["room_valid_reported"] += 1
                if er == tr:
                    c["room_correct"] += 1
                elif er is not None and (er, tr) in adj:
                    c["wrong_adjacent"] += 1
                else:
                    c["wrong_far"] += 1

    def good(j):
        _, ref, est, rep, tr, valid, er = grid[j]
        if not rep or math.dist(est, ref) > p.ttff_err_cm:
            return False
        return er == tr if valid else True

    def holds(j, dur, ok):
        """从网格点 j 起 dur 秒内每个点都满足 ok，而且网格确实覆盖到了 j + dur"""
        end = grid[j][0] + dur
        m = j
        while m < len(grid) and grid[m][0] <= end + 1e-9:
            if not ok(m):
                return False
            m += 1
        return grid[m - 1][0] >= end - 1e-9

    # TTFF：第一次「好」并保持 ttff_hold_s
    ttff_idx = next((j for j in range(len(grid)) if good(j) and holds(j, p.ttff_hold_s, good)), None)
    window = grid[-1][0] - grid[0][0] if grid else 0.0
    if ttff_idx is None:
        ttff_s, ttff_m = window, path[-1] if grid else 0.0
    else:
        ttff_s, ttff_m = grid[ttff_idx][0] - grid[0][0], path[ttff_idx]
    # TTFF 之前的错定（按连续段）
    wrong, prev_bad = 0, False
    for j in range(ttff_idx if ttff_idx is not None else len(grid)):
        _, ref, est, rep, tr, valid, er = grid[j]
        bad = rep and (math.dist(est, ref) > p.wrong_fix_cm or (valid and er != tr))
        if bad and not prev_bad:
            wrong += 1
        prev_bad = bad
    # 过门：真值房间（只看可判的点）从 A 变到 B
    seq = [(j, grid[j][4]) for j in range(len(grid)) if grid[j][5]]
    for (ja, ra), (jb, rb) in zip(seq, seq[1:]):
        if ra == rb:
            continue
        c["door_transitions"] += 1
        tb = grid[jb][0]
        lat = None
        for j in range(jb, len(grid)):
            if grid[j][0] - tb > p.miss_s:
                break
            if holds(j, p.hold_s, lambda m: grid[m][3] and grid[m][6] == rb):
                lat = grid[j][0] - tb
                break
        if lat is None or lat > p.miss_s:
            c["door_missed"] += 1
        else:
            c["door_latencies"].append(lat)
    return {**c, "ttff_s": ttff_s, "ttff_m": ttff_m, "ttff_fixed": ttff_idx is not None,
            "wrong_before_first": wrong, "window_s": window}


# ───────────────────────── 合并 ─────────────────────────

def aggregate(reps: list[dict], have_rooms: bool = True) -> dict:
    """多个回放的计数合并成指标（按点混合）。没有房间单元时房间类指标为 None"""
    def s(k):
        return sum(r[k] for r in reps)

    def ratio(a, b):
        return round(a / b, 4) if b else None

    errs = sorted(e for r in reps for e in r["errs"])
    lats = sorted(x for r in reps for x in r["door_latencies"])
    ttff_s = sorted(r["ttff_s"] for r in reps if r["ttff_s"] is not None)
    ttff_m = sorted(r["ttff_m"] for r in reps if r["ttff_m"] is not None)
    rv, rvr = s("room_valid"), s("room_valid_reported")
    rooms = have_rooms and rv > 0

    def r1(v):
        return None if v is None else round(v, 1)
    return {
        "replays": len(reps),
        "grid_points": s("grid"),
        "room_correct": ratio(s("room_correct"), rvr) if rooms else None,
        "room_correct_all": ratio(s("room_correct"), rv) if rooms else None,
        "wrong_room_adjacent": ratio(s("wrong_adjacent"), rvr) if rooms else None,
        "wrong_room_far": ratio(s("wrong_far"), rvr) if rooms else None,
        "door_transitions": s("door_transitions") if rooms else None,
        "door_latency_p50_s": r1(pct(lats, 0.5)) if rooms else None,
        "door_latency_p90_s": r1(pct(lats, 0.9)) if rooms else None,
        "door_miss": ratio(s("door_missed"), s("door_transitions")) if rooms else None,
        "within1m_points": ratio(s("within1m_points"), s("fix_points")),
        "within1m_time": ratio(s("within1m_time"), s("grid")),
        "p50_cm": r1(pct(errs, 0.5)),
        "p90_cm": r1(pct(errs, 0.9)),
        "coverage": ratio(s("reported"), s("grid")),
        "ttff_s_p50": r1(pct(ttff_s, 0.5)),
        "ttff_m_p50": r1(pct(ttff_m, 0.5)),
        "ttff_rate": ratio(sum(bool(r["ttff_fixed"]) for r in reps), len(reps)),
        "wrong_fix_before_first_correct": round(s("wrong_before_first") / len(reps), 2) if reps else None,
    }


def compute(track_groups: dict, map_obj: dict, meta: dict | None = None, p: Params = Params()) -> dict:
    """全部回放 → {"all": 指标, "by_map_age": {桶: 指标}, "by_carry_mode": {方式: 指标}}（只有聚合值，不出坐标 / 房间名）"""
    units = load_units(map_obj)
    adj = adjacency(units, p.adjacent_gap_cm)
    per = []
    for (sess, _run), rows in sorted(track_groups.items()):
        m = replay_metrics(rows, units, adj, p)
        info = (meta or {}).get(sess, {})
        per.append((info, m))
    out = {"all": aggregate([m for _, m in per], bool(units)), "rooms": len(units)}
    for key, fn in (("by_map_age", lambda i: age_bucket(i.get("map_age_days"))), ("by_carry_mode", lambda i: i.get("carry_mode"))):
        groups: dict[str, list] = {}
        for info, m in per:
            g = fn(info)
            if g is not None:
                groups.setdefault(g, []).append(m)
        if groups:
            out[key] = {g: aggregate(ms, bool(units)) for g, ms in sorted(groups.items())}
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--track", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--meta", type=Path)
    ap.add_argument("--json", type=Path)
    for k, v in Params().__dict__.items():
        ap.add_argument("--" + k.replace("_", "-"), type=float, default=v)
    a = ap.parse_args(argv)
    p = Params(**{k: getattr(a, k) for k in Params().__dict__})
    meta = json.loads(a.meta.read_text(encoding="utf-8")) if a.meta else None
    res = compute(load_track(a.track), json.loads(a.map.read_text(encoding="utf-8")), meta, p)
    txt = json.dumps(res, ensure_ascii=False, indent=1)
    if a.json:
        a.json.write_text(txt + "\n", encoding="utf-8")
    else:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(txt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
