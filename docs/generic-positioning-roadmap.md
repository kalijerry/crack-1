# 通用室内定位：技术调研与开发方向（对标 Oriient）

2026-11-08 定。前面的工作（[oriient-benchmark-plan](oriient-benchmark-plan.md)、[roadmap](roadmap.md)）都围绕**一家有蓝牙价签的建材卖场**。那是一个特殊场景：价签 BLE 密度极高、货架通道平行、单层、通道轴对齐。本文把方向扩到**通用场景**（商场、写字楼、医院、机场、地下车库、仓库、普通门店），对标 Oriient 的「只用手机、不装硬件」产品形态。

> 说明：Oriient 的算法不公开，下面关于它的描述只来自官网和公开报道，属于营销口径，不是实测。论文数字是作者自报，口径各不相同，只作量级参考。

---

## 0. 结论先行

1. **门店方案里真正通用的部分**：地磁粒子滤波、ARKit 当建图真值、会话偏移对齐（云端融合）、变化检测、hpass-eval 评估体系。**不通用的部分**：价签位置表、通道中心线约束、曼哈顿航向先验、单层假设、依赖 ARKit 视觉里程计做实时运动模型。
2. **最大的短板已经被公开数据集量出来了**（[benchmark.md](benchmark.md)）：在开阔商场（西溪银泰 F1、MLoc），冷启动 96% 以上错定，已知起点只用地磁也有 58% 的点偏 > 5 m，比纯推算还差。通用化的第一件事不是加新传感器，而是让地磁滤波在**没有通道约束的开阔区域**不被错误匹配拖偏。
3. Oriient 的护城河不是某个算法，而是：①不开摄像头、手机放口袋也能用的运动模型；②一个人拿手机走一遍就能建图；③用户数据持续刷新地图；④iOS + Android 后台运行的 SDK。我们 ①④ 差得最远，②③ 已有雏形。
4. 建议的开发顺序：**通用地图模型 → 开阔区域地磁 → 多楼层 → 无摄像头运动模型 → 可插拔无线观测 → 众包建图/更新 → SDK 产品化**。每一步都用公开数据集 + 自采数据的回放门槛把关，沿用现有「门槛不过不进下一阶段」的规矩。
5. 本次已落地两块地基：气压计楼层检测 `FloorDetector`（Swift，带测试）和 IMDF 通用场馆地图导入 `tools/venue/imdf_convert.py`（Python，带测试）。

---

## 1. 门店 vs 通用场景：差在哪

| 维度 | 现在的门店 | 通用场景 | 对算法的影响 |
|---|---|---|---|
| 空间结构 | 平行长通道，宽 1.4 m，路网清楚 | 商场中庭、大厅、走廊 + 房间、车库车道 | 不能再假设「人在通道中心线上」；需要**墙体/不可走区域约束**而不是**路网约束** |
| 航向先验 | 货架 0°/90°，曼哈顿先验很强 | 斜墙、弧形中庭、开放空间 | 曼哈顿先验只能作为可选项，按地图自动判断 |
| 楼层 | 单层 | 多层，电梯 / 扶梯 / 楼梯 / 坡道 | 要楼层状态、楼层切换检测、连接体（connector） |
| 无线基础设施 | 2 万多个价签 BLE，位置表已知 | 可能有 Wi-Fi、少量 iBeacon，也可能什么都没有 | 无线必须是**可插拔的增强项**，不能是前提 |
| 手机姿态 | 手持看屏（导航时） | 看屏、口袋、摆臂、通话、包里、推车 | 运动模型要按持握方式切换；不能依赖摄像头 |
| 运行方式 | App 前台、亮屏，可以开 ARKit | SDK 嵌在别人 App 里，常在后台 | 摄像头只能用于建图和偶尔的重定位，不能常开 |
| 地图来源 | 门店服务器的 Konva 风格 JSON | IMDF、GeoJSON、DXF/CAD、OSM indoor、RoomPlan 扫描 | 需要**场景无关的地图模型**和多种导入器 |
| 规模 | 1.8 万 m²，一层 | 商场 5～10 万 m²，多层；机场更大 | 冷启动搜索空间大十倍，必须有粗定位先验（Wi-Fi / 入口 / 上次位置 / GPS 进门点） |
| 磁场环境 | 钢货架多，起伏大 | 开阔区起伏小，车库钢筋 + 车辆多 | 开阔区磁场信息量低，要更长的序列、更保守的「定到」判定 |

