# 不用 Xcode 安装到 iPhone：GitHub 云编译 + 免费 Apple ID 侧载

适用于没有付费开发者账号的情况。**限制**：签名 7 天过期，到期后 App 打不开，需要重新签名安装一次（数据不会丢，App 里的会话目录保留）；同一个免费 Apple ID 同时最多有 3 个侧载 App。

## 一、云编译出 ipa（每次改完代码做一遍）

1. 把代码推到 GitHub（`kalijerry/crack-1`）。推送到任意分支或开 PR 都会触发 CI。
2. 打开仓库的 **Actions** 页，点最新一次 **CI**，等 `iOS app` 任务变绿（约 5～10 分钟）。
   - 变红说明编译失败或缺权限说明，点进去看日志，把报错发给我。
3. 在这次运行页面底部的 **Artifacts** 下载 `eslcollector-unsigned-ipa`，解压得到 `ESLCollector-unsigned.ipa`（需要登录 GitHub）。

也可以用命令行（先 `gh auth login`）：

```bash
gh run download --repo kalijerry/crack-1 -n eslcollector-unsigned-ipa -D ~/Downloads
```

## 二、手机端准备（只做一次）

1. **设置 → 隐私与安全性 → 开发者模式** 打开，手机会重启。
2. 数据线连接 Mac，手机上点「信任此电脑」。

## 三、用 Sideloadly 签名并安装

1. 从 Sideloadly 官网下载安装 Mac 版（本文步骤凭使用经验写成，界面可能随版本变化）。
2. 打开 Sideloadly，选中已连接的 iPhone。
3. 把 `ESLCollector-unsigned.ipa` 拖进窗口，填 Apple ID，点 **Start**，按提示输入密码。
   - 建议用一个**专门的 Apple ID**，不要用主账号。
   - Bundle ID 默认的 `com.example.eslcollector` 若被占用，Sideloadly 的 Advanced Options 里可以改，例如 `com.你的名字.eslcollector`。
4. 安装完成后，在手机上 **设置 → 通用 → VPN 与设备管理**，信任这个 Apple ID 的开发者证书。
5. 打开 App，允许蓝牙、运动与健身、定位（仅使用期间）三个权限。定位只用来读罗盘航向，不读位置。

## 四、每 7 天续签

到期前（或到期后）重新用 Sideloadly 装一次**同一个 ipa**即可，不需要重新云编译。
Sideloadly 有「自动重新签名」选项，需要 Mac 开着、手机与 Mac 同一 Wi-Fi，不保证可靠，建议采集当天早上手动确认一遍。

> **采集前一定先装好并跑一遍**：开始录制 30 秒，确认采集页「原始磁力计」约 100 Hz，再停止导出，检查会话目录里有 `mag_raw.csv` 等文件。进场前发现问题比现场发现好。

## 五、故障排查

| 现象 | 处理 |
|---|---|
| Sideloadly 报 `Guru Meditation` 或 provisioning 错误 | 换一个 Bundle ID 重试；确认 Apple ID 已开启双重认证并使用应用专用密码 |
| 提示 App ID 数量达到上限 | 免费账号每 7 天只能新建约 10 个 App ID，等一周或删旧的 |
| 打开 App 立即闪退 | 手机 **设置 → 隐私与安全性 → 分析与改进 → 分析数据** 找 ESLCollector 的崩溃日志发给我 |
| 磁力计频率远低于 100 Hz | 关闭低电量模式，关掉其他占用传感器的 App |
| 一周后打不开 | 签名过期，重新用 Sideloadly 安装即可 |
