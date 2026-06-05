import OkBrainMacOSAgentCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 16) {
            Toggle(
              isOn: Binding(
                get: { store.preventIdleSleepEnabled },
                set: { store.preventIdleSleepEnabled = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Prevent Idle Sleep")
                  .font(.headline)
                Text("Uses a per-process macOS activity assertion so remote screenshots stay available without sudo.")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
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

          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
              Text("Default")
                .foregroundStyle(.secondary)
              Text("On")
            }

            GridRow {
              Text("Activity")
                .foregroundStyle(.secondary)
              Text(activityText)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }

            GridRow {
              Text("Behavior")
                .foregroundStyle(.secondary)
              Text("Prevents idle display/system sleep while the agent is active; no global pmset settings are changed.")
            }
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

      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 16) {
            Toggle(
              isOn: Binding(
                get: { store.fileEditingEnabled },
                set: { store.fileEditingEnabled = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 4) {
                Text("File Editing")
                  .font(.headline)
                Text("Enables v2 fs.* RPCs. For now this is a simple app-level switch; per-root permissions will be added later.")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            StatusPill(
              title: fileEditingStatus,
              systemImage: store.configuration.fileEditing.enabled ? "checkmark.circle.fill" : "lock.doc",
              tint: store.configuration.fileEditing.enabled ? .green : .secondary
            )
          }

          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
              Text("Mode")
                .foregroundStyle(.secondary)
              Text(store.configuration.fileEditing.mode.rawValue)
                .font(.callout.monospaced())
            }

            GridRow {
              Text("Scope")
                .foregroundStyle(.secondary)
              Text(store.configuration.fileEditing.enabled ? "Any absolute root supplied by the request" : "Disabled")
            }

            GridRow {
              Text("Limits")
                .foregroundStyle(.secondary)
              Text("read \(store.configuration.fileEditing.limits.maxReadBytes) B • write \(store.configuration.fileEditing.limits.maxWriteBytes) B")
                .font(.callout.monospaced())
            }
          }
        }
        .padding(4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var activityText: String {
    store.idleSleepPrevention.activityDescription ?? "None"
  }

  private var fileEditingStatus: String {
    store.configuration.fileEditing.enabled ? "Enabled" : "Disabled"
  }
}

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