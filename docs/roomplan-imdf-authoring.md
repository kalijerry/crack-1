# 用 iPhone 扫描自己生成 IMDF 场馆地图

没有 CAD / IMDF 的场馆，用带激光雷达的 iPhone（Pro 系列）自己扫：RoomPlan 扫出墙、门、窗、家具和每个房间的地面，
入口处记一次 GPS 和朝向得到经纬度，气压计记楼层，扫完在手机上给房间选类别、起名字，最后把一栋楼的多层扫描导出成
IMDF 压缩包。导出的 IMDF 可以再用 `tools/venue/imdf_convert.py` 读回 App 的地图格式，也可以交给其他支持 IMDF 的系统。

```
RoomPlan 多房间扫描 ──► map.json（每层一份：units / floorPolygons / connectors / geoRef / ordinal）
   入口 GPS + 真北朝向 ─┘        │  手机上点选房间：IMDF 类别 + 名称（可拍门牌识别）
   气压计 → 楼层序号 ───┘        │  网页编辑器两点对准，修正 geoRef（可选）
                                 ▼
                    IMDF 压缩包（App 里导出，或 tools/venue/imdf_export.py）
                                 ▼
               imdf_convert.py → 每层 map.json + venue.json（跨楼层连接体分组）
```

## 1. 准备

- 设备：带激光雷达的 iPhone / iPad Pro。**iOS 17 起**能在同一次扫描里连续扫多个房间和走廊并自动拼接；iOS 16 一次只能扫一个房间。
- App：「房间扫描」页。第一次使用会请求定位权限（只用来记入口经纬度）和相机权限（扫描、拍门牌）。
- 打开「房间扫描」页后，GPS、指南针和气压计就开始工作；楼层要在走动中一直跟踪，所以**换层时不要退出这个页面**。

## 2. 场馆和楼层

1. 「场馆和楼层」里点「换一栋楼」，填场馆名（例如「XX 大厦」），选场馆类型（IMDF venue category，默认「办公园区 / 写字楼」）。之后的扫描都归到这个场馆。
2. 设当前楼层（IMDF 的 ordinal）：地面层 0，往上 1、2…，地下 −1、−2…。
3. 之后坐电梯、走楼梯、乘扶梯换层，气压计（`FloorDetector`）会自动加减楼层，并显示判断出的方式（电梯 / 扶梯 / 楼梯）。
   按 4 m 层高量化；商场层高 5～6 m 时可能判少一层，看到不对就手动改。
4. 同一层可以分几次扫：推荐「接着扫」进同一张地图（每次是一个扫描段，自动对齐、合成一张 map.json，
   见 [scan-and-map-management.md](scan-and-map-management.md)）；也可以分成几张地图（ordinal 相同），导出时自动合成一层。

## 3. 扫描一层

1. 填一个名称（例如「3F 东区」），点「开始扫描」。
2. **在入口记录位置**：站在这层的入口（或楼的大门口，离窗户近、GPS 精度好），手机**竖着拿、摄像头对着要走进去的方向**，
   点「记录入口」。屏幕上会显示 GPS 精度和朝向。精度差（> 15 m）或指南针受干扰时，之后在网页编辑器里两点对准修正（第 5 节）。
   每次扫描都要记一次（每次扫描的坐标系不同）。
3. 慢慢绕房间走一圈，扫过每面墙、门窗和家具。
4. 一个房间扫完点「这间扫完」（iOS 17）：AR 不停，走到下一个房间 / 走廊门口点「扫下一个」，
   走廊、电梯厅、楼梯间都当成「房间」扫，每个会成为一个单元。这一层扫完点「这层扫完」。
   iOS 16 点「扫完了」就结束。
5. 扫完自动生成地图、加进地图库并切换过去。RoomPlan 的 `StructureBuilder` 把各个房间拼成一个整体；
   万一拼接失败，会直接按同一个 AR 坐标系合并（扫描期间 AR 没停，坐标本来就一致）。

