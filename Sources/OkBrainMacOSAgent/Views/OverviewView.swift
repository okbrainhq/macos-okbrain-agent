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
    guard store.configuration.fileEditing.enabled else {
      return "Disabled"
    }

    let rootCount = store.configuration.fileEditing.allowedRoots.count
    return "\(store.configuration.fileEditing.mode.rawValue) • \(rootCount) root\(rootCount == 1 ? "" : "s")"
  }
}