---

## 2. Oriient 拆解与差距

### 2.1 公开可知的产品能力

| 能力 | 公开说法 | 来源 |
|---|---|---|
| 技术 | 建筑物磁场 + 手机内置传感器，不装信标、不依赖 Wi-Fi | 官网技术页 |
| 精度 | 约 1 m（3 ft），「整段行程都保持」 | 官网 |
| 建图 | 训练过的建图员拿普通手机走一遍，生成定位图层存云端，只建一次 | 官网技术页 |
| 持握 | 拿在手上、垂在身侧、放口袋都支持 | 官网「7 ways」 |
| 后台 | 通话、发消息、手机进口袋时继续定位，可做到店内邻近推送 | 官网「7 ways」 |
| 平台 | iOS + Android，轻量 SDK / 演示 App / 白标 App / 嵌入客户 App；后台和 API 管理内容 | 官网 |
| 离线 | 不需要网络即可定位 | 官网 |
| 规模 | 「全球数千个地点」；2022 年 A 轮 1100 万美元；上架 Google Cloud Marketplace | 官网、TechCrunch |
| 场景 | 零售（导航到商品、拣货、邻近营销、客流分析）、智慧楼宇、医院 | 官网 |

同类产品 IndoorAtlas 走的是「地磁 + Wi-Fi + 蓝牙 + 气压计楼层 + 视觉（AR 导航）」的混合路线，也可以作为第二个对标对象：Oriient 代表「纯手机、无硬件」，IndoorAtlas 代表「什么信号都用上」。

### 2.2 我们和它的差距（按能力）

| 能力 | Oriient | 我们现在 | 差距 | 优先级 |
|---|---|---|---|---|
| 开阔区域地磁定位 | 商场、楼宇可用 | 门店通道里中位 0.6 m（自测，偏乐观），跨会话 2.5～5 m；开阔商场基准错定 > 50% | **大** | P1 |
| 多楼层 | 支持（推断：零售多层门店、楼宇） | 单层；气压只录不用 | 大 | P2 |
| 无摄像头运动模型 | 口袋、身侧都行 | 实时定位主要靠 ARKit 视觉里程计；计步在掉头时会转错，竖拿少算三成 | **大** | P3 |
| 后台运行 | 支持 | 必须前台亮屏 | 大 | P3 / P6 |
| 建图效率 | 一人走一遍 | 一人走一遍 + ARKit 真值 + 路线规划 + 云端多会话融合 | 小（我们有真值，可能更准） | 已有 |
| 地图持续更新 | 用户数据持续刷新（推断） | 变化检测 + 「定位即采集」只记录不并入 | 中 | P5 |
| 跨机型 | 任何手机 | iPhone 16 Pro 为主；RSSI 跨机型标定已有，磁力计偏置/灵敏度跨机型没做 | 中 | P5 |
| Android | 支持 | 只有采集 App，没有定位 | 大 | P6 |
| 无线增强 | 不依赖 | 价签 BLE 很强，但只适用价签门店 | — | P4（做成可选） |
| 评估体系 | 不公开 | hpass-eval + 公开数据集基准 + 精度测试页 | 我们的优势 | 维持 |

---

## 3. 技术调研（按层）

### 3.1 运动模型（决定一切的地基）

