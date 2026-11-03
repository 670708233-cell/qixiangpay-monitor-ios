import Foundation                 // 基础库：Timer、NotificationCenter、Data 等
import AVFoundation               // 音频框架：AVAudioSession（音频会话）、AVAudioPlayer（播放器）
import UIKit                      // UI 框架：UIApplication 的退后台/回前台通知与后台任务
import MediaPlayer                // MPRemoteCommandCenter：禁掉锁屏控制中心的暂停键
import CoreLocation               // CLLocationManager：位置更新兜底（第二张后台牌照）

/// 后台保活 v1.2：静音音频循环（UIBackgroundModes=audio）+ 位置更新兜底（UIBackgroundModes=location）。
/// iOS 无常驻前台服务，这是自用分发下锁屏/切后台继续轮询+播报的标准做法。
/// v1.2 堵住 v1.1 的四个死区：
/// 1) 全零采样 WAV 可能被系统当"数字静音"掐掉 → 改成极低幅度正弦波（数据非零，输出无声）
/// 2) 主 RunLoop Timer 在锁屏/特定 mode 下可能不触发 → watchdog 改 GCD 定时器
/// 3) 锁屏控制中心误按暂停 → 注册 remote command 返回失败，按了无效
/// 4) 音频被掐且自愈窗口错过 → App 挂起、线程全冻、App 内自愈全部失效
///    → 位置更新兜底：GPS 回调能唤醒"已挂起"的 App（唯一 App 内可唤醒挂起的手段），
///      唤醒瞬间拉回音频。位置权限"始终允许"时此牌照独立于音频，双牌照并存。
/// 另有：退后台申请 30s 后台保护窗（音频死时 watchdog 仍有窗口拉回）。
/// 全链路自愈：来电/闹钟打断后恢复、拔耳机/断蓝牙后重拉、媒体服务重置后重建、
/// 退后台 1s 后主动检查、每 15s GCD watchdog 兜底、每轮轮询 ensure() 再兜一次。
final class KeepAlive: NSObject {    // NSObject：要挂 CLLocationManagerDelegate 回调
    static let shared = KeepAlive()  // 全局单例：整个 App 共用一个保活器（音频会话也只能有一个）

    /// 引擎启动时接上（保活自愈事件写进 UI 日志，方便定位被系统掐掉的原因）
    var log: ((String) -> Void)?  // 日志回调：由 MonitorEngine 注入，把保活事件显示到界面日志框

    private var player: AVAudioPlayer?      // 静音循环播放器：靠它维持音频会话"在放声音"的状态
    private var watchdog: DispatchSourceTimer?  // GCD 看门狗：不受 RunLoop mode 影响，锁屏照跑
    private var observers = [NSObjectProtocol]()  // 存所有通知观察者句柄，stop() 时统一移除防泄漏/重复
    private var started = false             // 保活开关状态：start/stop 幂等，防止重复装观察者
    private var bgTask: UIBackgroundTaskIdentifier = .invalid  // 退后台保护窗句柄（音频死后的 30s 缓冲）
    private var lastLocLog = Date.distantPast  // 位置回调日志节流：GPS 每秒回调，日志框别刷屏
    private let lm = CLLocationManager()    // 位置管理器：兜底牌照的载体（delegate 挂在本类）

    private func lg(_ s: String) { log?("[保活] \(s)") }  // 统一加 [保活] 前缀再转发给引擎日志

    func start() {                          // 开始保活（引擎启动时调用）
        guard !started else { ensure(); return }  // 已在保活中 → 只做一次健康检查，不重复初始化
        started = true                      // 置位运行标志
        installObservers()                  // 装载系统通知观察者（打断/路由/重置/退后台/回前台）
        installRemoteCommands()             // 禁掉锁屏控制中心的暂停/停止键（误按不致挂起）
        startWatchdog()                     // 启动 15s GCD 看门狗
        setupLocation()                     // 位置兜底：请求权限并开始低频定位（第二张牌照）
        activateAndPlay(reason: "启动")      // 首次激活音频会话并开始静音循环
    }

