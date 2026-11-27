import SwiftUI

@main
struct HLSDownloaderApp: App {
    init() {
        AppDiagnostics.shared.log("APP", "应用进程启动")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
