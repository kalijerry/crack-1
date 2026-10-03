# ESL 指纹定位：跨机型采集与标定工具

指纹库是用 **Samsung S25+** 采的，现在要在 **iPhone 16 Pro** 上用。本仓库提供：

| 目录 | 内容 |
|---|---|
| `ios/HPASSKit` | **定位与导航 Swift 库**：蓝牙指纹定位、惯导融合、路径规划。见 [模块说明](ios/HPASSKit/README.md) |
| `ios/ESLCollector` | iOS 采集 App（SwiftUI，iOS 16+）。录制价签 BLE 广播的 RSSI、50 Hz IMU，支持打点 |
| `android` | Android 采集 App（Kotlin，无 AndroidX 依赖）。功能与 iOS 版相同，在 S25+ 上用 |
| `tools/calibrate.py` | 读取两台手机的配对数据，拟合 RSSI 映射，并检查覆盖率和 IMU |
| `docs/data-format.md` | 两端共用的会话数据格式 |

本仓库不包含任何门店数据、账号或服务器地址。采集 App 完全离线工作。

---

## iOS App 的四个页面

| 页面 | 用途 |
|---|---|
| 采集 | 录制价签广播和 IMU，按点位打点，导出会话 |
| 门店数据 | 从服务器下载或本地导入地图、指纹、价签；数据自检 |
| 实时定位 | 地图上实时显示定位、轨迹、导航路线；现场标定 RSSI 偏移 |
| 日志 | App 内日志，含每次按钮操作；可筛选、搜索、导出 |

### 门店数据页

服务器地址、接口路径、门店编码、鉴权方式都**在 App 里运行时填写**，代码里不含任何服务端信息。

- 接口路径支持 `{store}` 和 `{floor}` 占位符，也可以直接填完整地址。
- 鉴权支持 Bearer、自定义请求头、Basic、查询参数四种。
- **凭据默认只存在内存里**，App 退出即清空。打开「记住凭据」才会写入 iOS 钥匙串（仅本机、解锁后可读）。服务器地址等非敏感配置存在 UserDefaults。
- 日志不会记录凭据值，只记录「已设置 / 未设置」。
- 没有服务器也能用：把三个 JSON 通过「文件」App 放进去，或在页面里直接导入。
- 导入后自动做数据自检，检查指纹区间、邻接表、价签与货架的对应关系等。

### 实时定位页

地图上实时绘制：货架、通道、指纹点、已走轨迹、当前位置（含朝向箭头和不确定度圆）、导航路线。
指纹原始结果与融合结果差异较大时，会用空心圈单独标出，方便判断是指纹跳了还是惯导漂了。

- 点击地图可设起点或设导航目标；也能从商品列表里按 SKU、名称、条码搜索目标。
- 导航提示显示方向箭头、剩余距离、距下个拐点距离。
- 参数区可现场调 RSSI 偏移和缩放、图平滑开关、惯导开关、通道约束、磁偏角。
- 标定区有两种方式：**盲标定**（按最近 120 秒的数据估计偏移，边走边标）和**已知点标定**（选一个指纹点，站上去开始/结束）。算出建议值后一键应用。
- 「记录轨迹」会把每次定位写进 `Documents/live-tracks/live_<时间>.csv`，事后可复盘。

> 注意：实时定位和采集页各自独立扫描蓝牙。两个同时开会有两路扫描，建议一次只用一个。

## iOS：编译与安装（需要 Mac + Xcode 15 以上）

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，仓库里不提交 `.xcodeproj`。

```bash
brew install xcodegen
```

```bash
cd ios/ESLCollector && xcodegen generate && open ESLCollector.xcodeproj
```

工程会自动引入同目录下的 `ios/HPASSKit` 本地 Swift Package。

1. 在 Xcode 中选中 target **ESLCollector**，打开 *Signing & Capabilities*：
   - 在 **Team** 里选你的 Apple ID。免费账号也可以，但签名每 7 天要重签一次。
   - 如果 Bundle Identifier `com.example.eslcollector` 已被占用，改成你自己的，例如 `com.<你的名字>.eslcollector`。
2. 16 Pro 用数据线连上 Mac，打开 *设置 → 隐私与安全性 → 开发者模式*（首次需要重启）。
3. 选择真机，⌘R 运行。用免费账号时，首次运行需要在 iPhone 的 *设置 → 通用 → VPN 与设备管理* 里信任开发者。
4. 首次启动会请求蓝牙和运动与健身权限，都要允许。

