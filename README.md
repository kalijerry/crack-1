# HPASS 室内定位与导航

只用手机、不装硬件的室内定位与导航系统，全部自研。核心是**地磁 + 惯导 + 视觉**的多源融合，无线信号（蓝牙 / Wi-Fi）作为可选增强。

算法基于公开文献自行实现，不依赖任何厂商 SDK。仓库里不包含任何场地数据、地图、账号或服务器地址。

## 能做什么

| 能力 | 说明 |
|---|---|
| 地磁定位 | 磁场图 + 粒子滤波，冷启动、跟丢检测与重找、跨会话磁场偏移自动对齐 |
| 惯导 / 视觉里程计 | 计步 + 步长 + 姿态融合；有摄像头时用 ARKit 视觉里程计做运动模型 |
| 地图约束 | 通道路网或可走多边形约束，粒子不穿墙 |
| 楼层 | 气压计判断换层，区分电梯 / 扶梯 / 楼梯 |
| 无线增强（可选） | 蓝牙指纹 / 信标作为冷启动先验和错定检测 |
| 视觉重定位 | 房间尺度的视觉地图重定位；文字标识识别作为绝对地标 |
| 建图 | 拿手机走一遍：ARKit 位姿做真值，手机上或云端生成磁场图；多次采集自动融合 |
| 地图来源 | 自有地图格式、IMDF 场馆导入、RoomPlan 三维扫描生成 |
| 导航 | A* 路径规划、转向提示、到达判定 |
| 地图维护 | 定位过程中检测磁场变化，提示需要补采的区域 |
| 评估 | 回放评估工具 + 公开数据集基准，按中位 / P90 / 错定率 / 首次定位距离出报告 |

## 仓库结构

| 目录 | 内容 |
|---|---|
| `ios/HPASSKit` | 定位与导航核心库（Swift Package，纯 Foundation，无第三方依赖），含命令行工具 `hpass-replay` / `hpass-eval` / `hpass-build`。见 [模块说明](ios/HPASSKit/README.md) |
| `ios/` | iOS 采集与定位 App（SwiftUI，iOS 16+，XcodeGen 工程） |
| `android` | Android 采集 App（Kotlin） |
| `server/telemetry` | 云端后台（Cloudflare Workers）：实时日志、会话 / 地图 / 报告存储、看板 |
| `tools/` | 离线工具：建图质检、磁场可行性分析、LiDAR 几何检查、跨机型 RSSI 标定、云端融合建图 |
| `tools/venue` | 场馆地图转换（IMDF 等） |
| `tools/bench` | 公开数据集基准 |
| `web/` | 地图编辑器 |
| `docs/` | 设计文档、数据格式、操作指南 |

## 文档

设计文档、数据格式和操作指南在 `docs/` 下。

## 编译

### 核心库与命令行工具（macOS）

```bash
cd ios/HPASSKit && swift test
```

```bash
cd ios/HPASSKit && swift build -c release
```

### iOS App（Mac + Xcode 15 以上）

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，仓库里不提交 `.xcodeproj`：在 App 工程目录（含 `project.yml`）里运行 `xcodegen generate`，再用 Xcode 打开生成的工程。

在 *Signing & Capabilities* 里选自己的 Team，必要时把 Bundle Identifier 改成自己的。真机需要打开开发者模式。也可以直接用 CI 产出的安装包。

### Android App

```bash
cd android && ./gradlew assembleDebug
```

### Python 工具

```bash
python -m unittest discover -s tools/tests
```

## 持续集成

所有构建、测试和评估都在 GitHub Actions 里跑：

| 工作流 | 内容 |
|---|---|
| `ci.yml` | 核心库测试、iOS / Android 构建、Python 工具测试、后台检查 |
| `lab.yml` | 定位实验室：固定数据和协议上回放，量化精度、拦住退步、跟踪离目标的差距 |
| `map-build.yml` | 云端融合建图（手动触发） |
| `ios-adhoc.yml` | 签名安装包 |

## 状态

核心算法有单元测试和回放评估。精度数字以跨会话、跨日期的回放评估为准，见各文档。