保存在地图库 `Documents/maps/<地图编号>/scans/<扫描段>/`：`map.json`、`room.usdz`（3D）、`captured_room.json`（原始结果）、视觉特征地图；地图目录里的 `map.json` 是各段合成的结果。（旧版本存在 `Documents/room-scans/`，房间扫描页「旧版扫描记录」里还能加进地图库。）

## 4. 房间类别和名称

扫描结果页点「房间类别和名称」：

- 平面图上点一个房间选中它，从 IMDF unit category 里选类别：房间 room、走廊 walkway、卫生间 restroom（及男 / 女 / 无性别）、
  电梯 elevator、楼梯 stairs、扶梯 escalator、坡道 ramp、大堂 lobby、会议室、办公室、商铺、非公共区域 nonpublic 等。
  RoomPlan 认出的房间类型会先给个建议（卫生间 → restroom，扫到楼梯 → stairs）。
- **连接体**：电梯 / 楼梯 / 扶梯 / 坡道所在的单元选对应类别，就成了连接体（`connectors`）。导出后，上下层同一位置的同类连接体
  会被 `imdf_convert.py` 归成一组（跨楼层路径规划和换层时粒子吸附用）。
- **非公共区域、结构**等不可走类别会从可走区域（`floorPolygons`）里去掉，放进 `obstaclePolygons`。
- 名称：直接输入，或点「拍门牌识别名称」拍门牌，系统文字识别（Vision，中文 + 英文，全部在手机上做）列出认出的几行字，点一下填进去。
- 「楼层」一节可以改楼层名（1F、B1）和 ordinal。

改完立即写回 map.json；这张图已在地图库里的话，库里那份也一起更新。

## 5. 修正经纬度（网页编辑器两点对准）

入口 GPS 在室内常有 5～20 m 误差，指南针也会被钢结构带偏。用 `web/map-editor.html`（或离线版 `map-editor-standalone.html`）的「地理对齐」：

1. 「载入地图 JSON」选扫描的 map.json（App 里「导出 2D 地图（JSON）」分享出来）。
2. 在平面图上点两下放 A、B 两个点，放在认得出的位置（大门、楼的外角、柱子），相距越远越好；按住可以拖动。
3. 在地图 App（卫星图）里长按这两个位置，复制「纬度, 经度」，填进 A、B。
4. 点「计算 geoRef」：只解旋转 + 平移（尺度用激光雷达量的）。提示的「尺度比」应该接近 1，差 5% 以上多半是点放错了或经纬度填反了。
5. 「保存修正后的 JSON」，再放回手机（地图库导入）或直接用 `imdf_export.py` 导出。

## 6. 导出 IMDF

- **手机上**：房间扫描页的房间地图按场馆分组，点「导出为 IMDF」，生成 `Documents/imdf/<场馆名>_imdf.zip`，可以直接分享。
  有扫描缺 `geoRef`（没记入口）时会列出来，补上再导出。
- **电脑上**：

  ```bash
  python3 tools/venue/imdf_export.py 扫描目录/ -o venue_imdf.zip --name "XX 大厦" --category businesscampus
  ```

  输入可以是多个 map.json 或目录（递归找 map.json，跳过 venue.json 这类非地图文件）。没有 geoRef 的老扫描可以用
  `--origin 经度,纬度` 给一个假原点（只为了能导出，坐标不真实）。

压缩包内容（坐标 WGS84，外环逆时针）：

| 文件 | 来源 |
|---|---|
| `manifest.json` | 版本 1.0.0、语言 zh-Hans |
| `address.geojson` / `venue.geojson` / `building.geojson` / `footprint.geojson` | 场馆名、类型；轮廓 = 所有层的凸包 |
| `level.geojson` | 每个 ordinal 一层，轮廓 = 该层单元的凸包 |
| `unit.geojson` | 每个单元（类别、名称） |
| `opening.geojson` | MapDoor / MapOpening → pedestrian 开口 |
| `fixture.geojson` | 扫到的家具（furniture） |
| `anchor.geojson` | 每个单元中心一个 |
| `occupant.geojson` | room 等类别的有名单元（房间名 / 租户） |

要素 id 是由「场馆名 / 楼层 / 局部编号」生成的 uuid5，重复导出 id 不变；Swift 版（`IMDFExporter`）和 Python 版规则一致，id 也一样。

