import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    AgentRuntimeStore.shared.start()
    // Build verification: codesign test
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

    MenuBarExtra {
      MenuBarView()
        .environmentObject(AgentRuntimeStore.shared)
    } label: {
      MenuBarLabel()
    }
  }
}

/// Menu bar icon that overlays a small orange dot when permission requests are
/// pending, giving the user a visible cue without opening the menu.
struct MenuBarLabel: View {
  @ObservedObject private var store = AgentRuntimeStore.shared

  var body: some View {
    Image(systemName: "brain.head.profile")
      .overlay(alignment: .topTrailing) {
        if !store.pendingAXPermissionRequests.isEmpty {
          Circle()
            .fill(.orange)
            .frame(width: 7, height: 7)
            .offset(x: 1, y: -1)
        }
      }
  }
}
