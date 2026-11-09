"""自采办公室「盲测机 + 真值伴随机」流水线（lab.py prepare-private 的 office-carry 协议，docs/office-test.md）。

- 盲测会话：meta.json 里 purpose = "blind_test"、camera = false、pair_id；按被测的携带方式（carry_mode）带着走，不建图、没有锚点。
- 伴随真值会话：同一个 pair_id，purpose = "ground_truth"（或 "truth_companion"），竖持开 ARKit 的建图式会话（arkit_pose + anchors），
  或者已经导出好的 truth.csv。
- 对时：两机叠在一起敲三下（开始、结束各一组），bump_sync.py 求偏移 + 漂移，残差 > 20 ms 的组不用、一组都没有就整段不用。
- 真值：伴随机轨迹（tools/magmap.py 的锚点分段对齐，ARKit 跟踪受限的时刻不要）换到盲测机的时钟，再沿行进方向往后挪杆臂
  （lever_arm_cm，默认 25 cm：伴随机举在身前，盲测机在身上），只留开始敲击之后 3 s 到结束敲击之前，写成盲测会话的 truth.csv。
- 打分：hpass-eval --motion pdr-imu 回放盲测会话的真实 IMU（arkit_pose.csv 只有表头），冷启动和已知起点各一次；
  已知起点只在手持看屏（texting 等，手机-行走夹角 δ≈0）时给真值起步朝向，其余携带方式 --start-heading unknown（整圆）。
- 报告只按 (站点代号, 携带方式, 地图年龄分桶) 聚合（office_metrics.py），不出坐标、房间名、日期。
"""
from __future__ import annotations

import csv
import json
import math
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import bump_sync  # noqa: E402

BLIND_PURPOSE = "blind_test"
COMPANION_PURPOSES = ("ground_truth", "truth_companion")
# 这些携带方式手机前向轴 ≈ 行走方向（δ≈0），已知起点时可以给真值起步朝向；其余整圆撒开
HEADING_KNOWN_MODES = ("texting", "handheld", "reading", "upright")
DEFAULT_LEVER_CM = 25.0             # 占位值，待自采 iPhone 双机数据标定；会话 meta 的 lever_arm_cm 优先
SKIP_AFTER_START_MS = 3000          # 开始敲击之后多久才开始打分（携带方式分类器要稳定）
TRUTH_MAX_RESIDUAL_CM = 50.0        # 伴随机锚点残差超过这个的会话作废
TRUTH_HZ_MS = 100                   # 真值 10 Hz


def classify(meta: dict, d: Path) -> str | None:
    """会话 → "build" / "test" / "blind" / "companion" / None（不用）"""
    purpose = meta.get("purpose")
    if purpose == BLIND_PURPOSE:
        if meta.get("camera") is False and meta.get("pair_id") and (d / "imu.csv").exists():
            return "blind"
        return None
    if purpose in COMPANION_PURPOSES:
        if meta.get("pair_id") and ((d / "truth.csv").exists() or (d / "anchors.csv").exists()):
            return "companion"
        return None
    if not meta.get("survey") or not (d / "anchors.csv").exists():
        return None
    return "test" if purpose == "test" else "build"


def pair_sessions(blinds: list[tuple[Path, dict]], comps: list[tuple[Path, dict]]):
    """按 pair_id 配对。返回 ([(盲测, 伴随, 盲测 meta, 伴随 meta)], [没配上的盲测名])；同一 pair_id 多个伴随取时间最近的"""
    by_pair: dict[str, list[tuple[Path, dict]]] = {}
    for d, m in comps:
        by_pair.setdefault(str(m["pair_id"]), []).append((d, m))
    pairs, unpaired = [], []
    for d, m in sorted(blinds, key=lambda x: x[0].name):
        cands = by_pair.get(str(m["pair_id"]), [])
        if not cands:
            unpaired.append(d.name)
            continue
        t0 = first_imu_ms(d) or 0
        c, cm = min(cands, key=lambda x: abs((first_imu_ms(x[0]) or 0) - t0))
        pairs.append((d, c, m, cm))
    return pairs, unpaired


def first_imu_ms(d: Path) -> int | None:
    p = d / "imu.csv"
    if not p.exists():
        return None
    with open(p, encoding="utf-8") as f:
        f.readline()
        for line in f:
            try:
                return int(float(line.split(",", 1)[0]))
            except ValueError:
                continue
    return None


