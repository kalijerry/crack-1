# 公开数据集基准（回归测试用）

目的：在自己 4 个小会话之外，用公开的商场数据回放同一套定位代码（`hpass-eval`），看磁场粒子滤波 + 蓝牙到底多准。

## 用的数据

| 数据 | 来源 | 许可 | 楼层 |
|---|---|---|---|
| Microsoft Indoor Location Competition 2.0 样例（杭州西溪银泰城 F1，120 条 trace，240×176 m） | GitHub `location-competition/indoor-location-competition-20`，`data/site1/F1` | MIT | `ms` |
| MLoc 官方 sample（`5d2709d9…/F1`，79 条 trace，72×361 m） | https://mloc.umn.edu/ 页面的 "Data Sample"（Google Drive 直链，免登录，约 70 MB） | © Regents of the University of Minnesota，**许可不明，只做内部研究，数据绝不入库** | `mloc` |

两者文件格式相同（每条 trace 一个 txt：`TYPE_ACCELEROMETER / GYROSCOPE / MAGNETIC_FIELD(_UNCALIBRATED) / BEACON / WAYPOINT …`，Android 坐标约定，时间戳 Unix ms）。
全量 MLoc（40 GB）、IPIN 2025、Kaggle 全量没有下载。

## 下载（数据放仓库外）

```bash
mkdir -p /private/tmp/claude-501/scratch/bench && cd /private/tmp/claude-501/scratch/bench
# Microsoft：整库约 420 MB；只取 data/site1/F1（约 240 MB），用稀疏检出
git clone --depth 1 --filter=blob:none --no-checkout https://github.com/location-competition/indoor-location-competition-20.git ilc
cd ilc && git sparse-checkout set data/site1/F1 && git checkout && cd ..
# MLoc sample
curl -L -o mloc_sample.zip "https://drive.usercontent.google.com/download?id=1F37UitIj_oPTN8UMolTX-Ehe9vOD6iPK&export=download&confirm=t"
mkdir mloc && cd mloc && unzip -q ../mloc_sample.zip
```

## 转换

```bash
python3 tools/bench/ilc_convert.py <楼层目录> <输出目录> [--drift arkit|pdr|none] [--test-n 15] [--test-min-s 45] [--seed 1]
```

输出 `map.json`（宽高 + `floorPolygons`）、`build/<trace>/`、`test/<trace>/`，均是我们的会话格式。假设与近似：

- **地图**：只有宽高 + 可走区域。可走区域 = 建图 trace 的真值路径占 1 m 格后外扩 2 m（不看测试 trace）；没有货架、没有通道中心线（所以不做自动贴通道，也没有通道走向先验）。
- **真值**：waypoint 很稀疏（约每 5 s 一个），按时间线性插值（假设点间匀速直走），所以真值本身有 1～2 m 级的误差，磁场图因此偏糊。
- **建图会话**：位姿 = 真值，锚点 = 全部 waypoint；磁场用 `TYPE_MAGNETIC_FIELD_UNCALIBRATED`（→ `mag_raw.csv`）和校准值（→ `imu.csv`）。
- **蓝牙**：iBeacon 的 MAC 当作价签 ID，RSSI 照搬；beacon 位置未知，由 `BLEFingerprintBuilder` 从建图 trace 学（指纹格子 + 价签位置），能当价签的至少 20 个才启用。注意这些 beacon 不是我们的价签，也可能有移动设备。
- **测试会话没有 ARKit**：位姿是**合成**的，不是真实 PDR。位姿 = 真值位移 → 随机初始朝向旋转 + 尺度误差 + 朝向随机游走。`arkit`：尺度 σ1%、朝向 0.5°/√s；`pdr`：尺度 σ4%、朝向 1.5°/√s。真实 PDR/VIO 的漂移形状更复杂。
- **参考轨迹**：测试会话里的 `truth.csv`（评估器直接当真值，不再对齐）。
- 建图/测试按 trace 随机切分（seed 固定）：测试 = 15 条 ≥45 s 的 trace，其余 ≥10 s 的做建图（ms：101 条，mloc：60 条）。

## 运行

```bash
tools/bench/run_ilc.sh <楼层目录> <工作目录> [每个会话重复次数]
# 例：tools/bench/run_ilc.sh .../site1F1 .../out 5
```

脚本先转换，再跑 4 种组合 × 2 种漂移。也可以手动：