| 方法 | 代表工作 | 精度量级 | 适不适合我们 |
|---|---|---|---|
| 计步 + 步长 + 航向（PDR） | Weinberg 步长（2002）；峰谷/过零计步 | 行程的 2～5%，航向误差主导 | 已有。要补：持握方式分类后分模型、掉头检测、步长在线学习 |
| 学习型惯导（只用 IMU） | RoNIN（2020，ResNet/LSTM/TCN，任意持握）；TLIO（2020，网络出位移 + EKF）；EqNIO（ICLR 2025，旋转等变，跨数据集泛化更好）；TinyIO（轻量化） | 公开数据集上 ATE 约 3～6 m / 数分钟 | **最值得做**。它正是「口袋里、身侧」这种场景的解法。注意 RoNIN 代码 GPL-3.0，要自己训练、自己实现网络，CoreML 部署 |
| 视觉惯导（VIO） | ARKit / ARCore | 行程的约 1%（我们实测路径段 0.1～0.6 m） | 已有。只适合建图、短时重定位；通用 SDK 不能常开摄像头 |
| 地图约束 | 粒子穿墙即淘汰（地图匹配），路网约束 | 把漂移限制在可走区域内 | 门店已有通道版；通用场景要做**墙体/多边形版** |

**判断**：Oriient 的「口袋里也准」几乎一定靠的是好运动模型 + 地图约束，而不是更好的磁场匹配。我们的路线是：ARKit 会话（我们已大量采集，有 IMU 和 VIO 真值）**天然就是学习型惯导的训练数据**——每次建图采集都在给 P3 攒标注。

### 3.2 地磁

| 主题 | 代表工作 | 要点 | 我们的状态 |
|---|---|---|---|
| 特征 | 多数文献用 \|B\|、竖直分量、水平分量 | 与朝向无关；全向量信息多但对姿态误差敏感 | 用 \|B\| / Bz / Bh；全向量待做 |
| 建图插值 | Solin 等，GP 建模环境磁场（IEEE T-RO 2018）；局部 GP | 高斯过程带不确定度，留出法更准 | 局部 GP 已做（留出误差好 18～26%） |
| 序列匹配 | MaLoc（UbiComp 2014）；Magil（EWSN 2017，把匹配当最短路）；DTW 系列 | 单点信息太少，必须 10～30 m 序列 | 粒子滤波隐式用序列；**冷启动缺显式序列检索** |
| 粒子滤波 | Haverinen & Kemppainen（2009，IndoorAtlas 前身）；多模态 PF + Wi-Fi（办公室约 2 m） | 多假设、重尾似然 | 已有（Student-t、冻结、跳变保护） |
| 磁场 SLAM | Kok & Solin（2018，可扩展 GP 磁场 SLAM）；1D 磁场 SLAM；Viset 等 EKF 磁场 SLAM | 无外部真值时靠回环纠偏 | 第 6 阶段参考，未做 |
| 众包建图 | Luo 等（Sensors 2017，DTW 聚类轨迹建图，0.48 m）；CrowdMagMap（IEEE IoT-J 2024，学习型惯导 + 关键帧关联，商场平均 1.48 m）；CrowdMagMap 2.0（多层地下车库，2.19 m） | **学习型惯导 + 磁特征关联**是众包建图的主流组合 | 云端多会话融合（偏移对齐）有了，轨迹本身还需要真值 |
| 深度学习直接回归 | 多尺度 TCN + LSTM（2021）等 | 需要大量场地数据，换场地要重训 | 不建议作为主路线 |
| 设备差异 | 各文献都提到硬磁偏置、灵敏度差异 | 跨会话「整体偏移」是主误差 | 会话偏移对齐 + 混合模式已做；跨机型灵敏度未做 |

