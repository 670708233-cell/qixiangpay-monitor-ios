import Foundation                 // 基础库：Thread、UserDefaults、NSLock 等
import UIKit                      // UI 框架（本文件实际用到的主要是间接依赖）
import UserNotifications          // 本地通知框架：UNUserNotificationCenter、UNMutableNotificationContent

/// 收款监控引擎：轮询已支付订单 → 比对 trade_no → TTS 播报。
/// 与 Android 版 MonitorService 逻辑对齐：基线吸收、指数退避、间隔实时读取、登录态自动恢复。
final class MonitorEngine {       // final：单例不允许继承
    static let shared = MonitorEngine()  // 全局单例：UI 与后台线程共用同一引擎状态

    // 单源预设（UI 与引擎共用）
    static let VOICES = ["标准女声", "甜美女声", "磁性男声", "萝莉音", "御姐音", "快速播报", "慢速清晰"]  // 7 个音色名称（下拉框选项）
    static let PITCH: [Float] = [1.0, 1.35, 0.65, 1.7, 0.8, 1.1, 1.0]  // 各音色对应音调倍率（与 VOICES 下标一一对应）
    static let RATE: [Float] = [1.0, 1.0, 0.95, 1.05, 0.9, 1.5, 0.75]  // Android 尺度，播报时换算  // 语速倍率（Android 尺度，iOS 端 ×0.5 换算）
    static let INTERVALS: [Int] = [3, 5, 10, 30, 60]                    // 秒  // 轮询间隔可选值（秒）
    static let INTERVAL_LABELS = ["3 秒", "5 秒", "10 秒", "30 秒", "60 秒"]  // 间隔的下拉框显示文案（与 INTERVALS 对齐）

    // 回调（主线程）
    var onLog: ((String) -> Void)?   // 日志回调：引擎把一条日志推给 UI
    var onStatus: ((_ status: String, _ uptime: String) -> Void)?  // 状态回调：状态文字 + 运行时长

    private let lock = NSLock()      // 互斥锁：保护 runningFlag 等跨线程状态
    private var runningFlag = false  // 是否运行中（真值以 lock 保护后的读取为准）
    private var stopFlag = false     // 停止信号：轮询线程每圈检查，置位即退出
    private var startAt: TimeInterval = 0   // CACurrentMediaTime 秒  // 启动时刻（单调时钟，不受系统改时间影响）
    private var announced = 0        // 本次运行已播报的订单笔数
    private var seen = Set<String>() // 已见订单号集合：去重核心，同一单绝不播第二次
    private var worker: Thread?      // 轮询后台线程句柄
    private(set) var user = ""       // 当前账号（只允许内部写，外部只读）
    private(set) var pass = ""       // 当前密码（同上）

    var running: Bool { lock.lock(); defer { lock.unlock() }; return runningFlag }  // 线程安全的运行状态读取

    static var intervalIndex: Int {  // 轮询间隔选择下标的持久化读写
        get { UserDefaults.standard.integer(forKey: "interval_idx") }   // 读（默认 0 = 3 秒）
        set { UserDefaults.standard.set(newValue, forKey: "interval_idx") }  // 写
    }

    static var voiceIndex: Int {     // 音色选择下标的持久化读写
        get { UserDefaults.standard.integer(forKey: "voice_idx") }      // 读（默认 0 = 标准女声）
        set { UserDefaults.standard.set(newValue, forKey: "voice_idx") }  // 写
    }

    private func log(_ s: String) { onLog?(s) }  // 内部便捷方法：转发日志回调
    private func status(_ s: String, uptime: String = "") { onStatus?(s, uptime) }  // 内部便捷方法：转发状态回调