    func stop() {                           // 停止保活（引擎停止时调用）
        started = false                     // 先摘标志，watchdog/ensure 不再误拉起
        watchdog?.cancel()                  // 停掉 GCD 看门狗
        watchdog = nil                      // 释放引用
        observers.forEach { NotificationCenter.default.removeObserver($0) }  // 逐个注销系统通知观察者
        observers.removeAll()               // 清空句柄数组
        lm.stopUpdatingLocation()           // 停位置兜底（用户停止监控就别再占 GPS）
        endBgWindow()                       // 释放后台保护窗
        player?.stop()                      // 停止静音播放
        player = nil                        // 释放播放器（下次 start 会重建）
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])  // 释放音频会话，并通知其他 App 可以继续放音乐
    }

    /// 发现没在播就拉起（watchdog + 轮询循环 + 位置回调三保险）
    func ensure() {                         // 健康检查入口：被外部反复调用
        guard started else { return }       // 已停止则什么都不做
        if player == nil || player?.isPlaying != true {  // 播放器不存在 或 已不在播放 → 说明被系统掐了
            activateAndPlay(reason: "自愈拉起")  // 重新激活会话并续播
        }
    }

    // MARK: - 音频保活

    private func activateAndPlay(reason: String) {  // 激活音频会话 + 启动静音循环，reason 用于日志区分场景
        let session = AVAudioSession.sharedInstance()  // 取 App 唯一的音频会话对象
        do {
            // 独占音频会话（不 mix）：保活优先级最高，代价是会暂停其他 App 的音乐
            try session.setCategory(.playback, mode: .default)  // playback 类别 = 后台可播、锁屏不中断
            try session.setActive(true)     // 正式激活会话（此后 App 获得后台运行资格）
            if player == nil {              // 播放器尚未创建（首次 或 媒体服务重置后被置空）
                // v1.2：改用极低幅度正弦波。全零采样的"数字静音"可能被系统解码优化判定不活跃，
                // 非零采样让解码器真实工作；volume=0.01 再压一层 → 实际输出完全无声
                player = try AVAudioPlayer(data: Self.toneWav(seconds: 8))  // 8 秒 440Hz 极低幅正弦波 WAV
                player?.numberOfLoops = -1  // -1 = 无限循环播完再播
                player?.prepareToPlay()     // 预加载音频缓冲，降低首次 play 延迟
            }
            player?.volume = 0.01           // 音量 1%：叠加波形自身 0.2% 振幅 → 系统认定在放音频、人耳无声
            if player?.isPlaying != true { player?.play() }  // 只在没播时调 play，避免重复调用打断播放
            lg("音频会话活跃（\(reason)）")   // 记录成功场景到 UI 日志
        } catch {                           // 激活可能失败（如来电占用中、会话冲突）
            lg("会话激活失败（\(reason)）：\(error.localizedDescription)，watchdog 会自动重试")  // 失败也留痕，靠 watchdog 兜底
        }
    }

    private func installObservers() {       // 装载全部系统通知观察者（自愈链核心）
        let nc = NotificationCenter.default  // 通知中心简写

        // 1) 打断（来电/闹钟/Siri/其他 App 抢音频）→ 结束后恢复
        observers.append(nc.addObserver(    // 注册观察者并保存句柄
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main  // 监听音频打断事件，回调派发到主线程
        ) { [weak self] note in             // weak 防循环引用（单例实际不会释放，规范起见）
            guard let info = note.userInfo, // 取打断事件附带信息
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,  // 打断类型原始值（ UInt 枚举）
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }  // 转成枚举，异常直接跳过
            if type == .began {             // 打断开始（如来电接起）
                self?.lg("音频被打断（来电/闹钟等），等待系统放行")  // 只记日志，此时不能抢回音频
            } else {                        // 打断结束（如挂断电话）
                let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0  // 系统给出的恢复选项
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {  // 系统说"可以恢复"
                    self?.activateAndPlay(reason: "打断结束恢复")  // 立即重新激活并续播
                } else {                    // 系统未放行（如 Siri 场景）
                    self?.lg("打断结束但系统未放行，交由 watchdog 重试")  // 留给 watchdog 15s 内再试
                }
            }
        })

        // 2) 音频路由变化（拔耳机/断蓝牙）→ 重新拉起
        observers.append(nc.addObserver(    // 注册路由变化观察者
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main  // 耳机/蓝牙/听筒切换事件
        ) { [weak self] note in
            guard let info = note.userInfo, // 取路由变化附带信息
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,  // 变化原因原始值
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }  // 转枚举
            switch reason {                 // 只关心两种会断音的场景
            case .oldDeviceUnavailable:     // 旧设备移除（典型：拔掉有线耳机）
                self?.activateAndPlay(reason: "音频设备断开")  // 播放会随设备移除而停 → 立即重拉
            case .newDeviceAvailable:       // 新设备接入（如连上蓝牙耳机）
                self?.activateAndPlay(reason: "新音频设备接入")  // 顺手确保播放延续到新设备
            default:                        // 其他原因（类别变更等）不处理
                break
            }
        })

        // 3) 媒体服务被系统整体重置（极冷门但一击致命）→ 重建播放器
        observers.append(nc.addObserver(    // 注册媒体服务重置观察者（iOS 极端情况重启 mediaserverd）
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lg("系统重置了媒体服务，重建音频会话")  // 记录这种罕见事故
            self?.player = nil              // 旧播放器已随媒体服务失效，必须置空重建
            self?.activateAndPlay(reason: "媒体服务重置")  // 从头创建播放器并激活会话
        })

        // 4) 退后台 → 申请 30s 保护窗 + 1s 后确认仍在播（系统收音频有延迟，立刻查会误判）
        observers.append(nc.addObserver(    // 注册退后台观察者
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.beginBgWindow()           // 先抢 30s 后台执行窗：期间即使音频死掉 watchdog 也有窗口拉回
            self?.lg("进入后台，静音保活+位置兜底运行中")  // 让用户在日志里看到"已切后台但还在跑"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in  // 延迟 1 秒再查
                self?.ensure()              // 给系统留出接管时间后确认播放仍在（不在就拉起）
            }
        })

        // 5) 回前台 → 释放保护窗 + 检查一次
        observers.append(nc.addObserver(    // 注册回前台观察者
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.endBgWindow()             // 前台不需要保护窗，释放掉
            self?.ensure()                  // 回前台瞬间做一次健康检查
        })
    }

    private func installRemoteCommands() {  // 禁掉锁屏控制中心的暂停/停止键
        let cc = MPRemoteCommandCenter.shared()  // 系统级遥控命令中心（锁屏/控制中心/耳机线控共用）
        [cc.pauseCommand, cc.stopCommand, cc.togglePlayPauseCommand,  // 三个可能停掉播放的键
         cc.previousTrackCommand, cc.nextTrackCommand].forEach { cmd in  // 切歌键顺手也禁（切歌会打断播放）
            cmd.addTarget { _ in .commandFailed }  // 返回失败：用户按了没反应，播放不受影响
        }
        lg("锁屏控制键已禁用（防误按暂停导致挂起）")  // 日志说明
    }

    private func startWatchdog() {          // 启动周期看门狗（GCD 定时器）
        // v1.2：改 GCD DispatchSourceTimer——主 RunLoop Timer 在锁屏/滚动等 RunLoop mode 切换时会暂停
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)  // 派发到主队列（回调线程安全）
        t.schedule(deadline: .now() + 15, repeating: 15)  // 15s 周期：比 v1.1 的 20s 更密一点
        t.setEventHandler { [weak self] in self?.ensure() }  // 每次触发做健康检查，不在播就拉起
        t.resume()                          // GCD 定时器创建后是挂起态，必须手动 resume
        watchdog = t                        // 存句柄供 stop() 取消
    }

    private func beginBgWindow() {          // 退后台时申请 30s 后台执行保护窗
        guard bgTask == .invalid else { return }  // 已在保护窗内不重复申请
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "keepalive-window") { [weak self] in  // 到期回调
            self?.activateAndPlay(reason: "保护窗到期")  // 到期前最后拉一次音频（成功则重新获得运行资格）
            self?.endBgWindow()             // 无论成败都释放句柄（系统到期强制回收，不释放会被记录滥用）
        }
    }

    private func endBgWindow() {            // 释放后台保护窗（回前台/停保活时）
        guard bgTask != .invalid else { return }  // 没申请过就什么都不做
        UIApplication.shared.endBackgroundTask(bgTask)  // 归还系统
        bgTask = .invalid                   // 清句柄
    }

    // MARK: - 位置兜底（第二张后台牌照）

    private func setupLocation() {          // 配置并启动位置兜底
        lm.delegate = self                  // 回调挂在本类（didUpdateLocations 是挂起唤醒的关键通道）
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters  // 十米级精度：足以维持定位链路，不追求导航级耗电
        lm.distanceFilter = 100             // 移动 100 米才回调：省电；静态摆放时靠系统周期性刷新维持活跃
        lm.pausesLocationUpdatesAutomatically = false  // 关键：禁止系统自动暂停定位（否则牌照失效）
        if #available(iOS 9.0, *) {         // 后台定位许可（iOS 9+ API）
            lm.allowsBackgroundLocationUpdates = true  // 允许在后台继续收 GPS（需 UIBackgroundModes=location）
        }
        if #available(iOS 11.0, *) {        // iOS 11+ 才有此开关
            lm.showsBackgroundLocationIndicator = false  // 关掉状态栏蓝色定位胶囊的常驻指示
        }
        let st = CLLocationManager.authorizationStatus()  // 当前授权状态
        if st == .notDetermined {           // 从没问过用户 → 弹"始终允许"授权框
            lg("请求位置权限：选『始终允许』可获得双保险保活")  // 弹窗前先在日志里说明用途
            lm.requestAlwaysAuthorization() // 请求始终定位（弹窗含"仅使用期间"选项，用户可降级）
        } else {                            // 已有授权记录 → 直接按当前状态启停
            applyLocationPermission(st)     // 递给统一处理
        }
    }

    private func applyLocationPermission(_ st: CLAuthorizationStatus) {  // 按授权状态启停定位
        switch st {
        case .authorizedAlways:             // 始终允许：唯一能后台持续定位的档位
            lm.startUpdatingLocation()      // 开定位 → 获得独立于音频的第二张后台牌照
            lg("位置兜底已开启（双牌照保活）")  // 日志确认
        case .authorizedWhenInUse:          // 仅使用期间：后台拿不到定位 → 提示升级
            lg("位置权限为『仅使用期间』，后台不生效；到 设置→本App 改为『始终允许』更稳")  // 引导用户升级
        case .denied, .restricted:          // 拒绝/受限：只剩音频牌照
            lg("位置权限被拒绝，仅靠音频保活；如被杀可到 设置→本App 开启位置『始终允许』")  // 说明后果
        case .notDetermined:                // 理论上不会走到（start 时已处理）
            break
        @unknown default:                   // 未来新增状态
            break
        }
    }

    // MARK: - 音频资源生成

    /// 代码生成 440Hz 极低幅正弦波 WAV（8kHz 单声道 16bit，振幅约 0.2% 满幅）
    /// v1.2 弃用全零静音采样：非零数据确保解码器真实工作，系统无法按"数字静音"优化
    static func toneWav(seconds: Double) -> Data {  // 纯手工拼 WAV 文件字节流，无需打包音频资源
        let sampleRate = 8000               // 采样率 8kHz（无声无所谓音质，越小越省内存）
        let n = Int(Double(sampleRate) * seconds)  // 总采样点数 = 采样率 × 秒数
        let dataSize = n * 2                // 数据字节数 = 采样点数 × 每点 2 字节（16bit）
        var d = Data()                      // 输出字节缓冲
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }  // 写 4 字节小端整数
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }  // 写 2 字节小端整数
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + dataSize))  // WAV 头：RIFF 标识 + 整个文件大小-8
        d.append(contentsOf: Array("WAVE".utf8))  // WAVE 格式标识
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)  // fmt 块：块长 16 + PCM 格式(1) + 单声道(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)  // 采样率 + 字节率(采样率×2) + 块对齐(2) + 位深(16)
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(dataSize))  // data 块：标识 + 数据长度
        let amp = 60                        // 振幅 60/32767 ≈ 0.2% 满幅：解码器有真实数据，叠加 volume 1% 后完全无声
        for i in 0..<n {                    // 逐采样点生成正弦波
            let phase = Double(i) * 440.0 / Double(sampleRate) * 2.0 * Double.pi  // 440Hz 相位递增
            let s = Int16(round(Double(amp) * sin(phase)))  // 正弦采样值（±60 范围内摆动）
            withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }  // 写入 2 字节小端采样
        }
        return d                            // 返回完整合法的 WAV 字节流
    }
}

