import SwiftUI

/// 视图模型：承接引擎回调（倒序日志 / 状态 / 运行时长）
final class AppVM: ObservableObject {
    @Published var logLines: [String] = []
    @Published var status = "状态：未运行"
    @Published var uptime = "运行时间 --:--:--"
    @Published var running = false
    @Published var user: String
    @Published var pass: String
    @Published var voiceIdx: Int
    @Published var intervalIdx: Int

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        let d = UserDefaults.standard
        user = d.string(forKey: "cfg_user") ?? ""
        pass = d.string(forKey: "cfg_pass") ?? ""
        voiceIdx = min(max(MonitorEngine.voiceIndex, 0), MonitorEngine.VOICES.count - 1)
        intervalIdx = min(max(MonitorEngine.intervalIndex, 0), MonitorEngine.INTERVALS.count - 1)
        MonitorEngine.shared.onLog = { [weak self] s in self?.appendLog(s) }
        MonitorEngine.shared.onStatus = { [weak self] s, up in
            DispatchQueue.main.async {
                self?.status = "状态：\(s)"
                if !up.isEmpty { self?.uptime = "运行时间 \(up)" }
                self?.running = MonitorEngine.shared.running
            }
        }
    }

    func appendLog(_ s: String) {
        DispatchQueue.main.async {
            self.logLines.insert("[\(self.fmt.string(from: Date()))] \(s)", at: 0)
            while self.logLines.count > 300 { self.logLines.removeLast() }
        }
    }

    func startMonitor() {
        MonitorEngine.shared.start(user: user, pass: pass)
        appendLog("==== 启动监控 ====")
        running = true
    }

    func stopMonitor() {
        MonitorEngine.shared.stop()
        status = "状态：已停止"
        appendLog("==== 已停止 ====")
        running = false
    }
}

struct ContentView: View {
    @StateObject private var vm = AppVM()

    private let cyan = Color(red: 0, green: 0.898, blue: 1)
    private let logGreen = Color(red: 0.2, green: 1, blue: 0.4)

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.04, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    title
                    accountFields
                    voicePicker
                    intervalPicker
                    buttons
                    statusLine
                    logBox
                    uptimeLine
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var title: some View {
        VStack(spacing: 2) {
            Text("收款播报")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(cyan)
                .kerning(3)
            Text("QIXIANG · PAY · MONITOR")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .kerning(4)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 8)
        }
    }

    private var accountFields: some View {
        VStack(spacing: 10) {
            TextField("账号", text: $vm.user)
                .keyboardType(.phonePad)
                .textFieldStyle(input)
            SecureField("密码", text: $vm.pass)
                .textFieldStyle(input)
        }
    }

    private var voicePicker: some View {
        HStack {
            Text("音色").font(.system(size: 13)).foregroundColor(.gray)
            Picker("", selection: $vm.voiceIdx) {
                ForEach(0..<MonitorEngine.VOICES.count, id: \.self) { Text(MonitorEngine.VOICES[$0]).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: vm.voiceIdx) { MonitorEngine.voiceIndex = $0 }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private var intervalPicker: some View {
        HStack {
            Text("间隔").font(.system(size: 13)).foregroundColor(.gray)
            Picker("", selection: $vm.intervalIdx) {
                ForEach(0..<MonitorEngine.INTERVAL_LABELS.count, id: \.self) {
                    Text(MonitorEngine.INTERVAL_LABELS[$0]).tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: vm.intervalIdx) { nv in
                MonitorEngine.intervalIndex = nv
                vm.appendLog("[设置] 检测间隔改为 \(MonitorEngine.INTERVAL_LABELS[nv])\(vm.running ? "（运行中，下一轮生效）" : "")")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            button("开始监控", enabled: !vm.running) { vm.startMonitor() }
                .background(RoundedRectangle(cornerRadius: 8).fill(
                    LinearGradient(colors: [Color(red: 0, green: 0.55, blue: 0.45),
                                           Color(red: 0, green: 0.35, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom)))
            button("测试播报", enabled: true) { vm.appendLog("[tts] 触发测试播报（音色：\(MonitorEngine.VOICES[vm.voiceIdx])）"); MonitorEngine.voiceIndex = vm.voiceIdx; MonitorEngine.shared.testTts() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
            button("停止", enabled: vm.running) { vm.stopMonitor() }
                .background(RoundedRectangle(cornerRadius: 8).fill(
                    LinearGradient(colors: [Color(red: 0.72, green: 0.18, blue: 0.25),
                                           Color(red: 0.5, green: 0.12, blue: 0.18)],
                                   startPoint: .top, endPoint: .bottom)))
        }
    }

    private func button(_ t: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundColor(.white.opacity(enabled ? 1 : 0.45))
        }
        .disabled(!enabled)
    }

    private var statusLine: some View {
        Text(vm.status)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(cyan)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    /// 日志列表框：固定高度内滚，最新在第一条
    private var logBox: some View {
        ScrollView {
            Text(vm.logLines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(logGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 300)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
    }

    private var uptimeLine: some View {
        Text(vm.uptime)
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .kerning(1)
            .frame(maxWidth: .infinity)
    }
}

extension TextFieldStyle where Self == BasicTextFieldStyle {
    static var input: BasicTextFieldStyle { BasicTextFieldStyle() }
}

struct BasicTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
