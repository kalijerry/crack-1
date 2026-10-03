# HPASSKit

室内定位与导航的 Swift 实现，纯 Foundation，无第三方依赖。iOS 16 / macOS 13 起。

算法全部基于公开文献自行实现（见下方「方法来源」），不依赖任何厂商 SDK。

## 模块

| 模块 | 职责 | 主要方法 |
|---|---|---|
| `Models/` | 坐标类型、门店数据解析（地图 / 指纹 / 价签 JSON） | — |
| `Positioning/` | 蓝牙指纹定位 | 高斯指纹似然、WKNN 加权质心、HMM 在线 Viterbi |
| `Fusion/` | 惯导推算与融合 | 互补滤波姿态、峰谷计步、Weinberg 步长、3 状态 EKF |
| `Routing/` | 路径规划与导航提示 | 通道建图、A\*（带转弯惩罚）、最近邻 + 2-opt、路线防抖 |

三个模块互相独立，可以单独使用。

## 单位与坐标约定

- **长度单位：厘米**，公开接口一律用厘米。`Fusion` 内部用米，只在边界换算。
- **坐标系：屏幕坐标，+x 向右，+y 向下**。因此正的转角表示右转。
- **朝向：`headingRad = 0` 指向地图 +y**，`dx = L·sinθ`，`dy = L·cosθ`。
  `magneticDeclinationDeg` 定义为地图 +y 轴的磁罗盘方位角，由调用方提供。

## 快速上手

```swift
import HPASSKit

// 1. 读门店数据
let map = try StoreDataLoader.loadMap(Data(contentsOf: mapURL))
let points = try StoreDataLoader.loadFingerprints(Data(contentsOf: fpURL))
let esls = try StoreDataLoader.loadEslItems(Data(contentsOf: eslURL))

// 2. 定位
var cfg = PositioningConfig()
cfg.rssiOffset = 7.0          // 跨机型补偿，由 tools/calibrate.py 得出
let positioner = FingerprintPositioner(points: points,
                                       eslToShelf: StoreDataLoader.eslToShelf(esls),
                                       config: cfg)
print(positioner.validate())   // 空数组表示数据没问题

// 3. 融合
let fusion = FusionEngine(map: map)

// 蓝牙回调里
positioner.add(readings)

// 每秒一次
if let fix = positioner.estimate(nowMs: now) {
    fusion.updateFix(position: fix.position, confidence: fix.confidence, tMs: now)
}

// IMU 回调里（约 50 Hz）
if let out = fusion.process(imuSample) {
    // out.position 厘米，out.headingRad 弧度
}

// 4. 导航
let planner = RoutePlanner(map: map)
let session = NavigationSession(planner: planner)
_ = session.start(targets: targetPoints, from: out.position)
if let hint = session.onLocation(out.position) {
    // hint.direction / hint.remainingDistance / hint.route
}
```

## 线程约定

`FingerprintPositioner`、`FusionEngine`、`NavigationSession` 都**不是线程安全的**，内部也没有加锁。
请在同一个串行队列上调用。蓝牙和传感器回调本来就需要串行化，在那个队列上调用即可。

## 跨机型 RSSI 补偿

指纹库在哪台设备上采集，就只在那台设备上直接可用。换机型必须先标定：

- 有另一台设备可对照：用 `tools/calibrate.py`，两台并排同时打点。
- 只有新设备：用 `RSSICalibrator.fit`（站在已知指纹点上）或 `.fitBlind`（边走边录），
  在指纹库上网格搜索使命中率最高的偏移量。

补偿通过 `PositioningConfig.rssiScale / rssiOffset` 作用在**原始读数**上。

## 方法来源

| 技术 | 参考 |
|---|---|
| 概率指纹定位 | Roos et al. (2002)；Horus 系统 |
| WKNN 加权质心 | 指纹定位的标准做法 |
| HMM + 在线 Viterbi | 轨迹平滑的标准做法，转移受可走图约束 |
| 互补滤波姿态 | Mahony et al. (2008) |
| 计步步长估计 | Weinberg (2002) |
| 扩展卡尔曼滤波 | 标准教材 |
| A\* 搜索 | Hart, Nilsson & Raphael (1968) |
| 最近邻 + 2-opt | 旅行商问题的经典启发式 |
| 道格拉斯-普克化简 | Douglas & Peucker (1973) |

## 状态

代码已写完并带有单元测试，但**尚未在真机验证**。编译与测试由 CI（macOS runner）执行。
关键常量（步长系数、磁校正增益、过程噪声、卡方门限等）都标注了需要用真实数据标定，
各模块源码里有说明。
