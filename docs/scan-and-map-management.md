# 分段扫描、接着扫、重扫精细化与地图管理

办公室一次扫不完，要分几次扫进**同一张地图**；扫完以后还要能对某一块**重扫、精细化**；地图要能删除、管理。
这份文档写数据模型和规则。核心库（HPASSKit）部分已经实现并有单元测试；App 界面、后台接口按「实现状态」一节分步做。

## 1. 概念

- **扫描段**：一次扫描（iOS 17 可以连扫几个房间）。每段各自用 `RoomMapBuilder` 生成自己的 map.json（自己的坐标系、自己的 `arAlign`），写入后不再修改。
- **合成地图**：地图目录里的 map.json，由 `MapComposer.compose` 按扫描段注册表重新生成。建图采集、定位、显示、云端融合都只读它，格式和以前一样（只多几个可选键）。
- **基准 AR 坐标系**（`frameId`）：第一段扫描时的 ARKit 世界系。视觉特征地图属于它；视觉重定位认出已扫区域后扫的段和它是同一个坐标系。
- **toMap**：段坐标 → 合成地图坐标的刚体变换（cm）。

## 2. 目录与文件（本机，只做加法）

```
Documents/maps/<mapId>/
  map.json                合成结果
  meta.json               地图库条目
  scans.json              扫描段注册表（ScanRegistry）
  scans/<scanId>/map.json 这一段单独生成的地图（老地图第一次打开时：scans/base/map.json = 当时 map.json 的拷贝）
  scans/<scanId>/…        原始 captured_room.json、room.usdz、这一段结束时的特征地图（可选，存档用）
  worldmap.arexperience + worldmap.json   在用的特征地图（基准坐标系）
```

## 3. scans.json

```json
{
  "version": 1, "mapId": "room_20261108_1012", "frameId": "UUID",
  "frameAlign": { "phi": 0, "pRefX": 0, "pRefY": 0, "aRefX": 0, "aRefY": 0 },
  "originOffsetCm": [0, 0], "geometryVersion": 1762590000000, "canvasCm": [2400, 1100], "name": "办公室",
  "scans": [
    { "id": "s1", "createdMs": 1762590000000, "enabled": true, "source": "roomplan", "inBaseFrame": true,
      "toMap": { "phi": 0, "pRefX": 0, "pRefY": 0, "aRefX": 0, "aRefY": 0 },
      "alignment": "base", "mode": "append", "unitIds": { "R1": "R1" },
      "quality": { "overlapCm": 620, "residualCm": 4.1, "ambiguous": false } }
  ],
  "unitLabels": { "R1": { "category": "room", "name": "会议室 A" } }
}
```

- `alignment`：`base` 第一段；`worldmap` 视觉重定位认出了已扫区域（和基准同一个 AR 坐标系，`toMap = 段 arAlign⁻¹ ∘ frameAlign`）；`geometry` 墙 / 门自动对齐；`manual` 手动两点对齐。
- `mode`：`append` 追加（接着扫）；`replace` 替换这一段足迹里的旧东西（重扫 / 精细化）。合并预览里按 `MapComposer.suggestedMode`（新段面积 ≥ 60% 已在旧图里 → 替换）给默认值。
- `frameAlign`：基准 AR 坐标系 → 合成地图，即合成地图的 `arAlign`。
- `canvasCm`：画布只增不减（关掉一段不缩小，磁场格 / 涂色尺寸不跟着变）。
- `unitIds`：本段局部单元编号 → 全局编号，段第一次合成时分配，之后稳定（IMDF 要素 id 由单元编号参与 uuid5，编号稳定 id 才稳定）。
- `unitLabels`：用户在「房间类别和名称」里填的，和扫描段无关，每次合成最后套回去。**改类别 / 名字必须写这里再重新合成**，直接改 map.json 会在下次合成时被覆盖。
- **撤销**：关掉一段 = 撤销那次扫描（追加的消失，被它替换掉的旧东西回来）。不另存历史快照。

## 4. 合成规则（`MapComposer`，确定性）

