import Foundation
import AVFoundation

/// 后台保活：静音音频循环播放（UIBackgroundModes=audio）。
/// iOS 无常驻前台服务，这是自用分发下锁屏/切后台继续轮询+播报的标准做法。
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav(seconds: 2))
            player?.numberOfLoops = -1
        }
        player?.volume = 0.01   // 近乎无声，但保持音频会话活跃
        player?.play()
    }

    func stop() {
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 代码生成静音 WAV（8kHz 单声道 16bit）
    static func silentWav(seconds: Double) -> Data {
        let sampleRate = 8000
        let n = Int(Double(sampleRate) * seconds)
        let dataSize = n * 2
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(dataSize))
        d.append(contentsOf: [UInt8](repeating: 0, count: dataSize))
        return d
    }
}
