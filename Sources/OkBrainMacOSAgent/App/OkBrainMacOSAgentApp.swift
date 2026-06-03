import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    AgentRuntimeStore.shared.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    AgentRuntimeStore.shared.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
struct OkBrainMacOSAgentApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Window("OkBrain macOS Agent", id: WindowID.main) {
      ContentView()
        .environmentObject(AgentRuntimeStore.shared)
        .frame(minWidth: 780, minHeight: 500)
    }
    .defaultSize(width: 920, height: 620)

    MenuBarExtra("OkBrain Agent", systemImage: "brain.head.profile") {
      MenuBarView()
        .environmentObject(AgentRuntimeStore.shared)
    }
  }
}