**开阔区域失败的原因**（结合基准结果的诊断）：
1. 开阔区磁场起伏小、相似位置多，粒子云是多峰的，而我们在多峰时就宣布「定到」→ 错定率高。需要**多峰检测 + 更严格的收敛判据**（主峰权重、次峰距离、持续时间）。
2. 没有通道约束后，航向漂移可以把粒子云带到任意方向，地磁似然在相似区域里「接住」错误假设。需要**墙体约束**（穿墙淘汰）和**航向偏差作为粒子状态**（已部分有）。
3. 测试 trace 很短（中位 36 s / 35 m），本来就不够收敛。要分开报「≥ 60 s 的 trace」的结果，避免被短 trace 掩盖改进。

### 3.3 无线

| 技术 | iOS | Android | 精度量级 | 需要基础设施 | 结论 |
|---|---|---|---|---|---|
| Wi-Fi 指纹（RADAR 2000、Horus 2005） | **不开放扫描** | 可以，但 Android 9+ 前台限流（每 2 分钟 4 次） | 3～5 m，楼层判定很好 | 现有 AP | Android 端的冷启动 / 楼层先验 |
| Wi-Fi RTT（802.11mc FTM） | 不开放 | Android 9+，需 AP 支持 | 1～2 m | 支持 FTM 的 AP | Android 可选增强 |
| BLE 信标指纹 / 测距 | 可以（iBeacon 需知道 UUID） | 可以 | 2～5 m | 信标 | 门店价签是特例；通用 iBeacon 做成同一接口 |
| BLE 5.1 AoA/AoD | 手机端基本不可用 | 有限 | < 1 m | 定位基站 | 不做 |
| UWB | 需要锚点，第三方接入受限 | 部分机型 | 0.1～0.3 m | 锚点 | 不做（违背无硬件定位） |
| GPS / GNSS | 室内无效 | 同 | — | — | 用于**进门点**：室外到室内的最后一个好 fix 作为冷启动先验 |

**结论**：无线在通用方案里是「有就用、没有也能跑」的**可插拔观测**。iOS 上通用场景几乎只有 BLE（和 GPS 进门点）可用，这也是 Oriient 选择纯地磁的原因。

### 3.4 视觉与几何

| 技术 | 用途 | 状态 |
|---|---|---|
| ARWorldMap 视觉重定位 | 房间尺度绝对位置；冷启动/跟丢恢复 | 房间已做（0.1～0.6 m） |
| 招牌 / 门牌 OCR | 绝对地标（商场店铺名、写字楼房间号、机场登机口） | 门店货架牌已做 `ShelfSignReader`；**通用场景价值更大**：IMDF 的 unit/occupant 名称天然就是地标库 |
| LiDAR 几何 | 走廊宽度、到墙距离 | 有离线工具，未进定位 |
| 大尺度 VPS（Immersal 等） | 全场视觉定位 | 依赖第三方，暂不做 |

### 3.5 地图与约束

- **标准格式**：Apple IMDF（GeoJSON，venue / level / unit / opening / fixture / amenity / occupant），OSM Simple Indoor Tagging，Google 的室内地图也用类似结构。IMDF 是最好的通用入口：Apple 地图室内数据、很多商场都有。
- **可走区域**：可走单元（走廊、大厅、店铺、房间）的并集减去不可走单元（结构、柱子、非公共区域）；开口（opening）连通相邻单元。
- **导航图**：可走多边形的中轴/可视图自动生成；门店的 `MapCross` 只是它的特例。
- **楼层连接体**：电梯、扶梯、楼梯、坡道单元，跨楼层同一位置。

### 3.6 楼层

- 气压：近地面约 0.12 hPa/m，手机气压计分辨率约 0.01 hPa，**相对变化**很可靠，绝对值受天气（每小时可变 1 hPa ≈ 8 m）和空调正压影响。业界做法是「相对变化判切换 + 无线/地图判绝对楼层」。
- 切换方式识别：电梯（垂直速度 1～3 m/s、几乎无步）、扶梯（0.3～0.6 m/s、少步或匀速走）、楼梯（0.1～0.3 m/s、持续步频）。识别结果还能把位置**直接吸附到对应连接体**，这是多层场景里最强的定位约束之一。
- 本次实现的 `FloorDetector`：低通 + 迟滞判「垂直移动中」，移动段结束后按楼层高度量化成楼层差，并按垂直速度和步频分类电梯 / 扶梯 / 楼梯；带缓慢参考漂移跟踪（静止时吸收天气变化）。

