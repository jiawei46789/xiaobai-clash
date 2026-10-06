# xiaobai-clash

HarmonyOS NEXT 原生 Clash/Mihomo VPN 客户端（HAP），在 [LIAN CONNECT](https://github.com/ljq123ok/LIAN-CONNECT)（GPL-3.0）基础上改造。上游文档存档于 `docs/UPSTREAM-README.md`。

> **用途边界**：本项目面向「在**自己拥有和控制的设备**上做个人流量审计」。请勿将其用于监控他人设备——未经同意收集他人通信去向在多数司法辖区违法。**禁止将本应用用于违法犯罪、攻击入侵、诈骗、侵权、传播违法信息或绕过法律法规监管等用途。**

## 相对上游的功能改动

| 功能 | 说明 |
|---|---|
| 流量去向回传 | VPN 扩展每秒把连接明细（域名/目标 IP:Port/命中规则/代理链/上下行字节）增量 POST 到电脑端接收器；事件分 `conn` / `update` / `end`，另有 `node_switch` |
| 接收器鉴权 | 设备与接收器成对配置 Bearer token（沙箱 `lian-report.json` 的 `token` 字段，空 = 不鉴权） |
| 节点自动体检+切换 | 纯 ArkTS 走 mihomo 本地控制端口（127.0.0.1:9090）：当前节点连续探测失败后自动切到最快存活节点；url-test 组在位时只在整组全灭才接管；含防抖冷却 |
| VPN 纯手动开关 | 默认关闭启动自动连接与意外中断自动重连（上游曾有的 autoConnect/wantConnected 路径已切断） |
| 深色模式开关 | 设置页即时切换并持久化（注意：这类"会被配置变更重建 UI"的开关不要用 @Builder 按值传参，Toggle 会拿旧参数弹回） |
| 订阅导入宽容化 | Clash YAML 识别不再要求首行前缀：注释开头、任意顶层键、base64 包 YAML、纯 proxy-providers 均可导入；节点计数只统计 `proxies:` 段 |
| 节点页订阅切换 | 多订阅时订阅条出现「切换」面板，一键换当前订阅 |

## 构建

需要 DevEco Studio / HarmonyOS SDK（API 24+）。**不需要** OpenHarmony Go 工具链——`entry/libs/arm64-v8a/libmihomo_ohos.so` 为预编译内核（构建自上游 pin 定的 mihomo + gVisor 提交，用 `scripts/build-core.sh` 可自行复现并比对）。

```powershell
$env:DEVECO_SDK_HOME = "<你的 SDK 路径>"
$env:JAVA_HOME = "<DevEco 自带 jbr>"
& "<DevEco 自带 node>" "<DevEco>/tools/hvigor/bin/hvigorw.js" `
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。
**未签名包不能安装**：需自签名（自己的证书 + 匹配 bundleName 与设备 UDID 的 profile），见 `docs/SELF_SIGNING.md`。签名材料放法参考 `scripts/publish-update.example.ps1`（构建→签名→无线装机一条龙，凭据一律从本机外部文件读取，不写进脚本/仓库）。

## 电脑端接收器

零依赖 Node 脚本，实时落盘 JSONL + 看板：

```bash
node pc-side/report-server.mjs [--port 18820] [--token ***] [--dir ./traffic-log]
# 看板 http://localhost:18820/ ；数据 traffic-log/connections-YYYY-MM-DD.jsonl
```

设备端配置在应用沙箱 `filesDir/lian-report.json`（首次运行自动生成默认值）：

```json
{ "enabled": true, "endpoint": "http://<你的电脑局域网IP>:18820/ingest",
  "token": "", "intervalSeconds": 2, "device": "my-phone",
  "includeDirect": true, "minDeltaBytes": 0, "maxBatch": 40 }
```

默认 endpoint 占位符 `192.168.1.100` 只是示例——首次启动前请用 `hdc file send` 预置配置文件，或直接改 `TrafficReporter.ets` 的 `DEFAULT_ENDPOINT` / `DEFAULT_TOKEN` 后重建，与接收端 `--token` 成对。

节点切换器独立配置：`lian-nodeswitch.json`（`enabled` / `intervalSeconds` / `failThreshold` / `switchCooldownSeconds` / `maxTest` / `testUrl` 等）。

## 安全注意

- 回传为**明文 HTTP**，token 只防注入伪造、不加密内容：仅在受控局域网启用
- 接收器 `/` 与 `/api/state` 不鉴权（默认只听本机；跨机使用请自行加反代鉴权）
- 仓库不含任何签名材料/口令/订阅凭据；订阅只存设备沙箱

## 许可证

GPL-3.0（继承上游）。发布时保留 `LICENSE`、`THIRD_PARTY_NOTICES.md` 与上游 attribution；再分发编译产物需按 GPL 提供对应源码与构建说明（本仓库即源码）。
