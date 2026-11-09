# 携带无关的运动模型（口袋 / 摆臂 / 通话 / 包）

终端用户不开摄像头、手机怎么带都行：口袋、手里摆、贴耳、包里、边走边看。这份文档说明 HPASSKit 里为此改的运动核心、
哪些数值是**占位值**、要用什么数据标定、App / 评估怎么接。

## 问题

原来的惯导假设「手机前向轴 = 行走方向」：看屏时成立，手机进口袋 / 换手 / 拿起来看，前向轴和行走方向的夹角 δ 就突变几十到一百多度，
粒子滤波的航向偏差（随机游走 2°/√m）跟不上，位置冻住或锁到别处。公开 Lab 的「无摄像头」场景是合成漂移，根本不经过 FusionEngine，
所以今天的「可用」说明不了口袋和摆臂。

## 做法（全部在配置后面，默认关，行为不变）

```
IMUSample(50 Hz, 可选重力列 / 四元数)
  ├─ FusionAttitudeFilter   up 优先用重力列（陀螺辅助），没有就互补滤波；偏航只由 ω·up 积分
  ├─ FusionStepDetector     可选自适应阈值 + 步频锁；K 按模式表
  └─ CarryModeClassifier    重力系特征 → texting / upright / calling / swinging / pocket / bag / still + 「操作手机」事件
            │
            ▼ CarryMotionEvent（initial / changed / handled）
MagneticLocalizer.apply(_:)  按模式切特征权重 / 噪声下限 / 随机游走；changed → 按新模式先验重撒航向偏差与步长比例
                              （粒子位置不动），之后走一段不判丢，期间按「找位置」的强度用地磁
```

1. **输入**：`IMUSample.gravity` / `attitude`（格式 v4 列，见 `docs/data-format.md`），`IMUSample.fromCSV` 读；老数据 nil，退回原来的滤波。
   `MagneticFeatureExtractor` 有重力列时直接用它当「向上」（摆臂时 Bz 误差从几 µT 降到 1 µT 以内，合成数据），或由外部 `setUp` 给姿态滤波的 up。
2. **携带模式分类** `CarryModeClassifier`：2 s 窗、全部在重力系算（屏幕法线倾角、长轴倾角、陀螺 RMS、陀螺能量单轴占比、
   偏航率在步幅 / 步频上的能量比、线加速度起伏、步频），规则 + 阈值表 `CarryModeThresholds`，1.5 s 滞回；
   「操作手机」= 1 s 内陀螺峰值 > 2.5 rad/s 且向上方向转过 > 40°，事件后冻结 1.2 s、清窗口、快速重判（切换延迟 ≈ 2.5～3 s）。
   `HoldClassifier` 变成它的映射壳，公开接口（`process` / `reset` / `tiltDeg`）不变，`HoldPosture` 多了 calling / pocket / bag。
   App 可以把近距离传感器塞进 `proximityNear`：竖直的手机贴着脸一律算通话（竖持 δ ≈ 0 和通话 δ ≈ ±90° 的先验相反，分错的代价不对称）。
3. **航向**：引擎报的始终是**前向轴**（+y，竖持时 −z，切换按几何补偿）的方位角；行走方向 = 它 + δ，δ 由粒子滤波每个粒子的航向偏差吸收。
   看屏 / 竖持 δ ≈ 0；通话：手机离竖直 < 30° 时前向轴 −z 指向侧面 δ ≈ ±90°，后仰更多时切回 +y 指向后方 δ ≈ 180°（合成数据验证过），
   所以通话先验是 ±90° / 180° 三峰；口袋 / 包 / 摆臂整圆。摆臂 / 口袋用一个步幅周期（两步）的圆平均航向推步，不在步事件瞬间采样
   （合成摆臂：步内航向抖动从 14° 降到 3°）。步内航向噪声按模式表。
   注意：手机大幅翻转时陀螺偏航积分不保几何（合成 texting → pocket 之后引擎航向偏了 90°，不是口袋几何的 35°），所以「操作手机」
   事件本身就把航向偏差整圆撒开，不等分类器。
4. **粒子滤波** `MagneticLocalizer.carryModeChanged(spreadDeg:centersDeg:scaleSigma:keepBias:suppressLostCm:)`：
   只动偏差和步长比例，粒子位置不动；之后 `suppressLostCm` 内不判丢、地磁按找位置的强度（不打 convergedMagWeight 折扣、不按相关长度变软）、
   估计只在另一团明显更重时才换簇（不走 15 次远跳确认）。`setCarryMode` / `apply` 第一次告知不重撒（起点先验还有效）。
   `MagneticConfig.carryModeAdaptive`（默认关）+ `carryTable`。
5. **计步** `FusionStepDetector.adaptive`：阈值 = clamp(max(0.5 σ_dyn, 0.35 × 最近几步峰谷差), 1.0, 2.5)，步频锁丢掉距上一步 < 0.6 步周期的峰；
   K 按模式表 × 在线学到的比例：`FusionEngine.applyLearnedStepScale(粒子步长比例中位数, for: 模式)`（吸收一半、限幅 0.6～1.7、可持久化），
   调用方随后 `MagneticLocalizer.absorbStepScale` 把粒子比例除回去。设计上收敛后每走 50 m 做一次。
