#!/usr/bin/env python3
"""纯推算（只用位姿，已知起点和朝向，不用磁场/蓝牙）的误差：给 hpass-eval --oracle-start 当下限参考。
用法：dr_baseline.py <测试会话父目录>
"""
import sys, os, math, bisect, statistics as st


def load(p, skip=1):
    return [l.rstrip("\n").split(",") for l in open(p).read().splitlines()[skip:]]


def main(root):
    allerr = []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        truth = [(int(r[0]), float(r[1]), float(r[2])) for r in load(os.path.join(d, "truth.csv"))]
        poses = [(int(r[0]), float(r[1]) * 100, float(r[3]) * 100) for r in load(os.path.join(d, "arkit_pose.csv"))]
        ts = [t[0] for t in truth]
        # 前 8 m 对齐旋转（和 evaluator 的 oracle-start 一致）
        a0 = poses[0]
        j = next((i for i, p in enumerate(poses) if math.dist(p[1:], a0[1:]) >= 800), len(poses) - 1)
        k = bisect.bisect_left(ts, poses[j][0])
        phi = math.atan2(truth[k][2] - truth[0][2], truth[k][1] - truth[0][1]) - math.atan2(poses[j][2] - a0[2], poses[j][1] - a0[1])
        c, s = math.cos(phi), math.sin(phi)
        errs = []
        for t, x, y in poses:
            i = bisect.bisect_left(ts, t)
            if i >= len(truth):
                break
            dx, dy = x - a0[1], y - a0[2]
            px, py = truth[0][1] + dx * c - dy * s, truth[0][2] + dx * s + dy * c
            errs.append(math.hypot(px - truth[i][1], py - truth[i][2]))
        errs.sort()
        allerr += errs
        print(f"{name}\t中位 {errs[len(errs)//2]:.0f} cm\tP90 {errs[int(len(errs)*.9)]:.0f} cm")
    allerr.sort()
    print(f"合计：中位 {allerr[len(allerr)//2]:.0f} cm  P90 {allerr[int(len(allerr)*.9)]:.0f} cm  >5m {100*sum(e>500 for e in allerr)/len(allerr):.0f}%")


if __name__ == "__main__":
    main(sys.argv[1])