**导出数据**：在 App 里点「历史会话 / 导出」，打包成 zip 后可以隔空投送到 Mac。也可以在 *文件 → 我的 iPhone → ESL采集 → sessions* 里直接找到原始目录。

## Android：编译与安装（S25+）

```bash
cd android && ./gradlew assembleDebug
```

```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

- 也可以直接用 Android Studio 打开 `android/` 目录。
- 首次启动需要授予「附近设备」和「位置」权限，并打开蓝牙。
- 停止录制后，数据会自动打包到 **下载/ESLCollector/** 目录。

---

## 现场标定流程（约半天）

1. **准备**
   - 两台手机都开启蓝牙。
   - iPhone 的设置 → 通用 → 日期与时间，打开「自动设置」；S25+ 打开「自动设置日期和时间」。两台手机的时钟必须对齐，脚本按时间窗配对数据。
   - 在 App 里填好设备标签，例如 `s25plus` 和 `16pro`。
2. **姿势**：两台手机并排拿在手里，背靠背或用胶带固定都行，屏幕朝向一致，用平时导航时的手持姿势。
3. **录制**：两台手机都点「开始录制」。先在空中画几次 8 字，等磁场精度变成「高」。
4. **打点**：选 8～15 个点位，最好就是指纹采集点，并且覆盖强信号区和弱信号区。
   - 每个点位上，两台手机**填相同的点位编号**，同时点「开始打点」，选 60 秒。
   - 结束时手机会震动；纯数字编号会自动 +1。
   - 坐标（cm）可以不填。
5. 走一段直线、转几个弯，用来检查 IMU 和航向，不打点。
6. 两台手机都停止录制，把两个 zip 拷到电脑上。

## 运行标定

```bash
python tools/calibrate.py android_s25plus_xxx.zip ios_16pro_xxx.zip --out calibration_out --plot
```

第一个参数是**参考机**（指纹采集用的 S25+），第二个是**目标机**（16 Pro）。脚本会输出：

- **RSSI 映射**：`rssi_S25 ≈ a·rssi_16Pro + b`。默认只拟合偏移 `b`；只有斜率明显偏离 1、并且误差明显更小时才推荐线性模型。
- **5 dB 分档一致率**：把 RSSI 按 5 dB 分箱，统计校正前后两台手机落在同一档的比例，用来衡量映射的效果。
- **覆盖率**：每个点位两台手机各扫到多少价签、每秒读数多少、读数稀疏的秒占比。读数太稀疏时，定位需要更长的时间窗才能凑够样本。
- **IMU 检查**：采样率、|a| 是否约等于 9.8、手机平放时 az 的符号。
- 输出文件：`calibration_out/calibration.json`、`pairs.csv`，加 `--plot` 时还有 `calibration.png`。

只看单个会话的统计：

```bash
python tools/calibrate.py ios_16pro_xxx.zip
```

### 映射的使用方式

**把映射应用到 iPhone 的每条原始读数上**，换算成「S25+ 会测到的值」后再送进定位算法。

注意要作用在**原始读数**上，而不是去平移指纹库里的 RSSI 区间。后者只能对齐区间判断，无法修正算法中按绝对 RSSI 取值的部分（例如按信号强弱分档加权）。

---

## 已知限制

- **iOS 必须前台、亮屏**。iOS 进入后台后会合并广播、降低扫描频率。App 录制时已禁用自动锁屏。
- **iOS 拿不到 MAC 地址**。`src` 列记录的是 CoreBluetooth 分配的 UUID。这不影响定位，因为价签 ID 取自厂商数据。
- **iOS 加速度换算**：已按 Android 约定换算（m/s²、含重力、平放时 +z 向上）。陀螺仪和磁场的坐标轴定义与 Android 相同。详见 `docs/data-format.md`。
- **定位与导航算法尚未真机验证**。单元测试用的是合成数据，关键常量（步长系数、磁校正增益、过程噪声、卡方门限）都需要用实地数据标定，优先级见 [HPASSKit 说明](ios/HPASSKit/README.md)。
- **服务器只允许 HTTPS 或局域网地址**。App 没有放开任意明文 HTTP，内网自签名证书可在页面里单独打开开关。
- 编译与测试由 CI（GitHub Actions，macOS + Ubuntu）执行，覆盖 Swift 库、iOS App、Android App 和 Python 工具。
