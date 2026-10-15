import AppKit
import SwiftUI

/// Shared tab selection so views can route the user (e.g. "去下载模型").
@MainActor
final class TabRouter: ObservableObject {
    @Published var selection = 0
}

/// Receives files dragged onto the Dock icon / opened via "打开方式", and
/// flushes unsaved edits on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppState.shared.enqueue(urls: urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.saveSession()
        }
    }
}

@main
struct FCPSubtitleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = TabRouter()
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup(state.windowTitle) {
            TabView(selection: $router.selection) {
                ContentView()
                    .tabItem { Label("生成字幕", systemImage: "captions.bubble") }
                    .tag(0)
                ModelsView()
                    .tabItem { Label("模型管理", systemImage: "square.and.arrow.down") }
                    .tag(1)
            }
            .environmentObject(router)
            .frame(minWidth: 820, minHeight: 500)
        }

        Settings {
            SettingsView()
        }
    }
}
