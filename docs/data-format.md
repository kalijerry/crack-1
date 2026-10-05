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