    /// 毫秒 → HH:MM:SS
    private func fmtDur(_ ms: Double) -> String {  // 把运行时长（毫秒）格式化为 时:分:秒
        let s = Int(ms / 1000)                     // 先转总秒数
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)  // 拆时/分/秒，各补零两位
    }

    // MARK: - 控制

    func start(user: String, pass: String) {  // 启动监控（UI「开始监控」按钮调用）
        lock.lock(); defer { lock.unlock() }  // 加锁保护状态判断与修改
        guard !runningFlag else { return }    // 已在运行 → 直接忽略（防重复启动）
        runningFlag = true                    // 置运行标志
        stopFlag = false                      // 清停止标志
        self.user = user                      // 记住账号
        self.pass = pass                      // 记住密码
        UserDefaults.standard.set(user, forKey: "cfg_user")  // 账号持久化（下次启动自动填充）
        UserDefaults.standard.set(pass, forKey: "cfg_pass")  // 密码持久化
        startAt = CACurrentMediaTime()        // 记录启动时刻（算运行时长用）
        announced = 0                         // 播报计数清零
        ApiClient.log = { [weak self] s in self?.log(s) }   // 网络层的日志接到引擎 → UI
        Gt4Solver.log = { [weak self] s in self?.log(s) }   // 滑块求解层的日志接到引擎 → UI
        KeepAlive.shared.log = { [weak self] s in self?.log(s) }  // ★保活自愈事件的日志也接到引擎 → UI
        // 前台也弹横幅（默认前台不展示通知）
        UNUserNotificationCenter.current().delegate = NotifyDelegate.shared  // ★注册通知代理：前台到账也弹横幅+响声
        KeepAlive.shared.start()              // ★启动静音音频保活（五重自愈链）
        requestNotifyPermission()             // 顺手请求通知权限（首次安装弹系统授权框）
        let t = Thread { [weak self] in self?.workerLoop() }  // 创建轮询线程（weak：线程存活期可能超过引擎）
        t.stackSize = 4 << 20                 // 栈开到 4MB（滑块图像检测递归较深，防栈溢出）
        worker = t                            // 保存线程句柄（stop 时 cancel）
        t.start()                             // 启动轮询线程
    }

    func stop() {                             // 停止监控（UI「停止」按钮调用）
        lock.lock(); defer { lock.unlock() }  // 加锁
        stopFlag = true                       // 置停止信号（轮询线程本圈结束即退）
        runningFlag = false                   // 清运行标志
        worker?.cancel()                      // 取消线程（配合 stopFlag 双保险）
        KeepAlive.shared.stop()               // 停掉音频保活（注销观察者+停播放器+释放会话）
        status("已停止")                       // 通知 UI 更新状态
    }

    func testTts() {                          // 「测试播报」按钮
        SpeechService.shared.speak("微信收款到账8.88元")  // 用当前音色念一句样例
        let idx = min(max(Self.voiceIndex, 0), Self.VOICES.count - 1)  // 取当前音色下标（越界保护）
        log("[tts] 测试播报完成（音色：\(Self.VOICES[idx])）")  // 日志确认
    }

    private func requestNotifyPermission() {  // 请求通知权限
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }  // 弹横幅+声音授权；结果不关心（拒绝也不影响 TTS）
    }

    // MARK: - 轮询循环

    private func workerLoop() {               // 轮询主循环（运行在独立后台线程）
        ApiClient.log = log                   // 线程内再绑一次日志（防主线程绑定被置空）
        Gt4Solver.log = log                   // 同上
        var baseline = true                   // 基线标志：第一轮只吸收现有订单、不播报（防止启动瞬间轰炸历史单）
        var backoff = 5.0                     // 异常退避秒数：失败后从 5s 开始指数翻倍
        while !stopFlag {                     // 主循环：收到停止信号即退出
            do {
                try pollOnce(baseline: baseline)  // 拉一次订单列表并处理
                baseline = false              // 首轮成功后不再是基线轮
                backoff = 5.0                 // 成功则重置退避
                KeepAlive.shared.ensure()     // ★轮询级保活兜底：音频被掐立即拉回（watchdog 之外再补一刀）
                status("运行中：已播报 \(announced) 笔",          // 更新 UI 状态
                       uptime: fmtDur((CACurrentMediaTime() - startAt) * 1000))  // 顺带刷新运行时长
                Thread.sleep(forTimeInterval: Double(pollIntervalSec()))  // 按用户设置睡到下一轮（实时读，改设置下一轮生效）
            } catch {                         // 本轮出错（网络/登录/解析）
                log("[err] \(error)（\(Int(backoff))s 后重试）")  // 记录错误与重试等待
                status("异常重试中：\(error.localizedDescription)")  // UI 状态提示
                ApiClient.resetSession()      // 清登录态：下轮强制走完整登录链
                Thread.sleep(forTimeInterval: backoff)  // 先退避等待（别轰炸源站）
                backoff = min(backoff * 2, 60)  // 指数翻倍，封顶 60s
            }
        }
        lock.lock(); runningFlag = false; lock.unlock()  // 线程退出前同步运行标志（自然退出场景）
        status("已停止")                       // 通知 UI
    }

    /// 用户设置的轮询间隔（每轮实时读，改设置下一轮立即生效）
    private func pollIntervalSec() -> Int {   // 读取当前应使用的轮询间隔
        let idx = min(max(Self.intervalIndex, 0), Self.INTERVALS.count - 1)  // 下标越界保护
        return Self.INTERVALS[idx]            // 返回对应秒数
    }

    private func pollOnce(baseline: Bool) throws {  // 单次轮询：登录态检查 → 拉订单 → 逐单去重处理
        if !ApiClient.hasToken() && !ApiClient.restoreCookies() {  // 无 token 且缓存 cookie 也恢复不了
            try loginChain()                  // → 走完整登录链（滑块）
        }
        let j = try ApiClient.orderList(dstatus: "1", page: "1", limit: "20")  // 拉第 1 页已支付订单（最新 20 笔）
        guard let rows = j["rows"] as? [[String: Any]] else {  // 响应里必须有 rows 数组
            throw RuntimeError("orderList 无 rows")  // 缺了就当异常抛出（触发退避重试）
        }
        var newCnt = 0                        // 本轮新发现订单计数
        for r in rows {                       // 逐单处理
            guard let tradeNo = r["trade_no"] as? String, !tradeNo.isEmpty,  // 单号必须非空
                  !seen.contains(tradeNo) else { continue }  // 见过的单直接跳过（去重）
            newCnt += 1                       // 计入新订单
            let money = (r["realmoney"] as? String).flatMap { $0.isEmpty ? nil : $0 }  // 优先取实际到账金额
                ?? (r["money"] as? String) ?? ""  // 空则退回订单金额，再空给空串
            let channel: String               // 支付渠道文案
            switch (r["type"] as? Int) ?? 0 { // 按订单 type 字段判断
            case 2: channel = "微信"          // 2 = 微信
            case 1: channel = "支付宝"        // 1 = 支付宝
            default: channel = "收款"         // 其他/缺失 = 泛称
            }
            let payTime = (r["endtime"] as? String).flatMap { $0.isEmpty ? nil : $0 }  // 优先取支付完成时间
                ?? (r["addtime"] as? String) ?? ""  // 空则退回下单时间
            let name = r["name"] as? String ?? ""  // 商品名（仅入日志）
            log("[新订单] \(channel) ¥\(money) 支付\(payTime) 单号\(tradeNo) \(name)")  // 完整信息入日志
            if !baseline {                    // 非基线轮才提醒（基线轮只吸收历史单）
                announced += 1                // 播报计数 +1
                SpeechService.shared.speak("\(channel)收款到账\(money)元")  // ★TTS 语音播报金额
                notifyOnce(tradeNo: tradeNo, channel: channel, money: money, payTime: payTime)  // ★系统推送（横幅+声音）
            }
            seen.insert(tradeNo)              // 标记为已见（下轮去重）
            if seen.count > 5000 { seen.removeAll() }  // 防集合无限膨胀：超 5000 清空重来（旧单早已出列表）
        }
        if baseline && newCnt > 0 { log("[基线] 吸收现有订单 \(newCnt) 笔（不播报）") }  // 基线轮的吸收汇总日志
    }

    private func loginChain() throws {        // 完整登录链：清会话 → CSRF → 滑块 → 提交
        log("[auth] 开始登录链（滑块）")        // 日志起头
        ApiClient.resetSession()              // 清空旧会话/cookie
        let csrf = try ApiClient.getCsrf()    // 取登录页 CSRF token
        guard let sec = Gt4Solver.solve() else { throw RuntimeError("滑块验证失败") }  // 纯协议过 GeeTest v4 滑块
        guard ApiClient.login(user: user, pass: pass, csrf: csrf, sec: sec) else {  // 提交登录
            throw RuntimeError("登录失败")     // 服务端拒绝 → 抛异常走退避
        }
        log("[auth] 登录成功 user_token=\(ApiClient.tokenPreview())..")  // 成功日志（token 只打前几位）
    }

    /// 本地通知：到账横幅+声音（后台时与 TTS 双通道，前台时由 NotifyDelegate 保证也弹）
    private func notifyOnce(tradeNo: String, channel: String, money: String, payTime: String) {  // 发一条到账推送
        let content = UNMutableNotificationContent()  // 通知内容对象
        content.title = "收款到账 \(channel) ¥\(money)"  // 标题：渠道 + 金额
        content.body = payTime.isEmpty ? "单号 \(tradeNo)" : "支付时间 \(payTime)\n单号 \(tradeNo)"  // 正文：支付时间（有则带）+ 完整单号
        content.sound = .default              // 系统提示音（锁屏/后台也能响）
        let req = UNNotificationRequest(identifier: tradeNo, content: content, trigger: nil)  // 立即触发；identifier=单号（同单可覆盖去重）
        UNUserNotificationCenter.current().add(req) { err in  // 提交到通知中心
            if let err = err { self.log("[通知] 发送失败：\(err.localizedDescription)") }  // 失败写日志（如权限被拒）
        }
    }
}

/// 前台也展示通知横幅（iOS 默认前台静默丢弃，不设 delegate 前台永远看不到推送）
final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {  // 通知中心代理：决定前台展示行为
    static let shared = NotifyDelegate()  // 单例：delegate 是弱引用，必须有人长期持有否则失效

    func userNotificationCenter(_ center: UNUserNotificationCenter,           // 前台收到通知时的回调
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list, .banner, .sound])  // 展示：进通知中心列表 + 顶部横幅 + 播放声音
    }
}