6. **地磁特征权重 / 噪声下限**按模式表（摆臂基本只信 |B|）。

## 占位值（待自采 iPhone 双机数据标定）

RIDI / NILoc 的数字因许可证**全部作废**，下表没有任何一个数值来自它们。每个都要用办公室双机协议（`docs/office-test.md`，
手机 A 按被测方式携带、手机 B 竖持跑 ARKit 做真值，开始 / 结束各敲三下对时）采到的 iPhone 数据重拟。

| 参数 | 现在的占位值 | 怎么标 |
|---|---|---|
| `CarryModeThresholds` 全部阈值 | 物理直觉（口袋大腿摆 ±25° → 陀螺 RMS ≥ 1.3；摆臂 ≥ 1.6、多轴；手持 < 0.9 …） | 各模式各 ≥ 3 人 × 2 机型的会话，`CarryFeatures` 写日志，离线小决策树 / 网格搜索，留出受试者混淆矩阵 ≥ 90%；特别要量 bag（现在几乎没有可靠特征）和坐下 / 起身对「操作手机」事件的误触发 |
| `CarryMotionTable.stepLengthK` | 全部 0.45（现有常量） | 每模式 len_ratio 拟 K；同时量 `applyLearnedStepScale` 在线回写够不够（人际差异和模式间差异一样大，表只是先验） |
| `initialScaleSigma` | 0.10～0.15 | 各模式 K 的人际 / 段际离散 |
| `headingSpreadDeg` / `headingCentersDeg` | texting / upright 15°，calling ±90°/180° 各 30°，其余整圆 | 切换后引擎航向与真值行走方向的夹角分布 |
| `headingBiasWalkDegPerM` | 2 / 2 / 3 / 4 / 5 / 5 | 去 30 s 趋势后夹角的抖动 |
| `stepHeadingSigmaDeg` | 3 / 3 / 10 / 6 / 8 / 10 | 步内航向残差 |
| `featureWeights` / `observationSigmaFloorUT` | texting (0.5,1,0.25)/4（现有跟踪档）… swinging (1,0.3,0.1)/6 | `hpass-eval --residuals` + `tools/bench/mag_residuals.py` 按模式出 t 尺度 / 相关长度；口袋高度（0.8 m）和建图高度的梯度差先做「手持 + 髋部两机同走」的残差实验 |
| `StepDetectorTuning` | 0.5 σ / 0.35 × 峰谷差 / 1.0～2.5 / 0.6 周期 | 各模式 steps_ratio 0.97～1.03（含快走） |
| `lostSuppressCm` | 800 / 1500 | 切换后重新收紧航向要走的路（合成走廊里 5～10 m） |
| `CarryMotionConfig.handledSpreadDeg` | nil（整圆） | 看「换手 / 拿起来看」这类小动作的 δ 变化；若多数 < 45° 可改成 45 |

## 接法

App（终端用户定位页，`MagneticEngine.makeFusion` / `makeLocalizer`）：
```swift
fcfg.motion.enabled = true                     // 分类器在引擎里跑；有近距离传感器就设 fusion.proximityNear
mcfg.carryModeAdaptive = true                  // 跟踪档 + 分模式
fusion.onCarryEvent = { [loc] ev in loc.apply(ev) }   // 同一串行队列
// 收敛后每 50 m：let s = loc.scaleStatistics().median; let f = fusion.applyLearnedStepScale(s, for: fusion.activeCarryMode); loc.absorbStepScale(f)
// localizer.reset 之后要重新告知：loc.setCarryMode(fusion.activeCarryMode)
```
界面照旧读 `HoldClassifier.process` → `HoldPosture`（或 `.carryMode`），track.csv 的 posture 列会多出 calling / pocket / bag。
评估（`SessionEvaluator` 的 `.pdrIMU` 路径）同样三行；Lab 的 `public/imu/*` 场景是手持 Android，分类器应判成 texting / upright，重撒不会触发。

## 测试

`CarryMotionTests`（合成 IMU，`SyntheticCarryIMU.swift`：人 + 手机刚体运动，加速度 / 陀螺 / 磁场 / 重力列 / 四元数自洽，
每种携带姿态有自己的周期性运动，姿态切换用 1 s 球面插值）：分类各姿态 ≥ 80%、切换 6 s 内判出、事件时刻、静止沿用携带姿态；
看屏 → 竖持航向不变；口袋夹角常数；通话几何 ±90°/180°；摆臂步幅平均；重力列 vs 加速度低通的 Bz；自适应计步不计次峰；
分模式 K 与在线标定；`carryModeChanged` 粒子不动、整圆 / 双峰 / 保留原偏差、保护期；整条流水线看屏 20 m → 口袋 / 通话 / 摆臂 30 m：
末端误差 13 / 24 / 41 cm、没判丢、重撒那帧估计不瞬移；同一剧本老路径（没有重撒）口袋末端误差 55 m。

合成数据只能证明机制对，证明不了数值对：所有阈值和表都要按上面的办法用自采数据重标。