### 3.7 地标与众包

| 工作 | 思路 | 借鉴点 |
|---|---|---|
| WiFi-SLAM（Ferris 2007） | GP-LVM 从无标签 Wi-Fi 数据恢复位置 | 无真值建图的鼻祖 |
| Zee（MobiCom 2012） | 零人工众包：用地图约束 + PDR 推轨迹，反推 Wi-Fi 图 | 用户轨迹 + 地图约束本身就能当真值 |
| UnLoc（MobiSys 2012） | 「有机地标」：电梯、楼梯、磁场异常点、Wi-Fi 突变自动成为地标，用来消漂移 | 磁场强异常点、电梯（气压 + 无步）都是免费地标 |
| Walkie-Markie（NSDI 2013） | Wi-Fi 信号强度趋势反转点做地标 | 同上 |

### 3.8 评估

- **标准**：ISO/IEC 18305:2016（室内定位测试与评估）；IPIN / EvAAL 竞赛口径：75 分位误差 + **楼层错一层罚 15 m**。我们的 hpass-eval 应补上这个口径，便于和竞赛结果比。
- **数据集**：Microsoft Indoor Location Competition 2.0（已接入）、MLoc（已接入，许可不明仅内部用）、UJIIndoorLoc-Mag、MagPIE、RoNIN / TLIO 数据集（训练惯导）、IPIN 历年竞赛数据（多层、带气压）。
- **注意**：公开数据集的位姿真值稀疏（Microsoft 约 5 s 一个点），测试轨迹短，结论只做相对比较；对外精度要用自采的长路线 + 地面标记。

---

## 4. 目标架构

```
                ┌───────────────── 场馆模型（VenueModel）────────────────┐
  导入器：门店 JSON │ IMDF / GeoJSON │ RoomPlan 扫描 │ 手绘编辑器 │ (DXF)      │
                │  楼层 → 可走多边形 / 障碍 / 开口 / 连接体 / 地标 / 导航图    │
                └───────┬───────────────────────────────────────────────┘
                        │  每层的信号图层：磁场 · 无线指纹 · 视觉锚点 · 文字地标
                        ▼
传感器 ─→ 运动模型（可切换）─────────→  多假设滤波（粒子）                    ─→ 位置 / 楼层 / 朝向
 IMU      PDR │ 学习型惯导 │ VIO          状态：楼层、x、y、航向偏差、步长比例、       / 不确定度 / 完好性
          持握方式分类                    磁偏置                                       │
 气压 ─→ FloorDetector ───────────────→  观测插件（都可选）：                          ▼
 磁力计 ─→ 可信度 / 跳变检测 ──────────→   地磁序列 · 墙体/路网约束 · 楼层/连接体 ·    导航 / 分析 /
 无线 ─→ BLE / Wi-Fi / RTT ─────────────→   无线 · 文字地标 · 视觉重定位 · GPS 进门点   邻近事件
 摄像头 ─→（仅建图 / 重定位）─────────→   · 用户修正
```

场景配置（同一内核，不同默认值）：

| 场景 | 运动模型 | 约束 | 默认观测 | 冷启动先验 |
|---|---|---|---|---|
| 价签门店（现状） | VIO / PDR | 通道路网 + 曼哈顿 | 地磁 + 价签 BLE | 价签位置表 |
| 普通门店 / 超市 | PDR / 学习型惯导 | 通道路网 | 地磁 | 入口、GPS 进门点 |
| 商场 / 机场 | 学习型惯导 | 墙体 + 连接体 | 地磁 + 楼层（+ Wi-Fi，Android） | 进门点、店名 OCR |
| 写字楼 / 医院 | 学习型惯导 | 墙体 + 门 | 地磁 + 楼层 + 门牌 OCR | 上次位置、房间号 |
| 地下车库 | 车载航位推算 / PDR | 车道路网 + 坡道 | 地磁 + 楼层（坡道） | 入口闸机 |
| 仓库拣货 | 推车/手持 PDR | 货架通道 | 地磁 + 可选 BLE | 任务起点 |

