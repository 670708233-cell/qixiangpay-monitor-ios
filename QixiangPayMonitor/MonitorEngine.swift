import Foundation
import UIKit
import UserNotifications

/// 收款监控引擎：轮询已支付订单 → 比对 trade_no → TTS 播报。
/// 与 Android 版 MonitorService 逻辑对齐：基线吸收、指数退避、间隔实时读取、登录态自动恢复。
final class MonitorEngine {
    static let shared = MonitorEngine()

    // 单源预设（UI 与引擎共用）
    static let VOICES = ["标准女声", "甜美女声", "磁性男声", "萝莉音", "御姐音", "快速播报", "慢速清晰"]
    static let PITCH: [Float] = [1.0, 1.35, 0.65, 1.7, 0.8, 1.1, 1.0]
    static let RATE: [Float] = [1.0, 1.0, 0.95, 1.05, 0.9, 1.5, 0.75]  // Android 尺度，播报时换算
    static let INTERVALS: [Int] = [3, 5, 10, 30, 60]                    // 秒
    static let INTERVAL_LABELS = ["3 秒", "5 秒", "10 秒", "30 秒", "60 秒"]

    // 回调（主线程）
    var onLog: ((String) -> Void)?
    var onStatus: ((_ status: String, _ uptime: String) -> Void)?

    private let lock = NSLock()
    private var runningFlag = false
    private var stopFlag = false
    private var startAt: TimeInterval = 0   // CACurrentMediaTime 秒
    private var announced = 0
    private var seen = Set<String>()
    private var worker: Thread?
    private(set) var user = ""
    private(set) var pass = ""

    var running: Bool { lock.lock(); defer { lock.unlock() }; return runningFlag }

    static var intervalIndex: Int {
        get { UserDefaults.standard.integer(forKey: "interval_idx") }
        set { UserDefaults.standard.set(newValue, forKey: "interval_idx") }
    }

    static var voiceIndex: Int {
        get { UserDefaults.standard.integer(forKey: "voice_idx") }
        set { UserDefaults.standard.set(newValue, forKey: "voice_idx") }
    }

    private func log(_ s: String) { onLog?(s) }
    private func status(_ s: String, uptime: String = "") { onStatus?(s, uptime) }

    /// 毫秒 → HH:MM:SS
    private func fmtDur(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    // MARK: - 控制

    func start(user: String, pass: String) {
        lock.lock(); defer { lock.unlock() }
        guard !runningFlag else { return }
        runningFlag = true
        stopFlag = false
        self.user = user
        self.pass = pass
        UserDefaults.standard.set(user, forKey: "cfg_user")
        UserDefaults.standard.set(pass, forKey: "cfg_pass")
        startAt = CACurrentMediaTime()
        announced = 0
        ApiClient.log = { [weak self] s in self?.log(s) }
        Gt4Solver.log = { [weak self] s in self?.log(s) }
        KeepAlive.shared.start()
        requestNotifyPermission()
        let t = Thread { [weak self] in self?.workerLoop() }
        t.stackSize = 4 << 20
        worker = t
        t.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopFlag = true
        runningFlag = false
        worker?.cancel()
        KeepAlive.shared.stop()
        status("已停止")
    }

    func testTts() {
        SpeechService.shared.speak("微信收款到账8.88元")
        let idx = min(max(Self.voiceIndex, 0), Self.VOICES.count - 1)
        log("[tts] 测试播报完成（音色：\(Self.VOICES[idx])）")
    }

    private func requestNotifyPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - 轮询循环

    private func workerLoop() {
        ApiClient.log = log
        Gt4Solver.log = log
        var baseline = true
        var backoff = 5.0
        while !stopFlag {
            do {
                try pollOnce(baseline: baseline)
                baseline = false
                backoff = 5.0
                status("运行中：已播报 \(announced) 笔",
                       uptime: fmtDur((CACurrentMediaTime() - startAt) * 1000))
                Thread.sleep(forTimeInterval: Double(pollIntervalSec()))
            } catch {
                log("[err] \(error)（\(Int(backoff))s 后重试）")
                status("异常重试中：\(error.localizedDescription)")
                ApiClient.resetSession()
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 60)
            }
        }
        lock.lock(); runningFlag = false; lock.unlock()
        status("已停止")
    }

    /// 用户设置的轮询间隔（每轮实时读，改设置下一轮立即生效）
    private func pollIntervalSec() -> Int {
        let idx = min(max(Self.intervalIndex, 0), Self.INTERVALS.count - 1)
        return Self.INTERVALS[idx]
    }

    private func pollOnce(baseline: Bool) throws {
        if !ApiClient.hasToken() && !ApiClient.restoreCookies() {
            try loginChain()
        }
        let j = try ApiClient.orderList(dstatus: "1", page: "1", limit: "20")
        guard let rows = j["rows"] as? [[String: Any]] else {
            throw RuntimeError("orderList 无 rows")
        }
        var newCnt = 0
        for r in rows {
            guard let tradeNo = r["trade_no"] as? String, !tradeNo.isEmpty,
                  !seen.contains(tradeNo) else { continue }
            newCnt += 1
            let money = (r["realmoney"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (r["money"] as? String) ?? ""
            let channel: String
            switch (r["type"] as? Int) ?? 0 {
            case 2: channel = "微信"
            case 1: channel = "支付宝"
            default: channel = "收款"
            }
            let payTime = (r["endtime"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (r["addtime"] as? String) ?? ""
            let name = r["name"] as? String ?? ""
            log("[新订单] \(channel) ¥\(money) 支付\(payTime) 单号\(tradeNo) \(name)")
            if !baseline {
                announced += 1
                SpeechService.shared.speak("\(channel)收款到账\(money)元")
                notifyOnce(tradeNo: tradeNo, channel: channel, money: money)
            }
            seen.insert(tradeNo)
            if seen.count > 5000 { seen.removeAll() }
        }
        if baseline && newCnt > 0 { log("[基线] 吸收现有订单 \(newCnt) 笔（不播报）") }
    }

    private func loginChain() throws {
        log("[auth] 开始登录链（滑块）")
        ApiClient.resetSession()
        let csrf = try ApiClient.getCsrf()
        guard let sec = Gt4Solver.solve() else { throw RuntimeError("滑块验证失败") }
        guard ApiClient.login(user: user, pass: pass, csrf: csrf, sec: sec) else {
            throw RuntimeError("登录失败")
        }
        log("[auth] 登录成功 user_token=\(ApiClient.tokenPreview())..")
    }

    /// 本地通知兜底（后台音频被系统掐掉时用户至少能看到横幅）
    private func notifyOnce(tradeNo: String, channel: String, money: String) {
        let content = UNMutableNotificationContent()
        content.title = "新收款 \(channel) ¥\(money)"
        content.body = "单号 \(tradeNo)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: tradeNo, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
