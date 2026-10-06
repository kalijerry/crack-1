# 会话数据格式

iOS 和 Android 采集端输出完全相同的格式，`tools/calibrate.py` 直接读取。

每次录制生成一个会话目录，命名为 `<平台>_<设备标签>_<yyyyMMdd_HHmmss>/`，目录内容如下：

| 文件 | 内容 |
|---|---|
| `meta.json` | 平台、机型、系统版本、App 版本、开始/结束时间、设备标签 |
| `ble.csv` | 每条广播一行 |
| `imu.csv` | 约 50 Hz，每个样本一行 |
| `marks.csv` | 每次打点一行 |

所有时间戳 `t_ms` 都是 **Unix 毫秒**（UTC）。

## ble.csv

```
t_ms,point_id,esl_id,rssi,src,mfg_hex
```

- `point_id`：录制这条广播时正在进行的打点编号，不在打点期间为空。
- `esl_id`：价签 ID。解析规则与 Handy+ 的 `NativeBluetoothManager.shortPackageParse` 一致：
  1. 取公司 ID = 13（0x000D）的厂商数据；
  2. 去掉公司 ID 后，payload 长度必须 ≥4 且 <8；
  3. 取前 4 字节，转成大写十六进制，用 `-` 连接，例如 `1A-2B-3C-4D`。

  非价签广播的 `esl_id` 为空。只有关闭「仅价签」开关时才会记录这类广播。
- `rssi`：dBm。iOS 上 RSSI 返回 127 表示不可用，这类记录直接丢弃。
- `src`：发出广播的设备标识。Android 记录 MAC 地址；iOS 拿不到 MAC，记录 CoreBluetooth 分配的 peripheral UUID。
- `mfg_hex`：完整的厂商数据，**包含** 2 字节公司 ID（小端序）。

## imu.csv

```
t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg
```

数值统一换算成 **Android 传感器约定**，两个平台的数据可以用同一套算法处理：

| 列 | 单位 | 约定 |
|---|---|---|
| ax..az | m/s²，含重力 | 手机屏幕朝上平放时 az ≈ **+9.81** |
| gx..gz | rad/s | 右手系，逆时针为正 |
| mx..mz | µT | 已校准的磁场 |
| mag_acc | — | 磁场精度。iOS 取 -1 到 2（`CMMagneticFieldCalibrationAccuracy`）；Android 取 0 到 3（`SENSOR_STATUS_*`） |
| q* | — | 姿态四元数，只作参考 |
| heading_deg | ° | 系统给出的航向。不可用时为 -1 |

iOS 端的换算方法：
- 加速度：`a_android = -(userAcceleration + gravity) × 9.80665`。CoreMotion 用的单位是 g，而且符号与 Android 相反。
- 陀螺仪和磁场：坐标轴定义与 Android 相同（x 向右，y 指向手机顶部，z 垂直屏幕向外），不需要换算。

## marks.csv

```
point_id,x_cm,y_cm,t_start_ms,t_end_ms,note
```

- `x_cm`、`y_cm` 是门店地图坐标，单位 cm，可以不填。
- 做标定时，**两台手机要并排同时打点，并使用相同的 point_id**。

---

# 格式 v2：地磁可行性实验的附加文件（仅 iOS）

`meta.json` 里 `format_version` 为 2 时，会话目录除上述文件外还有下列文件。v1 的四个文件不变，`calibrate.py` 不受影响。
`meta.json` 另有 `setup_note`（保护壳 / MagSafe / 手持姿态备注）和 `sensors_available`（本次各传感器是否可用）。

| 文件 | 列 | 频率 | 说明 |
|---|---|---|---|
| `mag_raw.csv` | `t_ms,mx,my,mz` | ≈100 Hz | 原始磁力计，µT，设备坐标系，**未做偏置校正**。与 `imu.csv` 里已校准的 `mx..mz` 相减即系统当前估计的偏置，用来检测校准跳变 |
| `baro.csv` | `t_ms,rel_alt_m,pressure_kpa` | ≈1 Hz | 相对高度（起点为 0）与气压 |
| `heading.csv` | `t_ms,magnetic_deg,true_deg,accuracy_deg,x,y,z` | 事件 | CLHeading；`true_deg` 无定位授权时为 -1 |
| `pedometer.csv` | `t_ms,steps,distance_m,cadence_hz,pace_s_per_m` | 事件 | CMPedometer 累计值，缺项为空 |
| `device.csv` | `t_ms,battery,battery_state,thermal,low_power,brightness` | 1 Hz | `thermal`：0 正常 1 偏热 2 严重 3 危急 |

尚未包含：ARKit 位姿（阶段 1 后续，建图真值用）。

---

# 格式 v3：建图采集会话（仅 iOS，`meta.json` 里 `survey: true`）

在 v2 的基础上多两个文件。`meta.json` 另有 `map_width_cm`、`map_height_cm`、`arkit: true`。

| 文件 | 列 | 频率 | 说明 |
|---|---|---|---|
| `arkit_pose.csv` | `t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason` | ≈30 Hz | ARKit 世界跟踪位姿。世界系重力对齐，x 右、y 上、z 朝向观察者；俯视时 (x, z) 与地图 (x, y) 手性相同。`tracking`：0 不可用、1 受限、2 正常；`limited_reason`：1 初始化、2 运动过快、3 特征不足、4 重定位、9 其他 |
| `anchors.csv` | `t_ms,kind,map_x_cm,map_y_cm,ar_x_cm,ar_z_cm,heading_rad,note` | 事件 | 操作者在 App 里长按地图记下的已知位置。`kind`：`start` 起点；`reanchor` 走动中的修正；`heading` 设朝向（记的是当时的估计位置，**不是真值**）；`end` 结束时的估计位置（**不是真值**）。`ar_*` 是同一时刻 ARKit 的 (x, z)，单位 cm |

离线建图时只把 `start` 和 `reanchor` 当真值：相邻两个锚点之间，用它们拟合「旋转 + 平移」把 ARKit 轨迹对到地图上，终点残差按时间线性摊回去；最后一个锚点之后沿用上一段的旋转，且最多信任 30 m。

## 位置真值导出（`tools/magmap.py --truth-dir`）

`<会话名>.csv`，列 `t_ms,x_cm,y_cm`，约 10 Hz，是对齐后的地图坐标。给 `hpass-replay` 离线回放用。

## 磁场图（`magmap.json`）

`tools/magmap.py` 的输出，也是 App「地磁定位」页导入的格式：

```json
{ "width": 19606, "height": 9206, "mapElementList": [], "markPoints": [{"id":"1","x":100,"y":200}],
  "magField": { "cellCm": 50, "cols": 393, "rows": 185,
                "cells": [[|B|, Bz, Bh] 或 null, …], "sigma": [[…] 或 null, …], "counts": [n, …] } }
```

数组按行优先，下标 = row × cols + col；单位 µT。`counts` 是每格真实样本数（补齐的格子为 0），只用于质检。
