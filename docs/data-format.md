# 会话数据格式

iOS 和 Android 采集端输出完全相同的格式，`tools/calibrate.py` 直接读取。

每次录制生成一个会话目录，命名为 `<平台>_<设备标签>_<yyyyMMdd_HHmmss>/`，目录内容如下：

| 文件 | 内容 |
|---|---|
| `meta.json` | 平台、机型、系统版本、App 版本、开始/结束时间、设备标签 |
| `ble.csv` | 每条广播一行 |
| `wifi.csv` | 每次 Wi-Fi 扫描里每个 AP 一行（可选，只有 Android 能扫） |
| `imu.csv` | 约 50 Hz，每个样本一行 |
| `marks.csv` | 每次打点一行 |

所有时间戳 `t_ms` 都是 **Unix 毫秒**（UTC）。

## ble.csv

```
t_ms,point_id,esl_id,rssi,src,mfg_hex
```

- `point_id`：录制这条广播时正在进行的打点编号，不在打点期间为空。
- `esl_id`：标签 ID。解析规则：
  1. 取公司 ID = 13（0x000D）的厂商数据（目标标签广播的厂商 ID）；
  2. 去掉公司 ID 后，payload 长度必须 ≥4 且 <8；
  3. 取前 4 字节，转成大写十六进制，用 `-` 连接，例如 `1A-2B-3C-4D`。

  非标签广播的 `esl_id` 为空。只有关闭「仅标签」开关时才会记录这类广播。
- `rssi`：dBm。iOS 上 RSSI 返回 127 表示不可用，这类记录直接丢弃。
- `src`：发出广播的设备标识。Android 记录 MAC 地址；iOS 拿不到 MAC，记录 CoreBluetooth 分配的 peripheral UUID。
- `mfg_hex`：完整的厂商数据，**包含** 2 字节公司 ID（小端序）。

## wifi.csv

```
t_ms,bssid,rssi,freq
```

可选文件。iOS 第三方 App 拿不到 Wi-Fi 扫描结果，只有 Android 采集端（和公开数据集转换脚本 `tools/bench/ilc_convert.py`）会写；
定位只在评估加 `--wifi` 时用（`public/pdr/cold-wifi` 场景）。

- `t_ms`：这一轮扫描结果上报的时刻。同一轮扫描的各个 AP 用同一个 `t_ms`，读取时按 `t_ms` 分组成一次扫描。
- `bssid`：AP 的 MAC 地址，小写，冒号分隔，例如 `a8:0c:ca:03:9d:d7`。
- `rssi`：dBm。
- `freq`：信道中心频率（MHz），例如 2437、5180。

系统会把之前缓存的旧结果混进新一轮扫描里：AP「最后一次被看到」的时刻比上报时刻早 5 秒以上的不写进来。

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

- `x_cm`、`y_cm` 是场地地图坐标，单位 cm，可以不填。
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

---

# 格式 v4：imu.csv 加重力列、四元数改真值（iOS，`meta.json` 里 `imu_format: 4`）

```
t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg,gvx,gvy,gvz
```

前 16 列与 v1 相同、顺序不变（按列名或按下标读的老工具都不受影响），末尾多三列：

| 列 | 单位 | 约定 |
|---|---|---|
| gvx..gvz | m/s² | CoreMotion 陀螺辅助的重力（`CMDeviceMotion.gravity × 9.80665`）。**统一成 Android 约定**：手机屏幕朝上平放时 ≈ (0, 0, **+9.81**)，与 ax..az 同号。iOS 原始值方向相反，App 里已取负；公开数据转换器写 `TYPE_GRAVITY` 时不用取负 |
| qw..qz | — | CoreMotion `attitude.quaternion` 真值（v1–v3 的实时定位页写的是占位 1,0,0,0）。参考系见 `meta.json` 的 `attitude_frame` |

`meta.json` 相关字段：

