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

    if !store.pendingAXPermissionRequests.isEmpty {
      Menu("Pending permission requests (\(store.pendingAXPermissionRequests.count))") {
        ForEach(store.pendingAXPermissionRequests) { request in
          Menu("\(request.intent.label) — \(request.target.displayName)") {
            Button("Allow \(request.intent.label) Once") {
              store.resolvePendingAXPermissionRequest(id: request.id, resolution: .allowOnce)
            }
            Button("Always Allow \(request.intent.label)") {
              store.resolvePendingAXPermissionRequest(id: request.id, resolution: .allowAlways)
            }
            Divider()
            Button("Dismiss") {
              store.resolvePendingAXPermissionRequest(id: request.id, resolution: .dismiss)
            }
          }
        }
      }
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
