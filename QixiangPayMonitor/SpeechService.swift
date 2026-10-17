import Foundation
import AVFoundation

/// TTS 播报：7 音色预设（pitch/rate），单源 MonitorEngine.VOICES/PITCH/RATE。
/// iOS rate 尺度（0~1，默认 0.5）与 Android（1.0 正常）不同，按 0.5×AndroidRate 换算。
final class SpeechService {
    static let shared = SpeechService()

    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let idx = min(max(MonitorEngine.voiceIndex, 0), MonitorEngine.VOICES.count - 1)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.pitchMultiplier = MonitorEngine.PITCH[idx]
        u.rate = 0.5 * MonitorEngine.RATE[idx]
        u.volume = 1.0
        u.postUtteranceDelay = 0.1
        synth.speak(u)
        MonitorEngine.shared.onLog?("[播报] \(text)（音色：\(MonitorEngine.VOICES[idx])）")
    }
}
