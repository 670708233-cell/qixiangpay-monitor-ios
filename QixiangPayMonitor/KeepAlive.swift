import Foundation                 // 基础库：Timer、NotificationCenter、Data 等
import AVFoundation               // 音频框架：AVAudioSession（音频会话）、AVAudioPlayer（播放器）
import UIKit                      // UI 框架：UIApplication 的退后台/回前台通知

/// 后台保活：静音音频循环播放（UIBackgroundModes=audio）。
/// iOS 无常驻前台服务，这是自用分发下锁屏/切后台继续轮询+播报的标准做法。
/// 全链路自愈：来电/闹钟打断后恢复、拔耳机/断蓝牙后重拉、
/// 媒体服务重置后重建、退后台 1s 后主动检查、每 20s watchdog 兜底。
/// 任一自愈路径失效，MonitorEngine 轮询循环每轮还会调 ensure() 再兜一次。
final class KeepAlive {           // final：不允许被继承，单例语义更明确
    static let shared = KeepAlive()  // 全局单例：整个 App 共用一个保活器（音频会话也只能有一个）

    /// 引擎启动时接上（保活自愈事件写进 UI 日志，方便定位被系统掐掉的原因）
    var log: ((String) -> Void)?  // 日志回调：由 MonitorEngine 注入，把保活事件显示到界面日志框

    private var player: AVAudioPlayer?      // 静音循环播放器：靠它维持音频会话"在放声音"的状态
    private var watchdog: Timer?            // 看门狗定时器：每 20s 检查一次播放器是否还活着
    private var observers = [NSObjectProtocol]()  // 存所有通知观察者句柄，stop() 时统一移除防泄漏/重复
    private var started = false             // 保活开关状态：start/stop 幂等，防止重复装观察者

    private func lg(_ s: String) { log?("[保活] \(s)") }  // 统一加 [保活] 前缀再转发给引擎日志

    func start() {                          // 开始保活（引擎启动时调用）
        guard !started else { ensure(); return }  // 已在保活中 → 只做一次健康检查，不重复初始化
        started = true                      // 置位运行标志
        installObservers()                  // 装载 5 个系统通知观察者（打断/路由/重置/退后台/回前台）
        startWatchdog()                     // 启动 20s 周期看门狗
        activateAndPlay(reason: "启动")      // 首次激活音频会话并开始静音循环
    }

    func stop() {                           // 停止保活（引擎停止时调用）
        started = false                     // 先摘标志，watchdog/ensure 不再误拉起
        watchdog?.invalidate()              // 停掉看门狗定时器
        watchdog = nil                      // 释放引用
        observers.forEach { NotificationCenter.default.removeObserver($0) }  // 逐个注销系统通知观察者
        observers.removeAll()               // 清空句柄数组
        player?.stop()                      // 停止静音播放
        player = nil                        // 释放播放器（下次 start 会重建）
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])  // 释放音频会话，并通知其他 App 可以继续放音乐
    }

    /// 发现没在播就拉起（watchdog + 轮询循环双保险）
    func ensure() {                         // 健康检查入口：被外部（watchdog/引擎轮询）反复调用
        guard started else { return }       // 已停止则什么都不做
        if player == nil || player?.isPlaying != true {  // 播放器不存在 或 已不在播放 → 说明被系统掐了
            activateAndPlay(reason: "自愈拉起")  // 重新激活会话并续播
        }
    }

    // MARK: - 内部

    private func activateAndPlay(reason: String) {  // 激活音频会话 + 启动静音循环，reason 用于日志区分场景
        let session = AVAudioSession.sharedInstance()  // 取 App 唯一的音频会话对象
        do {
            // 独占音频会话（不 mix）：保活优先级最高，代价是会暂停其他 App 的音乐
            try session.setCategory(.playback, mode: .default)  // playback 类别 = 后台可播、锁屏不中断
            try session.setActive(true)     // 正式激活会话（此后 App 获得后台运行资格）
            if player == nil {              // 播放器尚未创建（首次 或 媒体服务重置后被置空）
                player = try AVAudioPlayer(data: Self.silentWav(seconds: 8))  // 用代码生成的 8 秒静音 WAV 创建播放器
                player?.numberOfLoops = -1  // -1 = 无限循环播完再播
                player?.prepareToPlay()     // 预加载音频缓冲，降低首次 play 延迟
            }
            player?.volume = 0.01           // 音量 1%：近乎无声但系统认定"在放音频"
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
                    self?.lg("打断结束但系统未放行，交由 watchdog 重试")  // 留给 watchdog 20s 内再试
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

        // 4) 退后台 → 1s 后确认仍在播（系统收音频有延迟，立刻查会误判）
        observers.append(nc.addObserver(    // 注册退后台观察者
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lg("进入后台，静音保活运行中")  // 让用户在日志里看到"已切后台但还在跑"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in  // 延迟 1 秒再查
                self?.ensure()              // 给系统留出接管时间后确认播放仍在（不在就拉起）
            }
        })

        // 5) 回前台 → 顺手检查一次
        observers.append(nc.addObserver(    // 注册回前台观察者
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.ensure()                  // 回前台瞬间做一次健康检查
        })
    }

    private func startWatchdog() {          // 启动周期看门狗
        // 音频会话活跃时主线程 Timer 后台照跑；每 20s 自检一次
        watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in  // 主 RunLoop 上 20s 一次
            self?.ensure()                  // 每次触发做健康检查，不在播就拉起
        }
    }

    /// 代码生成静音 WAV（8kHz 单声道 16bit）
    static func silentWav(seconds: Double) -> Data {  // 纯手工拼 WAV 文件字节流，无需打包音频资源
        let sampleRate = 8000               // 采样率 8kHz（静音无所谓音质，越小越省内存）
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
        d.append(contentsOf: [UInt8](repeating: 0, count: dataSize))  // 全 0 采样数据 = 静音
        return d                            // 返回完整合法的 WAV 字节流
    }
}
