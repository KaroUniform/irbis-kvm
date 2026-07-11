import AppKit
import SwiftUI

@main
struct IrbisKVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = KVMController()

    var body: some Scene {
        WindowGroup {
            KVMContentView(controller: controller)
                .onReceive(NotificationCenter.default.publisher(for: .irbisKVMWillTerminate)) { _ in
                    controller.emergencyRelease()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("На весь экран") {
                    controller.releaseInput()
                    (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit IrbisKVM") {
                    controller.emergencyRelease()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .irbisKVMWillTerminate, object: nil)
    }
}

extension Notification.Name {
    static let irbisKVMWillTerminate = Notification.Name("irbisKVMWillTerminate")
}
