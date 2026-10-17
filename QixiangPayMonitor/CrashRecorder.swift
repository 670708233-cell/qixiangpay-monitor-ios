import Foundation

/// 崩溃黑匣子：捕获未处理 NSException 与致命信号，写入 Documents/last_crash.txt。
/// 下次启动由 AppVM.consumePending() 读出显示在 UI 顶部红框，摆脱对爱思/系统日志的依赖。
/// 注意：C 函数指针不允许闭包捕获上下文，handler 一律用顶层全局函数。

private func _crashPath() -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("last_crash.txt").path
}

private func _writeCrash(_ text: String) {
    let fd = open(_crashPath(), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    text.withCString { p in
        _ = write(fd, p, strlen(p))
    }
    close(fd)
}

private func _exHandler(_ ex: NSException) {
    let sym = Thread.callStackSymbols.joined(separator: "\n")
    _writeCrash("[UncaughtException] \(ex.name.rawValue)\nreason: \(ex.reason ?? "-")\nstack:\n\(sym)\n")
}

private func _sigHandler(_ s: Int32) {
    // 先写最小头（纯 POSIX），再尽力补栈
    let head = "==== [Signal \(s)] ts=\(time(nil)) ====\n"
    head.withCString { p in
        let fd = open(_crashPath(), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 { _ = write(fd, p, strlen(p)); close(fd) }
    }
    let sym = Thread.callStackSymbols.joined(separator: "\n")
    _writeCrash("stack:\n\(sym)\n")
    // 恢复默认处理并重发，让系统正常终止（保留系统 tombstone）
    signal(s, SIG_DFL)
    raise(s)
}

enum CrashRecorder {

    /// App 启动最早时机调用（QixiangPayMonitorApp.init）
    static func install() {
        NSSetUncaughtExceptionHandler(_exHandler)
        for sig in [SIGABRT, SIGSEGV, SIGTRAP, SIGILL, SIGFPE, SIGBUS] {
            signal(sig, _sigHandler)
        }
    }

    /// AppVM 启动时调用：返回上次崩溃报告（有则显示），并清档防重复
    static func consumePending() -> String? {
        let path = _crashPath()
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        return text.prefix(4000).description
    }
}
