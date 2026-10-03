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

数值统一换算成 **Android 传感器约定**，HPASS 算法可以直接使用：

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
