#!/bin/bash
# 跑 ILC 基准：./run_ilc.sh <楼层目录> <工作目录> [runs]
# 先转换（arkit / pdr 两种合成漂移），再用 hpass-eval 跑 冷启动 / 已知起点 × 磁场 / 磁场+蓝牙，最后给纯推算下限。
set -e
FLOOR="$1"; WORK="$2"; RUNS="${3:-3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/../../ios/HPASSKit/.build/release/hpass-eval"
(cd "$HERE/../../ios/HPASSKit" && swift build -c release --product hpass-eval 2>&1 | tail -1)
for drift in arkit pdr; do
  D="$WORK/$drift"
  [ -d "$D/test" ] || python3 "$HERE/ilc_convert.py" "$FLOOR" "$D" --drift "$drift"
  echo "=== 合成漂移：$drift"
  echo "--- 纯推算（已知起点+朝向，不用磁场/蓝牙）"
  python3 "$HERE/dr_baseline.py" "$D/test" | tail -1
  for mode in "冷启动:" "已知起点:--oracle-start"; do
    for ble in "只磁场:--no-ble" "磁场+蓝牙:"; do
      echo "--- ${mode%%:*} / ${ble%%:*}"
      (cd "$D" && "$EVAL" --map map.json --build build --test test --runs "$RUNS" ${mode#*:} ${ble#*:} | grep -E "【汇总】|蓝牙指纹")
    done
  done
done