def read_truth(p: Path) -> list[tuple[float, float, float]]:
    out = []
    with open(p, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                out.append((float(r["t_ms"]), float(r["x_cm"]), float(r["y_cm"])))
            except (KeyError, TypeError, ValueError):
                continue
    return sorted(out)


def companion_truth(d: Path, max_residual_cm: float = TRUTH_MAX_RESIDUAL_CM):
    """伴随机 → ([(t_ms, x_cm, y_cm)]（伴随机的时钟）, 不能用的原因或 None)。有 truth.csv 直接用；
    否则按 magmap.py 的锚点分段对齐 ARKit 轨迹（跟踪受限的时刻、最后锚点之后太远的不要）"""
    if (d / "truth.csv").exists():
        return read_truth(d / "truth.csv"), None
    import magmap  # tools/magmap.py（只用标准库）
    rep = {"warnings": []}
    pose = magmap.Pose(magmap.read_csv(d / "arkit_pose.csv"))
    anchors = magmap.load_anchors(d / "anchors.csv")
    segs = magmap.build_segments(anchors, pose, rep)
    if not segs:
        return [], "伴随机没有可用的锚点"
    for s in segs:
        if not s["tail"] and "resid" in s and math.hypot(*s["resid"]) > max_residual_cm:
            return [], f"伴随机锚点残差 {math.hypot(*s['resid']):.0f} cm > {max_residual_cm:g} cm"
    out, last = [], None
    si = 0
    for t in pose.t:
        while si < len(segs) - 1 and t >= segs[si + 1]["t0"]:
            si += 1
        seg = segs[si]
        if t < segs[0]["t0"] or "bad" in seg or (not seg["tail"] and t > seg["t1"]):
            continue
        if seg["tail"] and pose.path_at(t) - pose.path_at(seg["t0"]) > magmap.TAIL_MAX_CM:
            continue
        p = pose.at(t)
        if not p or not p[2]:
            continue
        if last is not None and t - last < TRUTH_HZ_MS:
            continue
        x, y = magmap.to_map(seg, (p[0], p[1]), t)
        out.append((float(t), x, y))
        last = t
    return out, None


def apply_lever(truth: list[tuple[float, float, float]], lever_cm: float, span_ms: float = 500, min_move_cm: float = 15):
    """沿行进方向往后挪 lever_cm（盲测机在伴随机后面）。行进方向 = 前后 span_ms 的位移；站着不动时沿用上一次的方向"""
    if lever_cm == 0 or not truth:
        return list(truth)
    import bisect
    ts = [t for t, _, _ in truth]
    out, last_dir = [], None
    for t, x, y in truth:
        i0 = max(0, bisect.bisect_left(ts, t - span_ms))
        i1 = min(len(ts) - 1, bisect.bisect_right(ts, t + span_ms) - 1)
        dx, dy = truth[i1][1] - truth[i0][1], truth[i1][2] - truth[i0][2]
        L = math.hypot(dx, dy)
        if L >= min_move_cm:
            last_dir = (dx / L, dy / L)
        if last_dir is None:
            out.append((t, x, y))
        else:
            out.append((t, x - lever_cm * last_dir[0], y - lever_cm * last_dir[1]))
    return out


def make_blind_session(blind: Path, comp: Path, bmeta: dict, cmeta: dict, dst: Path, map_built_ms: int | None,
                       sync_params: bump_sync.SyncParams = bump_sync.SyncParams()) -> dict:
    """配好的一对 → dst（盲测会话 + truth.csv）。返回 {ok, reason, carry_mode, map_age_days, start_heading, sync}"""
    info = {"ok": False, "name": blind.name, "carry_mode": bmeta.get("carry_mode") or "unknown"}
    sync = bump_sync.sync_files(blind / "imu.csv", comp / "imu.csv", sync_params)
    info["sync"] = {k: sync.get(k) for k in ("ok", "offset_ms", "drift_ppm", "reason")}
    if not sync["ok"]:
        info["reason"] = "对时失败：" + (sync.get("reason") or "")
        return info
    truth_b, why = companion_truth(comp)
    if why:
        info["reason"] = why
        return info
    lever = float(cmeta.get("lever_arm_cm", bmeta.get("lever_arm_cm", DEFAULT_LEVER_CM)))
    truth_a = [(bump_sync.to_a_clock(sync, t), x, y) for t, x, y in truth_b]
    truth_a = apply_lever(truth_a, lever)
    w0, w1 = sync["window_a_ms"]
    lo = (w0 + SKIP_AFTER_START_MS) if w0 is not None else -math.inf
    hi = w1 if w1 is not None else math.inf
    truth_a = [p for p in truth_a if lo <= p[0] <= hi]
    if len(truth_a) < 20:
        info["reason"] = "评分窗口里的真值太少"
        return info
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(blind, dst)
    with open(dst / "truth.csv", "w", newline="\n", encoding="utf-8") as f:
        f.write("t_ms,x_cm,y_cm\n")
        for t, x, y in truth_a:
            f.write(f"{int(round(t))},{x:.1f},{y:.1f}\n")
    if not (dst / "arkit_pose.csv").exists():
        (dst / "arkit_pose.csv").write_text("t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason\n", encoding="utf-8")
    t0 = first_imu_ms(blind)
    age = None
    if t0 is not None and map_built_ms is not None:
        age = max(0, math.floor((t0 - map_built_ms) / 86_400_000))
    info.update({"ok": True, "map_age_days": age,
                 "start_heading": "truth" if info["carry_mode"] in HEADING_KNOWN_MODES else "unknown",
                 "truth_points": len(truth_a), "lever_arm_cm": lever})
    # 对时细节留在私有工作目录（不进公开报告）
    (dst / "office_sync.json").write_text(json.dumps(sync, ensure_ascii=False, indent=1), encoding="utf-8")
    return info
