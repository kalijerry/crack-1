#!/usr/bin/env python3
"""
跨机型 RSSI 标定：用两台手机并排同时打点的数据，拟合
    rssi_参考机 ≈ a * rssi_目标机 + b
其中参考机是采集指纹库用的设备（如 S25+），目标机是要部署的设备（如 iPhone 16 Pro）。

用法：
    python calibrate.py <参考机会话目录或zip> <目标机会话目录或zip> [--out 输出目录] [--min-n 5] [--plot]
    python calibrate.py <会话目录或zip>        # 只看单个会话的统计

只依赖 Python 3.8+ 标准库；--plot 需要 matplotlib。
数据格式见 docs/data-format.md。
"""
import argparse
import csv
import json
import math
import statistics
import sys
import tempfile
import zipfile
from collections import defaultdict
from pathlib import Path

# HPASS 对手机蓝牙读数（type=1）的打分档位：type0 档位 + eslAoaEmitPower(-15)
TIER_THRESHOLDS = [(-65, 10.0), (-70, 3.0), (-80, 1.5), (-90, 1.0), (-100, 0.5)]
# HPASS executeESLPos：1 秒窗口读数 <= 10 时改用 2 秒窗口
SPARSE_SECOND_LIMIT = 10


def tier(rssi):
    for th, score in TIER_THRESHOLDS:
        if rssi >= th:
            return score
    return 0.0


# ---------------------------------------------------------------- 读取

class Session:
    def __init__(self, path: Path):
        self.dir = resolve_session_dir(path)
        self.meta = json.loads((self.dir / "meta.json").read_text(encoding="utf-8"))
        self.name = self.dir.name
        self.marks = read_csv(self.dir / "marks.csv")
        self.ble = []  # (t_ms, esl_id, rssi)
        for r in read_csv(self.dir / "ble.csv"):
            if r["esl_id"]:
                self.ble.append((int(r["t_ms"]), r["esl_id"], int(r["rssi"])))
        self.ble.sort()
        self.imu_path = self.dir / "imu.csv"

    @property
    def label(self):
        return f'{self.meta.get("device_label", "")} ({self.meta.get("model", "")}, {self.meta.get("platform", "")})'

    def readings_between(self, t0, t1):
        return [b for b in self.ble if t0 <= b[0] <= t1]

    def mark_windows(self):
        out = {}
        for m in self.marks:
            out.setdefault(m["point_id"], []).append((int(m["t_start_ms"]), int(m["t_end_ms"])))
        return out


def resolve_session_dir(path: Path) -> Path:
    if path.is_file() and path.suffix.lower() == ".zip":
        tmp = Path(tempfile.mkdtemp(prefix="eslcal_"))
        with zipfile.ZipFile(path) as z:
            z.extractall(tmp)
        path = tmp
    if (path / "meta.json").exists():
        return path
    found = sorted(p.parent for p in path.rglob("meta.json"))
    if len(found) == 1:
        return found[0]
    if not found:
        sys.exit(f"错误：{path} 里找不到 meta.json")
    sys.exit(f"错误：{path} 里有多个会话，请直接指定其中一个：\n  " + "\n  ".join(map(str, found)))


