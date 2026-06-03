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
                Text("Prevent Idle System Sleep")
                  .font(.headline)
                Text("Keeps the agent awake for socket requests and screenshots. The display may still turn off.")
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
              Text("Assertion")
                .foregroundStyle(.secondary)
              Text(assertionText)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }

            GridRow {
              Text("Behavior")
                .foregroundStyle(.secondary)
              Text("Prevents idle system sleep only; does not force the display to stay on.")
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
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var assertionText: String {
    guard let assertionID = store.idleSleepPrevention.assertionID else {
      return "None"
    }

    return String(assertionID)
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
