import AppKit
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    Button("Show Window") {
      openWindow(id: WindowID.main)
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }

    Button("Capture Screenshot") {
      store.captureFullScreenProbe()
      openWindow(id: WindowID.main)
    }
    .disabled(store.isCapturing)

    Divider()

    Button("Restart Socket") {
      store.restartSocket()
    }

    Divider()

    Button("Quit OkBrain Agent") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