按 `createdMs` 顺序处理启用的段，每段：

1. 元素按 `toMap` 变换：墙门窗开口按中心 + 旋转角；家具（`MapShelf`，左上角）先转中心再换回左上角；多边形逐点。
2. **单元编号**：已分配的直接用；否则和已有单元比「是不是同一个房间」（任一方质心落在另一方里，且面积比 0.5～2）→ 继承编号、类别、名字；第一段沿用自己的编号；其余分配新的 `R<n>`。
3. **替换**（`replace`）：足迹 = 本段单元多边形外扩 30 cm。旧墙把足迹里的那截裁掉；旧门窗 / 家具 / 其他元素按中心、旧单元按质心删掉。
4. **单元并入**：同一房间的旧单元已在 → 追加时保留旧多边形；没匹配上、但 ≥ 60% 面积落在已有单元里的新单元当作「站在旧房间里又扫了半个」丢掉（墙仍参与去重）。
5. **去重**（只和更早的段比，同一段内部不动）：墙 = 平行 ≤ 5°、垂直距离 ≤ 25 cm、沿线间隙 ≤ 20 cm（替换时 50 cm，跨过裁剪留下的缺口）→ 取区间并集，位置沿用旧墙，高度取大；门窗开口 = 同类、中心距 ≤ 40 cm、夹角 ≤ 20°；家具 = 同类、中心距 ≤ 40 cm、宽深各在 ±30% 内。阈值集中在 `MapComposer.Thresholds`。
6. 家具编号 `Room-类别-n` 按位置排序后全局重编。
7. 内容伸到留白以外（x 或 y < 100 cm）→ 整体平移 50 cm 的整数倍（见 §6）。
8. 根字段沿用第一段的（楼层名、来源、楼层序号、场馆）；`geoRef` / `geoAnchor` 取第一个带它的段换算到地图坐标；`arAlign = frameAlign`；最后 `RoomMapBuilder.applyUnits` 派生可走区域、连接体和标签。

合并前用 `MapComposer.consistency` 核对：新段墙体和已有墙体的重合长度、平均 / 最大偏差。重合太少或偏差大（> 30 cm）要用户确认或改手动对齐；视觉重定位成功的段也要核对（ARKit 可能先认错再纠正）。

## 5. 新段怎么对到地图上

1. **视觉重定位**（首选，iOS 17）：载入在用的特征地图，站在已扫过的房间里转一圈；认出后**先提示走到新房间门口，再由用户点开始扫**（否则 RoomPlan 会在旧房间里再扫出一个残缺副本）。超时 `WorldMapPolicy.relocalizeTimeoutSec`（45 秒）放弃特征地图，按 2 继续。
2. **几何自动对齐**（`RigidAlign2D.auto`）：两段都已转正，旋转只剩 0 / 90 / 180 / 270°；每个旋转 × 每对门（宽度、方向相近）给出平移 → 点到线 ICP 精修（平移 + ≤ 3° 旋转）。打分 = 重合墙长 − 3 × 冲突墙长（墙落进对方房间内部、附近又没有墙）；精修后出发的那对门必须仍然对得上。要求重合 ≥ 3 m 且有门对上或两组不平行的墙对上；次优解得分 ≥ 最优 85% 标「有歧义」。**新一段必须把门口 / 走廊这类已扫过的地方再扫一小段**，否则无解。
3. **手动两点对齐**（`RigidAlign2D.twoPoints`）：旧图、新段各点两个对应点（同一扇门的两边、同一个墙角），只解旋转 + 平移，显示尺度比（偏离 1 超过 5% 多半是点错了）；然后 `snapToAxes` 吸附到 90° 整数倍、`refine` 精修一轮。

几何 / 手动对齐的段不在基准 AR 坐标系里（`inBaseFrame = false`），它的特征地图不能顶替在用的那份；以后接着扫仍然从已认出的区域出发走过去即可。

## 6. 原点平移（罕见：只在往 −x / −y 扩展时）