读回来检查：

```bash
python3 tools/venue/imdf_convert.py venue_imdf.zip out/
```

会打印每层的可走面积、单元数、开口数、连接体数和跨楼层连接体组数，应该和扫描时一致。

## 7. 数据格式补充（map.json）

在原有房间扫描格式（`mapElementList`、`floorPolygons`、`arAlign`）上新增：

| 字段 | 说明 |
|---|---|
| `units` | `[{id, category, name?, polygon:[x0,y0,x1,y1,…]}]`，地图 cm。单房间扫描也有一个 `R1` |
| `floorPolygons` / `obstaclePolygons` | 由 `units` 派生：可走 / 不可走单元 |
| `connectors` | 连接体单元 `{id, category, x, y, polygon, ordinal}`，格式同 imdf_convert |
| `mapElementList` | 另加 `MapLabel`（有名单元）、`MapConnector`（连接体），由 `units` 派生 |
| `ordinal`、`venueId`、`venueName` | 楼层序号、所属场馆 |
| `geoRef` | `{lon0, lat0, marginCm, mPerDegLon, mPerDegLat, rotationDeg}`，见下 |
| `geoAnchor` | 入口记录的原始值 `{lon, lat, trueHeadingDeg, accuracyM, x, y}`，只做记录 |

`geoRef` 和 `imdf_convert.py` 输出的格式相同，多一个 `rotationDeg`（imdf_convert 输出的地图总是正北朝上，相当于 0）：

```
dx, dy = (x − marginCm)/100, (y − marginCm)/100      # 米，地图 +x 向右、+y 向下
e = dx·cos r − dy·sin r                               # 向东
s = dx·sin r + dy·cos r                               # 向南
lon = lon0 + e / mPerDegLon,  lat = lat0 − s / mPerDegLat      # r = rotationDeg
```

地图 +x 轴的方位角是 90° + r。入口记录时 r = 真北朝向 − 90° − 手机朝向在地图里的方向角。
三处实现：`tools/venue/georef.py`、`HPASSKit/Models/GeoRef.swift`、`web/map-editor.html`。

## 8. 代码与测试

| 部分 | 位置 |
|---|---|
| 多房间扫描、入口记录、楼层、导出按钮 | `ios/HPASSApp/HPASSApp/RoomScanView.swift` |
| 场馆设置、GPS / 朝向、气压楼层、单元编辑、门牌识别 | `ios/HPASSApp/HPASSApp/VenueAuthoring.swift` |
| 多房间 → map.json、单元派生字段、改类别 / 名字 | `HPASSKit/Models/RoomMapBuilder.swift` |
| geoRef | `HPASSKit/Models/GeoRef.swift`、`tools/venue/georef.py` |
| IMDF 类别表 | `HPASSKit/Models/IMDFCategory.swift`（和 imdf_convert 的 NON_WALKABLE / CONNECTOR 一致） |
| IMDF 导出 | `HPASSKit/Models/IMDFExporter.swift`（含最小 zip 写入器）、`tools/venue/imdf_export.py` |

- Python：`python -m unittest discover -s tools/tests`。`test_imdf_export.py` 合成两层小楼，两层分别扫描、地图朝向不同，
  导出后用 imdf_convert 读回：可走面积、门（数量、宽度、经纬度位置）、连接体及跨楼层分组、名称都一致。
- Swift：`VenueAuthoringTests`（合成数据，SyntheticRoom 风格）：多房间单元、改类别 / 名字、geoRef 约定、入口记录换算到经纬度
  （< 2 cm）、导出要素、zip 可读；macOS 上有 python3 时还会用 imdf_convert 读 Swift 导出的压缩包，两边对得上。

## 已知限制

- level / venue 轮廓用凸包，L 形楼会多出一块；单元本身是准的。
- 开口不区分门的类型（IMDF `door` 写 null）；窗户不导出。
- IMDF `relationship`（连接体的上下层关系）和 `amenity` 还没导出：跨楼层分组目前由 imdf_convert 按位置推断。
- 室内 GPS 和指南针误差大，正式交付前建议都做一次两点对准。