---

## 5. 开发路线（每阶段带门槛）

所有门槛都在**回放**里测：公开数据集（ms / mloc）+ 自采会话。数字是事前目标，跑出第一版结果后再修正。门槛由[定位实验室（Lab CI）](lab-ci.md)在每个 PR 和每晚自动量，其中自采数据的 `walk-once`（只走一遍建图、换一天测试）是对标 Oriient 的核心指标。

### P0 通用地图模型（1～2 周）

| 任务 | 状态 |
|---|---|
| IMDF 导入：level → 每层 `map.json`（`floorPolygons` 可走区、障碍、开口、连接体、地标）+ `venue.json`（楼层表、跨楼层连接体组） | ✅ `tools/venue/imdf_convert.py`。`floorPolygons` 和带坐标的元素现有 `StoreDataLoader` 已能读；`obstaclePolygons`、`connectors` 还要在 Swift 侧接上 |
| `StoreMap` 增加多楼层容器（`VenueModel`：楼层列表 + 连接体），单层门店是一层的特例 | 待做 |
| 由可走多边形自动生成导航图（栅格骨架化或可视图），替代手画的 `MapCross` | 待做 |
| 地图编辑器（web/map-editor）支持多边形和楼层 | 待做 |

**门槛 G0**：一个公开 IMDF 场馆导入后，每层可走面积与原始数据一致（误差 < 1%），任意两点路径规划成功率 ≥ 99%。

### P1 开阔区域地磁（2～3 周，最关键）

| 任务 | 说明 |
|---|---|
| 墙体约束 | 粒子穿越不可走区域即降权/淘汰（门店已有通道版，泛化到多边形） |
| 多峰检测 + 收敛判据 | 主峰权重、第二峰距离、持续时间三条同时满足才「定到」；否则只输出粗区域 |
| 冷启动序列检索 | 走 15～30 m 后，用 DTW / 相关在磁场图上检索候选起点，作为粒子初始化（替代全图均匀撒） |
| 自适应粒子数 | KLD 采样：多峰时多、收敛后少，省电 |
| 评估口径 | hpass-eval 增加「≥ 60 s trace」分组、IPIN 75 分位口径、错定持续时长 |

**门槛 G1**（ms 基准，合成漂移 pdr，5 次）：已知起点只用地磁，中位 ≤ 3 m、错定 ≤ 15%；冷启动，「定到」的点中错定 ≤ 20%（宁可晚定，不可错定）。

### P2 多楼层（2 周）

| 任务 | 状态 |
|---|---|
| 气压楼层检测 + 电梯/扶梯/楼梯分类 | ✅ `FloorDetector`（Swift，含单元测试） |
| 粒子状态加楼层；楼层切换时粒子吸附到对应类型的连接体 | 待做 |
| 采集 App 记录楼层切换；建图按楼层分开 | 待做 |
| 公开数据：IPIN 竞赛多层数据（带气压）接入基准 | 待做 |

**门槛 G2**：楼层判对率 ≥ 98%；楼层切换后 10 s 内水平误差回到切换前水平。

### P3 无摄像头运动模型（3～4 周）

| 任务 | 说明 |
|---|---|
| 持握方式分类 | 已有 `HoldClassifier`，扩展到口袋、摆臂、通话、包里 |
| 学习型惯导原型 | 训练数据 = 我们的 ARKit 会话（IMU + VIO 真值）+ RoNIN 数据集；小网络（TCN / ResNet1D，参考 EqNIO 的等变设计），CoreML 部署；自己实现，不用 GPL 代码 |
| 与粒子滤波耦合 | 网络输出位移 + 协方差，作为运动模型噪声（TLIO 思路） |
| 后台运行 | iOS 后台只用 CoreMotion + 磁力计（不开摄像头），评估耗电 |