| 字段 | 说明 |
|---|---|
| `imu_format` | 4 |
| `attitude_frame` | `xArbitraryZVertical`（实时定位 / 盲测：姿态不用磁力计，偏航只靠陀螺 + 重力）或 `xMagneticNorthZVertical`（建图 / 采集：要 iOS 校准后磁场和系统航向） |
| `mag_calibration` | `ios`：mx..mz 是 iOS 校准后磁场；`app_hard_iron:<来源>`：参考系不含磁力计时 iOS 不给校准值，mx..mz = `mag_raw` − 本机硬铁偏置，来源 `learned`（建图 / 采集会话学到的存档）、`sphere_fit`（现场球面拟合）、`none`（还没有，mx..mz 为 0、mag_acc = -1） |
| `mag_bias_ut` | 用到的偏置 [x, y, z] µT（有时才写） |

`mag_acc`：`ios` 时同 v1；`app_hard_iron` 时 2 = 存档偏置、1 = 现场拟合、-1 = 没有偏置。

## 实时定位 / 盲测会话（`mag-tracks/<时间>_files/`，`meta.json` 里 `live: true`）

不开摄像头也录。文件：`imu.csv`（v4）、`mag_raw.csv`、`ble.csv`、`signs.csv`、`track.csv`（结束时拷入）、`meta.json`；
开了「视觉增强」且摄像头打开过时另有 `arkit_pose.csv` 等（`arkit: true`）。盲测会话另有 `acc_raw.csv`。

`track.csv`：

```
t_ms,x_cm,y_cm,unc_cm,conf,pdr_x,pdr_y,heading_deg,steps,b_total,b_vert,b_horiz,check,src,trust,posture,lat_left_cm,lat_right_cm,room_id,carry_mode
```

- `src`：终端用户定位里恒为 `pdr`（计步永远推粒子）。旧版本出现的 `visual` / `vio` / `vio-raw` 不再产生。
- `check`：`视觉观测` 表示这一刻用了一次视觉重定位当位置观测（σ 50 cm，只在「视觉增强」开着、手机竖持时）。
- `room_id`：房间级输出接入前为空，离线按 map.json 的 units 计算。
- `carry_mode`：盲测会话声明的携带方式（中途切换后跟着变），普通定位为空。

`acc_raw.csv`（盲测机 / 伴随真值机，对时用）：`t_ms,ax,ay,az`，≈100 Hz 原始加速度计（`CMAccelerometerData`），
m/s²，Android 约定（含重力，平放 az ≈ +9.81）。

盲测会话 `meta.json` 另有：`purpose: "blind_test"`、`protocol: "office-carry-v1"`、`camera: false`、`carry_mode`、
`route`、`pair_id`（伴随机广播的 8 位十六进制配对编号）、`pair_source`（`ble` / `manual` / 空）、`bumps_ms`（在线检测到的敲击时刻，只作核对，
离线以 `acc_raw.csv` 互相关为准）、`mode_switches`（`[{t_ms, mode}]`）、`map_id`、`map_version`、`model`、`battery_start/end`、
`thermal_start/end`、`proximity_monitoring`。

伴随真值机用建图采集的测试会话（`survey: true`、`purpose: "test"`，格式 v3），`meta.json` 另有 `role: "gt_companion"`、
`pair_id`、`lever_arm_cm`、`bumps_ms`、`mode_switch_marks_ms`；地贴处的长按修正记在 `anchors.csv`（`kind = reanchor`）。

## 位置真值导出（`tools/magmap.py --truth-dir`）

`<会话名>.csv`，列 `t_ms,x_cm,y_cm`，约 10 Hz，是对齐后的地图坐标。给 `hpass-replay` 离线回放用。

## 磁场图（`magmap.json`）

`tools/magmap.py` 的输出，也是 App「地磁定位」页导入的格式：

```json
{ "width": 2000, "height": 1000, "mapElementList": [], "markPoints": [{"id":"1","x":100,"y":200}],
  "magField": { "cellCm": 50, "cols": 40, "rows": 20,
                "cells": [[|B|, Bz, Bh] 或 null, …], "sigma": [[…] 或 null, …], "counts": [n, …] } }
```

数组按行优先，下标 = row × cols + col；单位 µT。`counts` 是每格真实样本数（补齐的格子为 0），只用于质检。