def read_csv(path: Path):
    if not path.exists():
        return []
    with path.open(encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


# ---------------------------------------------------------------- 统计

def per_second_counts(readings, t0, t1):
    n_sec = max(1, int((t1 - t0) // 1000))
    counts = [0] * n_sec
    uniq = [set() for _ in range(n_sec)]
    for t, eid, _ in readings:
        i = int((t - t0) // 1000)
        if 0 <= i < n_sec:
            counts[i] += 1
            uniq[i].add(eid)
    return counts, [len(u) for u in uniq]


def imu_summary(path: Path):
    rows = read_csv(path)
    if len(rows) < 10:
        return None
    ts = [int(r["t_ms"]) for r in rows]
    dts = [b - a for a, b in zip(ts, ts[1:]) if b > a]
    norms = [math.sqrt(float(r["ax"]) ** 2 + float(r["ay"]) ** 2 + float(r["az"]) ** 2) for r in rows]
    mag_acc = defaultdict(int)
    for r in rows:
        mag_acc[r["mag_acc"]] += 1
    return {
        "samples": len(rows),
        "hz": 1000.0 / statistics.median(dts) if dts else 0,
        "acc_norm_median": statistics.median(norms),
        "az_mean_first_2s": statistics.mean(float(r["az"]) for r in rows if ts[0] <= int(r["t_ms"]) <= ts[0] + 2000),
        "mag_acc": dict(mag_acc),
    }


def print_session_summary(s: Session):
    print(f"\n== {s.name}\n   设备：{s.label}")
    print(f"   价签读数 {len(s.ble)} 条，唯一价签 {len({b[1] for b in s.ble})} 个，打点 {len(s.marks)} 次")
    if s.ble:
        t0, t1 = s.ble[0][0], s.ble[-1][0]
        counts, uniq = per_second_counts(s.ble, t0, t1)
        sparse = sum(1 for c in counts if c <= SPARSE_SECOND_LIMIT) / len(counts)
        print(f"   读数/秒 中位数 {statistics.median(counts):.0f}，唯一价签/秒 中位数 {statistics.median(uniq):.0f}，"
              f"读数≤{SPARSE_SECOND_LIMIT} 的秒占 {sparse:.0%}")
        rssis = [b[2] for b in s.ble]
        print(f"   RSSI 中位数 {statistics.median(rssis):.0f} dBm，范围 [{min(rssis)}, {max(rssis)}]")
    imu = imu_summary(s.imu_path)
    if imu:
        print(f"   IMU {imu['samples']} 样本，约 {imu['hz']:.0f} Hz，|a| 中位数 {imu['acc_norm_median']:.2f} m/s²，"
              f"开头 2 秒 az 均值 {imu['az_mean_first_2s']:+.2f}，磁场精度分布 {imu['mag_acc']}")
        if abs(imu["acc_norm_median"] - 9.8) > 1.0:
            print("   ⚠ |a| 偏离 9.8 较多，检查加速度单位换算")


def linear_fit(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 1.0, my - mx
    a = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return a, my - a * mx


def mae(vals):
    return sum(abs(v) for v in vals) / len(vals) if vals else float("nan")


# ---------------------------------------------------------------- 标定

def calibrate(ref: Session, tgt: Session, min_n: int, out_dir: Path, plot: bool):
    ref_w, tgt_w = ref.mark_windows(), tgt.mark_windows()
    common = sorted(set(ref_w) & set(tgt_w), key=lambda p: (len(p), p))
    if not common:
        sys.exit("错误：两个会话没有相同编号的打点，无法配对。")
    only_ref, only_tgt = sorted(set(ref_w) - set(tgt_w)), sorted(set(tgt_w) - set(ref_w))
    if only_ref or only_tgt:
        print(f"\n注意：只在参考机出现的点 {only_ref}，只在目标机出现的点 {only_tgt}，已忽略")

    pairs = []          # (point, esl_id, ref_median, tgt_median, ref_n, tgt_n)
    coverage = []       # (point, ref_tags, tgt_tags, jaccard, ref_rate, tgt_rate, ref_sparse, tgt_sparse)
    for p in common:
        # 同一编号打了多次时逐次配对
        for (rs, re), (ts, te) in zip(ref_w[p], tgt_w[p]):
            t0, t1 = max(rs, ts), min(re, te)
            if t1 - t0 < 3000:
                print(f"注意：点 {p} 两台手机的打点时间重叠不足 3 秒（检查两台手机时钟或是否同时开始），已跳过")
                continue
            rr, tr = ref.readings_between(t0, t1), tgt.readings_between(t0, t1)
            by_r, by_t = defaultdict(list), defaultdict(list)
            for _, e, v in rr:
                by_r[e].append(v)
            for _, e, v in tr:
                by_t[e].append(v)
            for e in sorted(set(by_r) & set(by_t)):
                if len(by_r[e]) >= min_n and len(by_t[e]) >= min_n:
                    pairs.append((p, e, statistics.median(by_r[e]), statistics.median(by_t[e]), len(by_r[e]), len(by_t[e])))
            sr, st = set(by_r), set(by_t)
            cr, _ = per_second_counts(rr, t0, t1)
            ct, _ = per_second_counts(tr, t0, t1)
            coverage.append((p, len(sr), len(st), len(sr & st) / max(1, len(sr | st)),
                             statistics.mean(cr), statistics.mean(ct),
                             sum(c <= SPARSE_SECOND_LIMIT for c in cr) / len(cr),
                             sum(c <= SPARSE_SECOND_LIMIT for c in ct) / len(ct)))

    if len(pairs) < 5:
        sys.exit(f"错误：有效配对只有 {len(pairs)} 个（每台每价签至少 {min_n} 条读数），请延长打点时长或降低 --min-n。")

    xs = [q[3] for q in pairs]  # 目标机
    ys = [q[2] for q in pairs]  # 参考机
    diffs = [y - x for x, y in zip(xs, ys)]
    b_off = statistics.median(diffs)
    a_lin, b_lin = linear_fit(xs, ys)
    res_off = [y - (x + b_off) for x, y in zip(xs, ys)]
    res_lin = [y - (a_lin * x + b_lin) for x, y in zip(xs, ys)]

    strong = [i for i, y in enumerate(ys) if y > -65]
    weak = [i for i, y in enumerate(ys) if y <= -65]

    def tier_agree(mapper):
        return sum(tier(ys[i]) == tier(mapper(xs[i])) for i in range(len(xs))) / len(xs)

    agree_raw = tier_agree(lambda x: x)
    agree_off = tier_agree(lambda x: x + b_off)
    agree_lin = tier_agree(lambda x: a_lin * x + b_lin)

    # 线性模型只有在斜率明显偏离 1 且误差明显更小时才推荐
    use_linear = abs(a_lin - 1) > 0.1 and mae(res_lin) < mae(res_off) * 0.85
    model = {"model": "linear", "a": round(a_lin, 4), "b": round(b_lin, 2)} if use_linear \
        else {"model": "offset", "a": 1.0, "b": round(b_off, 2)}

    print("\n================ 标定结果 ================")
    print(f"参考机（指纹采集）：{ref.label}")
    print(f"目标机（部署）：    {tgt.label}")
    print(f"配对点位 {len(common)} 个，(点位, 价签) 配对 {len(pairs)} 组")
    print(f"\n差值 参考-目标：中位数 {b_off:+.1f} dB，均值 {statistics.mean(diffs):+.1f}，标准差 {statistics.pstdev(diffs):.1f}")
    print(f"仅偏移模型  rssi_ref = rssi_tgt {b_off:+.1f}        MAE {mae(res_off):.2f} dB")
    print(f"线性模型    rssi_ref = {a_lin:.3f}·rssi_tgt {b_lin:+.1f}   MAE {mae(res_lin):.2f} dB")
    if strong and weak:
        print(f"分段残差（仅偏移）：强信号(>-65) MAE {mae([res_off[i] for i in strong]):.2f}，"
              f"弱信号 MAE {mae([res_off[i] for i in weak]):.2f}")
    print(f"\nHPASS 打分档位一致率：不校正 {agree_raw:.0%} → 仅偏移 {agree_off:.0%} → 线性 {agree_lin:.0%}")

    print("\n覆盖率（每个点位）：")
    print("  点位    参考机价签 目标机价签 重合率  参考读数/秒 目标读数/秒  参考稀疏秒 目标稀疏秒")
    for c in coverage:
        print(f"  {c[0]:<7} {c[1]:>9} {c[2]:>10} {c[3]:>6.0%} {c[4]:>11.1f} {c[5]:>11.1f} {c[6]:>10.0%} {c[7]:>10.0%}")
    avg_ratio = statistics.mean(c[5] for c in coverage) / max(1e-9, statistics.mean(c[4] for c in coverage))
    print(f"  目标机读数量约为参考机的 {avg_ratio:.0%}"
          + ("；⚠ 明显偏少，HPASS 会更频繁退回 2 秒窗口，可能需要调大窗口" if avg_ratio < 0.6 else ""))

    print(f"\n推荐：{model['model']}，在目标机上把每条读数换算为 rssi = {model['a']}·rssi_raw {model['b']:+}，"
          "再送入算法（不要用 loadFpData_MS 的 offset，它只平移指纹区间、不平移打分档位）。")

    out_dir.mkdir(parents=True, exist_ok=True)
    result = {
        "reference": {"session": ref.name, **{k: ref.meta.get(k) for k in ("device_label", "model", "platform")}},
        "target": {"session": tgt.name, **{k: tgt.meta.get(k) for k in ("device_label", "model", "platform")}},
        "recommended": model,
        "offset_model": {"b": round(b_off, 2), "mae": round(mae(res_off), 3)},
        "linear_model": {"a": round(a_lin, 4), "b": round(b_lin, 2), "mae": round(mae(res_lin), 3)},
        "tier_agreement": {"raw": round(agree_raw, 3), "offset": round(agree_off, 3), "linear": round(agree_lin, 3)},
        "pairs": len(pairs),
        "points": len(common),
        "target_reading_rate_ratio": round(avg_ratio, 3),
    }
    (out_dir / "calibration.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    with (out_dir / "pairs.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["point_id", "esl_id", "ref_median", "tgt_median", "ref_n", "tgt_n"])
        w.writerows(pairs)
    print(f"\n已写出 {out_dir / 'calibration.json'} 和 pairs.csv")

    if plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            print("未安装 matplotlib，跳过画图（pip install matplotlib）")
            return
        fig, ax = plt.subplots(figsize=(6, 6))
        ax.scatter(xs, ys, s=12, alpha=0.6, label="(point, tag) medians")
        lo, hi = min(xs + ys) - 2, max(xs + ys) + 2
        ax.plot([lo, hi], [lo + b_off, hi + b_off], label=f"offset {b_off:+.1f}")
        ax.plot([lo, hi], [a_lin * lo + b_lin, a_lin * hi + b_lin], "--", label=f"linear {a_lin:.2f}x{b_lin:+.1f}")
        ax.plot([lo, hi], [lo, hi], ":", color="gray", label="y = x")
        ax.set_xlabel(f"target RSSI ({tgt.meta.get('device_label')})")
        ax.set_ylabel(f"reference RSSI ({ref.meta.get('device_label')})")
        ax.legend()
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(out_dir / "calibration.png", dpi=150)
        print(f"已写出 {out_dir / 'calibration.png'}")


def main():
    # Windows 控制台默认 GBK，统一输出 UTF-8
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference", type=Path, help="参考机（指纹采集设备，如 S25+）会话目录或 zip")
    ap.add_argument("target", type=Path, nargs="?", help="目标机（如 iPhone 16 Pro）会话目录或 zip")
    ap.add_argument("--out", type=Path, default=Path("calibration_out"), help="输出目录")
    ap.add_argument("--min-n", type=int, default=5, help="每个点位每个价签每台手机至少多少条读数才参与拟合")
    ap.add_argument("--plot", action="store_true", help="输出散点图（需要 matplotlib）")
    args = ap.parse_args()

    ref = Session(args.reference)
    print_session_summary(ref)
    if args.target is None:
        return
    tgt = Session(args.target)
    print_session_summary(tgt)
    calibrate(ref, tgt, args.min_n, args.out, args.plot)


if __name__ == "__main__":
    main()