**门槛 G3**：不开摄像头，口袋 / 手持两种姿态，60 s 纯推算终点误差 ≤ 行程的 3%；全流程（地磁 + 惯导）跨会话中位 ≤ 2 m。

### P4 可插拔无线观测（1～2 周，可并行）

- 统一的 `RadioObservation` 接口：价签 BLE（现有）、通用 iBeacon、Wi-Fi 指纹（Android）、Wi-Fi RTT（Android）。
- 主要用途：冷启动先验、楼层先验、错定检测（现在的 BLEAssist 泛化）。
- **门槛 G4**：ms 基准上「冷启动 + Wi-Fi 先验」首次定位 ≤ 15 m 步行，错定 ≤ 10%。

### P5 建图效率与地图维护（3 周）

| 任务 | 说明 |
|---|---|
| 无 ARKit 建图 | 学习型惯导 + 地图约束 + 磁场回环（1D 磁场 SLAM 思路），让建图不再要求一直开摄像头 |
| 定位即采集 → 并入 | 把高置信定位攒的磁场按会话偏移对齐后并入（现在只记录） |
| 跨机型 | 磁力计灵敏度/偏置归一化；Android 机型 |
| 有机地标 | 电梯、强磁异常点自动成为地标（UnLoc 思路） |

**门槛 G5**：用户数据并入后，被标记「变了」的区域在 3 次经过内恢复到原精度。

### P6 SDK 产品化（持续）

- **API 边界**：`start(venue:)`、位置回调（楼层、位置、不确定度、来源）、地理围栏/邻近事件、导航。
- **跨平台内核**：现在的核心是 Swift。Android 有两条路：Kotlin 移植（快，但两份代码）或把内核抽成 C++/Rust（慢，长期省事）。**建议先等 P1～P3 算法稳定再决定**，现阶段算法还在大改，过早抽内核成本最高。
- 后台、省电（目标：每小时 ≤ 5% 电量）、隐私（定位在端上；上传磁场统计不传原始轨迹，或可选匿名化）。
- 后台分析：热力图、停留、路径（Oriient 的零售价值主要在这里）。

---

## 6. 指标（通用场景）

| 档位 | 位置误差 | 楼层 | 冷启动 | 姿态 |
|---|---|---|---|---|
| 可用 | 中位 ≤ 3 m，P90 ≤ 6 m | ≥ 95% | ≤ 40 m 步行，错定 ≤ 20% | 手持 |
| 目标 | 中位 ≤ 2 m，P90 ≤ 4 m | ≥ 98% | ≤ 25 m，错定 ≤ 10% | 手持 + 口袋 |
| 对标 Oriient | 中位 ≤ 1.5 m，P90 ≤ 3 m | ≥ 99% | ≤ 15 m，错定 ≤ 5% | 手持 + 口袋 + 身侧，后台 |

Oriient 宣称约 1 m，口径不明。我们以「跨会话、跨日期、自采长路线」为准，不和自己考自己的数字比。

---

## 7. 近期行动（接下来 4 周）

| 周 | 我来做 | 需要你做 |
|---|---|---|
| 1 | P0：VenueModel 多楼层容器；IMDF → App 地图库；hpass-eval 增加 IPIN 口径和长 trace 分组 | 找一个有 IMDF 或 CAD 的场馆（商场 / 写字楼），或同意先用公开 IMDF 样例 |
| 2 | P1：墙体约束 + 多峰收敛判据，在 ms / mloc 上 A/B | — |
| 3 | P1：冷启动序列检索；P2：FloorDetector 接入粒子滤波 | 在一栋多层楼里采 2～3 个会话：楼梯、电梯、扶梯各走一次（带 ARKit） |
| 4 | P3：用已有 ARKit 会话训练惯导原型（离线评估，不上手机） | 采集时开始换姿态：手持、口袋各走一段 |

