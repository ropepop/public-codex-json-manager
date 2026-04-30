import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }
}

@main
struct CodexAuthRotatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        _store = StateObject(wrappedValue: AppRuntimeConfiguration.makeStore())
    }

    var body: some Scene {
        WindowGroup("Codex Auth Rotator") {
            ContentView()
                .environmentObject(store)
                .frame(
                    minWidth: MainWindowLayout.minimumWidth,
                    minHeight: MainWindowLayout.minimumHeight
                )
                .task {
                    await store.start()
                }
        }
        .defaultSize(width: MainWindowLayout.defaultWidth, height: MainWindowLayout.defaultHeight)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Refresh Now") {
                    Task {
                        await store.refresh(manual: true)
                    }
                }
                .disabled(store.isRefreshing || store.isSwitching)
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Find Accounts") {
                    NotificationCenter.default.post(name: .focusAccountSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
