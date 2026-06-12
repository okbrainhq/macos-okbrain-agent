import OkBrainMacOSAgentCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // MARK: - Prevent Idle Sleep
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center) {
            Toggle(
              isOn: Binding(
                get: { store.preventIdleSleepEnabled },
                set: { store.preventIdleSleepEnabled = $0 }
              )
            ) {
              Text("Prevent Idle Sleep")
                .font(.headline)
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            StatusPill(
              title: store.idleSleepPrevention.state.label,
              systemImage: store.idleSleepPrevention.state.systemImage,
              tint: store.idleSleepPrevention.state.tint
            )
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            InfoRow(
              icon: "display",
              text: "Keeps your Mac awake so the agent can always respond. Your screen can still turn off normally to save power."
            )

            InfoRow(
              icon: "wake",
              text: "When the display is off, the agent will briefly wake it to take screenshots, then let it sleep again."
            )

            InfoRow(
              icon: "lock.screen",
              text: "You can lock your screen — the agent keeps working. However, screenshots are unavailable while locked."
            )

            InfoRow(
              icon: "gearshape",
              text: "Tip: Set your Mac's auto-lock to \"Never\" so the screen turns off without locking, allowing screenshots to work."
            )

            InfoRow(
              icon: "shield.checkered",
              text: "No system settings are changed. Sleep prevention only applies while this app is running."
            )
          }

          if let errorMessage = store.idleSleepPrevention.errorMessage {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
        .padding(4)
      }

      // MARK: - File Editing
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center) {
            Toggle(
              isOn: Binding(
                get: { store.fileEditingEnabled },
                set: { store.fileEditingEnabled = $0 }
              )
            ) {
              Text("File Editing")
                .font(.headline)
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            StatusPill(
              title: fileEditingStatus,
              systemImage: store.configuration.fileEditing.enabled ? "checkmark.circle.fill" : "lock.doc",
              tint: store.configuration.fileEditing.enabled ? .green : .secondary
            )
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            InfoRow(
              icon: "doc.text",
              text: "Allows the agent to read and write files on your Mac. Disabled by default — you stay in control."
            )

            InfoRow(
              icon: "folder.badge.gearshape",
              text: "Access is restricted to folders you explicitly allow. The agent cannot touch anything outside those boundaries."
            )

            InfoRow(
              icon: "lock.open",
              text: "Each folder rule can be set to read-only or read-write, so you decide exactly what the agent can do."
            )

            InfoRow(
              icon: "shield.checkered",
              text: "Built-in size limits protect against accidental huge writes. Access stays limited to the folders you allow."
            )

            HStack(spacing: 6) {
              Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
              Text("\(store.filePermissionRules.count) folder rule\(store.filePermissionRules.count == 1 ? "" : "s") configured")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var fileEditingStatus: String {
    store.configuration.fileEditing.enabled ? "Enabled" : "Disabled"
  }
}

// MARK: - Info Row

private struct InfoRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .padding(.top, 1)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - State Extensions

private extension IdleSleepPreventionSnapshot.State {
  var label: String {
    switch self {
    case .disabled:
      "Disabled"
    case .inactive:
      "Inactive"
    case .active:
      "Active"
    case .failed:
      "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .disabled:
      "pause.circle"
    case .inactive:
      "clock"
    case .active:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch self {
    case .disabled, .inactive:
      .secondary
    case .active:
      .green
    case .failed:
      .red
    }
  }
}