```bash
cd <工作目录>/arkit
ios/HPASSKit/.build/release/hpass-eval --map map.json --build build --test test --runs 5 [--no-ble] [--oracle-start]
python3 tools/bench/dr_baseline.py <工作目录>/arkit/test     # 纯推算下限
```

对代码的小改动：`hpass-eval` 的 `--build/--test` 可以直接给父目录；`--oracle-start`（已知起点和朝向的跟踪模式，不含冷启动）；`--no-hybrid`；末尾打印 `【汇总】`（所有点混合的中位/P90/错定率）；评估器读 `truth.csv`。

## 结果（15 条测试 trace × 5 次随机种子；误差单位 cm，错定 = 误差 > 5 m）

「定位覆盖」= 参考轨迹上有多少比例的点系统给出了「已定位」结果（其余点不算误差）。**覆盖很低时，中位数只代表少数几个点**。

**ms（西溪银泰 F1），合成漂移 arkit**

| 模式 | 中位 | P90 | 错定 | ≤2 m | 覆盖 | 首次定位中位 | 定到次数 |
|---|---|---|---|---|---|---|---|
| 纯推算（已知起点，下限参考） | 27 | 148 | 0% | — | — | — | — |
| 冷启动，只磁场 | 7070 | 13452 | 96% | 2% | 68% | 15.6 m | 75/75 |
| 冷启动，磁场+蓝牙 | 2518 | 6259 | 99% | 1% | 8% | 35.7 m | 30/75 |
| 已知起点，只磁场 | 1246 | 9273 | 58% | 22% | 88% | 0 | 75/75 |
| 已知起点，磁场+蓝牙 | 590 | 6468 | 53% | 33% | 23% | 0 | 75/75 |

漂移 pdr 的结果相近（冷启动只磁场 7239/13223、错定 99%；已知起点磁场+蓝牙 455/4769、错定 48%）。

**mloc（sample 楼层），合成漂移 arkit**

| 模式 | 中位 | P90 | 错定 | ≤2 m | 覆盖 | 首次定位中位 | 定到次数 |
|---|---|---|---|---|---|---|---|
| 纯推算（已知起点，下限参考） | 65 | 535 | 11% | — | — | — | — |
| 冷启动，只磁场 | 10523 | 25037 | 96% | 3% | 73% | 13.3 m | 75/75 |
| 冷启动，磁场+蓝牙 | 533 | 951 | 52% | 17% | 1% | 37.9 m | 19/75 |
| 已知起点，只磁场 | 1804 | 20799 | 58% | 28% | 88% | 0 | 75/75 |
| 已知起点，磁场+蓝牙 | 189 | 730 | 17% | 51% | 7% | 0 | 70/75 |

pdr 漂移：已知起点磁场+蓝牙 211/678、错定 17%，其余同量级。

对比公开数字（口径不同，只作量级参考）：MLoc 论文中位 2.4 m；Microsoft 竞赛前几名约 1.5～2 m（用 WiFi，我们没用）。

## 怎么读这些结果（诚实的限制）

1. **我们的定位在这类数据上不达标**：冷启动基本都是错定（>96%）；已知起点时只磁场也是一半以上的点偏 >5 m，比纯推算还差很多——说明在开阔商场里，现在的磁场滤波会被错误的磁场匹配拖偏。蓝牙（学出来的指纹）能把已知起点的结果拉到 2 m 左右，但「覆盖」只有 1～23%，因为交叉检验/门控很少承认「已定位」。
2. 这套系统是为「货架通道 + 价签」的门店设计的，这里没有通道约束、没有价签位置表、trace 又短（中位 36 s / 35 m），冷启动在 240×176 m 的开阔楼层几乎没机会收敛；这个基准更像是压力测试，不能直接代表门店场景的精度。
3. 位姿是合成的（见上）；真值是线性插值；地图的磁场图用真值路径建、没有通道贴合；beacon 不是我们的价签。以上都使结果偏离真实使用，但对不同算法版本的**相对比较**仍然可用（同一数据、同一切分、同一随机种子）。
4. 随机性：粒子滤波每次结果差别很大，所以用 `--runs`，汇总是所有次数混合；比较算法改动时至少用 5 次。
5. 换其他楼层/站点：同样的命令；Microsoft 全量数据要 Kaggle 登录，没用。
