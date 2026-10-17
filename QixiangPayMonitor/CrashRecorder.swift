import Foundation

/// 崩溃黑匣子：捕获未处理 NSException 与致命信号，写入 Documents/last_crash.txt。
/// 下次启动由 AppVM.consumePending() 读出显示在 UI 顶部红框，摆脱对爱思/系统日志的依赖。
enum CrashRecorder {

    static var crashFilePath: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("last_crash.txt")
    }

    /// App 启动最早时机调用（QixiangPayMonitorApp.init）
    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let sym = Thread.callStackSymbols.joined(separator: "\n")
            writeCrash("[UncaughtException] \(ex.name.rawValue)\nreason: \(ex.reason ?? "-")\nstack:\n\(sym)\n")
        }
        for sig in [SIGABRT, SIGSEGV, SIGTRAP, SIGILL, SIGFPE, SIGBUS] {
            signal(sig) { s in
                // 先写最小头（纯 POSIX，async-signal-safe），再尽力补栈
                let head = "==== [Signal \(s)] ts=\(time(nil)) ====\n"
                head.withCString { p in
                    _ = write(crashFD(), p, strlen(p))
                }
                let sym = Thread.callStackSymbols.joined(separator: "\n")
                let body = "stack:\n\(sym)\n"
                body.withCString { p in
                    _ = write(crashFD(), p, strlen(p))
                }
                // 恢复默认处理并重发，让系统正常终止（保留系统 tombstone）
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func crashFD() -> Int32 {
        let path = crashFilePath.path
        return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }

    private static func writeCrash(_ text: String) {
        let path = crashFilePath.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        text.withCString { p in
            _ = write(fd, p, strlen(p))
        }
        close(fd)
    }

    /// AppVM 启动时调用：返回上次崩溃报告（有则显示），并清档防重复
    static func consumePending() -> String? {
        let path = crashFilePath.path
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: crashFilePath)
        return text.prefix(4000).description
    }
}