- 平移量是 50 cm 的整数倍（磁场格 50 cm、涂色格 25 cm 的公倍数），`originOffsetCm` 累加；所有段的 `toMap`、`frameAlign`、画布一起平移（`ScanRegistry.shifted`）。
- 单张 map.json 的平移：`MapFrameShift.apply`（元素、单元、多边形、connectors、`geoRef` 的 lon0/lat0、`geoAnchor`、`arAlign.pRef`、宽高、偏移）。特征地图旁注：`WorldMapSidecar.shifted`（pRef 平移，`frameId` 不变）。
- 本机按格子存的定位数据（磁场图、涂色、方向图）在几何变化时本来就会因尺寸不符被清掉，不搬运；界面要明说「本机定位数据会清空，上传后等云端重新融合」。
- **采集会话文件不改写**：会话 meta 记 `map_origin_offset_cm`，读会话时按「地图现在的偏移 − 录制时的偏移」平移地图坐标（见 [data-format.md](data-format.md)）。

## 7. 特征地图兼容规则（frameId）

`WorldMapSidecar.frameId` 与 map.json 的 `frameId`：两边都有 → 相等即兼容（原点平移后 `arAlign` 变了也照样能用）；任何一边没有 → 沿用 `arAlign` 2 cm 等价。旁注 `version` 仍为 1（云端只认 1）。云端融合同一规则（`tools/cloud_build_lib.py`，单元测试 `tools/tests/test_cloud_build.py`）。

## 8. map.json 新增的可选键

`frameId`、`originOffsetCm`、`geometryVersion`、`scans`（`[{id, name, enabled, alignment, mode}]` 只读摘要）。老 App、hpass-build、云端融合、网页编辑器、IMDF 导出原样忽略或透传。hpass-build 从 `--map` 读 `originOffsetCm` 换算会话坐标。

## 9. 地图管理与删除（App）

以前「删不掉、删了又回来」的原因（都已修）：删除 / 改名只在开发者模式出现（脚注却说左滑可删）；在用的地图不能删，普通模式又会强制切回云端图；普通模式只列云端图，本机扫的地图看不到；云端刷新会把「本机没有」的云端图自动装回来；删除只删地图目录、`store-data/map.json` 还在，下次启动又被收成一张图。

- 地图库两种模式都列出全部地图（云端正式版在前，徽标区分「云端正式版 / 本机」），左滑重命名、删除、开关信号；点一张进**地图详情**。
- 删除（含在用的）：先切到下一张（云端正式版优先，否则最近建的）；没有别的就清空当前地图、根目录工作区并删 `store-data/map.json`。确认框列出会删什么、会换到哪张。地图库、场地数据页、地图详情共用同一个确认框。
- 本机墓碑（`Documents/maps/.tombstones.json`，`{mapId: {deletedAtMs, cloudVersion}}`）：删掉的地图云端那份不再自动下载 / 更新，云端列表显示「已删除 · 重新下载」（云端版本比删除时新则「已删除 · 云端有新版本」）；点了才清墓碑并安装。
- 删除地图不删采集会话（本机没有「已上传」标记，删了会丢掉还没上传的采集）。
- 云端更新不覆盖本机名字（只在首次安装时采用云端名字）；在用的地图不会被自动换成云端图（只在没有在用地图时自动用上）。
- 云端包的几何版本（包里 map.json 的 `geometryVersion`）比本机小 → 整包不装（等云端用新几何重新融合：`tools/cloud_build.py` 把地图的 `geometryVersion` 记进报告 `mapGeometryVersion`，版本变了就算会话没变也重建），条目记 `skippedCloudVersion`，这一版不再反复下载（列表显示「本机较新」），并让本机 map.json 重新上传（`Telemetry.invalidateUploadedMap`）。云端几何和本机注册表版本不同 → 本机注册表作废，按新 map.json 重新生成基准段。

### 地图详情（`MapDetailView`）

