# 定位云端后台（Cloudflare Worker）

App 实时发日志和定位 / 采集状态（WebSocket），采集会话和地图上传到 R2；浏览器打开就是看板：地图上看每台手机的实时位置和轨迹、滚动日志、下载会话、看评估报告。

## 部署（第一次，大约 10 分钟）

需要一个 Cloudflare 账号（免费版够用；Durable Objects 用的是 SQLite 存储，免费版可用）。

```bash
cd server/telemetry
npm install
npx wrangler login                       # 浏览器里登录 Cloudflare 授权
npx wrangler r2 bucket create hpass-data # 存会话、地图、日志、报告
npx wrangler secret put TOKEN            # 输入一个足够长的口令（App 和看板都用它）
npx wrangler deploy                      # 输出 https://hpass-telemetry.<你的子域>.workers.dev
```

## App 里

「门店数据 → 云端后台」：填上面的地址（不带 https:// 也行）和口令，打开「连接后台」。
- 日志、定位 / 采集状态实时上去（每秒最多 2 次状态；断网时攒着，连上补发）；
- 「采集结束自动上传会话」默认开，也可以在「导出给电脑建图」里手动上传；
- 连上时自动上传当前地图（看板画地图用），切换地图会重新上传。

## 看板

浏览器打开部署地址，输入口令，点「连接」。左边设备列表，中间地图（滚轮缩放、拖动），右边日志 / 会话 / 评估。

## 评估报告

建图会话和测试会话分开（App 采集页打开「这次是测试会话」），在电脑上：

```bash
cd ios/HPASSKit
swift run -c release hpass-eval --map map.json --build 会话1,会话2 --test 测试会话1 --json report.json
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @report.json \
  https://hpass-telemetry.<你的子域>.workers.dev/api/reports/$(date +%Y%m%d_%H%M).json
```

会话 zip 从看板「会话」里下载、解压就是 hpass-eval 要的目录。

## 本地调试

```bash
printf 'TOKEN=test\n' > .dev.vars
npx wrangler dev        # http://localhost:8787
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 看板 |
| GET | `/ws?role=device&device=名字&token=…` | App 连这里，发 JSON（单条或数组）：`hello` / `log` / `state` |
| GET | `/ws?role=viewer&token=…` | 看板连这里，先收 `snapshot`，之后实时收设备消息和 `online` |
| PUT/GET | `/api/sessions/<名字>.zip`、GET `/api/sessions` | 会话上传 / 下载 / 列表 |
| PUT/GET | `/api/maps/<地图编号>` | 地图 JSON |
| PUT/GET | `/api/reports/<名字>.json`、GET `/api/reports` | 评估报告 |
| GET | `/api/logs?day=YYYY-MM-DD`、`/api/logs/<key>` | 日志分块（NDJSON，每 200 条或 30 秒一块） |

所有接口都要口令：`Authorization: Bearer <TOKEN>`，WebSocket 用 `?token=`。没配 TOKEN 时全部拒绝。
