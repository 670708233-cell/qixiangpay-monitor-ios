# 七星支付收款播报 · iOS 版

Android 版（`qixiangpay-monitor-android/`）的完整 iOS 移植。纯协议链（无 WebView）：
**GeeTest v4 滑块 → 登录 → 订单轮询 → TTS 播报到账**。

## 功能对照

| 功能 | Android | iOS（本目录） |
|---|---|---|
| 滑块纯协议求解（w=AES+RSA、td 轨迹 gzip、缺口 IoU 检测） | Gt4Solver.kt | `Gt4Solver.swift`（逐位对齐，含 ±2 偏移重试环） |
| 登录 + cookie jar + 登录态缓存免滑块 | ApiClient.kt + sess.xml | `ApiClient.swift` + UserDefaults |
| 订单轮询（基线吸收/去重/指数退避 5s→60s） | MonitorService | `MonitorEngine.swift` |
| 订单日志（完整单号 + 支付时间 endtime + 商品名） | ✓ | ✓ |
| 7 音色 TTS（pitch/rate 变调变速） | TextToSpeech | AVSpeechSynthesizer（rate 按 0.5× 换算） |
| 检测间隔设置（3/5/10/30/60 秒，运行中改下一轮生效） | ✓ | ✓ |
| 倒序日志框（新记录在第一条，300 行上限）+ 运行时长 | ✓ | ✓ |
| 后台/锁屏播报 | 前台服务 | 静音音频保活 + 本地通知兜底 |
| 科技暗色风 UI | ✓ | ✓（SwiftUI） |

## 构建

1. 装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成工程（免去手写 pbxproj）：

   ```bash
   brew install xcodegen
   cd qixiangpay-monitor-ios
   xcodegen
   open QixiangPayMonitor.xcodeproj
   ```

2. 在 Xcode 里：选真机 → Signing & Capabilities 勾选你的 Team（免费 Apple ID 即可，7 天有效期）→ Run。
3. 首次启动需在 设置→通用→VPN与设备管理 信任开发者证书。

## 后台播报说明（与 Android 的本质差异）

iOS **没有常驻前台服务**。本项目采用自用分发下的标准方案：

- `UIBackgroundModes: audio` + 循环播放**近无声**音频（音量 0.01），锁屏/切后台时轮询与 TTS 继续跑
- **保活自愈链**（v1.1）：来电/闹钟打断自动恢复、拔耳机/断蓝牙自动重拉、媒体服务被系统重置自动重建、退后台 1s 后主动检查、20s watchdog + 轮询循环每轮兜底——任一事件掐掉音频会话都会被自动拉回
- 每笔新订单同时发一条**本地通知**（横幅+声音）兜底，前台也弹横幅（NotifyDelegate）——万一保活被系统掐掉，你还能看到通知
- 限制：
  - 自用签名（免费证书 7 天需重签）/ TestFlight / 个人开发者证书均可
  - **无法上 App Store**（后台音频用途不符审核条款）
  - **用户上滑强杀 App 必死**，这是 iOS 系统级限制无解；正常运行请只按 Home/锁屏，不要上滑
  - 手机重启后需重新打开 App；低电量模式可能限制后台音频，建议充电时使用

## 技术要点（移植自逆向定案）

- w = `AES-128-CBC(iv="0"*16, 随机hex key)` + `RSA-1024-PKCS1v15(key)`，模数硬编码于 `Gt4Solver.swift`
- td 轨迹 gzip → base64url，`td_sign = HMAC-SHA256(lot_number, td)`
- 缺口检测：HSV V 通道中位数 − 阈值(60/80/100) + 2×2 腐蚀 + 积分图形状 IoU
- 请求**必须带 Accept 头**（源站 WAF 铁律，缺则 404）
- 轮询成功路径必须 sleep（源站怕轰炸，间隔预设最短 3 秒）
