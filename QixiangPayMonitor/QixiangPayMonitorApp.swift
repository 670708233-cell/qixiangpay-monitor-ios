import SwiftUI

@main
struct QixiangPayMonitorApp: App {
    init() {
        CrashRecorder.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