---

## 参考

- Oriient 官网：[技术](https://www.oriient.me/geomagnetic-indoor-positioning-technology/)、[7 ways](https://www.oriient.me/ready-for-all-scenarios-7-ways-oriient-outperforms-the-competition/)；[TechCrunch：A 轮 1100 万美元（2022）](https://techcrunch.com/2022/05/11/oriient-raises-11m-series-a-for-its-indoor-positioning-service)
- IndoorAtlas：[磁场定位原理](https://www.indooratlas.com/blog/magnetic-positioning-technology-how-it-works-2/)
- Ouyang & Abed-Meraim, [A Survey of Magnetic-Field-Based Indoor Localization](https://mdpi.com/2079-9292/11/6/864), Electronics 2022
- Solin et al., Modeling and interpolation of the ambient magnetic field by Gaussian processes, IEEE T-RO 2018
- Kok & Solin, [Scalable Magnetic Field SLAM in 3D Using Gaussian Process Maps](https://arxiv.org/pdf/1804.01926), FUSION 2018；[1d-magnetic-field-slam](https://github.com/manonkok/1d-magnetic-field-slam/)
- Xie et al., MaLoc: A Practical Magnetic Fingerprinting Approach to Indoor Localization using Smartphones, UbiComp 2014
- Wu, He & Chan, [Magil](https://home.cse.ust.hk/~gchan/papers/EWSN17_magil.pdf), EWSN 2017
- Haverinen & Kemppainen, Global indoor self-localization based on the ambient magnetic field, RAS 2009
- Luo et al., [Constructing an Indoor Floor Plan Using Crowdsourcing Based on Magnetic Fingerprinting](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5712792/), Sensors 2017
- [CrowdMagMap](https://www.aminer.org/pub/6578d75b939a5f40826d0f68/crowdmagmap-crowdsourcing-based-magnetic-map-construction-for-shopping-mall), IEEE IoT-J 2024；[CrowdMagMap 2.0](https://quarxiv.authorea.com/doi/full/10.36227/techrxiv.171591465.55835918/v1)（预印本）
- [ISPRS Annals 2025：粒子滤波生成磁场图](https://isprs-annals.copernicus.org/articles/X-1-W2-2025/9/2025/)
- [多尺度 TCN + LSTM 磁场定位](https://arxiv.org/pdf/2109.11750), 2021
- Herath et al., RoNIN, ICRA 2020；Liu et al., [TLIO](https://arxiv.org/pdf/2007.01867), RA-L 2020；[EqNIO](https://proceedings.iclr.cc/paper_files/paper/2025/file/6554c4151c2ccbd36da2d55c015b2039-Paper-Conference.pdf), ICLR 2025；[ReNiL](https://arxiv.org/abs/2508.06053v2), 2025
- Bahl & Padmanabhan, RADAR, INFOCOM 2000；Youssef & Agrawala, Horus, MobiSys 2005
- Ferris et al., WiFi-SLAM using Gaussian Process Latent Variable Models, IJCAI 2007；Rai et al., Zee, MobiCom 2012；Wang et al., UnLoc, MobiSys 2012；Shen et al., Walkie-Markie, NSDI 2013
- Weinberg, Using the ADXL202 in Pedometer and Personal Navigation Applications, AN-602, 2002
- ISO/IEC 18305:2016；IPIN 竞赛：[2024 征集](https://evaal.isti.cnr.it/2024/call-for-competition)、[2025 Track 1 技术附件](https://evaal.isti.cnr.it/fileadmin/2025/IPIN2025_-_track_1_technical_annex.pdf)
- Apple Indoor Mapping Data Format (IMDF) 规范；OSM Simple Indoor Tagging