预览、来源 / 版本 / 范围、使用这张地图；房间地图另有「接着扫（扩大范围）」「重扫某块（精细化）」、**扫描段列表**（每段：时间、房间数、对齐方式和偏差、合并方式；开关 = 启用 / 关掉，左滑改名 / 删除；唯一启用的一段不能关）、「房间类别和名称」；导出 map.json、重命名、删除。

### 扫描流程（`RoomScanView` / `ScanMergeView`）

- 扫描入口两种模式都有：「建图」页（在用的是房间地图时主按钮是「接着扫当前地图」）、「设置 → 房间扫描」、地图详情。
- 新建地图：第一段直接开始；写到 `maps/<id>/scans/<scanId>/`，`ScanRegistry.newMap` + 合成，加进地图库并切换。
- 接着扫（iOS 17、地图有特征地图）：自建 `ARSession`（`worldAlignment = .gravity`，载入 `MapLibrary.relocalizationWorldMap`：最近一段在基准坐标系里扫的段自己存的完整特征地图，没有就用地图目录的），显示已扫范围和进度；经过「重定位中」→ 正常、位姿连续 1 秒无跳变才算认出（`ScanRelocalizer`）。**认出后只提示，用户走到新房间门口再点「开始扫」**，这时才用 `RoomCaptureView(frame:arSession:)` 在同一个会话上扫。
- RoomPlan 自检：开始扫后 3 秒内位姿跳 > 0.5 m 或跟踪回到「启动中」→ 判定 RoomPlan 重置了坐标系，这一段改为几何对齐。
- 认不出（45 秒超时、或用户点「认不出，先扫后对齐」）、iOS 16、地图没有特征地图：用 RoomPlan 自带的会话照常扫，扫完几何对齐。
- 「这段扫完」前检查 `worldMappingStatus`，不是 mapped / extending 提示再转一圈（只提示一次）。
- 合并预览：视觉认出的段 `toMap = 段 arAlign⁻¹ ∘ frameAlign`，再用 `MapComposer.consistency` 核对（重合 < 1 m 或偏差 > 30 cm 标黄）；其余 `RigidAlign2D.auto`，有歧义标黄，对不上必须手动两点对齐（`twoPoints` → `snapToAxes(5°)` → `refine`）。合并方式默认按 `suggestedMode`，可选「追加补充 / 替换这块」。也可以「另存为新地图」或「放弃」。
- 视觉认出的段确认合并后，它结束时的特征地图顶替地图在用的那份（旁注 `source = scan-append`、基准 `frameId`、`uploaded = false`）；超过 15 MB 不顶替（只影响上传），接着扫仍用段目录里的完整那份。
- 「房间类别和名称」改走注册表（`unitLabels`、楼层名 / 序号）再重新合成；IMDF 导出读地图库里各张房间地图的 map.json。
- 会话 meta 新键：`map_origin_offset_cm`、`map_geometry_version`、`map_frame_id`（采集和实时定位都写）；手机本地生成磁场图时按地图当前偏移换算。

## 10. 实现状态

| 部分 | 状态 |
|---|---|
| HPASSKit：`ScanRegistry`、`MapComposer`、`RigidAlign2D`、`MapGeometry`、`MapFrameShift`、`MapARTransform` 代数、旁注 `frameId`、会话偏移换算、`RoomMapBuilder` 段级参数 / `roomUnit` | 已实现，单元测试覆盖 |
| 云端融合特征地图的 `frameId` 规则 | 已实现（`tools/cloud_build_lib.py`） |
| App：扫描流程（新建 / 接着扫、重定位门禁、RoomPlan 自检降级）、合并预览与手动对齐、地图库删除 / 改名 / 墓碑 / 地图详情、`UnitEditorView` 改走注册表、会话 meta 新键 | 已实现（macOS CI 编译；RoomPlan 挂在自建会话上的行为要真机验证） |
| 后台：删除包、墓碑过滤；cloud_build 跳过已删除地图 | 第二步（单手机办公室测试先用本机墓碑） |

iOS 16：没有多房间也没有自定义 ARSession，只能单房间 + 几何 / 手动对齐；单元多边形来自墙端点凸包，匹配时按质心互含 + 面积比容忍差异。
