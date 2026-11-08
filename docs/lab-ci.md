# 定位实验室（Lab CI）

目的：要做到 Oriient「走一遍就能用」的水平，每一次算法改动都必须在**固定数据、固定协议**上量出来，退步当场拦住，离目标还差多少一眼看清。全部在 GitHub Actions 里跑，不依赖谁的电脑。

## 怎么跑

| 触发 | 档位 | 场景 | 结果去哪 |
|---|---|---|---|
| PR（改了 `ios/HPASSKit/Sources`、`tools/lab`、`tools/bench`） | pr | 核心 4 个公开场景 + 自采场景，每场景 3 个随机种子 | PR 评论（只保留一条，每次更新）+ 运行 Summary；**有退步 PR 检查失败** |
| push 到 main | pr | 同上 | 看板「评估」 |
| 每晚 北京时间 02:00 | nightly | 全部场景，5 个种子 | 看板「评估」，最上面是趋势表 |
| 手动（Actions → Lab → Run workflow） | 可选 | 可只跑某些场景 | 可勾「把这次结果提成新基线」 |

工作流：[.github/workflows/lab.yml](../.github/workflows/lab.yml)；场景、门槛、档位：[tools/lab/suite.json](../tools/lab/suite.json)；运行器：[tools/lab/lab.py](../tools/lab/lab.py)。

## 数据和协议

**公开数据**（每次都跑，不需要任何口令）：Microsoft Indoor Location Competition 2.0 商场一层（MIT 许可，CI 里下载并缓存）。测试会话的位姿是合成漂移，见 [benchmark.md](benchmark.md)。

| 场景 | 意义 |
|---|---|
| `public/pdr/track-mag` | 已知起点 · 只地磁 · 无摄像头（PDR 级漂移）：磁场图 + 滤波本身有多准 |
| `public/pdr/cold-mag` | 冷启动 · 只地磁 · 无摄像头：最难，也是通用场景的主战场 |
| `public/pdr/cold-mag-radio` | 冷启动 · 地磁 + 蓝牙 |
| `public/pdr-sparse/track-mag` | 建图只用 15 条 trace：模拟「只走几趟」的稀疏建图 |
| `public/vio/*`、`public/pdr/track-mag-radio` | 每晚跑：视觉里程计级漂移、已知起点 + 蓝牙 |

**自采数据**（有后台口令时自动加入）：后台里每张地图的建图会话和测试会话（采集时打开「这次是测试会话」）。

| 协议 | 做法 |
|---|---|
| `walk-once` | **每个建图会话单独建图（= 只走一遍）**，用不是同一天的测试会话来测，所有组合混在一起出指标。这是对标 Oriient「走一遍就能用」的核心指标 |
| `all-builds` | 全部建图会话融合后测 |

仓库是公开的：报告、日志里站点只用哈希代号（`site-xxxxxx`），不出现地图编号、名称、会话内容。

## 指标与判定

每个场景把所有测试会话、所有随机种子的定位点混在一起：中位、P75（IPIN 竞赛口径）、P90、错定（误差 > 5 m 的比例）、覆盖（参考轨迹上有多少比例给出了定位）、首次定位前走的距离、定到率。

- **退步**（PR 失败）：和 `tools/lab/baseline.json` 比，中位变差超过 15% + 0.3 m、P90 变差超过 15% + 0.6 m、错定多 5 个点、覆盖少 7 个点、定到率少 10 个点；或者以前能跑的场景现在跑不出结果。容差是给粒子滤波的随机性留的。
- **档位**（只显示，不拦）：

| 档位 | 中位 | P90 | 错定 | 覆盖 |
|---|---|---|---|---|
| 可用 | ≤ 3 m | ≤ 6 m | ≤ 20% | ≥ 50% |
| 目标 | ≤ 2 m | ≤ 4 m | ≤ 10% | ≥ 60% |
| 对标 Oriient | ≤ 1.5 m | ≤ 3 m | ≤ 5% | ≥ 70% |

报告里每个场景都写着「离对标 Oriient 还差多少」。覆盖也是门槛，防止靠「只在有把握的少数点上报位置」刷指标。

## 基线

1. 第一次：还没有 `baseline.json`，实验室只报告不拦。合并后手动跑一次 nightly 并勾「把这次结果提成新基线」，工作流会推一个 `lab/baseline-<运行号>` 分支并尝试开 PR（仓库设置里没允许 Actions 开 PR 时，日志里给出手动开 PR 的链接）。
2. 之后：算法有了确定的改善（报告里一片 🟢），同样操作更新基线，把进步「锁住」。
3. 加新场景：改 `suite.json`；新场景没有基线时标 🆕，不拦。

## 本地

```bash
python -m unittest tools/tests/test_lab.py
```

```bash
python tools/lab/lab.py report --results lab-results.json --baseline tools/lab/baseline.json
```

`run` 需要 `hpass-eval`（macOS 上 `swift build -c release --product hpass-eval`），一般直接用 CI。

## 下一步

- 多楼层场景：接入带气压的公开数据（IPIN 竞赛数据）后加楼层判对率，按 IPIN 口径楼层错一层罚 15 m。
- 无摄像头的真实 PDR：等运动模型（P3）进 `hpass-eval` 后，自采测试会话改用真实计步回放，不再用视觉里程计。
- 耗时与耗电：回放计时已记录（`seconds`），后续加每秒计算量的预算。
