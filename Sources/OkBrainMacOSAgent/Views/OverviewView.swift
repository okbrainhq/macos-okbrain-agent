import OkBrainMacOSAgentCore
import SwiftUI

struct OverviewView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .center, spacing: 12) {
        StatusPill(
          title: store.socketSnapshot.status.label,
          systemImage: store.socketSnapshot.status.systemImage,
          tint: store.socketSnapshot.status.tint
        )

        StatusPill(
          title: "Screen \(store.permissions.screenRecording.label)",
          systemImage: store.permissions.screenRecording.systemImage,
          tint: store.permissions.screenRecording.tint
        )

        Spacer()

        Button {
          store.refreshPermissions()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }

        Button {
          store.restartSocket()
        } label: {
          Label("Restart Socket", systemImage: "arrow.triangle.2.circlepath")
        }
      }

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 12) {
        GridRow {
          Text("Socket")
            .foregroundStyle(.secondary)
          Text(store.configuration.socketPath)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }

        GridRow {
          Text("Protocol")
            .foregroundStyle(.secondary)
          Text(AgentConfiguration.supportedProtocolVersions.joined(separator: ", "))
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }

        GridRow {
          Text("File Editing")
            .foregroundStyle(.secondary)
          StatusPill(
            title: fileEditingLabel,
            systemImage: store.configuration.fileEditing.enabled ? "doc.text.fill" : "doc.text.magnifyingglass",
            tint: store.configuration.fileEditing.enabled ? .green : .secondary
          )
        }

        GridRow {
          Text("Version")
            .foregroundStyle(.secondary)
          Text(store.configuration.version)
        }

        GridRow {
          Text("Accessibility")
            .foregroundStyle(.secondary)
          StatusPill(
            title: store.permissions.accessibility.label,
            systemImage: store.permissions.accessibility.systemImage,
            tint: store.permissions.accessibility.tint
          )
        }
      }

      GroupBox("Sleep") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Toggle(isOn: $store.preventIdleSleepEnabled) {
              Text("Prevent Idle Sleep").font(.headline)
            }
            .toggleStyle(.switch)
            Spacer(minLength: 12)
            StatusPill(
              title: store.idleSleepPrevention.state.label,
              systemImage: store.idleSleepPrevention.state.systemImage,
              tint: store.idleSleepPrevention.state.tint
            )
          }
          Text("Keeps your Mac awake while the agent runs. The display can still sleep.")
            .font(.callout)
            .foregroundStyle(.secondary)
          if let errorMessage = store.idleSleepPrevention.errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
          }
        }
        .padding(4)
      }

      HStack(spacing: 10) {
        Button {
          store.requestScreenRecordingAccess()
        } label: {
          Label("Screen Recording", systemImage: "rectangle.inset.filled.and.person.filled")
        }
        .buttonStyle(.borderedProminent)

        Button {
          store.requestAccessibilityAccess()
        } label: {
          Label("Accessibility", systemImage: "figure")
        }
      }

      if let errorMessage = store.socketSnapshot.errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .onAppear {
      store.refreshPermissions()
    }
  }

  private var fileEditingLabel: String {
    store.configuration.fileEditing.enabled ? "Enabled • \(store.configuration.fileEditing.mode.rawValue)" : "Disabled"
  }
}

private extension IdleSleepPreventionSnapshot.State {
  var label: String {
    switch self {
    case .disabled: "Disabled"
    case .inactive: "Inactive"
    case .active: "Active"
    case .failed: "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .disabled: "pause.circle"
    case .inactive: "clock"
    case .active: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .disabled, .inactive: .secondary
    case .active: .green
    case .failed: .red
    }
  }
}