// MARK: - CLLocationManagerDelegate（位置回调 = 挂起唤醒通道）

extension KeepAlive: CLLocationManagerDelegate {  // delegate 扩展：定位授权变化与位置回调
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {  // iOS 14+ 授权状态变化
        applyLocationPermission(manager.authorizationStatus)  // 用户在弹窗选完（或设置里改了）→ 启停定位
    }

    func locationManager(_ manager: CLLocationManager,  // iOS 14 之前的老回调（低版本兼容，留着无害）
                         didChangeAuthorization status: CLAuthorizationStatus) {
        applyLocationPermission(status)     // 同上处理
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {  // 位置回调
        // ★核心通道：App 被挂起后（音频死透、watchdog 冻结），GPS 回调是唯一能把进程唤醒的 App 内手段；
        // 唤醒瞬间立即检查音频，死了就拉回——挂起态被位置"救活"回运行态
        DispatchQueue.main.async { [weak self] in  // 回到主线程操作播放器与日志
            guard let self = self, self.started else { return }  // 保活已停就不折腾
            self.ensure()                   // 拉回音频（不在播就重建）
            if Date().timeIntervalSince(self.lastLocLog) > 300 {  // 5 分钟记一条，证明兜底活着
                self.lastLocLog = Date()    // 刷新节流戳
                self.lg("位置兜底心跳正常")  // 低频日志：用户能看到兜底在跑
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {  // 定位失败
        guard started else { return }       // 已停止不刷日志
        if Date().timeIntervalSince(lastLocLog) > 300 {  // 同样 5 分钟节流（失败也会高频回调）
            lastLocLog = Date()             // 复用同一个节流戳
            lg("定位暂不可用：\(error.localizedDescription)（不影响音频保活）")  // 留痕但说明音频牌照还在
        }
    }
}
